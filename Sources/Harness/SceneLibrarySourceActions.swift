import AppKit
import UniformTypeIdentifiers

extension SceneLibraryController {
    func reloadSourceActions() {
        sourceActions.removeAllItems()
        sourceActions.addItem(withTitle: "Sources…")
        sourceActions.addItem(withTitle: "Add Source…")
        for source in store.catalog.sources {
            sourceActions.addItem(withTitle: "Relink \(source.name)…")
            sourceActions.lastItem?.representedObject = ["action": "relink", "id": source.id]
            sourceActions.addItem(withTitle: "Remove \(source.name)…")
            sourceActions.lastItem?.representedObject = ["action": "remove", "id": source.id]
        }
    }

    @objc func sourceAction() {
        guard let item = sourceActions.selectedItem else { return }
        if item.title == "Add Source…" { chooseSourceFolder(relinking: nil); return }
        guard let command = item.representedObject as? [String: String],
              let action = command["action"], let id = command["id"] else { return }
        if action == "relink" { chooseSourceFolder(relinking: id); return }
        guard action == "remove", let source = store.catalog.sources.first(where: { $0.id == id }),
              let window = presentationWindow else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(source.name) from Library?"
        alert.informativeText = "Its Library references, favorites, recent records, and collection references are removed. Files in the Source folder stay untouched."
        alert.addButton(withTitle: "Remove Source")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                let removed = Set(self.store.catalog.entries.filter { $0.sourceID == id }.map(\.id))
                try self.store.removeSource(id)
                if self.activeSourceID == id { self.activeSourceID = nil }
                for entryID in removed {
                    self.cache.removeValue(forKey: entryID)
                    self.thumbnails.remove(entryID)
                }
                self.cacheOrder.removeAll { removed.contains($0) }
                self.reload()
                self.detail.stringValue = "Removed \(source.name) from the Library. Source files were preserved."
            } catch { self.detail.stringValue = error.localizedDescription }
        }
    }

    func chooseSourceFolder(relinking id: String?) {
        guard let window = presentationWindow else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.folder]
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = id == nil ? "Add Source" : "Relink Source"
        panel.message = id == nil
            ? "Choose a wallpaper folder. Idlesse scans it once and stores one folder access reference plus safe relative paths."
            : "Choose the folder that now contains this Source. Saved entry IDs and relative paths stay unchanged."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let root = panel.url else { return }
            if let id {
                do {
                    try self.store.relinkSource(id, to: root)
                    self.cache.removeAll(); self.cacheOrder.removeAll(); self.thumbnails.removeAll()
                    self.reload()
                    self.detail.stringValue = "Source relinked."
                } catch { self.detail.stringValue = error.localizedDescription }
            } else {
                self.importSource(root)
            }
        }
    }

    func importSource(_ root: URL) {
        guard conversionTask == nil else {
            detail.stringValue = "An import is already running. Try again when it finishes."
            return
        }
        conversionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.conversionTask = nil }
            self.detail.stringValue = "Scanning Source…"
            do {
                let drafts = try await Task.detached(priority: .utility) { try Self.scanSource(root) }.value
                try Task.checkCancellation()
                let oldIDs = Set(self.store.catalog.entries.map(\.id))
                let source = try self.store.addSource(root, entries: drafts)
                let firstNew = self.store.catalog.entries.first { $0.sourceID == source.id && !oldIDs.contains($0.id) }?.id
                    ?? self.store.catalog.entries.first { $0.sourceID == source.id }?.id
                self.search.stringValue = ""
                self.activeSourceID = source.id
                self.filter.selectItem(at: 2)
                self.reload(selecting: firstNew)
                self.detail.stringValue = "\(source.name): \(self.store.catalog.entries.filter { $0.sourceID == source.id }.count) wallpapers in Library."
            } catch {
                guard !Task.isCancelled else { return }
                self.detail.stringValue = "Source import failed: \(error.localizedDescription)"
            }
        }
    }
}
