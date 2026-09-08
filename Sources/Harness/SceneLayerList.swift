import AppKit

/// Frontmost layer first, with native selection and local drag ordering.
final class SceneLayerList: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = LayerTableView()
    private var names: [String] = []
    weak var target: AnyObject?
    var action: Selector?
    var onReorder: ((Int, Int) -> Void)?
    var indexOfSelectedItem: Int { table.selectedRow < 0 ? -1 : names.count - 1 - table.selectedRow }
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
            self.onReorder?(self.names.count - 1 - source, self.names.count - 1 - destination)
        }
        documentView = table
        hasVerticalScroller = true
        drawsBackground = false
        table.setAccessibilityLabel("Scene layers, front to back")
    }
    override func layout() {
        super.layout()
        table.setFrameSize(NSSize(width: contentSize.width, height: max(contentSize.height, CGFloat(names.count) * table.rowHeight)))
        table.sizeLastColumnToFit()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func removeAllItems() { names.removeAll(); table.reloadData() }
    func addItems(withTitles titles: [String]) { names = titles; table.reloadData() }
    func selectItem(at index: Int) {
        guard names.indices.contains(index) else { return }
        table.selectRowIndexes(IndexSet(integer: names.count - 1 - index), byExtendingSelection: false)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { names.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(labelWithString: names[names.count - 1 - row])
        field.lineBreakMode = .byTruncatingMiddle
        return field
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
