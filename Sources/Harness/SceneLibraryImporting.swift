import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

extension SceneLibraryController {
    @objc func addScenes() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.item]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Add references to scenes or media. Originals stay in their current folder."
        panel.beginSheetModal(for: presentationWindow!) { [weak self] response in
            guard let self, response == .OK else { return }
            self.importScenes(panel.urls)
        }
    }

    static func supportedImport(_ url: URL) -> Bool {
        url.isFileURL && MediaImport.supports(url)
    }

    func droppedURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self],
                                options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter(Self.supportedImport)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard tableView === table, !droppedURLs(info.draggingPasteboard).isEmpty else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard tableView === table else { return false }
        let urls = droppedURLs(info.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        importScenes(urls)
        return true
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>)
                        -> NSDragOperation {
        droppedURLs(draggingInfo.draggingPasteboard).isEmpty ? [] : .copy
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let urls = droppedURLs(draggingInfo.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        importScenes(urls)
        return true
    }

    func importScenes(_ urls: [URL]) {
        guard conversionTask == nil else {
            detail.stringValue = "An import is already running. Try again when it finishes."
            return
        }
        conversionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.conversionTask = nil }
            var firstID: String?
            var failures: [String] = []
            for (index, source) in urls.enumerated() {
                if Task.isCancelled { return }
                self.detail.stringValue = "Importing \(index + 1) of \(urls.count)…"
                do {
                    guard Self.supportedImport(source) else {
                        throw SceneError.invalid("This file type is not supported.")
                    }
                    let convert = try await MediaImport.needsConversion(source)
                    try Task.checkCancellation()
                    let imported: URL
                    if convert {
                        self.detail.stringValue = "Converting \(index + 1) of \(urls.count)…"
                        imported = try await MediaImport.convert(source)
                    } else {
                        imported = source
                    }
                    try Task.checkCancellation()
                    let entry = try self.store.add(imported,
                        title: convert ? source.deletingPathExtension().lastPathComponent : nil)
                    if firstID == nil { firstID = entry.id }
                } catch {
                    if Task.isCancelled { return }
                    failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if firstID != nil {
                self.search.stringValue = ""
                self.activeSourceID = nil
                self.filter.selectItem(at: 2)
            }
            self.reload(selecting: firstID)
            if !failures.isEmpty {
                if let handler = self.importFailureHandler { handler(failures); return }
                let alert = NSAlert()
                alert.messageText = "Some scenes could not be added"
                alert.informativeText = failures.joined(separator: "\n")
                if let window = self.presentationWindow { await alert.beginSheetModal(for: window) }
            }
        }
    }

}
