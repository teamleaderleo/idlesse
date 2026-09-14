from pathlib import Path


def read(path):
    return Path(path).read_text()

def write(path, text):
    Path(path).write_text(text)

def once(path, old, new):
    s = read(path)
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {n}: {old[:80]!r}")
    write(path, s.replace(old, new, 1))

def between(path, start, end, new):
    s = read(path)
    if s.count(start) != 1:
        raise SystemExit(f"{path}: start marker count {s.count(start)} for {start[:80]!r}")
    i = s.index(start)
    j = s.index(end, i)
    write(path, s[:i] + new + s[j:])

controller = "Sources/Harness/SceneLibraryController.swift"
grid = "Sources/Harness/LibraryGridView.swift"

once(controller,
'''    struct Item {
        let id: String
        let title: String
        let builtin: URL?
        let entry: SceneLibraryStore.Entry?
    }
''',
'''    struct Item {
        let id: String
        let title: String
        let builtin: URL?
        let entry: SceneLibraryStore.Entry?
        let stack: LibraryStackProjection?
        let stackHint: String?

        init(id: String, title: String, builtin: URL?, entry: SceneLibraryStore.Entry?,
             stack: LibraryStackProjection? = nil, stackHint: String? = nil) {
            self.id = id
            self.title = title
            self.builtin = builtin
            self.entry = entry
            self.stack = stack
            self.stackHint = stackHint
        }
    }
''')

once(controller,
'''    private let viewModeControl = NSSegmentedControl(labels: ["List", "Grid"], trackingMode: .selectOne, target: nil, action: nil)
    private let collectionActions = NSPopUpButton(frame: .zero, pullsDown: true)
''',
'''    private let viewModeControl = NSSegmentedControl(labels: ["List", "Grid"], trackingMode: .selectOne, target: nil, action: nil)
    private let stackModeControl = NSSegmentedControl(labels: ["Stacks", "Flat"], trackingMode: .selectOne, target: nil, action: nil)
    private let stackActions = NSPopUpButton(frame: .zero, pullsDown: true)
    private let collectionActions = NSPopUpButton(frame: .zero, pullsDown: true)
''')

once(controller,
'''    private var pendingFilterTitle: String?
    private var task: Task<Void, Never>?
''',
'''    private var pendingFilterTitle: String?
    private var focusedStackID: String?
    private var task: Task<Void, Never>?
''')

once(controller, '        let available = allItems()\n', '        let available = flatItems()\n')

once(controller,
'''        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeChanged)
        viewModeControl.selectedSegment = UserDefaults.standard.integer(forKey: "Idlesse.library.viewMode")
        mediaFilter.addItems(withTitles: ["All Media", "Videos", "Scenes", "Images"])
''',
'''        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeChanged)
        viewModeControl.selectedSegment = UserDefaults.standard.integer(forKey: "Idlesse.library.viewMode")
        stackModeControl.target = self
        stackModeControl.action = #selector(stackModeChanged)
        stackModeControl.selectedSegment = min(1, max(0, UserDefaults.standard.integer(forKey: "Idlesse.library.stackMode")))
        stackModeControl.setAccessibilityLabel("Library stack browsing")
        stackActions.addItem(withTitle: "Stacks…")
        stackActions.target = self
        stackActions.action = #selector(stackAction)
        mediaFilter.addItems(withTitles: ["All Media", "Videos", "Scenes", "Images"])
''')

once(controller,
'''        let toolbar = NSStackView(views: [search, filter, mediaFilter, sort, viewModeControl, inspectorButton, collectionActions, sourceActions, importButton])
''',
'''        let toolbar = NSStackView(views: [search, filter, mediaFilter, sort, viewModeControl, stackModeControl, inspectorButton, collectionActions, stackActions, sourceActions, importButton])
''')

once(controller,
'''            self.selected = item
            menu.autoenablesItems = false
            for (title, action) in [(self.apply.isEnabled ? "Set Wallpaper" : "On Desktop", #selector(useScene)),
''',
'''            self.selected = item
            menu.autoenablesItems = false
            if item.stack != nil {
                let open = menu.addItem(withTitle: "Open Stack", action: #selector(useScene), keyEquivalent: "")
                open.target = self
                return menu
            }
            for (title, action) in [(self.apply.isEnabled ? "Set Wallpaper" : "On Desktop", #selector(useScene)),
''')

once(controller,
'''    @objc private func mediaFilterChanged() { reload() }
''',
'''    @objc private func stackModeChanged() {
        focusedStackID = nil
        UserDefaults.standard.set(stackModeControl.selectedSegment, forKey: "Idlesse.library.stackMode")
        reload()
    }

    @objc private func mediaFilterChanged() { reload() }
''')

once(controller,
'''    private func allItems() -> [Item] {
        Self.builtinScenes().map { Item(id: "builtin.\\($0.name)", title: $0.title, builtin: $0.url, entry: nil) }
            + store.catalog.entries.filter { $0.availability == .present }
                .map { Item(id: $0.id, title: Self.displayTitle($0.title), builtin: nil, entry: $0) }
    }
''',
'''    private func flatItems() -> [Item] {
        Self.builtinScenes().map { Item(id: "builtin.\\($0.name)", title: $0.title, builtin: $0.url, entry: nil) }
            + store.catalog.entries.filter { $0.availability == .present }
                .map { Item(id: $0.id, title: Self.displayTitle($0.title), builtin: nil, entry: $0) }
    }

    private func allItems(flat: Bool = false, query: String = "") -> [Item] {
        if flat || stackModeControl.selectedSegment == 1 { return flatItems() }
        if let focusedStackID, let stack = LibraryStackBrowser.projection(id: focusedStackID, in: store.catalog) {
            var children = LibraryStackBrowser.matchingChildren(of: stack, in: store.catalog, query: query)
            if children.isEmpty && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let byID = Dictionary(uniqueKeysWithValues: store.catalog.entries.map { ($0.id, $0) })
                children = stack.entryIDs.compactMap { byID[$0] }.filter { $0.availability == .present }
            }
            return children.map { Item(id: $0.id, title: Self.displayTitle($0.title), builtin: nil, entry: $0) }
        }

        let builtins = Self.builtinScenes().map { Item(id: "builtin.\\($0.name)", title: $0.title, builtin: $0.url, entry: nil) }
        let stacks = LibraryStackBrowser.projections(in: store.catalog)
        let stackedIDs = Set(stacks.flatMap(\\.entryIDs))
        let stackItems = stacks.compactMap { stack -> Item? in
            guard let representative = LibraryStackBrowser.representative(for: stack, in: store.catalog, query: query) else { return nil }
            let hint = "\\(stack.entryIDs.count) items · \\(LibraryStackBrowser.typeHint(for: stack, in: store.catalog).capitalized)"
            return Item(id: stack.id, title: stack.name, builtin: nil, entry: representative,
                        stack: stack, stackHint: hint)
        }
        let singles = store.catalog.entries.filter { $0.availability == .present && !stackedIDs.contains($0.id) }
            .map { Item(id: $0.id, title: Self.displayTitle($0.title), builtin: nil, entry: $0) }
        return builtins + stackItems + singles
    }

    private func entries(for item: Item) -> [SceneLibraryStore.Entry] {
        guard let stack = item.stack else { return item.entry.map { [$0] } ?? [] }
        let byID = Dictionary(uniqueKeysWithValues: store.catalog.entries.map { ($0.id, $0) })
        return stack.entryIDs.compactMap { byID[$0] }.filter { $0.availability == .present }
    }

    private func searchScore(_ item: Item, query: String) -> Double? {
        if query.isEmpty { return 0 }
        if let stack = item.stack { return LibraryStackBrowser.score(query: query, stack: stack, in: store.catalog) }
        if let entry = item.entry { return LibraryStackBrowser.entryScore(query: query, entry: entry) }
        return Self.fuzzyScore(query: query, in: item.title)
    }

    private func recentDate(_ item: Item) -> Date {
        if let stack = item.stack { return stack.entryIDs.compactMap { store.catalog.recent[$0] }.max() ?? .distantPast }
        return store.catalog.recent[item.id] ?? .distantPast
    }

    private func isFavorite(_ item: Item) -> Bool {
        if let stack = item.stack { return stack.entryIDs.contains { store.catalog.favorites.contains($0) } }
        return store.catalog.favorites.contains(item.id)
    }

    private func isRecent(_ item: Item) -> Bool {
        if let stack = item.stack { return stack.entryIDs.contains { store.catalog.recent[$0] != nil } }
        return store.catalog.recent[item.id] != nil
    }

    private func matchesMediaType(_ item: Item, _ type: String) -> Bool {
        if item.builtin != nil { return type == "scene" }
        return entries(for: item).contains { $0.inferredMediaType == type }
    }
''')

start = '''        let activeCollection = store.catalog.collections.first { $0.id == (filter.selectedItem?.representedObject as? String) }\n'''
end = '''        table.reloadData()\n'''
new_reload = '''        let activeCollection = store.catalog.collections.first { $0.id == (filter.selectedItem?.representedObject as? String) }
        let query = search.stringValue
        let catalog = allItems(flat: activeCollection != nil, query: query)
        let scores: [String: Double] = query.isEmpty ? [:] : catalog.reduce(into: [:]) { scores, item in
            scores[item.id] = searchScore(item, query: query)
        }
        let collectionPositions: [String: Int] = (activeCollection?.sceneIDs ?? []).enumerated().reduce(into: [:]) { positions, entry in
            if positions[entry.element] == nil { positions[entry.element] = entry.offset }
        }
        items = catalog.filter { item in
            let matches = query.isEmpty || scores[item.id] != nil
            guard matches else { return false }
            if homeNavigation {
                if mediaFilter.indexOfSelectedItem == 1 && !matchesMediaType(item, "video") { return false }
                if mediaFilter.indexOfSelectedItem == 2 && !matchesMediaType(item, "scene") { return false }
                if mediaFilter.indexOfSelectedItem == 3 && !matchesMediaType(item, "image") { return false }
                switch scope {
                case .favorites: return isFavorite(item)
                case .recent: return isRecent(item)
                case .library, .collection: break
                }
            }
            if activeCollection != nil { return collectionPositions[item.id] != nil }
            switch filter.indexOfSelectedItem {
            case 1: return item.builtin != nil
            case 2: return item.entry != nil
            case 3: return isFavorite(item)
            case 4: return matchesMediaType(item, "video")
            case 5: return matchesMediaType(item, "scene")
            case 6: return matchesMediaType(item, "image")
            default: return true
            }
        }.sorted {
            if activeCollection != nil {
                return (collectionPositions[$0.id] ?? Int.max) < (collectionPositions[$1.id] ?? Int.max)
            }
            if !query.isEmpty {
                let a = scores[$0.id] ?? .infinity
                let b = scores[$1.id] ?? .infinity
                if a != b { return a < b }
            }
            if (homeNavigation && scope == .recent) || sort.indexOfSelectedItem == 1 {
                let a = recentDate($0), b = recentDate($1)
                if a != b { return a > b }
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
'''
between(controller, start, end, new_reload)

once(controller,
'''        let text = NSTextField(labelWithString: (store.catalog.favorites.contains(item.id) ? "★  " : "") + item.title)
''',
'''        let favoritePrefix = item.stack == nil && store.catalog.favorites.contains(item.id) ? "★  " : ""
        let stackSuffix = item.stack.map { "  · \\($0.entryIDs.count) items" } ?? ""
        let text = NSTextField(labelWithString: favoritePrefix + item.title + stackSuffix)
''')

once(controller,
'''    private func updateApplyState() {
        let isPlaying: Bool
        if let selected, let playingURL {
            isPlaying = (try? open(selected).url.standardizedFileURL) == playingURL
        } else { isPlaying = false }
        apply.title = isPlaying ? "On Desktop" : "Set Wallpaper"
        apply.isEnabled = selected != nil && !isPlaying
    }
''',
'''    private func updateApplyState() {
        if selected?.stack != nil {
            apply.title = "Open Stack"
            apply.isEnabled = true
            return
        }
        let isPlaying: Bool
        if let selected, let playingURL {
            isPlaying = (try? open(selected).url.standardizedFileURL) == playingURL
        } else { isPlaying = false }
        apply.title = isPlaying ? "On Desktop" : "Set Wallpaper"
        apply.isEnabled = selected != nil && !isPlaying
    }
''')

preview_start = '''    private func preview() {\n'''
preview_marker = '''        guard let selected else {\n'''
s = read(controller)
i = s.index(preview_start)
j = s.index(preview_marker, i)
prefix = '''    private func preview() {
        stopLivePreview()
        let isStack = selected?.stack != nil
        livePreviewButton.isEnabled = selected != nil && !isStack
        task?.cancel(); task = nil; generation += 1
        let token = generation
        if posterItemID != selected?.id { poster.image = nil }
        posterItemID = selected?.id
        favorite.isHidden = isStack
        favorite.isEnabled = selected != nil && !isStack
        updateApplyState()
        edit.isEnabled = selected != nil && !isStack
        remove.isEnabled = selected?.entry != nil && !isStack
        more.isEnabled = selected != nil
        more.item(at: 2)?.isEnabled = selected != nil && !isStack
        more.item(at: 3)?.isEnabled = selected?.entry != nil && !isStack
        adjust.isEnabled = canAdjustSelection
        more.item(at: 4)?.isEnabled = canAdjustSelection
        reloadStackActions()
        collectionActions.removeAllItems()
        collectionActions.addItems(withTitles: [rotationTimer == nil ? "Collections…" : "Collections · Rotating every \\(rotationMinutes)m", "New Collection…"])
        if filter.selectedItem?.representedObject is String {
            collectionActions.addItems(withTitles: ["Rename Collection…", "Delete Collection…",
                "Move Collection Up", "Move Collection Down", "Move Scene Earlier", "Move Scene Later", "Play Collection in Order", "Shuffle Collection", "Playback & Schedule…"])
        }
        collectionActions.addItems(withTitles: ["Change Every 5 Minutes", "Change Every 15 Minutes", "Change Every 30 Minutes", "Change Every 60 Minutes"])
        if rotationTimer != nil { collectionActions.addItem(withTitle: "Stop Collection Rotation") }
        if let selected, selected.stack == nil {
            for collection in store.catalog.collections {
                collectionActions.addItem(withTitle: "\\(collection.sceneIDs.contains(selected.id) ? "Remove from" : "Add to") \\(collection.name)")
                collectionActions.lastItem?.representedObject = collection.id
            }
        }
'''
write(controller, s[:i] + prefix + s[j:])

once(controller,
'''        titleLabel.stringValue = selected.title
        favorite.title = store.catalog.favorites.contains(selected.id) ? "★" : "☆"
        detail.stringValue = "Preparing still preview…"
''',
'''        titleLabel.stringValue = selected.title
        favorite.title = selected.stack == nil ? (store.catalog.favorites.contains(selected.id) ? "★" : "☆") : ""
        detail.stringValue = selected.stack.map { "\\($0.entryIDs.count) items · \\(selected.stackHint ?? "Stack") · Preparing representative preview…" }
            ?? "Preparing still preview…"
''')

once(controller,
'''                    self.detail.stringValue = cached.note
''',
'''                    self.detail.stringValue = self.detailNote(cached.note, for: selected)
''')
once(controller,
'''                self.detail.stringValue = note
''',
'''                self.detail.stringValue = self.detailNote(note, for: selected)
''')

insert_before_source = '''    private static func sourceDetails(_ url: URL) async throws -> String {\n'''
helpers = r'''    private func detailNote(_ note: String, for item: Item) -> String {
        guard let stack = item.stack else { return note }
        return "\(stack.entryIDs.count) items · \(item.stackHint ?? "Stack") · \(note). Open the stack to browse its variants."
    }

    private func focusStack(_ item: Item) {
        guard let stack = item.stack else { return }
        focusedStackID = stack.id
        stackModeControl.selectedSegment = 0
        UserDefaults.standard.set(0, forKey: "Idlesse.library.stackMode")
        let representative = LibraryStackBrowser.representative(for: stack, in: store.catalog, query: search.stringValue)?.id
        reload(selecting: representative)
    }

    private func leaveStack() {
        let previous = focusedStackID
        focusedStackID = nil
        reload(selecting: previous)
    }

    private func reloadStackActions() {
        stackActions.removeAllItems()
        let focused = focusedStackID.flatMap { LibraryStackBrowser.projection(id: $0, in: store.catalog) }
        stackActions.addItem(withTitle: focused.map { "Stack · \($0.name)" } ?? "Stacks…")
        if focused != nil {
            stackActions.addItem(withTitle: "Back to Stacks")
            stackActions.lastItem?.representedObject = ["action": "back"]
        }

        let userStackID = selected?.stack?.userStackID ?? focused?.userStackID
        if let focused, let userStackID, let selected, selected.stack == nil,
           focused.entryIDs.contains(selected.id) {
            stackActions.addItem(withTitle: "Use “\(selected.title)” as Representative")
            stackActions.lastItem?.representedObject = ["action": "representative", "stack": userStackID, "entry": selected.id]
        }
        if let userStackID {
            stackActions.addItem(withTitle: "Rename Stack…")
            stackActions.lastItem?.representedObject = ["action": "rename", "stack": userStackID]
            stackActions.addItem(withTitle: "Delete Stack…")
            stackActions.lastItem?.representedObject = ["action": "delete", "stack": userStackID]
        }

        guard let selected, selected.stack == nil, selected.entry != nil else { return }
        let candidates: [(String, String?)] = [("series", selected.entry?.series), ("character", selected.entry?.character)]
            + (selected.entry?.tags.prefix(3).map { ("tag", Optional($0)) } ?? [])
        for (field, value) in candidates {
            guard let value else { continue }
            let ids = matchingStackIDs(field: field, value: value)
            guard ids.count >= 2, ids.contains(selected.id) else { continue }
            stackActions.addItem(withTitle: "Create Stack from \(field.capitalized): \(value)")
            stackActions.lastItem?.representedObject = ["action": "create", "field": field, "value": value, "entry": selected.id]
        }
    }

    private func matchingStackIDs(field: String, value: String) -> [String] {
        let claimed = Set(store.catalog.stacks.flatMap(\.sceneIDs))
        return store.catalog.entries.filter { entry in
            guard entry.availability == .present, !claimed.contains(entry.id) else { return false }
            switch field {
            case "series": return entry.series?.caseInsensitiveCompare(value) == .orderedSame
            case "character": return entry.character?.caseInsensitiveCompare(value) == .orderedSame
            case "tag": return entry.tags.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
            default: return false
            }
        }.map(\.id)
    }

    @objc private func stackAction() {
        guard let command = stackActions.selectedItem?.representedObject as? [String: String],
              let action = command["action"] else { return }
        do {
            switch action {
            case "back": leaveStack()
            case "representative":
                guard let stack = command["stack"], let entry = command["entry"] else { return }
                try store.setStackRepresentative(stack, entryID: entry)
                reload(selecting: entry)
            case "create":
                guard let field = command["field"], let value = command["value"], let entry = command["entry"] else { return }
                let ids = matchingStackIDs(field: field, value: value)
                let stack = try store.createStack(name: value, sceneIDs: ids, representativeID: entry)
                focusedStackID = nil
                stackModeControl.selectedSegment = 0
                UserDefaults.standard.set(0, forKey: "Idlesse.library.stackMode")
                reload(selecting: "user:" + stack.id)
            case "rename":
                if let stack = command["stack"] { renameStack(stack) }
            case "delete":
                if let stack = command["stack"] { confirmDeleteStack(stack) }
            default: break
            }
        } catch { reportTask(error.localizedDescription) }
    }

    private func renameStack(_ id: String) {
        guard let stack = store.catalog.stacks.first(where: { $0.id == id }), let window = presentationWindow else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = stack.name
        let alert = NSAlert()
        alert.messageText = "Rename Stack"
        alert.informativeText = "Stacking changes Library presentation only. Every wallpaper remains independent."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn else { return }
            do { try self.store.renameStack(id, name: field.stringValue); self.reload(selecting: "user:" + id) }
            catch { self.reportTask(error.localizedDescription) }
        }
    }

    private func confirmDeleteStack(_ id: String) {
        guard let stack = store.catalog.stacks.first(where: { $0.id == id }), let window = presentationWindow else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(stack.name)” stack?"
        alert.informativeText = "The stack disappears. Its wallpapers and files stay in the Library."
        alert.addButton(withTitle: "Delete Stack")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn else { return }
            do { try self.store.removeStack(id); self.focusedStackID = nil; self.reload() }
            catch { self.reportTask(error.localizedDescription) }
        }
    }

'''
once(controller, insert_before_source, helpers + insert_before_source)

once(controller,
'''    @objc private func toggleFavorite() {
        guard let selected else { return }
''',
'''    @objc private func toggleFavorite() {
        guard let selected, selected.stack == nil else { return }
''')
once(controller,
'''    @objc private func removeScene() {
        guard let selected, selected.entry != nil else { return }
''',
'''    @objc private func removeScene() {
        guard let selected, selected.entry != nil, selected.stack == nil else { return }
''')
once(controller,
'''    @objc private func useScene() { act(editing: false) }
''',
'''    @objc private func useScene() {
        guard let selected else { return }
        if selected.stack != nil { focusStack(selected); return }
        act(editing: false)
    }
''')

once(controller,
'''        preview()
        act(editing: false)
    }
''',
'''        preview()
        if let selected, selected.stack != nil { applyStackRepresentative(selected) }
        else { act(editing: false) }
    }
''')

once(controller,
'''        if let id = item.representedObject as? String, let selected {
            do { try store.toggleMembership(sceneID: selected.id, collectionID: id); reload() }
''',
'''        if let id = item.representedObject as? String, let selected, selected.stack == nil {
            do { try store.toggleMembership(sceneID: selected.id, collectionID: id); reload() }
''')

once(controller,
'''    @objc private func doubleClickScene() {
        guard items.indices.contains(table.clickedRow) else { return }
        selected = items[table.clickedRow]
        act(editing: false)
    }
''',
'''    @objc private func doubleClickScene() {
        guard items.indices.contains(table.clickedRow) else { return }
        selected = items[table.clickedRow]
        useScene()
    }
''')

once(controller,
'''    private var canAdjustSelection: Bool {
        selected?.entry != nil && selected?.entry?.mediaType != "scene"
    }
''',
'''    private var canAdjustSelection: Bool {
        selected?.stack == nil && selected?.entry != nil && selected?.entry?.mediaType != "scene"
    }
''')

once(controller,
'''    @objc private func frameScene() {
        guard let selected, selected.entry != nil else { return }
''',
'''    @objc private func frameScene() {
        guard let selected, selected.entry != nil, selected.stack == nil else { return }
''')

once(controller,
'''    private func act(editing: Bool, asCopy: Bool = false) {
        guard let selected else { return }
        do {
''',
'''    private func applyStackRepresentative(_ item: Item) {
        guard let entry = item.entry else { return }
        do {
            let opened = try open(item)
            try store.used(entry.id)
            stopRotation()
            retainUseAccess(opened.access)
            onUse(opened.url)
            if !embedded { window?.orderOut(nil) }
        } catch { reportTask(error.localizedDescription) }
    }

    private func act(editing: Bool, asCopy: Bool = false) {
        guard let selected, selected.stack == nil else { return }
        do {
''')

once(controller,
'''        let preferenceKeys = ["Idlesse.library.inspectorVisible", "Idlesse.library.viewMode",
                              "Idlesse.library.selectedID", "Idlesse.library.sortMode", "Idlesse.library.filterTitle"]
''',
'''        let preferenceKeys = ["Idlesse.library.inspectorVisible", "Idlesse.library.viewMode", "Idlesse.library.stackMode",
                              "Idlesse.library.selectedID", "Idlesse.library.sortMode", "Idlesse.library.filterTitle"]
''')

smoke_insert = r'''
        // Stack UI: Source grouping creates one browsing card, never eager child thumbnail work.
        let stackFolder = folder.appendingPathComponent("stack-ui", isDirectory: true)
        let sourceFolder = stackFolder.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try ScenePackageWriter.write(SceneDescriptor(title: "Aurora Dawn"),
            to: sourceFolder.appendingPathComponent("Aurora Dawn.idlesse"))
        try ScenePackageWriter.write(SceneDescriptor(title: "Nebula Night"),
            to: sourceFolder.appendingPathComponent("Nebula Night.idlesse"))
        UserDefaults.standard.set(0, forKey: "Idlesse.library.stackMode")
        var stackApplied = false
        let stackController = try SceneLibraryController(indexURL: stackFolder.appendingPathComponent("index.json"),
            onUse: { _ in stackApplied = true }, onEdit: { _, _ in })
        _ = try stackController.store.addSource(sourceFolder, name: "Stack Source", entries: [
            .init(relativeMediaPath: "Aurora Dawn.idlesse", title: "Aurora Dawn", catalogID: "dawn", groupID: "aurora",
                  series: "Aurora", character: "Mira", tags: ["warm"], mediaType: "scene"),
            .init(relativeMediaPath: "Nebula Night.idlesse", title: "Nebula Night", catalogID: "night", groupID: "aurora",
                  series: "Aurora", character: "Mira", tags: ["night"], mediaType: "scene")
        ])
        stackController.reload()
        let sourceStack = stackController.items.first { $0.stack?.kind == .source }!
        precondition(sourceStack.stack?.entryIDs.count == 2 && sourceStack.stackHint == "2 items · Scene")
        let stackJobsBefore = stackController.thumbnailJobsStarted
        var stackThumbs = 0
        stackController.requestThumbnail(for: sourceStack) { _ in stackThumbs += 1 }
        stackController.requestThumbnail(for: sourceStack) { _ in stackThumbs += 1 }
        precondition(stackController.thumbnailJobsStarted == stackJobsBefore + 1,
                     "A stack card must request one representative thumbnail, not one thumbnail per child")
        let stackThumbDeadline = Date().addingTimeInterval(10)
        while stackThumbs < 2 && Date() < stackThumbDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(stackThumbs == 2)

        stackController.search.stringValue = "night"
        stackController.reload()
        let searchedStack = stackController.items.first { $0.stack?.kind == .source }!
        precondition(searchedStack.entry?.title == "Nebula Night", "Search must choose the matching child as transient representative")
        stackController.selected = searchedStack
        stackController.useScene()
        precondition(!stackApplied && stackController.focusedStackID == searchedStack.stack?.id)
        precondition(stackController.items.count == 1 && stackController.items[0].title == "Nebula Night")
        stackController.clearSearch()
        precondition(stackController.items.count == 2 && stackController.items.allSatisfy { $0.stack == nil },
                     "Opening a stack must expose its independent child entries")

        stackController.selected = stackController.items.first { $0.title == "Aurora Dawn" }
        stackController.preview()
        let createAction = stackController.stackActions.itemArray.firstIndex { $0.title == "Create Stack from Series: Aurora" }!
        stackController.stackActions.selectItem(at: createAction)
        stackController.stackAction()
        precondition(stackController.store.catalog.stacks.count == 1 && stackController.focusedStackID == nil)
        let userStack = stackController.items.first { $0.stack?.kind == .user }!
        precondition(userStack.stack?.entryIDs.count == 2)

        stackController.stackModeControl.selectedSegment = 1
        stackController.stackModeChanged()
        precondition(stackController.items.filter { $0.entry != nil }.count == 2 && stackController.items.allSatisfy { $0.stack == nil },
                     "Flat mode must expose every concrete Library item")
        let favoriteID = stackController.store.catalog.stacks[0].sceneIDs[0]
        try stackController.store.favorite(favoriteID)
        stackController.stackModeControl.selectedSegment = 0
        stackController.stackModeChanged()
        stackController.useHomeNavigation()
        stackController.setScope(.favorites)
        precondition(stackController.items.count == 1 && stackController.items[0].stack?.kind == .user,
                     "Favorites should surface a stack when any child is favorited")
        let concreteCollection = try stackController.store.createCollection(name: "Concrete")
        try stackController.store.toggleMembership(sceneID: favoriteID, collectionID: concreteCollection.id)
        stackController.setScope(.collection(concreteCollection.id))
        precondition(stackController.items.count == 1 && stackController.items[0].id == favoriteID && stackController.items[0].stack == nil,
                     "Collections must remain concrete items even while stack browsing is enabled")
        stackController.window?.close()
'''

once(controller,
'''        controller.window?.close()
        print("Library UI checks passed: built-in poster/color, favorites, search, source controls, draft routing, procedural thumbnails\\(videoURL == nil ? "" : ", composed video poster"); offscreen snapshot saved")
''',
smoke_insert + '''        controller.window?.close()
        print("Library UI checks passed: built-in poster/color, favorites, search, source controls, stacks/flat browsing, draft routing, procedural thumbnails\\(videoURL == nil ? "" : ", composed video poster"); offscreen snapshot saved")
''')

once(grid,
'''        let mediaType = item.builtin != nil ? "scene" : item.entry?.inferredMediaType
        switch mediaType {
''',
'''        if let stackHint = item.stackHint {
            badgeLabel.stringValue = stackHint
            return changed
        }
        let mediaType = item.builtin != nil ? "scene" : item.entry?.inferredMediaType
        switch mediaType {
''')

print("phase4 UI transforms applied")