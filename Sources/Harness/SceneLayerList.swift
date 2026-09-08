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
