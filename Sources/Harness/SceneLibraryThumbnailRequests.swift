import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

extension SceneLibraryController {
    func requestThumbnailIfWanted(_ item: Item) {
        if wantedThumbnailIDs.contains(item.id) { requestThumbnail(item) }
    }

    func requestThumbnail(_ item: Item) {
        guard thumbnailOperations[item.id] == nil, composedThumbnailID != item.id,
              composedThumbnailQueue[item.id] == nil else { return }
        let itemID = item.id
        let operation = ThumbnailOperation { [weak self] operation in
            guard let self, !operation.isCancelled, let opened = try? self.open(item) else { return }
            let source = opened.url
            let posterAccess = item.entry.flatMap { try? self.store.accessPoster($0) }
            defer { withExtendedLifetime(opened.access) {}; withExtendedLifetime(posterAccess) {} }
            guard !operation.isCancelled else { return }

            let sidecar = posterAccess?.url ?? Self.thumbnailSidecar(for: source)
            guard let revision = try? Self.thumbnailRevision(for: source, sidecar: sidecar) else {
                self.finishThumbnail(itemID: itemID, operation: operation, image: nil)
                return
            }
            let cached = self.thumbnails.lookup(itemID, revision: revision)
            if cached.found {
                self.finishThumbnail(itemID: itemID, operation: operation, image: cached.image)
                return
            }
            guard !operation.isCancelled else { return }

            let frame: CGImage?
            if let sidecar {
                frame = Self.downsampledImage(sidecar, maxPixel: Self.galleryThumbnailMaxPixel)
            } else if source.pathExtension.lowercased() == "idlesse" {
                DispatchQueue.main.async { [weak self, weak operation] in
                    guard let self, let operation, self.thumbnailOperations[itemID] === operation else { return }
                    self.thumbnailOperations.removeValue(forKey: itemID)
                    if !operation.isCancelled { self.scheduleComposedThumbnail(itemID) }
                }
                return
            } else if let still = Self.downsampledImage(source, maxPixel: Self.galleryThumbnailMaxPixel) {
                frame = still
            } else {
                frame = Self.videoThumbnail(source, operation: operation)
            }
            guard !operation.isCancelled else { return }
            let image = frame.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            let bytes = frame.map { $0.width * $0.height * 4 } ?? 0
            self.thumbnails.insert(image, id: itemID, revision: revision, bytes: bytes)
            self.finishThumbnail(itemID: itemID, operation: operation, image: image)
        }
        thumbnailOperations[itemID] = operation
        thumbnailQueue.addOperation(operation)
    }

    func finishThumbnail(itemID: String, operation: ThumbnailOperation, image: NSImage?) {
        DispatchQueue.main.async { [weak self, weak operation] in
            guard let self, let operation, self.thumbnailOperations[itemID] === operation else { return }
            self.thumbnailOperations.removeValue(forKey: itemID)
            guard !operation.isCancelled, self.wantedThumbnailIDs.contains(itemID),
                  let index = self.items.firstIndex(where: { $0.id == itemID }) else { return }
            if let cell = self.table.view(atColumn: 0, row: index, makeIfNecessary: false) as? NSTableCellView {
                cell.imageView?.image = image ??
                    NSImage(systemSymbolName: "photo", accessibilityDescription: "Wallpaper preview")
            }
            let path = IndexPath(item: index, section: 0)
            if let card = self.collectionView.item(at: path) as? LibraryGalleryItem {
                let item = self.items[index]
                card.configure(title: item.title, favorite: self.store.catalog.favorites.contains(item.id),
                               image: image)
            }
        }
    }

}
