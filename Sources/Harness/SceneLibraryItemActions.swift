import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

extension SceneLibraryController {
    @objc func moreAction() {
        switch more.indexOfSelectedItem {
        case 1: showInFinder()
        case 2: showDetails()
        case 3: refreshPreview()
        case 4: duplicateScene()
        case 5: removeScene()
        default: break
        }
    }

    @objc func toggleFavorite() {
        guard let selected else { return }
        do { try store.favorite(selected.id); reload() }
        catch { detail.stringValue = error.localizedDescription }
    }

    @objc func showInFinder() {
        guard let selected else { return }
        do {
            let opened = try open(selected)
            NSWorkspace.shared.activateFileViewerSelecting([opened.url])
            withExtendedLifetime(opened.access) {}
        }
        catch { detail.stringValue = error.localizedDescription }
    }

    @objc func showDetails() {
        guard let selected else { return }
        do {
            let opened = try open(selected)
            let source = opened.url
            defer { withExtendedLifetime(opened.access) {} }
            let alert = NSAlert()
            alert.messageText = selected.title
            let origin: String
            if selected.builtin != nil { origin = "Included with Idlesse" }
            else if let sourceID = selected.entry?.sourceID, let source = store.catalog.sources.first(where: { $0.id == sourceID }) {
                origin = "Source: \(source.name)"
            } else { origin = "Imported reference" }
            let current = detail.stringValue.hasPrefix("Preparing") ? "" : "\n\(detail.stringValue)"
            alert.informativeText = "\(origin)\n\(source.path)\(current)"
            alert.addButton(withTitle: "OK")
            if let window = presentationWindow { alert.beginSheetModal(for: window) }
        } catch { detail.stringValue = error.localizedDescription }
    }

    @objc func removeScene() {
        guard let selected, selected.entry != nil, let window = presentationWindow else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(selected.title) from Library?"
        alert.informativeText = "This removes the Library reference, favorite/recent metadata, and collection memberships. The source media stays in its current folder."
        alert.addButton(withTitle: "Remove Reference")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn, let selected = self.selected else { return }
            do {
                try self.store.remove(selected.id)
                self.cache.removeValue(forKey: selected.id)
                self.cacheOrder.removeAll { $0 == selected.id }
                self.thumbnails.remove(selected.id)
                self.reload()
            } catch { self.detail.stringValue = error.localizedDescription }
        }
    }

    @objc func useScene() { act(editing: false) }

}
