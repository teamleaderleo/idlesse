import AppKit

/// Frontmost layer first, with native selection and local drag ordering.
final class SceneLayerList: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = LayerTableView()
    private var roots: [SceneNode] = []
    private var rows: [(index: Int, depth: Int)] = []
    private var expanded = Set<UUID>()
    private var nodes: [SceneNode] = []
    var onVisibility: ((Int) -> Void)?
    var onLock: ((Int) -> Void)?
    weak var target: AnyObject?
    var action: Selector?
    var onReorder: ((Int, Int) -> Void)?
    var indexOfSelectedItem: Int { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].index : -1 }
    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: .init("layer"))
        column.title = "Layers"
        column.width = 170
        table.frame = NSRect(x: 0, y: 0, width: 170, height: 200)
        table.autoresizingMask = [.width]
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 36
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.onMove = { [weak self] source, destination in
            guard let self else { return }
            guard self.rows.indices.contains(source), self.rows.indices.contains(destination) else { return }
            self.onReorder?(self.rows[source].index, self.rows[destination].index)
        }
        documentView = table
        hasVerticalScroller = true
        drawsBackground = false
        table.setAccessibilityLabel("Scene layers, front to back")
    }
    override func layout() {
        super.layout()
        table.setFrameSize(NSSize(width: contentSize.width, height: max(contentSize.height, CGFloat(rows.count) * table.rowHeight)))
        table.sizeLastColumnToFit()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func removeAllItems() { rows.removeAll(); table.reloadData() }
    func setNodes(_ roots: [SceneNode]) {
        self.roots = roots
        nodes = roots.flatMap { $0.descendants }
        expanded.formIntersection(Set(nodes.map { $0.id }))
        rebuildRows()
    }
    private func rebuildRows() {
        rows.removeAll()
        let indices = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        func visit(_ level: [SceneNode], depth: Int) {
            for node in level.reversed() {
                rows.append((indices[node.id]!, depth))
                if expanded.contains(node.id) { visit(node.children, depth: depth + 1) }
            }
        }
        visit(roots, depth: 0)
        table.reloadData(); needsLayout = true
    }
    @objc private func disclosure(_ sender: NSButton) {
        let node = nodes[sender.tag]
        if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
        rebuildRows()
        selectItem(at: sender.tag)
    }
    @objc private func visibility(_ sender: NSButton) { onVisibility?(sender.tag) }
    @objc private func lock(_ sender: NSButton) { onLock?(sender.tag) }
    func selectItem(at index: Int) {
        guard nodes.indices.contains(index) else { return }
        let id = nodes[index].id
        let ancestors = nodes.filter { $0.kind == .group && $0.id != id && $0.descendants.contains { $0.id == id } }
        if ancestors.contains(where: { !expanded.contains($0.id) }) {
            expanded.formUnion(ancestors.map { $0.id }); rebuildRows()
        }
        guard let row = rows.firstIndex(where: { $0.index == index }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let index = rows[row].index
        let node = nodes[index]
        let icon = NSImageView(image: NSImage(systemSymbolName: node.kind == .image ? "photo" : node.kind == .video ? "film" : node.kind == .group ? "folder" : "sparkles", accessibilityDescription: node.kind.rawValue)!)
        let field = NSTextField(labelWithString: node.displayName)
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = node.displayName
        field.textColor = node.visible ? .labelColor : .secondaryLabelColor
        let eye = NSButton(image: NSImage(systemSymbolName: node.visible ? "eye" : "eye.slash", accessibilityDescription: node.visible ? "Hide layer" : "Show layer")!, target: self, action: #selector(visibility))
        let lock = NSButton(image: NSImage(systemSymbolName: node.locked ? "lock.fill" : "lock.open", accessibilityDescription: node.locked ? "Unlock layer" : "Lock layer")!, target: self, action: #selector(lock))
        for button in [eye, lock] { button.tag = index; button.isBordered = false; button.widthAnchor.constraint(equalToConstant: 22).isActive = true }
        eye.toolTip = node.visible ? "Hide layer" : "Show layer"
        lock.toolTip = node.locked ? "Unlock canvas editing" : "Lock canvas editing"
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let indentation = NSView()
        indentation.widthAnchor.constraint(equalToConstant: CGFloat(rows[row].depth * 12)).isActive = true
        let disclosure = NSButton(image: NSImage(systemSymbolName: expanded.contains(node.id) ? "chevron.down" : "chevron.right", accessibilityDescription: expanded.contains(node.id) ? "Collapse group" : "Expand group")!, target: self, action: #selector(disclosure))
        disclosure.tag = index; disclosure.isBordered = false
        disclosure.isHidden = node.kind != .group
        disclosure.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let stack = NSStackView(views: [indentation, disclosure, icon, field, eye, lock])
        stack.spacing = 4
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if indexOfSelectedItem >= 0, let action { NSApp.sendAction(action, to: target, from: self) }
    }
}

private final class LayerTableView: NSTableView {
    var onMove: ((Int, Int) -> Void)?
    private var sourceRow: Int?
    private var insertionRow: Int?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return }
        window?.makeFirstResponder(self)
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        sourceRow = row
    }
    override func mouseDragged(with event: NSEvent) {
        guard sourceRow != nil else { return }
        autoscroll(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let row = row(at: p)
        insertionRow = row < 0 ? (p.y < 0 ? 0 : numberOfRows) : row + (p.y > rect(ofRow: row).midY ? 1 : 0)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { sourceRow = nil; insertionRow = nil; needsDisplay = true }
        guard let sourceRow, let insertionRow else { return }
        let destination = max(0, min(numberOfRows - 1, insertionRow > sourceRow ? insertionRow - 1 : insertionRow))
        if sourceRow != destination { onMove?(sourceRow, destination) }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let insertionRow else { return }
        let y = insertionRow < numberOfRows ? rect(ofRow: insertionRow).minY : rect(ofRow: numberOfRows - 1).maxY
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 4, y: y))
        line.line(to: NSPoint(x: bounds.width - 4, y: y))
        line.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        line.stroke()
    }
}


/// Local effect edits are committed together by the Appearance sheet.
final class SceneEffectsEditor: NSStackView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let table = NSTableView()
    private let kind = NSPopUpButton(frame: .zero, pullsDown: false)
    private let amount = NSTextField(string: "")
    private let rangeLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton(title: "+ Effect", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let kinds: [SceneNode.Style.Effect.Kind] = [.bloom, .blur, .exposure, .saturation, .vignette]
    private let dragType = NSPasteboard.PasteboardType("app.idlesse.effect-row")
    private let owner = UUID().uuidString
    private var effects: [SceneNode.Style.Effect]
    private var drafts: [UUID: String] = [:]
    init(effects: [SceneNode.Style.Effect]) {
        self.effects = effects
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        widthAnchor.constraint(equalToConstant: 280).isActive = true
        let column = NSTableColumn(identifier: .init("effect"))
        column.width = 260
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 28
        table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("Ordered effects, first applied first")
        table.registerForDraggedTypes([dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.widthAnchor.constraint(equalToConstant: 280).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        addArrangedSubview(scroll)
        addButton.target = self; addButton.action = #selector(addEffect)
        removeButton.target = self; removeButton.action = #selector(removeEffect)
        addArrangedSubview(NSStackView(views: [addButton, removeButton]))
        kind.addItems(withTitles: kinds.map { $0.rawValue.capitalized })
        kind.target = self; kind.action = #selector(changeKind)
        kind.setAccessibilityLabel("Selected effect type")
        amount.setAccessibilityLabel("Selected effect amount")
        amount.delegate = self
        kind.widthAnchor.constraint(equalToConstant: 150).isActive = true
        amount.widthAnchor.constraint(equalToConstant: 110).isActive = true
        addArrangedSubview(NSStackView(views: [kind, amount]))
        addArrangedSubview(rangeLabel)
        if !effects.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateSelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func numberOfRows(in tableView: NSTableView) -> Int { effects.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: "\(row + 1).  \(effects[row].type.rawValue.capitalized)")
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    private func updateSelection() {
        let selected = effects.indices.contains(table.selectedRow)
        kind.isEnabled = selected; amount.isEnabled = selected; removeButton.isEnabled = selected
        addButton.isEnabled = effects.count < 8
        guard selected else { amount.stringValue = ""; rangeLabel.stringValue = "Add an effect to begin."; return }
        let effect = effects[table.selectedRow]
        kind.selectItem(at: kinds.firstIndex(of: effect.type)!)
        amount.stringValue = effect.id.flatMap { drafts[$0] } ?? String(effect.amount)
        rangeLabel.stringValue = "Amount: \(effect.range.lowerBound)…\(effect.range.upperBound)"
    }
    func controlTextDidChange(_ notification: Notification) {
        guard effects.indices.contains(table.selectedRow), let id = effects[table.selectedRow].id else { return }
        drafts[id] = amount.stringValue
    }
    @objc private func addEffect() {
        guard effects.count < 8 else { return }
        effects.append(.init(type: .bloom, amount: 0.8))
        table.reloadData(); table.selectRowIndexes(IndexSet(integer: effects.count - 1), byExtendingSelection: false)
        updateSelection()
    }
    @objc private func removeEffect() {
        let index = table.selectedRow
        guard effects.indices.contains(index) else { return }
        if let id = effects[index].id { drafts.removeValue(forKey: id) }
        effects.remove(at: index); table.reloadData()
        if !effects.isEmpty { table.selectRowIndexes(IndexSet(integer: min(index, effects.count - 1)), byExtendingSelection: false) }
        updateSelection()
    }
    @objc private func changeKind() {
        guard effects.indices.contains(table.selectedRow) else { return }
        let index = table.selectedRow
        effects[index].type = kinds[kind.indexOfSelectedItem]
        effects[index].amount = effects[index].type == .blur ? 8 : effects[index].type == .exposure ? 0 : 1
        if let id = effects[index].id { drafts.removeValue(forKey: id) }
        table.reloadData(); table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        updateSelection()
    }
    func validatedEffects() throws -> [SceneNode.Style.Effect] {
        if effects.indices.contains(table.selectedRow), let id = effects[table.selectedRow].id { drafts[id] = amount.stringValue }
        return try effects.map { effect in
            var result = effect
            if let text = effect.id.flatMap({ drafts[$0] }) {
                guard let value = Double(text), value.isFinite else { throw SceneError.invalid("Enter a finite effect amount.") }
                result.amount = value
            }
            guard result.range.contains(result.amount) else { throw SceneError.invalid("\(result.type.rawValue.capitalized) amount must be \(result.range.lowerBound)…\(result.range.upperBound).") }
            return result
        }
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard effects.indices.contains(row), let id = effects[row].id else { return nil }
        let item = NSPasteboardItem(); item.setString(owner + ":" + id.uuidString, forType: dragType); return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard operation == .above, let value = info.draggingPasteboard.string(forType: dragType),
              value.hasPrefix(owner + ":") else { return [] }
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard (0...effects.count).contains(row), let value = info.draggingPasteboard.string(forType: dragType),
              value.hasPrefix(owner + ":"), let id = UUID(uuidString: String(value.dropFirst(owner.count + 1))),
              let index = effects.firstIndex(where: { $0.id == id }) else { return false }
        let effect = effects.remove(at: index)
        let destination = row > index ? row - 1 : row
        effects.insert(effect, at: destination)
        table.reloadData(); table.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        updateSelection(); return true
    }
}
