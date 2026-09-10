import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

extension SceneLibraryController {
    func scheduleComposedThumbnail(_ itemID: String) {
        guard wantedThumbnailIDs.contains(itemID),
              composedThumbnailID != itemID,
              composedThumbnailQueue[itemID] == nil,
              let item = items.first(where: { $0.id == itemID }) else { return }
        composedThumbnailQueue[itemID] = item
        composedThumbnailOrder.append(itemID)
        pumpComposedThumbnails()
    }

    func pumpComposedThumbnails() {
        guard composedThumbnailTask == nil else { return }
        while let first = composedThumbnailOrder.first, !wantedThumbnailIDs.contains(first) {
            composedThumbnailOrder.removeFirst()
            composedThumbnailQueue.removeValue(forKey: first)
        }
        guard let itemID = composedThumbnailOrder.first,
              let item = composedThumbnailQueue.removeValue(forKey: itemID) else { return }
        composedThumbnailOrder.removeFirst()
        composedThumbnailID = itemID
        composedThumbnailTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.composedThumbnailTask = nil
                self.composedThumbnailID = nil
                self.pumpComposedThumbnails()
            }
            guard self.wantedThumbnailIDs.contains(itemID) else { return }
            do {
                let opened = try self.open(item)
                let source = opened.url
                defer { withExtendedLifetime(opened.access) {} }
                let revision = try await Task.detached(priority: .utility) {
                    try Self.thumbnailRevision(for: source, sidecar: nil)
                }.value
                try Task.checkCancellation()
                let cached = self.thumbnails.lookup(itemID, revision: revision)
                if cached.found {
                    self.finishComposedThumbnail(itemID: itemID, image: cached.image)
                    return
                }
                let scene = try await LocalSceneSource().resolve(source)
                try Task.checkCancellation()
                guard self.wantedThumbnailIDs.contains(itemID) else { return }
                let previewTime = scene.metadata?.previewTime ?? 2
                let clock = SceneClock(now: { 0 })
                try clock.configure(timeline: scene.timeline)
                try clock.seek(to: previewTime)
                let width = Self.galleryThumbnailMaxPixel
                let height = width * 9 / 16
                let renderer = try MetalSceneRenderer(playable: scene,
                    bounds: NSRect(x: 0, y: 0, width: width, height: height),
                    scale: 1, clock: clock, onError: { _ in })
                defer { renderer.releaseResources() }
                try await renderer.prepareOfflineVideo(
                    at: scene.timeline?.videosFollowScene == true ? clock.time : previewTime,
                    size: CGSize(width: width, height: height))
                try Task.checkCancellation()
                let bytes = try renderer.renderFrame(signals: .init(time: clock.time),
                                                     width: width, height: height, sampleVideo: false)
                guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                      let frame = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                            .union(.byteOrder32Little),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                else { return }
                let after = try await Task.detached(priority: .utility) {
                    try Self.thumbnailRevision(for: source, sidecar: nil)
                }.value
                try Task.checkCancellation()
                guard after == revision, self.wantedThumbnailIDs.contains(itemID) else { return }
                let image = NSImage(cgImage: frame, size: NSSize(width: width, height: height))
                self.thumbnails.insert(image, id: itemID, revision: revision,
                                       bytes: width * height * 4)
                self.finishComposedThumbnail(itemID: itemID, image: image)
            } catch {
                if Task.isCancelled { return }
            }
        }
    }

    func finishComposedThumbnail(itemID: String, image: NSImage?) {
        guard wantedThumbnailIDs.contains(itemID),
              let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? NSTableCellView {
            cell.imageView?.image = image ??
                NSImage(systemSymbolName: "photo", accessibilityDescription: "Wallpaper preview")
        }
        let path = IndexPath(item: index, section: 0)
        if let card = collectionView.item(at: path) as? LibraryGalleryItem {
            let item = items[index]
            card.configure(title: item.title, favorite: store.catalog.favorites.contains(item.id),
                           image: image)
        }
    }

}
