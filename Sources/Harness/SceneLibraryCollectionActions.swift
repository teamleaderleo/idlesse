import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

extension SceneLibraryController {
    @objc func collectionAction() {
        guard let item = collectionActions.selectedItem else { return }
        if ["Move Collection Up", "Move Collection Down"].contains(item.title),
           let id = filter.selectedItem?.representedObject as? String {
            do {
                try store.moveCollection(id, by: item.title == "Move Collection Up" ? -1 : 1)
                reload()
            } catch { detail.stringValue = error.localizedDescription }
            return
        }
        if ["Move Scene Earlier", "Move Scene Later"].contains(item.title),
           let id = filter.selectedItem?.representedObject as? String, let selected {
            do {
                try store.moveScene(selected.id, in: id, by: item.title == "Move Scene Earlier" ? -1 : 1)
                reload(selecting: selected.id)
            } catch { detail.stringValue = error.localizedDescription }
            return
        }
        if item.title == "Playback & Schedule…" { editPlayback(); return }
        if item.title == "Stop Collection Rotation" { stopRotation(); preview(); return }

        if item.title.hasPrefix("Change Every "),
           let minutes = Int(item.title.split(separator: " ")[2]) {
            if let id = filter.selectedItem?.representedObject as? String,
               let collection = store.catalog.collections.first(where: { $0.id == id }) {
                var settings = collection.playback ?? SceneLibraryStore.Playback()
                settings.minutes = minutes
                do { try store.setPlayback(id, settings) }
                catch { detail.stringValue = error.localizedDescription; return }
            }
            let editedID = filter.selectedItem?.representedObject as? String
            if rotationCollectionID == nil || editedID == rotationCollectionID {
                rotationMinutes = minutes
                if rotationTimer != nil { armRotationTimer(); preview() }
            }
            detail.stringValue = "Collections change every \(minutes) minutes."
            return
        }

        if item.title == "Play Collection in Order" || item.title == "Shuffle Collection" {
            guard let id = filter.selectedItem?.representedObject as? String,
                  let collection = store.catalog.collections.first(where: { $0.id == id }),
                  !collection.sceneIDs.isEmpty else {
                detail.stringValue = "Add scenes to this collection first."
                return
            }
            stopRotation()
            var settings = collection.playback ?? SceneLibraryStore.Playback()
            settings.shuffle = item.title == "Shuffle Collection"
            do { try store.setPlayback(id, settings) }
            catch { detail.stringValue = error.localizedDescription; return }
            beginRotation(store.catalog.collections.first { $0.id == id }!, shuffle: settings.shuffle)
            preview()
            return
        }

        if let id = item.representedObject as? String, let selected {
            do { try store.toggleMembership(sceneID: selected.id, collectionID: id); reload() }
            catch { detail.stringValue = error.localizedDescription }
            return
        }

        let activeID = filter.selectedItem?.representedObject as? String
        let deleting = item.title == "Delete Collection…"
        let renaming = item.title == "Rename Collection…"
        guard item.title == "New Collection…" || deleting || renaming else { return }
        let alert = NSAlert()
        alert.messageText = deleting ? "Delete this collection?" : (renaming ? "Rename Collection" : "New Collection")
        alert.informativeText = deleting
            ? "Scenes and original files stay in your Library."
            : "Give this group of scenes a name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = renaming
            ? (store.catalog.collections.first { $0.id == activeID }?.name ?? "")
            : ""
        if !deleting { alert.accessoryView = field }
        alert.addButton(withTitle: deleting ? "Delete Collection" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: presentationWindow!) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn else { return }
            do {
                if deleting, let activeID {
                    try self.store.removeCollection(activeID)
                    self.filter.selectItem(at: 0)
                } else if renaming, let activeID {
                    try self.store.renameCollection(activeID, name: field.stringValue)
                } else {
                    let collection = try self.store.createCollection(name: field.stringValue)
                    self.reload()
                    self.filter.selectItem(at:
                        self.filter.itemArray.firstIndex {
                            ($0.representedObject as? String) == collection.id
                        }!)
                    self.search.stringValue = ""
                }
                self.reload()
            } catch { self.detail.stringValue = error.localizedDescription }
        }
    }

}
