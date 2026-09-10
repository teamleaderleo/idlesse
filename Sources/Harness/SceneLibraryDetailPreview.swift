import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

extension SceneLibraryController {
    @objc func refreshPreview() {
        if let selected {
            cache.removeValue(forKey: selected.id)
            cacheOrder.removeAll { $0 == selected.id }
            thumbnails.remove(selected.id)
        }
        preview()
        updateThumbnailDemand()
    }

    func preview() {
        task?.cancel()
        task = nil
        generation += 1
        let token = generation
        poster.image = nil
        hideQuickPreview()

        favorite.isEnabled = selected != nil
        apply.isEnabled = selected != nil
        edit.isEnabled = selected != nil
        more.isEnabled = selected != nil
        more.item(at: 1)?.isEnabled = selected != nil
        more.item(at: 2)?.isEnabled = selected != nil
        more.item(at: 3)?.isEnabled = selected != nil
        more.item(at: 4)?.isEnabled = selected != nil
        more.item(at: 5)?.isEnabled = selected?.entry != nil

        collectionActions.removeAllItems()
        collectionActions.addItems(withTitles: [
            rotationTimer == nil ? "Collections…" : "Collections · Rotating every \(rotationMinutes)m",
            "New Collection…"
        ])
        if filter.selectedItem?.representedObject is String {
            collectionActions.addItems(withTitles: ["Rename Collection…", "Delete Collection…",
                "Move Collection Up", "Move Collection Down", "Move Scene Earlier", "Move Scene Later",
                "Play Collection in Order", "Shuffle Collection", "Playback & Schedule…"])
        }
        collectionActions.addItems(withTitles: ["Change Every 5 Minutes", "Change Every 15 Minutes",
                                                "Change Every 30 Minutes", "Change Every 60 Minutes"])
        if rotationTimer != nil { collectionActions.addItem(withTitle: "Stop Collection Rotation") }
        if let selected {
            for collection in store.catalog.collections {
                collectionActions.addItem(withTitle:
                    "\(collection.sceneIDs.contains(selected.id) ? "Remove from" : "Add to") \(collection.name)")
                collectionActions.lastItem?.representedObject = collection.id
            }
        }

        guard let selected else {
            titleLabel.stringValue = "No wallpapers"
            detail.stringValue = "Import a wallpaper or change the search or Library section."
            favorite.title = "☆"
            return
        }
        titleLabel.stringValue = selected.title
        favorite.title = store.catalog.favorites.contains(selected.id) ? "★" : "☆"
        detail.stringValue = "Preparing still preview…"

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if token == self.generation { self.task = nil } }
            do {
                let opened = try self.open(selected)
                let url = opened.url
                defer { withExtendedLifetime(opened.access) {} }
                let revision = try await Task.detached(priority: .utility) { try PosterRevision.read(url) }.value
                try Task.checkCancellation()
                guard token == self.generation else { return }
                if let cached = self.cache[selected.id], cached.revision == revision {
                    self.poster.image = cached.image
                    self.detail.stringValue = cached.note
                    return
                }
                self.cache.removeValue(forKey: selected.id)
                let scene = try await LocalSceneSource().resolve(url)
                try Task.checkCancellation()
                guard token == self.generation else { return }
                let previewTime = scene.metadata?.previewTime ?? 2
                let sourceDetails = try await Self.sourceDetails(url)
                let note = sourceDetails.isEmpty
                    ? (scene.animated ? "Animated scene" : "Scene")
                    : String(sourceDetails.dropFirst(3))
                let clock = SceneClock(now: { 0 })
                try clock.configure(timeline: scene.timeline)
                try clock.seek(to: previewTime)
                let renderer = try MetalSceneRenderer(playable: scene,
                    bounds: NSRect(x: 0, y: 0, width: 1024, height: 576),
                    scale: 1, clock: clock, onError: { _ in })
                defer { renderer.releaseResources() }
                try await renderer.prepareOfflineVideo(
                    at: scene.timeline?.videosFollowScene == true ? clock.time : previewTime,
                    size: CGSize(width: 1024, height: 576))
                try Task.checkCancellation()
                let bytes = try renderer.renderFrame(signals: .init(time: clock.time),
                                                     width: 1024, height: 576, sampleVideo: false)
                guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                      let frame = CGImage(width: 1024, height: 576, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: 4096, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                            .union(.byteOrder32Little),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                else { throw SceneError.invalid("Could not prepare the Library preview.") }
                let image = NSImage(cgImage: frame, size: NSSize(width: 1024, height: 576))
                try Task.checkCancellation()
                guard token == self.generation else { return }
                let after = try await Task.detached(priority: .utility) { try PosterRevision.read(url) }.value
                try Task.checkCancellation()
                guard token == self.generation else { return }
                guard after == revision else {
                    throw SceneError.invalid("Scene changed while preparing its preview. Select it again to retry.")
                }
                self.cacheOrder.removeAll { $0 == selected.id }
                while self.cacheOrder.count >= 4 { self.cache.removeValue(forKey: self.cacheOrder.removeFirst()) }
                self.cacheOrder.append(selected.id)
                self.cache[selected.id] = (image, note, revision)
                self.poster.image = image
                self.detail.stringValue = note
            } catch {
                guard token == self.generation, !Task.isCancelled else { return }
                self.detail.stringValue =
                    "Preview unavailable: \(error.localizedDescription). Try Edit in Studio, or re-add a moved file."
            }
        }
    }

}
