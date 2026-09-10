import AppKit

extension SceneLibraryController {
    static func assertGalleryPolicySmoke() {
        precondition(galleryThumbnailMaxPixel == 384)
        precondition(galleryThumbnailPixelBudget == 16 * 1024 * 1024)
        precondition(galleryThumbnailCacheEntryLimit == 96)
        precondition(galleryThumbnailDecoderLimit == 1)
        precondition(galleryDestination(current: 5, keyCode: 123, columns: 3, count: 20) == 4)
        precondition(galleryDestination(current: 5, keyCode: 124, columns: 3, count: 20) == 6)
        precondition(galleryDestination(current: 5, keyCode: 125, columns: 3, count: 20) == 8)
        precondition(galleryDestination(current: 5, keyCode: 126, columns: 3, count: 20) == 2)
        let demand = thumbnailDemandIndices(active: [100, 101, 102, 103, 104, 105], count: 1000, radius: 8)
        precondition(demand.count == 22 && demand.min() == 92 && demand.max() == 113,
                     "Gallery thumbnail demand must stay within the visible band plus eight items on each side")
    }

    static func runGalleryCatalogSmoke(controller: SceneLibraryController, folder: URL) throws {
        let sourceRoot = folder.appendingPathComponent("Catalog")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let sourceDrafts = (0..<300).map { i in
            SceneLibraryStore.SourceEntry(relativeMediaPath: String(format: "%04d.jpg", i),
                                          title: "Catalog Wallpaper \(i)", mediaType: "image")
        }
        let source = try controller.store.addSource(sourceRoot, entries: sourceDrafts)
        controller.activeSourceID = source.id
        controller.filter.selectItem(at: 2)
        controller.reload()
        precondition(controller.items.count == 300, "Source-backed catalogs must browse into the hundreds")
        precondition(controller.sidebarRows.contains { $0.kind == .source(source.id) })
        try controller.store.removeSource(source.id)
        controller.activeSourceID = nil
        controller.filter.selectItem(at: 0)
        controller.reload()
        precondition(controller.items.count == 8)
    }
}

extension SceneLibraryController {
    static func runVideoSmoke(controller: SceneLibraryController, folder: URL, videoURL: URL) throws {
        let invalidMedia = folder.appendingPathComponent("invalid.webm")
        try Data("not a video".utf8).write(to: invalidMedia)
        var importFailures: [String] = []
        controller.importFailureHandler = { importFailures = $0 }
        controller.importScenes([invalidMedia, videoURL])
        let importDeadline = Date().addingTimeInterval(10)
        while controller.conversionTask != nil && Date() < importDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(controller.conversionTask == nil, "Async import timed out")
        precondition(importFailures.count == 1 && importFailures[0].contains("invalid.webm"),
                     "Failed conversion must be reported while later native media imports")
        precondition(controller.search.stringValue.isEmpty && controller.filter.indexOfSelectedItem == 2)
        precondition(controller.items.count == 1 && controller.selected?.id == controller.items[0].id,
                     "Import must reveal and select its scene despite previous search/filter")
        let videoDeadline = Date().addingTimeInterval(10)
        while controller.task != nil && Date() < videoDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(controller.poster.image != nil &&
                     controller.detail.stringValue.contains("fps") &&
                     controller.detail.stringValue.contains("×"),
                     controller.detail.stringValue)

        var video = SceneNode(content: .video(videoURL))
        video.opacity = 0
        let package = folder.appendingPathComponent("Transparent Video.idlesse")
        try ScenePackageWriter.write(SceneDescriptor(title: "Transparent Video", nodes: [video]), to: package)
        controller.importScenes([package])
        let compositionDeadline = Date().addingTimeInterval(10)
        while (controller.conversionTask != nil || controller.task != nil) &&
                Date() < compositionDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(controller.poster.image != nil, controller.detail.stringValue)
        let pixels = NSBitmapImageRep(data: controller.poster.image!.tiffRepresentation!)!
        for y in stride(from: 0, to: pixels.pixelsHigh, by: 32) {
            for x in stride(from: 0, to: pixels.pixelsWide, by: 32) {
                let color = pixels.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                precondition(max(color.redComponent, color.greenComponent, color.blueComponent) < 0.01,
                             "Video posters must respect scene opacity instead of exposing the raw frame")
            }
        }
    }
}
