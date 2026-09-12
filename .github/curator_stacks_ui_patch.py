from pathlib import Path
import re


def read(path): return Path(path).read_text()
def write(path, text): Path(path).write_text(text)
def replace_once(path, old, new):
    text = read(path)
    if old not in text:
        raise SystemExit(f'missing patch anchor in {path}: {old[:120]!r}')
    write(path, text.replace(old, new, 1))
def regex_once(path, pattern, replacement):
    text = read(path)
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f'pattern count {count} in {path}: {pattern[:120]!r}')
    write(path, updated)

controller = 'Sources/Harness/SceneLibraryController.swift'
grid = 'Sources/Harness/LibraryGridView.swift'

replace_once(controller, '''    struct Item {
        let id: String
        let title: String
        let builtin: URL?
        let entry: SceneLibraryStore.Entry?
    }
''', '''    struct Item {
        let id: String
        let title: String
        let builtin: URL?
        let entry: SceneLibraryStore.Entry?
        let stack: LibraryStackProjection?
        let stackHint: String?
        init(id: String, title: String, builtin: URL?, entry: SceneLibraryStore.Entry?,
             stack: LibraryStackProjection? = nil, stackHint: String? = nil) {
            self.id = id; self.title = title; self.builtin = builtin; self.entry = entry
            self.stack = stack; self.stackHint = stackHint
        }
    }
''')

replace_once(controller, '    private let viewModeControl = NSSegmentedControl(labels: ["List", "Grid"], trackingMode: .selectOne, target: nil, action: nil)\n',
'''    private let viewModeControl = NSSegmentedControl(labels: ["List", "Grid"], trackingMode: .selectOne, target: nil, action: nil)
    private let stackModeControl = NSSegmentedControl(labels: ["Stacks", "Flat"], trackingMode: .selectOne, target: nil, action: nil)
    private let stackActions = NSPopUpButton(frame: .zero, pullsDown: true)
''')
replace_once(controller, '    private var pendingFilterTitle: String?\n',
             '    private var pendingFilterTitle: String?\n    private var focusedStackID: String?\n')

replace_once(controller, '''        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeChanged)
        viewModeControl.selectedSegment = UserDefaults.standard.integer(forKey: "Idlesse.library.viewMode")
        let toolbar = NSStackView(views: [search, filter, sort, viewModeControl, collectionActions, sourceActions, add])
''', '''        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeChanged)
        viewModeControl.selectedSegment = UserDefaults.standard.integer(forKey: "Idlesse.library.viewMode")
        stackModeControl.target = self
        stackModeControl.action = #selector(stackModeChanged)
        stackModeControl.selectedSegment = min(1, max(0, UserDefaults.standard.integer(forKey: "Idlesse.library.stackMode")))
        stackModeControl.setAccessibilityLabel("Library stack browsing")
        stackActions.addItem(withTitle: "Stacks…")
        stackActions.target = self
        stackActions.action = #selector(stackAction)
        let toolbar = NSStackView(views: [search, filter, sort, viewModeControl, stackModeControl, collectionActions, stackActions, sourceActions, add])
''')

replace_once(controller, '''    @objc private func viewModeChanged() {
        let isGrid = viewModeControl.selectedSegment == 1
        UserDefaults.standard.set(viewModeControl.selectedSegment, forKey: "Idlesse.library.viewMode")
        scroll.isHidden = isGrid
        right.isHidden = isGrid
        gridScroll.isHidden = !isGrid
        if isGrid { gridView.update(items: items, selectedID: selected?.id) }
    }
''', '''    @objc private func viewModeChanged() {
        let isGrid = viewModeControl.selectedSegment == 1
        UserDefaults.standard.set(viewModeControl.selectedSegment, forKey: "Idlesse.library.viewMode")
        scroll.isHidden = isGrid
        right.isHidden = isGrid
        gridScroll.isHidden = !isGrid
        if isGrid { gridView.update(items: items, selectedID: selected?.id) }
    }
    @objc private func stackModeChanged() {
        UserDefaults.standard.set(stackModeControl.selectedSegment, forKey: "Idlesse.library.stackMode")
        focusedStackID = nil
        reload()
    }
''')

old_all = '''    private func allItems() -> [Item] {
        Self.builtinScenes().map { Item(id: "builtin.\\($0.name)", title: $0.title, builtin: $0.url, entry: nil) }
            + store.catalog.entries.filter { $0.availability == .present }
                .map { Item(id: $0.id, title: Self.displayTitle($0.title), builtin: nil, entry: $0) }
    }
'''
new_all = '''    private func flatItems() -> [Item] {
        Self.builtinScenes().map { Item(id: "builtin.\\($0.name)", title: $0.title, builtin: $0.url, entry: nil) }
            + store.catalog.entries.filter { $0.availability == .present }
                .map { Item(id: $0.id, title: Self.displayTitle($0.title), builtin: nil, entry: $0) }
    }
    private func allItems(flat: Bool = false, query: String = "") -> [Item] {
        if flat || stackModeControl.selectedSegment == 1 { return flatItems() }
        if let focusedStackID, let stack = LibraryStackBrowser.projection(id: focusedStackID, in: store.catalog) {
            return LibraryStackBrowser.matchingChildren(of: stack, in: store.catalog, query: query).map {
                Item(id: $0.id, title: Self.displayTitle($0.title), builtin: nil, entry: $0)
            }
        }
        let builtins = Self.builtinScenes().map { Item(id: "builtin.\\($0.name)", title: $0.title, builtin: $0.url, entry: nil) }
        let stacks = LibraryStackBrowser.projections(in: store.catalog)
        let stackedIDs = Set(stacks.flatMap(\\.entryIDs))
        let stackItems = stacks.compactMap { stack -> Item? in
            guard let representative = LibraryStackBrowser.representative(for: stack, in: store.catalog, query: query) else { return nil }
            return Item(id: stack.id, title: stack.name, builtin: nil, entry: representative, stack: stack,
                        stackHint: LibraryStackBrowser.typeHint(for: stack, in: store.catalog))
        }
        let singles = store.catalog.entries.filter { $0.availability == .present && !stackedIDs.contains($0.id) }
            .map { Item(id: $0.id, title: Self.displayTitle($0.title), builtin: nil, entry: $0) }
        return builtins + stackItems + singles
    }
'''
replace_once(controller, old_all, new_all)
replace_once(controller, '        let available = allItems()\n', '        let available = allItems(flat: true, query: "")\n')

helpers = '''
    private func entries(for item: Item) -> [SceneLibraryStore.Entry] {
        guard let stack = item.stack else { return item.entry.map { [$0] } ?? [] }
        let ids = Set(stack.entryIDs)
        return store.catalog.entries.filter { ids.contains($0.id) }
    }
    private func searchScore(_ item: Item, query: String) -> Double? {
        guard !query.isEmpty else { return 0 }
        if let stack = item.stack { return LibraryStackBrowser.score(query: query, stack: stack, in: store.catalog) }
        if let entry = item.entry { return LibraryStackBrowser.entryScore(query: query, entry: entry) }
        return Self.fuzzyScore(query: query, in: item.title)
    }
    private func recentDate(_ item: Item) -> Date {
        if let stack = item.stack {
            return stack.entryIDs.compactMap { store.catalog.recent[$0] }.max() ?? .distantPast
        }
        return store.catalog.recent[item.id] ?? .distantPast
    }
    private func matchesTypeFilter(_ item: Item, index: Int) -> Bool {
        if index == 0 { return true }
        if index == 1 { return item.builtin != nil }
        if index == 2 { return item.entry != nil }
        if index == 3 {
            if let stack = item.stack { return stack.entryIDs.contains { store.catalog.favorites.contains($0) } }
            return store.catalog.favorites.contains(item.id)
        }
        let candidates = entries(for: item)
        func kind(_ entry: SceneLibraryStore.Entry) -> String {
            let path = entry.relativeMediaPath?.lowercased() ?? ""
            if entry.mediaType == "video" || path.hasSuffix(".mp4") || path.hasSuffix(".mov") { return "video" }
            if entry.mediaType == "scene" || path.hasSuffix(".idlesse") { return "scene" }
            return "image"
        }
        if index == 4 { return candidates.contains { kind($0) == "video" } }
        if index == 5 { return item.builtin != nil || candidates.contains { kind($0) == "scene" } }
        if index == 6 { return candidates.contains { kind($0) == "image" } }
        return true
    }
'''
replace_once(controller, '    @objc private func clearSearch() { search.stringValue = ""; reload() }\n',
             '    @objc private func clearSearch() { search.stringValue = ""; reload() }\n' + helpers)

pattern = r'''        items = allItems\(\)\.filter \{ item in\n.*?        table\.reloadData\(\)'''
replacement = '''        let baseItems = allItems(flat: activeCollection != nil, query: search.stringValue)
        items = baseItems.filter { item in
            let matches = searchScore(item, query: search.stringValue) != nil
            if let activeCollection { return matches && activeCollection.sceneIDs.contains(item.id) }
            return matches && matchesTypeFilter(item, index: filter.indexOfSelectedItem)
        }.sorted {
            if let activeCollection {
                return activeCollection.sceneIDs.firstIndex(of: $0.id)! < activeCollection.sceneIDs.firstIndex(of: $1.id)!
            }
            if !search.stringValue.isEmpty {
                let a = searchScore($0, query: search.stringValue) ?? .infinity
                let b = searchScore($1, query: search.stringValue) ?? .infinity
                if a != b { return a < b }
            }
            if sort.indexOfSelectedItem == 1 {
                let a = recentDate($0), b = recentDate($1)
                if a != b { return a > b }
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        table.reloadData()'''
regex_once(controller, pattern, replacement)

replace_once(controller, '        let text = NSTextField(labelWithString: (store.catalog.favorites.contains(item.id) ? "★  " : "") + item.title)\n',
'''        let favoritePrefix = item.stack == nil && store.catalog.favorites.contains(item.id) ? "★  " : ""
        let stackSuffix = item.stack.map { "  · \\($0.entryIDs.count) items" } ?? ""
        let text = NSTextField(labelWithString: favoritePrefix + item.title + stackSuffix)
''')

replace_once(controller, '''        favorite.isEnabled = selected != nil
        apply.isEnabled = selected != nil
        edit.isEnabled = selected != nil
        remove.isEnabled = selected?.entry != nil
''', '''        favorite.isEnabled = selected != nil && selected?.stack == nil
        apply.isEnabled = selected != nil && selected?.stack == nil
        edit.isEnabled = selected != nil && selected?.stack == nil
        remove.isEnabled = selected?.entry != nil && selected?.stack == nil
''')
replace_once(controller, '        more.item(at: 3)?.isEnabled = selected?.entry != nil\n',
             '        more.item(at: 3)?.isEnabled = selected?.entry != nil && selected?.stack == nil\n')
replace_once(controller, '        if let selected {\n            for collection in store.catalog.collections {\n',
             '        if let selected, selected.stack == nil {\n            for collection in store.catalog.collections {\n')
replace_once(controller, '    private func preview() {\n        task?.cancel(); task = nil; generation += 1\n',
             '    private func preview() {\n        reloadStackActions()\n        task?.cancel(); task = nil; generation += 1\n')
replace_once(controller, '        favorite.title = store.catalog.favorites.contains(selected.id) ? "★" : "☆"\n        detail.stringValue = "Preparing still preview…"\n',
'''        favorite.title = selected.stack == nil ? (store.catalog.favorites.contains(selected.id) ? "★" : "☆") : ""
        detail.stringValue = selected.stack.map { "\\($0.entryIDs.count) items · Preparing representative preview…" } ?? "Preparing still preview…"
''')
replace_once(controller, '                    self.detail.stringValue = cached.note\n',
             '                    self.detail.stringValue = self.detailNote(cached.note, for: selected)\n')
replace_once(controller, '                self.detail.stringValue = note\n',
             '                self.detail.stringValue = self.detailNote(note, for: selected)\n')

stack_ui = '''
    private func detailNote(_ note: String, for item: Item) -> String {
        guard let stack = item.stack else { return note }
        let hint = item.stackHint ?? LibraryStackBrowser.typeHint(for: stack, in: store.catalog)
        return "\\(stack.entryIDs.count) items · \\(hint) · \\(note). Double-click to open the stack."
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
        stackActions.addItem(withTitle: focusedStackID == nil ? "Stacks…" : "Stack · Browsing children")
        if focusedStackID != nil {
            stackActions.addItem(withTitle: "Back to Stacks")
            stackActions.lastItem?.representedObject = ["action": "back"]
        }
        if let stack = selected?.stack, let userID = stack.userStackID {
            stackActions.addItem(withTitle: "Delete Stack “\\(stack.name)”")
            stackActions.lastItem?.representedObject = ["action": "delete", "stack": userID]
        }
        if let focusedStackID, let stack = LibraryStackBrowser.projection(id: focusedStackID, in: store.catalog),
           let userID = stack.userStackID, let selected, selected.stack == nil {
            stackActions.addItem(withTitle: "Use “\\(selected.title)” as Representative")
            stackActions.lastItem?.representedObject = ["action": "representative", "stack": userID, "entry": selected.id]
        }
        guard let selected, selected.stack == nil, let entry = selected.entry else { return }
        let candidates: [(String, String?)] = [("series", entry.series), ("character", entry.character)] + entry.tags.prefix(3).map { ("tag", Optional($0)) }
        for (field, value) in candidates {
            guard let value, matchingStackIDs(field: field, value: value).count >= 2 else { continue }
            stackActions.addItem(withTitle: "Create Stack from \\(field.capitalized): \\(value)")
            stackActions.lastItem?.representedObject = ["action": "create", "field": field, "value": value, "entry": selected.id]
        }
    }
    private func matchingStackIDs(field: String, value: String) -> [String] {
        store.catalog.entries.filter { entry in
            guard entry.availability == .present else { return false }
            switch field {
            case "series": return entry.series?.caseInsensitiveCompare(value) == .orderedSame
            case "character": return entry.character?.caseInsensitiveCompare(value) == .orderedSame
            case "tag": return entry.tags.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
            default: return false
            }
        }.map(\\.id)
    }
    @objc private func stackAction() {
        guard let command = stackActions.selectedItem?.representedObject as? [String: String], let action = command["action"] else { return }
        do {
            switch action {
            case "back": leaveStack()
            case "delete":
                if let id = command["stack"] { try store.removeStack(id); focusedStackID = nil; reload() }
            case "representative":
                if let id = command["stack"], let entry = command["entry"] { try store.setStackRepresentative(id, entryID: entry); reload(selecting: entry) }
            case "create":
                guard let field = command["field"], let value = command["value"], let entry = command["entry"] else { return }
                let ids = matchingStackIDs(field: field, value: value)
                let stack = try store.createStack(name: value, sceneIDs: ids, representativeID: entry)
                reload(selecting: "user:" + stack.id)
            default: break
            }
        } catch { detail.stringValue = error.localizedDescription }
    }
'''
replace_once(controller, '    private static func sourceDetails(_ url: URL) async throws -> String {\n',
             stack_ui + '    private static func sourceDetails(_ url: URL) async throws -> String {\n')

replace_once(controller, '    @objc private func toggleFavorite() {\n        guard let selected else { return }\n',
             '    @objc private func toggleFavorite() {\n        guard let selected, selected.stack == nil else { return }\n')
replace_once(controller, '    @objc private func removeScene() {\n        guard let selected, selected.entry != nil else { return }\n',
             '    @objc private func removeScene() {\n        guard let selected, selected.entry != nil, selected.stack == nil else { return }\n')
replace_once(controller, '    @objc private func useScene() { act(editing: false) }\n',
'''    @objc private func useScene() {
        if let selected, selected.stack != nil { focusStack(selected); return }
        act(editing: false)
    }
''')
replace_once(controller, '    private func act(editing: Bool, asCopy: Bool = false) {\n        guard let selected else { return }\n',
'''    private func act(editing: Bool, asCopy: Bool = false) {
        guard let selected else { return }
        if selected.stack != nil { focusStack(selected); return }
''')

# Stack cards display count/type and still issue exactly one thumbnail request for their representative Item.
replace_once(grid, '''        let mediaPath = item.entry?.relativeMediaPath?.lowercased() ?? ""
        if mediaPath.hasSuffix(".mp4") || mediaPath.hasSuffix(".mov") || item.entry?.mediaType == "video" {
            badgeLabel.stringValue = "VIDEO"
        } else if item.builtin != nil || mediaPath.hasSuffix(".idlesse") || item.entry?.mediaType == "scene" {
            badgeLabel.stringValue = "INTERACTIVE SCENE"
        } else {
            badgeLabel.stringValue = "IMAGE"
        }
''', '''        if let stack = item.stack {
            badgeLabel.stringValue = "\\(stack.entryIDs.count) ITEMS · \\(item.stackHint ?? "MIXED")"
        } else {
            let mediaPath = item.entry?.relativeMediaPath?.lowercased() ?? ""
            if mediaPath.hasSuffix(".mp4") || mediaPath.hasSuffix(".mov") || item.entry?.mediaType == "video" {
                badgeLabel.stringValue = "VIDEO"
            } else if item.builtin != nil || mediaPath.hasSuffix(".idlesse") || item.entry?.mediaType == "scene" {
                badgeLabel.stringValue = "INTERACTIVE SCENE"
            } else {
                badgeLabel.stringValue = "IMAGE"
            }
        }
''')

# Extend stack tests with card-level projection invariants used by the controller.
tests = 'Tests/LibraryStackTests.swift'
replace_once(tests, '        precondition(LibraryStackBrowser.typeHint(for: sourceProjection, in: catalog) == "MIXED")\n',
'''        precondition(LibraryStackBrowser.typeHint(for: sourceProjection, in: catalog) == "MIXED")
        precondition(LibraryStackBrowser.representative(for: sourceProjection, in: catalog, query: "warm")?.id == "a")
        precondition(LibraryStackBrowser.score(query: "Aurora", stack: sourceProjection, in: catalog) != nil)
''')

with Path('docs/library-stacks.md').open('a') as handle:
    handle.write('''\n## Gallery behavior\n\nStudio Library defaults to **Stacks** browsing with a persistent **Flat** toggle. A stack card carries one representative `Entry`, so the virtualized grid asks for one thumbnail. Search can swap that representative to the best matching child. Double-clicking a stack enters a focused child browser; the active query remains in force, and the Stacks menu returns to the compact gallery. User stacks can be created from an explicit shared series, character, or tag and can remember a chosen representative.\n''')

print('Curator stack gallery patch applied')
