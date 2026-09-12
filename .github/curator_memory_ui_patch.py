from pathlib import Path

path = Path('Sources/Harness/SceneLibraryController.swift')
s = path.read_text()

def replace_once(old, new):
    global s
    if old not in s:
        raise SystemExit('missing anchor: ' + old[:140])
    s = s.replace(old, new, 1)

replace_once('    private let favorite = NSButton(title: "Favorite", target: nil, action: nil)\n',
'''    private let favorite = NSButton(title: "Favorite", target: nil, action: nil)
    private let rating = NSPopUpButton(frame: .zero, pullsDown: false)
''')
replace_once('    private var rotationShuffle = false\n    private var rotationMinutes = 30\n',
'''    private var rotationMode: SceneLibraryStore.Playback.SelectionMode = .ordered
    private var rotationSeed: UInt64 = 0
    private var rotationMinutes = 30
''')
replace_once('        if let collection { beginRotation(collection, shuffle: collection.playback?.shuffle ?? false) }\n',
             '        if let collection { beginRotation(collection, mode: collection.playback?.effectiveMode ?? .ordered) }\n')
replace_once('''    private func beginRotation(_ collection: SceneLibraryStore.Collection, shuffle: Bool) {
        rotationCollectionID = collection.id
        rotationShuffle = shuffle
        rotationMinutes = collection.playback?.minutes ?? 30
        rotationQueue = SceneRotationQueue()
        advanceRotation()
        if rotationCollectionID != nil { armRotationTimer() }
    }
''', '''    private func beginRotation(_ collection: SceneLibraryStore.Collection, mode: SceneLibraryStore.Playback.SelectionMode) {
        rotationCollectionID = collection.id
        rotationMode = mode
        rotationMinutes = collection.playback?.minutes ?? 30
        rotationQueue = SceneRotationQueue()
        rotationSeed = Date().timeIntervalSinceReferenceDate.bitPattern
        advanceRotation()
        if rotationCollectionID != nil { armRotationTimer() }
    }
''')
replace_once('''        guard let next = rotationQueue.next(ids, shuffle: rotationShuffle),
              let item = available.first(where: { $0.id == next }) else { stopRotation(manual: false); return }
''', '''        let next: String?
        if rotationMode == .ordered || rotationMode == .shuffle {
            next = rotationQueue.next(ids, shuffle: rotationMode == .shuffle)
        } else {
            rotationSeed &+= 0x9E3779B97F4A7C15
            next = LibraryMemoryPlayback.select(from: ids, catalog: store.catalog, mode: rotationMode, seed: rotationSeed)
        }
        guard let next, let item = available.first(where: { $0.id == next }) else { stopRotation(manual: false); return }
''')

replace_once('        favorite.target = self; favorite.action = #selector(toggleFavorite)\n',
'''        favorite.target = self; favorite.action = #selector(toggleFavorite)
        rating.addItems(withTitles: ["Unrated", "★", "★★", "★★★", "★★★★", "★★★★★"])
        rating.target = self; rating.action = #selector(rateSelected)
        rating.setAccessibilityLabel("Wallpaper rating")
''')
replace_once('        let heading = NSStackView(views: [titleLabel, NSView(), favorite])\n',
             '        let heading = NSStackView(views: [titleLabel, NSView(), rating, favorite])\n')

# Smart collection-aware reload.
replace_once('''        let collectionID = filter.selectedItem?.representedObject as? String
        let previousFilter = min(filter.indexOfSelectedItem, 6)
''', '''        let filterKey = filter.selectedItem?.representedObject as? String
        let collectionID = filterKey.flatMap { $0.hasPrefix("smart:") ? nil : $0 }
        let smartID = filterKey.flatMap { $0.hasPrefix("smart:") ? String($0.dropFirst(6)) : nil }
        let previousFilter = min(filter.indexOfSelectedItem, 6)
''')
replace_once('''        for collection in store.catalog.collections {
            filter.addItem(withTitle: "Collection: \(collection.name)")
            filter.lastItem?.representedObject = collection.id
        }
        if let collectionID, let index = filter.itemArray.firstIndex(where: { ($0.representedObject as? String) == collectionID }) {
            filter.selectItem(at: index)
        } else { filter.selectItem(at: max(0, previousFilter)) }
''', '''        for collection in store.catalog.collections {
            filter.addItem(withTitle: "Collection: \(collection.name)")
            filter.lastItem?.representedObject = collection.id
        }
        for collection in store.catalog.smartCollections {
            filter.addItem(withTitle: "Smart: \(collection.name)")
            filter.lastItem?.representedObject = "smart:" + collection.id
        }
        if let collectionID, let index = filter.itemArray.firstIndex(where: { ($0.representedObject as? String) == collectionID }) {
            filter.selectItem(at: index)
        } else if let smartID, let index = filter.itemArray.firstIndex(where: { ($0.representedObject as? String) == "smart:" + smartID }) {
            filter.selectItem(at: index)
        } else { filter.selectItem(at: max(0, previousFilter)) }
''')
replace_once('''        let activeCollection = store.catalog.collections.first { $0.id == (filter.selectedItem?.representedObject as? String) }
        let baseItems = allItems(flat: activeCollection != nil, query: search.stringValue)
''', '''        let selectedKey = filter.selectedItem?.representedObject as? String
        let activeCollection = store.catalog.collections.first { $0.id == selectedKey }
        let activeSmart = selectedKey.flatMap { key -> SceneLibraryStore.SmartCollection? in
            guard key.hasPrefix("smart:") else { return nil }
            let id = String(key.dropFirst(6))
            return store.catalog.smartCollections.first { $0.id == id }
        }
        let smartMembers = activeSmart.map { LibrarySmartCollectionEngine.members(of: $0, in: store.catalog) } ?? []
        let smartOrder = Dictionary(uniqueKeysWithValues: smartMembers.enumerated().map { ($0.element.id, $0.offset) })
        let smartIDs = Set(smartMembers.map(\.id))
        let baseItems = allItems(flat: activeCollection != nil || activeSmart != nil, query: search.stringValue)
''')
replace_once('''            if let activeCollection { return matches && activeCollection.sceneIDs.contains(item.id) }
            return matches && matchesTypeFilter(item, index: filter.indexOfSelectedItem)
''', '''            if let activeCollection { return matches && activeCollection.sceneIDs.contains(item.id) }
            if activeSmart != nil { return matches && smartIDs.contains(item.id) }
            return matches && matchesTypeFilter(item, index: filter.indexOfSelectedItem)
''')
replace_once('''            if let activeCollection {
                return activeCollection.sceneIDs.firstIndex(of: $0.id)! < activeCollection.sceneIDs.firstIndex(of: $1.id)!
            }
''', '''            if let activeCollection {
                return activeCollection.sceneIDs.firstIndex(of: $0.id)! < activeCollection.sceneIDs.firstIndex(of: $1.id)!
            }
            if activeSmart != nil { return (smartOrder[$0.id] ?? .max) < (smartOrder[$1.id] ?? .max) }
''')
replace_once('        updateEmptyState(activeCollection: activeCollection)\n',
'''        updateEmptyState(activeCollection: activeCollection)
        if items.isEmpty, let activeSmart, search.stringValue.isEmpty {
            titleLabel.stringValue = activeSmart.name
            detail.stringValue = "This Smart Collection has no current matches. Its saved conditions will update automatically as your Library changes."
        }
''')

# Preview controls and memory note.
replace_once('''        favorite.isEnabled = selected != nil && selected?.stack == nil
        apply.isEnabled = selected != nil && selected?.stack == nil
''', '''        favorite.isEnabled = selected != nil && selected?.stack == nil
        rating.isEnabled = selected?.entry != nil && selected?.stack == nil
        apply.isEnabled = selected != nil && selected?.stack == nil
''')
replace_once('''        collectionActions.removeAllItems()
        collectionActions.addItems(withTitles: [rotationTimer == nil ? "Collections…" : "Collections · Rotating every \(rotationMinutes)m", "New Collection…"])
        if filter.selectedItem?.representedObject is String {
            collectionActions.addItems(withTitles: ["Rename Collection…", "Delete Collection…",
                "Move Collection Up", "Move Collection Down", "Move Scene Earlier", "Move Scene Later", "Play Collection in Order", "Shuffle Collection", "Playback & Schedule…"])
        }
''', '''        collectionActions.removeAllItems()
        collectionActions.addItems(withTitles: [rotationTimer == nil ? "Collections…" : "Collections · Rotating every \(rotationMinutes)m", "New Collection…", "New Smart Collection…"])
        let activeCollectionForActions = store.catalog.collections.first { $0.id == (filter.selectedItem?.representedObject as? String) }
        let activeSmartKey = (filter.selectedItem?.representedObject as? String).flatMap { $0.hasPrefix("smart:") ? String($0.dropFirst(6)) : nil }
        if activeCollectionForActions != nil {
            collectionActions.addItems(withTitles: ["Rename Collection…", "Delete Collection…",
                "Move Collection Up", "Move Collection Down", "Move Scene Earlier", "Move Scene Later", "Play Collection in Order", "Shuffle Collection", "Play Collection Weighted", "Surprise Me", "Playback & Schedule…"])
        } else if activeSmartKey != nil {
            collectionActions.addItem(withTitle: "Delete Smart Collection…")
        }
''')
replace_once('''        titleLabel.stringValue = selected.title
        favorite.title = selected.stack == nil ? (store.catalog.favorites.contains(selected.id) ? "★" : "☆") : ""
''', '''        titleLabel.stringValue = selected.title
        favorite.title = selected.stack == nil ? (store.catalog.favorites.contains(selected.id) ? "★" : "☆") : ""
        rating.selectItem(at: selected.entry.map { store.catalog.memory[$0.id]?.rating ?? 0 } ?? 0)
''')
replace_once('''    private func detailNote(_ note: String, for item: Item) -> String {
        guard let stack = item.stack else { return note }
        let hint = item.stackHint ?? LibraryStackBrowser.typeHint(for: stack, in: store.catalog)
        return "\(stack.entryIDs.count) items · \(hint) · \(note). Double-click to open the stack."
    }
''', '''    private func detailNote(_ note: String, for item: Item) -> String {
        if let stack = item.stack {
            let hint = item.stackHint ?? LibraryStackBrowser.typeHint(for: stack, in: store.catalog)
            return "\(stack.entryIDs.count) items · \(hint) · \(note). Double-click to open the stack."
        }
        guard let entry = item.entry else { return note }
        let memory = store.catalog.memory[entry.id] ?? .init()
        let stars = memory.rating.map { String(repeating: "★", count: $0) } ?? "Unrated"
        let duplicate = LibraryDuplicateDetector.duplicateIDs(in: store.catalog).contains(entry.id) ? " · Exact duplicate detected" : ""
        return "\(note) · \(stars) · Played \(memory.playCount) time\(memory.playCount == 1 ? "" : "s")\(duplicate)"
    }
''')
replace_once('''    @objc private func toggleFavorite() {
        guard let selected, selected.stack == nil else { return }
        do { try store.favorite(selected.id); reload() } catch { detail.stringValue = error.localizedDescription }
    }
''', '''    @objc private func toggleFavorite() {
        guard let selected, selected.stack == nil else { return }
        do { try store.favorite(selected.id); reload() } catch { detail.stringValue = error.localizedDescription }
    }
    @objc private func rateSelected() {
        guard let id = selected?.entry?.id, selected?.stack == nil else { return }
        do { try store.rate(id, rating: rating.indexOfSelectedItem == 0 ? nil : rating.indexOfSelectedItem); preview() }
        catch { detail.stringValue = error.localizedDescription }
    }
''')

# Collection actions: Smart builder + weighted/surprise modes.
replace_once('''    @objc private func collectionAction() {
        guard let item = collectionActions.selectedItem else { return }
''', '''    @objc private func collectionAction() {
        guard let item = collectionActions.selectedItem else { return }
        if item.title == "New Smart Collection…" { createSmartCollection(); return }
        if item.title == "Delete Smart Collection…",
           let key = filter.selectedItem?.representedObject as? String, key.hasPrefix("smart:") {
            do { try store.removeSmartCollection(String(key.dropFirst(6))); filter.selectItem(at: 0); reload() }
            catch { detail.stringValue = error.localizedDescription }
            return
        }
''')
replace_once('''        if ["Play Collection in Order", "Shuffle Collection"].contains(item.title),
           let id = filter.selectedItem?.representedObject as? String,
           let collection = store.catalog.collections.first(where: { $0.id == id }) {
            stopRotation()
            var settings = collection.playback ?? SceneLibraryStore.Playback()
            settings.shuffle = item.title == "Shuffle Collection"
            do { try store.setPlayback(id, settings) }
            catch { detail.stringValue = error.localizedDescription; return }
            beginRotation(store.catalog.collections.first { $0.id == id }!, shuffle: settings.shuffle)
            preview()
            return
        }
''', '''        if ["Play Collection in Order", "Shuffle Collection", "Play Collection Weighted", "Surprise Me"].contains(item.title),
           let id = filter.selectedItem?.representedObject as? String,
           let collection = store.catalog.collections.first(where: { $0.id == id }) {
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
replace_once('''        if let id = item.representedObject as? String, let selected {
            do { try store.toggleMembership(sceneID: selected.id, collectionID: id); reload() }
''', '''        if let id = item.representedObject as? String, !id.hasPrefix("smart:"), let selected {
            do { try store.toggleMembership(sceneID: selected.id, collectionID: id); reload() }
''')

# Playback editor becomes an explicit four-mode popup.
replace_once('''        let shuffle = NSButton(checkboxWithTitle: "Shuffle without repeats", target: nil, action: nil)
        shuffle.state = settings.shuffle ? .on : .off
''', '''        let mode = NSPopUpButton()
        mode.addItems(withTitles: ["Order", "Shuffle without repeats", "Weighted by favorites/ratings", "Surprise: favor less-played/recent"])
        let modes: [SceneLibraryStore.Playback.SelectionMode] = [.ordered, .shuffle, .weighted, .surprise]
        mode.selectItem(at: modes.firstIndex(of: settings.effectiveMode) ?? 0)
        mode.setAccessibilityLabel("Collection playback choice")
''')
replace_once('''        let stack = NSStackView(views: [enabled, days, NSTextField(labelWithString: "From"), start,
            NSTextField(labelWithString: "Until"), end, NSTextField(labelWithString: "Change scene every"), interval, shuffle])
''', '''        let stack = NSStackView(views: [enabled, days, NSTextField(labelWithString: "From"), start,
            NSTextField(labelWithString: "Until"), end, NSTextField(labelWithString: "Change scene every"), interval,
            NSTextField(labelWithString: "Choose scenes"), mode])
''')
replace_once('''            let updated = SceneLibraryStore.Playback(minutes: [5, 15, 30, 60][interval.indexOfSelectedItem],
                shuffle: shuffle.state == .on, startMinute: enabled.state == .on ? minute(start) : nil,
''', '''            let chosenMode = modes[mode.indexOfSelectedItem]
            let updated = SceneLibraryStore.Playback(minutes: [5, 15, 30, 60][interval.indexOfSelectedItem],
                shuffle: chosenMode == .shuffle, mode: chosenMode, startMinute: enabled.state == .on ? minute(start) : nil,
''')

# Smart Collection builder: one required and one optional understandable predicate.
smart_builder = '''
    private func createSmartCollection() {
        guard let window = presentationWindow else { return }
        let alert = NSAlert()
        alert.messageText = "New Smart Collection"
        alert.informativeText = "Saved conditions update automatically from local Library metadata and memory. Conditions are combined with AND."
        let name = NSTextField(string: "")
        name.placeholderString = "Smart Collection name"
        name.widthAnchor.constraint(equalToConstant: 320).isActive = true
        let current = selected?.entry
        var choices: [(String, SceneLibraryStore.SmartPredicate?)] = [
            ("Favorites", .favorite(true)), ("Unplayed", .unplayed), ("Rated 4★ or better", .ratingAtLeast(4)),
            ("Played 10+ times", .playedAtLeast(10)), ("Exact duplicates", .duplicate),
            ("Images", .mediaType("image")), ("Videos", .mediaType("video")), ("Interactive scenes", .mediaType("scene"))
        ]
        if let series = current?.series { choices.append(("Series: " + series, .series(series))) }
        if let character = current?.character { choices.append(("Character: " + character, .character(character))) }
        for tag in current?.tags.prefix(3) ?? [] { choices.append(("Tag: " + tag, .tag(tag))) }
        if let sourceID = current?.sourceID { choices.append(("Current Source", .sourceID(sourceID))) }
        let first = NSPopUpButton(); first.addItems(withTitles: choices.map(\.0))
        let second = NSPopUpButton(); second.addItem(withTitle: "No second condition"); second.addItems(withTitles: choices.map(\.0))
        let sortPopup = NSPopUpButton(); sortPopup.addItems(withTitles: ["Name", "Rating", "Recently played", "Play count"])
        let form = NSStackView(views: [name, NSTextField(labelWithString: "Condition"), first,
            NSTextField(labelWithString: "Optional second condition"), second,
            NSTextField(labelWithString: "Sort by"), sortPopup])
        form.orientation = .vertical; form.alignment = .leading; form.spacing = 7
        form.frame = NSRect(x: 0, y: 0, width: 340, height: 190)
        alert.accessoryView = form
        alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn else { return }
            var predicates = [choices[first.indexOfSelectedItem].1!]
            if second.indexOfSelectedItem > 0 { predicates.append(choices[second.indexOfSelectedItem - 1].1!) }
            let sorts: [SceneLibraryStore.SmartSort] = [.name, .rating, .recent, .playCount]
            do {
                let collection = try self.store.createSmartCollection(name: name.stringValue, predicates: predicates, sort: sorts[sortPopup.indexOfSelectedItem])
                self.reload()
                if let index = self.filter.itemArray.firstIndex(where: { ($0.representedObject as? String) == "smart:" + collection.id }) {
                    self.filter.selectItem(at: index); self.search.stringValue = ""; self.reload()
                }
            } catch { self.detail.stringValue = error.localizedDescription }
        }
    }
'''
replace_once('    private func editPlayback() {\n', smart_builder + '    private func editPlayback() {\n')

# Docs note UI surface.
path.write_text(s)
with Path('docs/library-memory.md').open('a') as f:
    f.write('''\n## Library surface\n\nThe preview shows an explicit 1–5 star rating and local play count. Smart Collections are authored from one required and one optional readable condition, with name/rating/recent/play-count sorting. Collection playback offers Order, Shuffle, Weighted, and Surprise choices. Exact duplicate membership is visible in the preview and available as a Smart Collection condition; detection remains advisory and never merges entries.\n''')
print('Curator memory UI patch applied')
