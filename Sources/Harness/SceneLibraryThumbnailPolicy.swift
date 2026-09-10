import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

extension SceneLibraryController {
    func open(_ item: Item) throws -> OpenedItem {
        if let builtin = item.builtin { return OpenedItem(url: builtin, access: nil) }
        guard let entry = item.entry else { throw CocoaError(.fileNoSuchFile) }
        let access = try store.access(entry)
        return OpenedItem(url: access.url, access: access)
    }

    static func thumbnailSidecar(for source: URL) -> URL? {
        let candidates: [URL]
        if source.pathExtension.lowercased() == "idlesse" {
            candidates = [source.appendingPathComponent("preview.jpg")]
        } else {
            let base = source.deletingPathExtension()
            let restoredBase = base.lastPathComponent.replacingOccurrences(of: "-Restored-4K60", with: "")
            candidates = [
                base.appendingPathExtension("jpg"),
                source.deletingLastPathComponent().appendingPathComponent(restoredBase + ".jpg")
            ]
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func thumbnailRevision(for source: URL, sidecar: URL?) throws -> ThumbnailRevision {
        let sourceRevision = try PosterRevision.read(source)
        guard let sidecar else {
            return ThumbnailRevision(source: sourceRevision, sidecarPath: nil, sidecarDate: nil, sidecarSize: nil)
        }
        var candidate = sidecar
        candidate.removeAllCachedResourceValues()
        let values = try? candidate.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return ThumbnailRevision(source: sourceRevision, sidecarPath: candidate.path,
                                 sidecarDate: values?.contentModificationDate, sidecarSize: values?.fileSize)
    }

    static func downsampledImage(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    static func videoThumbnail(_ source: URL, operation: ThumbnailOperation) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: galleryThumbnailMaxPixel,
                                       height: galleryThumbnailMaxPixel * 9 / 16)
        operation.installGenerator(generator)
        if operation.isCancelled { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: CGImage?
        generator.generateCGImagesAsynchronously(forTimes: [
            NSValue(time: CMTime(seconds: 0, preferredTimescale: 600))
        ]) { _, image, _, _, _ in
            lock.lock()
            result = image
            lock.unlock()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            if operation.isCancelled {
                generator.cancelAllCGImageGeneration()
                return nil
            }
        }
        lock.lock()
        let image = result
        lock.unlock()
        return image
    }

}

extension SceneLibraryController {
    static func thumbnailDemandIndices(active: [Int], count: Int, radius: Int) -> [Int] {
        guard count > 0 else { return [] }
        let visible = active.filter { (0..<count).contains($0) }.sorted()
        guard let first = visible.first, let last = visible.last else { return Array(0..<min(radius, count)) }
        let low = max(0, first - radius)
        let high = min(count - 1, last + radius)
        let visibleSet = Set(visible)
        return visible + (low...high).filter { !visibleSet.contains($0) }
    }

    func updateThumbnailDemand() {
        let indices: [Int]
        switch viewMode {
        case .gallery:
            let active = collectionView.indexPathsForVisibleItems().map(\.item)
            indices = Self.thumbnailDemandIndices(active: active, count: items.count, radius: Self.galleryPrefetchItems)
        case .list:
            guard !items.isEmpty else {
                wantedThumbnailIDs = []
                cancelUnwantedThumbnailOperations()
                return
            }
            let visible = table.rows(in: table.visibleRect)
            if visible.location == NSNotFound {
                indices = Array(0..<min(Self.listPrefetchRows, items.count))
            } else {
                let low = max(0, visible.location - Self.listPrefetchRows)
                let lastVisible = min(items.count - 1, visible.location + max(0, visible.length - 1))
                let high = min(items.count - 1, lastVisible + Self.listPrefetchRows)
                indices = Array(low...high)
            }
        }
        wantedThumbnailIDs = Set(indices.map { items[$0].id })
        cancelUnwantedThumbnailOperations()
        for index in indices { requestThumbnail(items[index]) }
    }

    func cancelUnwantedThumbnailOperations() {
        let stale = thumbnailOperations.keys.filter { !wantedThumbnailIDs.contains($0) }
        for id in stale {
            thumbnailOperations[id]?.cancel()
            thumbnailOperations.removeValue(forKey: id)
        }
        composedThumbnailOrder.removeAll { !wantedThumbnailIDs.contains($0) }
        composedThumbnailQueue = composedThumbnailQueue.filter { wantedThumbnailIDs.contains($0.key) }
        if let composedThumbnailID, !wantedThumbnailIDs.contains(composedThumbnailID) {
            composedThumbnailTask?.cancel()
        }
    }

}
