import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

extension SceneLibraryController {
    func armRotationTimer() {
        rotationTimer?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(rotationMinutes * 60), repeats: true) { [weak self] _ in
            guard let self else { return }
            let previous = self.scheduleToken
            if self.scheduleTimer != nil { self.checkSchedule() }
            if previous == self.scheduleToken { self.advanceRotation() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    @objc func doubleClickScene() {
        guard items.indices.contains(table.clickedRow) else { return }
        selected = items[table.clickedRow]
        synchronizeSelectionViews(index: table.clickedRow, reveal: false)
        act(editing: false)
    }

    func doubleClickGalleryItem() {
        guard let path = collectionView.selectionIndexPaths.first,
              items.indices.contains(path.item) else { return }
        selected = items[path.item]
        synchronizeSelectionViews(index: path.item, reveal: false)
        act(editing: false)
    }

    @objc func editScene() { act(editing: true) }
    @objc func duplicateScene() { act(editing: true, asCopy: true) }

    func act(editing: Bool, asCopy: Bool = false) {
        guard let selected else { return }
        do {
            let opened = try open(selected)
            try store.used(selected.id)
            if editing {
                retainEditAccess(opened.access)
                onEdit(opened.url, asCopy || selected.builtin != nil)
            } else {
                stopRotation()
                retainUseAccess(opened.access)
                onUse(opened.url)
                if !embedded { window?.orderOut(nil) }
            }
        } catch { detail.stringValue = error.localizedDescription }
    }

    func windowWillClose(_ notification: Notification) {
        conversionTask?.cancel()
        task?.cancel()
        generation += 1
        hideQuickPreview()
        wantedThumbnailIDs.removeAll()
        thumbnailQueue.cancelAllOperations()
        thumbnailOperations.removeAll()
        composedThumbnailTask?.cancel()
        composedThumbnailTask = nil
        composedThumbnailID = nil
        composedThumbnailQueue.removeAll()
        composedThumbnailOrder.removeAll()
        thumbnails.removeAll()
        cache.removeAll()
        cacheOrder.removeAll()
        poster.image = nil
    }
}
