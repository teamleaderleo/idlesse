from pathlib import Path

p = Path('.github/curator_memory_ui_patch.py')
s = p.read_text()
start = s.index("replace_once('''        if [\"Play Collection in Order\", \"Shuffle Collection\"].contains(item.title),")
end = s.index("replace_once('''        if let id = item.representedObject as? String, let selected {", start)
replacement = r'''replace_once('''        if item.title == "Play Collection in Order" || item.title == "Shuffle Collection" {
            guard let id = filter.selectedItem?.representedObject as? String,
                  let collection = store.catalog.collections.first(where: { $0.id == id }),
                  !collection.sceneIDs.isEmpty else { detail.stringValue = "Add scenes to this collection first."; return }
            stopRotation()
            var settings = collection.playback ?? SceneLibraryStore.Playback()
            settings.shuffle = item.title == "Shuffle Collection"
            do { try store.setPlayback(id, settings) }
            catch { detail.stringValue = error.localizedDescription; return }
            beginRotation(store.catalog.collections.first { $0.id == id }!, shuffle: settings.shuffle)
            preview()
            return
        }
''', '''        if ["Play Collection in Order", "Shuffle Collection", "Play Collection Weighted", "Surprise Me"].contains(item.title) {
            guard let id = filter.selectedItem?.representedObject as? String,
                  let collection = store.catalog.collections.first(where: { $0.id == id }),
                  !collection.sceneIDs.isEmpty else { detail.stringValue = "Add scenes to this collection first."; return }
            stopRotation()
            let mode: SceneLibraryStore.Playback.SelectionMode = item.title == "Shuffle Collection" ? .shuffle :
                (item.title == "Play Collection Weighted" ? .weighted : (item.title == "Surprise Me" ? .surprise : .ordered))
            var settings = collection.playback ?? SceneLibraryStore.Playback()
            settings.shuffle = mode == .shuffle
            settings.mode = mode
            do { try store.setPlayback(id, settings) }
            catch { detail.stringValue = error.localizedDescription; return }
            beginRotation(store.catalog.collections.first { $0.id == id }!, mode: mode)
            preview()
            return
        }
''')
'''
s = s[:start] + replacement + s[end:]
p.write_text(s)
