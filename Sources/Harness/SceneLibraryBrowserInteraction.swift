import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

extension SceneLibraryController {
    func select(_ item: Item?) {
        let previousID = selected?.id
        selected = item
        let index = item.flatMap { chosen in items.firstIndex(where: { $0.id == chosen.id }) }
        synchronizeSelectionViews(index: index, reveal: false)
        if previousID != item?.id { hideQuickPreview() }
        preview()
    }

    func synchronizeSelectionViews(index: Int?, reveal: Bool) {
        synchronizingSelection = true
        defer { synchronizingSelection = false }
        if let index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            let path = IndexPath(item: index, section: 0)
            collectionView.selectionIndexPaths = Set([path])
            if reveal {
                table.scrollRowToVisible(index)
                collectionView.scrollToItems(at: Set([path]), scrollPosition: .nearestVerticalEdge)
            }
        } else {
            table.deselectAll(nil)
            collectionView.selectionIndexPaths = []
        }
    }

    @objc func changeViewMode() {
        viewMode = viewModeControl.selectedSegment == 0 ? .gallery : .list
        galleryScroll.isHidden = viewMode != .gallery
        listScroll.isHidden = viewMode != .list
        if let selected, let index = items.firstIndex(where: { $0.id == selected.id }) {
            synchronizeSelectionViews(index: index, reveal: true)
        }
        collectionView.collectionViewLayout?.invalidateLayout()
        DispatchQueue.main.async { [weak self] in self?.updateThumbnailDemand() }
    }

    func windowDidResize(_ notification: Notification) {
        collectionView.collectionViewLayout?.invalidateLayout()
        DispatchQueue.main.async { [weak self] in self?.updateThumbnailDemand() }
    }

    @objc func browserDidScroll(_ notification: Notification) {
        updateThumbnailDemand()
    }

    func handleCommonKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
            presentationWindow?.makeFirstResponder(search)
            return true
        }
        return false
    }

    func handleGalleryKey(_ event: NSEvent) -> Bool {
        if handleCommonKey(event) { return true }
        if event.keyCode == 36 || event.keyCode == 76 { useScene(); return true }
        if event.keyCode == 49 { toggleQuickPreview(); return true }
        if event.keyCode == 51 || event.keyCode == 117 { removalKeyNotice(); return true }
        guard [123, 124, 125, 126].contains(event.keyCode), !items.isEmpty else { return false }
        let current = selected.flatMap { chosen in items.firstIndex(where: { $0.id == chosen.id }) } ?? 0
        let columns = galleryMetrics(for: collectionView.bounds.width).columns
        let destination = Self.galleryDestination(current: current, keyCode: event.keyCode,
                                                  columns: columns, count: items.count)
        guard destination != current else { return true }
        selected = items[destination]
        synchronizeSelectionViews(index: destination, reveal: true)
        hideQuickPreview()
        preview()
        return true
    }

    static func galleryDestination(current: Int, keyCode: UInt16, columns: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let step: Int
        switch keyCode {
        case 123: step = -1
        case 124: step = 1
        case 125: step = max(1, columns)
        case 126: step = -max(1, columns)
        default: step = 0
        }
        return min(max(0, current + step), count - 1)
    }

    func removalKeyNotice() {
        detail.stringValue = selected?.entry == nil
            ? "Included wallpapers stay in the Library."
            : "Use More → Remove Library Reference… to remove this entry. The source file stays in place."
    }

    func toggleQuickPreview() {
        if quickPreviewPanel?.isVisible == true { hideQuickPreview(); return }
        guard let selected, let image = poster.image else {
            detail.stringValue = "The larger still preview is still preparing."
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.backgroundColor = .black
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        let imageView = NSImageView(frame: panel.contentView!.bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = image
        imageView.setAccessibilityLabel(selected.title + " large still preview")
        panel.contentView?.addSubview(imageView)
        if let screen = presentationWindow?.screen ?? NSScreen.main {
            let size = NSSize(width: min(960, screen.visibleFrame.width * 0.82),
                              height: min(540, screen.visibleFrame.height * 0.82))
            let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                                 y: screen.visibleFrame.midY - size.height / 2)
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
        quickPreviewPanel = panel
    }

    func hideQuickPreview() {
        quickPreviewPanel?.orderOut(nil)
        quickPreviewPanel = nil
    }

}
