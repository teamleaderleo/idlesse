import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

extension SceneLibraryController {
    static func smokeTest(outputURL: URL, videoURL: URL? = nil) throws {
        assertGalleryPolicySmoke()

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("library-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("revision.png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: raw)
        let oldRevision = try PosterRevision.read(raw)
        try Data([1, 2]).write(to: raw)
        let newRevision = try PosterRevision.read(raw)
        precondition(oldRevision != newRevision)

        var copied = false
        var applied = false
        let controller = try SceneLibraryController(indexURL: folder.appendingPathComponent("index.json"),
            onUse: { _ in applied = true }, onEdit: { _, asCopy in copied = asCopy })
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([raw as NSURL, folder.appendingPathComponent("ignored.txt") as NSURL])
        precondition(controller.droppedURLs(pasteboard) == [raw])
        precondition(controller.items.count == 8 && controller.items.contains { $0.title == "Desk Clock" })
        precondition(controller.sourceActions.itemArray.contains { $0.title == "Add Source…" })
        precondition(controller.sidebarRows.contains { $0.kind == .all })
        precondition(controller.sidebarRows.contains { $0.kind == .favorites })
        precondition(controller.collectionView.numberOfItems(inSection: 0) == controller.items.count)

        try runGalleryCatalogSmoke(controller: controller, folder: folder)

        let index = controller.items.firstIndex { $0.title == "Undertow" }!
        controller.selected = controller.items[index]
        controller.synchronizeSelectionViews(index: index, reveal: false)
        controller.preview()
        let deadline = Date().addingTimeInterval(10)
        while controller.task != nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(controller.poster.image != nil, controller.detail.stringValue)
        let colors = NSBitmapImageRep(data: controller.poster.image!.tiffRepresentation!)!
        var hasWarmColor = false
        for y in stride(from: 0, to: colors.pixelsHigh, by: 32) {
            for x in stride(from: 0, to: colors.pixelsWide, by: 32) {
                if let color = colors.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent - color.blueComponent > 0.2 {
                    hasWarmColor = true
                }
            }
        }
        precondition(hasWarmColor, "Undertow's copper poster must preserve BGRA channel order")

        let selectionBeforeModeChange = controller.selected?.id
        controller.viewModeControl.selectedSegment = 1
        controller.changeViewMode()
        precondition(controller.selected?.id == selectionBeforeModeChange &&
                     controller.table.selectedRow == index)
        controller.viewModeControl.selectedSegment = 0
        controller.changeViewMode()
        precondition(controller.collectionView.selectionIndexPaths.first?.item == index)

        controller.editScene()
        precondition(copied, "Built-in edits must become drafts")
        controller.table.deselectAll(nil)
        controller.doubleClickScene()
        precondition(!applied, "An empty-space double-click must not apply the selection")

        controller.selected = controller.items[index]
        controller.synchronizeSelectionViews(index: index, reveal: false)
        controller.toggleFavorite()
        controller.filter.selectItem(at: 3)
        controller.reload()
        precondition(controller.items.count == 1 && controller.items[0].title == "Undertow")
        precondition(controller.selected?.id == controller.items[0].id)
        precondition(controller.collectionView.selectionIndexPaths.first?.item == 0)

        let collection = try controller.store.createCollection(name: "Psychedelic")
        try controller.store.toggleMembership(sceneID: controller.selected!.id, collectionID: collection.id)
        controller.reload()
        controller.filter.selectItem(at:
            controller.filter.itemArray.firstIndex {
                ($0.representedObject as? String) == collection.id
            }!)
        controller.reload()
        precondition(controller.items.count == 1 && controller.selected?.title == "Undertow")
        precondition(controller.sidebarRows.contains { $0.kind == .collection(collection.id) })
        precondition(controller.collectionActions.itemArray.contains { $0.title == "Rename Collection…" })

        controller.collectionActions.selectItem(withTitle: "Shuffle Collection")
        controller.collectionAction()
        precondition(applied && controller.rotationTimer != nil)
        applied = false
        controller.rotationTimer?.fire()
        precondition(applied, "Rotation timer must apply the next scene")
        controller.stopRotation()
        precondition(controller.rotationTimer == nil && controller.rotationCollectionID == nil)

        try controller.store.setPlayback(collection.id, .init(startMinute: 0, endMinute: 720))
        let today = Calendar.current.startOfDay(for: Date())
        let morning = Calendar.current.date(byAdding: .hour, value: 1, to: today)!
        applied = false
        controller.checkSchedule(now: morning)
        precondition(applied && controller.rotationTimer != nil)
        controller.stopRotation()
        applied = false
        controller.checkSchedule(now: morning.addingTimeInterval(60))
        precondition(!applied && controller.rotationTimer == nil,
                     "Manual stop must last through this schedule window")
        controller.checkSchedule(now: Calendar.current.date(byAdding: .day, value: 1, to: morning)!)
        precondition(applied && controller.rotationTimer != nil,
                     "A new daily boundary must resume scheduling even after a missed day")
        controller.stopRotation()
        try controller.store.setPlayback(collection.id, .init())

        controller.preview()
        let posterDeadline = Date().addingTimeInterval(10)
        while controller.task != nil && Date() < posterDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(controller.poster.image != nil, controller.detail.stringValue)
        let root = controller.window!.contentView!
        root.layoutSubtreeIfNeeded()
        let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: outputURL, options: .withoutOverwriting)

        controller.search.stringValue = "No matching scene"
        controller.reload()
        precondition(controller.items.isEmpty && !controller.apply.isEnabled)

        if let videoURL {
            try runVideoSmoke(controller: controller, folder: folder, videoURL: videoURL)
        }

        controller.window?.close()
        print("Library UI checks passed: gallery/list selection, bounded thumbnails, built-in poster/color, favorites, search, draft routing\(videoURL == nil ? "" : ", composed video poster"); offscreen snapshot saved")
    }
}
