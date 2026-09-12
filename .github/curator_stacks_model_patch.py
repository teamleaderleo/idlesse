from pathlib import Path
import re


def read(path):
    return Path(path).read_text()

def write(path, text):
    Path(path).write_text(text)

def replace_once(path, old, new):
    text = read(path)
    if old not in text:
        raise SystemExit(f'missing patch anchor in {path}: {old[:100]!r}')
    write(path, text.replace(old, new, 1))

def regex_once(path, pattern, replacement):
    text = read(path)
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f'pattern count {count} in {path}: {pattern[:100]!r}')
    write(path, updated)

store = 'Sources/Harness/SceneLibraryStore.swift'
recon = 'Sources/Harness/SceneLibraryReconciliation.swift'
sqlite = 'Sources/Harness/SceneLibrarySQLiteStore.swift'

# ---- Semantic catalog: explicit Source group identity + durable user stacks ----
replace_once(store, '        var catalogID: String?\n        var sourceID: String?\n',
             '        var catalogID: String?\n        var groupID: String?\n        var sourceID: String?\n')
replace_once(store, '        init(id: String, title: String, bookmark: Data? = nil, catalogID: String? = nil,\n             sourceID: String? = nil, relativeMediaPath: String? = nil,\n',
             '        init(id: String, title: String, bookmark: Data? = nil, catalogID: String? = nil,\n             groupID: String? = nil, sourceID: String? = nil, relativeMediaPath: String? = nil,\n')
replace_once(store, '            self.catalogID = catalogID\n            self.sourceID = sourceID\n',
             '            self.catalogID = catalogID\n            self.groupID = groupID\n            self.sourceID = sourceID\n')
replace_once(store, '            case id, title, bookmark, catalogID, sourceID, relativeMediaPath, relativePosterPath\n',
             '            case id, title, bookmark, catalogID, groupID, sourceID, relativeMediaPath, relativePosterPath\n')
replace_once(store, '            catalogID = try values.decodeIfPresent(String.self, forKey: .catalogID)\n            sourceID = try values.decodeIfPresent(String.self, forKey: .sourceID)\n',
             '            catalogID = try values.decodeIfPresent(String.self, forKey: .catalogID)\n            groupID = try values.decodeIfPresent(String.self, forKey: .groupID)\n            sourceID = try values.decodeIfPresent(String.self, forKey: .sourceID)\n')
replace_once(store, '            try values.encodeIfPresent(catalogID, forKey: .catalogID)\n            try values.encodeIfPresent(sourceID, forKey: .sourceID)\n',
             '            try values.encodeIfPresent(catalogID, forKey: .catalogID)\n            try values.encodeIfPresent(groupID, forKey: .groupID)\n            try values.encodeIfPresent(sourceID, forKey: .sourceID)\n')

replace_once(store, '        var catalogID: String?\n        var relativePosterPath: String?\n',
             '        var catalogID: String?\n        var groupID: String?\n        var relativePosterPath: String?\n')
replace_once(store, '        init(relativeMediaPath: String, title: String? = nil, catalogID: String? = nil,\n             relativePosterPath: String? = nil, series: String? = nil,\n',
             '        init(relativeMediaPath: String, title: String? = nil, catalogID: String? = nil,\n             groupID: String? = nil, relativePosterPath: String? = nil, series: String? = nil,\n')
replace_once(store, '            self.catalogID = catalogID\n            self.relativePosterPath = relativePosterPath\n',
             '            self.catalogID = catalogID\n            self.groupID = groupID\n            self.relativePosterPath = relativePosterPath\n')

collection_anchor = '''    struct Collection: Codable, Equatable {
        var id: String = UUID().uuidString
        var name: String
        var sceneIDs: [String] = []
        var playback: Playback?
    }
'''
collection_replacement = collection_anchor + '''    struct UserStack: Codable, Equatable, Sendable {
        var id: String = UUID().uuidString
        var name: String
        var sceneIDs: [String]
        var representativeID: String?
    }
'''
replace_once(store, collection_anchor, collection_replacement)
replace_once(store, '        var recent: [String: Date] = [:]\n        var collections: [Collection] = []\n',
             '        var recent: [String: Date] = [:]\n        var collections: [Collection] = []\n        var stacks: [UserStack] = []\n')
replace_once(store, '        enum CodingKeys: String, CodingKey { case version, entries, sources, favorites, recent, collections }\n',
             '        enum CodingKeys: String, CodingKey { case version, entries, sources, favorites, recent, collections, stacks }\n')
replace_once(store, '            collections = try values.decodeIfPresent([Collection].self, forKey: .collections) ?? []\n',
             '            collections = try values.decodeIfPresent([Collection].self, forKey: .collections) ?? []\n            stacks = try values.decodeIfPresent([UserStack].self, forKey: .stacks) ?? []\n')

# Source-backed entry creation carries the explicit group ID.
replace_once(store, '                catalogID: draft.catalogID, sourceID: sourceID, relativeMediaPath: path,\n',
             '                catalogID: draft.catalogID, groupID: draft.groupID, sourceID: sourceID, relativeMediaPath: path,\n')

# Explicit removal cleans stack references in the same transaction as favorites/collections.
replace_once(store, '        for index in next.collections.indices { next.collections[index].sceneIDs.removeAll { removed.contains($0) } }\n        try save(next)\n',
             '        for index in next.collections.indices { next.collections[index].sceneIDs.removeAll { removed.contains($0) } }\n        Self.pruneStacks(&next.stacks, removing: removed)\n        try save(next)\n')
replace_once(store, '        for i in next.collections.indices { next.collections[i].sceneIDs.removeAll { $0 == id } }\n        try save(next)\n',
             '        for i in next.collections.indices { next.collections[i].sceneIDs.removeAll { $0 == id } }\n        Self.pruneStacks(&next.stacks, removing: [id])\n        try save(next)\n')

stack_methods = '''
    @discardableResult func createStack(name: String, sceneIDs: [String], representativeID: String? = nil) throws -> UserStack {
        let stack = UserStack(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                              sceneIDs: sceneIDs, representativeID: representativeID)
        var next = catalog
        next.stacks.append(stack)
        try save(next)
        return stack
    }
    func renameStack(_ id: String, name: String) throws {
        var next = catalog
        guard let index = next.stacks.firstIndex(where: { $0.id == id }) else { throw failure("Stack no longer exists.") }
        next.stacks[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try save(next)
    }
    func removeStack(_ id: String) throws {
        var next = catalog
        next.stacks.removeAll { $0.id == id }
        try save(next)
    }
    func setStackRepresentative(_ stackID: String, entryID: String?) throws {
        var next = catalog
        guard let index = next.stacks.firstIndex(where: { $0.id == stackID }) else { throw failure("Stack no longer exists.") }
        guard entryID == nil || next.stacks[index].sceneIDs.contains(entryID!) else {
            throw failure("Choose a wallpaper already inside this stack.")
        }
        next.stacks[index].representativeID = entryID
        try save(next)
    }
    func moveStackScene(_ sceneID: String, in stackID: String, by offset: Int) throws {
        var next = catalog
        guard let stack = next.stacks.firstIndex(where: { $0.id == stackID }),
              let index = next.stacks[stack].sceneIDs.firstIndex(of: sceneID), [-1, 1].contains(offset) else {
            throw failure("Select a wallpaper in a stack.")
        }
        let destination = index + offset
        guard next.stacks[stack].sceneIDs.indices.contains(destination) else { return }
        next.stacks[stack].sceneIDs.swapAt(index, destination)
        try save(next)
    }
'''
replace_once(store, '    @discardableResult func createCollection(name: String) throws -> Collection {\n',
             stack_methods + '    @discardableResult func createCollection(name: String) throws -> Collection {\n')

replace_once(store, '                  entry.catalogID.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,\n',
             '                  entry.catalogID.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,\n                  entry.groupID.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,\n')
replace_once(store, '                      entry.sourceID == nil, entry.relativeMediaPath == nil, entry.relativePosterPath == nil,\n',
             '                      entry.groupID == nil, entry.sourceID == nil, entry.relativeMediaPath == nil, entry.relativePosterPath == nil,\n')
replace_once(store, '        try validateCollections(value)\n', '        try validateStacks(value)\n        try validateCollections(value)\n')

validate_stacks = '''
    private func validateStacks(_ value: Catalog) throws {
        let entryIDs = Set(value.entries.map(\\.id))
        guard value.stacks.count <= 128,
              Set(value.stacks.map(\\.id)).count == value.stacks.count,
              Set(value.stacks.map { $0.name.lowercased() }).count == value.stacks.count else {
            throw failure("Use at most 128 stacks with unique names.")
        }
        for stack in value.stacks {
            guard !stack.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  stack.name.utf8.count <= 120, stack.id.utf8.count <= 128,
                  (2...256).contains(stack.sceneIDs.count), Set(stack.sceneIDs).count == stack.sceneIDs.count,
                  stack.sceneIDs.allSatisfy(entryIDs.contains),
                  stack.representativeID.map(stack.sceneIDs.contains) ?? true else {
                throw failure("Stacks need 2–256 existing wallpapers and an optional representative from the stack.")
            }
        }
    }
    private static func pruneStacks(_ stacks: inout [UserStack], removing removed: Set<String>) {
        for index in stacks.indices.reversed() {
            stacks[index].sceneIDs.removeAll { removed.contains($0) }
            if let representative = stacks[index].representativeID, removed.contains(representative) {
                stacks[index].representativeID = nil
            }
            if stacks[index].sceneIDs.count < 2 { stacks.remove(at: index) }
        }
    }
'''
replace_once(store, '    private func validateCollections(_ value: Catalog) throws {\n',
             validate_stacks + '    private func validateCollections(_ value: Catalog) throws {\n')

# ---- Reconciliation: group identity is Source-owned metadata, stable Entry.id remains Library-owned ----
replace_once(recon, '                     catalogID: draft.catalogID, sourceID: sourceID, relativeMediaPath: path,\n',
             '                     catalogID: draft.catalogID, groupID: draft.groupID, sourceID: sourceID, relativeMediaPath: path,\n')
replace_once(recon, '        entry.catalogID = draft.catalogID\n        entry.relativeMediaPath = try validatedRelativePath(draft.relativeMediaPath)\n',
             '        entry.catalogID = draft.catalogID\n        entry.groupID = draft.groupID\n        entry.relativeMediaPath = try validatedRelativePath(draft.relativeMediaPath)\n')
replace_once(recon, '        return old.title != incomingTitle || old.catalogID != incoming.catalogID ||\n',
             '        return old.title != incomingTitle || old.catalogID != incoming.catalogID || old.groupID != incoming.groupID ||\n')

# ---- SQLite mapping: extend Quarry's catalog, no second store ----
replace_once(sqlite, '            put(entry.catalogID, "catalogID", into: &value)\n',
             '            put(entry.catalogID, "catalogID", into: &value)\n            put(entry.groupID, "groupID", into: &value)\n')
replace_once(sqlite, '        root["collections"] = catalog.collections.enumerated().map { ordinal, collection -> [String: Any] in\n',
             '''        root["stacks"] = catalog.stacks.enumerated().map { ordinal, stack -> [String: Any] in
            var value: [String: Any] = ["ordinal": ordinal, "id": stack.id, "name": stack.name, "sceneIDs": stack.sceneIDs]
            put(stack.representativeID, "representativeID", into: &value)
            return value
        }
        root["collections"] = catalog.collections.enumerated().map { ordinal, collection -> [String: Any] in
''')
replace_once(sqlite, '            obs_digest TEXT,\n            obs_package_revision TEXT\n        );\n',
             '            obs_digest TEXT,\n            obs_package_revision TEXT,\n            group_id TEXT\n        );\n')
replace_once(sqlite, '''        CREATE TABLE collection_items (
            collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            scene_id TEXT NOT NULL,
            PRIMARY KEY(collection_id, ordinal),
            UNIQUE(collection_id, scene_id)
        ) WITHOUT ROWID;
''', '''        CREATE TABLE collection_items (
            collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            scene_id TEXT NOT NULL,
            PRIMARY KEY(collection_id, ordinal),
            UNIQUE(collection_id, scene_id)
        ) WITHOUT ROWID;
        CREATE TABLE user_stacks (
            id TEXT PRIMARY KEY,
            ordinal INTEGER NOT NULL UNIQUE,
            name TEXT NOT NULL,
            representative_entry_id TEXT REFERENCES entries(id) ON DELETE SET NULL
        );
        CREATE TABLE user_stack_items (
            stack_id TEXT NOT NULL REFERENCES user_stacks(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
            PRIMARY KEY(stack_id, ordinal),
            UNIQUE(stack_id, entry_id)
        ) WITHOUT ROWID;
''')
replace_once(sqlite, '        CREATE INDEX entries_source_availability ON entries(source_id, availability);\n',
             '        CREATE INDEX entries_source_availability ON entries(source_id, availability);\n        CREATE INDEX entries_source_group ON entries(source_id, group_id);\n')
replace_once(sqlite, '        CREATE INDEX collection_items_scene ON collection_items(scene_id, collection_id);\n',
             '        CREATE INDEX collection_items_scene ON collection_items(scene_id, collection_id);\n        CREATE INDEX user_stack_items_entry ON user_stack_items(entry_id, stack_id);\n')
replace_once(sqlite, '        for table in ["collection_items", "collection_weekdays", "collections", "item_state", "favorites",\n',
             '        for table in ["user_stack_items", "user_stacks", "collection_items", "collection_weekdays", "collections", "item_state", "favorites",\n')
replace_once(sqlite, '        try insertEntries(catalog.entries, in: db)\n        try insertFavorites(catalog.favorites, in: db)\n',
             '        try insertEntries(catalog.entries, in: db)\n        try insertStacks(catalog.stacks, in: db)\n        try insertFavorites(catalog.favorites, in: db)\n')
replace_once(sqlite, '                availability, obs_byte_length, obs_modified_at, obs_digest_algorithm, obs_digest, obs_package_revision)\n            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)\n',
             '                availability, obs_byte_length, obs_modified_at, obs_digest_algorithm, obs_digest, obs_package_revision, group_id)\n            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)\n')
replace_once(sqlite, '            try entry.bind(value.observation?.packageRevision, at: 22); try entry.stepDone(); entry.reset()\n',
             '            try entry.bind(value.observation?.packageRevision, at: 22); try entry.bind(value.groupID, at: 23); try entry.stepDone(); entry.reset()\n')

insert_stacks = '''
    private static func insertStacks(_ stacks: [SceneLibraryStore.UserStack], in db: Database) throws {
        let stack = try db.prepare("INSERT INTO user_stacks(id, ordinal, name, representative_entry_id) VALUES(?, ?, ?, ?)")
        let item = try db.prepare("INSERT INTO user_stack_items(stack_id, ordinal, entry_id) VALUES(?, ?, ?)")
        for (ordinal, value) in stacks.enumerated() {
            try stack.bind(value.id, at: 1); try stack.bind(ordinal, at: 2); try stack.bind(value.name, at: 3)
            try stack.bind(value.representativeID, at: 4); try stack.stepDone(); stack.reset()
            for (itemOrdinal, entryID) in value.sceneIDs.enumerated() {
                try item.bind(value.id, at: 1); try item.bind(itemOrdinal, at: 2); try item.bind(entryID, at: 3)
                try item.stepDone(); item.reset()
            }
        }
    }
'''
replace_once(sqlite, '    private static func insertFavorites(_ favorites: Set<String>, in db: Database) throws {\n',
             insert_stacks + '    private static func insertFavorites(_ favorites: Set<String>, in db: Database) throws {\n')
replace_once(sqlite, '        catalog.recent = try readState(in: db)\n        catalog.collections = try readCollections(in: db)\n',
             '        catalog.recent = try readState(in: db)\n        catalog.stacks = try readStacks(in: db)\n        catalog.collections = try readCollections(in: db)\n')
replace_once(sqlite, '            ("collection_items", 32 * 256),\n',
             '            ("collection_items", 32 * 256),\n            ("user_stacks", 128),\n            ("user_stack_items", 128 * 256),\n')
replace_once(sqlite, '                   obs_byte_length, obs_modified_at, obs_digest_algorithm, obs_digest, obs_package_revision\n            FROM entries ORDER BY ordinal\n',
             '                   obs_byte_length, obs_modified_at, obs_digest_algorithm, obs_digest, obs_package_revision, group_id\n            FROM entries ORDER BY ordinal\n')
replace_once(sqlite, '            result.append(.init(id: id, title: title, bookmark: statement.data(2), catalogID: statement.text(3),\n                sourceID: statement.text(4), relativeMediaPath: statement.text(5), relativePosterPath: statement.text(6),\n',
             '            result.append(.init(id: id, title: title, bookmark: statement.data(2), catalogID: statement.text(3),\n                groupID: statement.text(21), sourceID: statement.text(4), relativeMediaPath: statement.text(5), relativePosterPath: statement.text(6),\n')

read_stacks = '''
    private static func readStacks(in db: Database) throws -> [SceneLibraryStore.UserStack] {
        var items: [String: [(Int, String)]] = [:]
        let itemRows = try db.prepare("SELECT stack_id, ordinal, entry_id FROM user_stack_items ORDER BY stack_id, ordinal")
        while try itemRows.stepRow() {
            guard let id = itemRows.text(0), let entryID = itemRows.text(2) else { throw failure("A stack item row is invalid.") }
            items[id, default: []].append((itemRows.int(1), entryID))
        }
        let statement = try db.prepare("SELECT id, name, representative_entry_id FROM user_stacks ORDER BY ordinal")
        var result: [SceneLibraryStore.UserStack] = []
        while try statement.stepRow() {
            guard let id = statement.text(0), let name = statement.text(1) else { throw failure("A stack row is invalid.") }
            result.append(.init(id: id, name: name,
                sceneIDs: (items[id] ?? []).sorted { $0.0 < $1.0 }.map(\\.1), representativeID: statement.text(2)))
        }
        return result
    }
'''
replace_once(sqlite, '    private static func readCollections(in db: Database) throws -> [SceneLibraryStore.Collection] {\n',
             read_stacks + '    private static func readCollections(in db: Database) throws -> [SceneLibraryStore.Collection] {\n')

# New pure stack projection/search helper.
Path('Sources/Harness/SceneLibraryStacks.swift').write_text(r'''import Foundation

struct LibraryStackProjection: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable { case source, user }
    let id: String
    let name: String
    let entryIDs: [String]
    let representativeEntryID: String?
    let kind: Kind
    let userStackID: String?
}

enum LibraryStackBrowser {
    static func projections(in catalog: SceneLibraryStore.Catalog) -> [LibraryStackProjection] {
        let entriesByID = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.id, $0) })
        var claimed = Set<String>()
        var result: [LibraryStackProjection] = []

        for stack in catalog.stacks {
            let ids = stack.sceneIDs.filter { entriesByID[$0] != nil }
            guard ids.count >= 2 else { continue }
            result.append(.init(id: "user:" + stack.id, name: stack.name, entryIDs: ids,
                                representativeEntryID: stack.representativeID, kind: .user, userStackID: stack.id))
            claimed.formUnion(ids)
        }

        var groups: [String: [SceneLibraryStore.Entry]] = [:]
        for entry in catalog.entries where !claimed.contains(entry.id) {
            guard let sourceID = entry.sourceID, let groupID = normalized(entry.groupID) else { continue }
            groups[sourceID + "\u{0}" + groupID, default: []].append(entry)
        }
        for key in groups.keys.sorted() {
            guard let entries = groups[key], entries.count >= 2,
                  let sourceID = entries.first?.sourceID, let groupID = normalized(entries.first?.groupID) else { continue }
            let ordered = entries.sorted { $0.id < $1.id }.map(\.id)
            let encoded = Data(groupID.utf8).base64EncodedString()
            result.append(.init(id: "source:" + sourceID + ":" + encoded,
                                name: sourceName(groupID: groupID, entries: entries), entryIDs: ordered,
                                representativeEntryID: nil, kind: .source, userStackID: nil))
        }
        return result
    }

    static func projection(id: String, in catalog: SceneLibraryStore.Catalog) -> LibraryStackProjection? {
        projections(in: catalog).first { $0.id == id }
    }

    static func representative(for stack: LibraryStackProjection, in catalog: SceneLibraryStore.Catalog,
                               query: String = "") -> SceneLibraryStore.Entry? {
        let byID = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.id, $0) })
        let available = stack.entryIDs.compactMap { byID[$0] }.filter { $0.availability == .present }
        guard !available.isEmpty else { return nil }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let ranked = available.compactMap { entry -> (SceneLibraryStore.Entry, Double)? in
                entryScore(query: q, entry: entry).map { (entry, $0) }
            }.sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0.id < rhs.0.id : lhs.1 < rhs.1 }
            if let first = ranked.first { return first.0 }
            guard fuzzyScore(query: q, in: stack.name) != nil else { return nil }
        }
        if let remembered = stack.representativeEntryID,
           let entry = available.first(where: { $0.id == remembered }) { return entry }
        return available.first
    }

    static func matchingChildren(of stack: LibraryStackProjection, in catalog: SceneLibraryStore.Catalog,
                                 query: String) -> [SceneLibraryStore.Entry] {
        let byID = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.id, $0) })
        let available = stack.entryIDs.compactMap { byID[$0] }.filter { $0.availability == .present }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return available }
        return available.filter { entryScore(query: q, entry: $0) != nil }
    }

    static func score(query: String, stack: LibraryStackProjection, in catalog: SceneLibraryStore.Catalog) -> Double? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return 0 }
        var scores = matchingChildren(of: stack, in: catalog, query: q).compactMap { entryScore(query: q, entry: $0) }
        if let name = fuzzyScore(query: q, in: stack.name) { scores.append(name) }
        return scores.min()
    }

    static func entryScore(query: String, entry: SceneLibraryStore.Entry) -> Double? {
        let fields = [entry.title, entry.series, entry.character, entry.variant].compactMap { $0 }
            + entry.tags + (entry.provenance?.values.sorted() ?? [])
        return fields.compactMap { fuzzyScore(query: query, in: $0) }.min()
    }

    static func typeHint(for stack: LibraryStackProjection, in catalog: SceneLibraryStore.Catalog) -> String {
        let ids = Set(stack.entryIDs)
        let types = Set(catalog.entries.filter { ids.contains($0.id) }.map { entry -> String in
            let path = entry.relativeMediaPath?.lowercased() ?? ""
            if entry.mediaType == "video" || path.hasSuffix(".mp4") || path.hasSuffix(".mov") { return "video" }
            if entry.mediaType == "scene" || path.hasSuffix(".idlesse") { return "scene" }
            return "image"
        })
        if types.count == 1 { return types.first!.uppercased() }
        return "MIXED"
    }

    private static func sourceName(groupID: String, entries: [SceneLibraryStore.Entry]) -> String {
        let series = Set(entries.compactMap { normalized($0.series) })
        if series.count == 1, let value = series.first { return value }
        let characters = Set(entries.compactMap { normalized($0.character) })
        if characters.count == 1, let value = characters.first { return value }
        return groupID
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func fuzzyScore(query: String, in text: String) -> Double? {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return 0 }
        let t = Array(text.lowercased())
        if text.localizedCaseInsensitiveContains(query) {
            return (t.starts(with: q) ? 0 : 0.5) + 1 + Double(t.count) / 1000
        }
        var ti = 0, last = -2
        var score = 4.0
        for qc in q {
            var found = false
            while ti < t.count {
                let c = t[ti]; ti += 1
                if c == qc {
                    if ti - 1 == 0 || t[ti - 2] == " " || t[ti - 2] == "-" { score -= 0.3 }
                    if ti - 1 == last + 1 { score -= 0.2 }
                    last = ti - 1; found = true; break
                }
                score += 0.05
            }
            if !found { return nil }
        }
        return score + Double(t.count) / 1000
    }
}
''')

# Focused model + SQLite regression coverage.
Path('Tests/LibraryStackTests.swift').write_text(r'''import Foundation

@main
struct LibraryStackChecks {
    static func main() throws {
        let source = SceneLibraryStore.SourceRoot(id: "source-a", name: "Source", bookmark: Data([1]))
        let a = SceneLibraryStore.Entry(id: "a", title: "Aurora Dawn", catalogID: "a", groupID: "aurora",
            sourceID: source.id, relativeMediaPath: "a.jpg", series: "Aurora", character: "Mira", tags: ["warm"], mediaType: "image")
        let b = SceneLibraryStore.Entry(id: "b", title: "Nebula Night", catalogID: "b", groupID: "aurora",
            sourceID: source.id, relativeMediaPath: "b.mov", series: "Aurora", character: "Mira", tags: ["night"], mediaType: "video")
        let c = SceneLibraryStore.Entry(id: "c", title: "Solo", catalogID: "c",
            sourceID: source.id, relativeMediaPath: "c.jpg", series: "Elsewhere", mediaType: "image")
        var catalog = SceneLibraryStore.Catalog()
        catalog.sources = [source]
        catalog.entries = [a, b, c]

        let sourceProjection = LibraryStackBrowser.projections(in: catalog).first { $0.kind == .source }!
        precondition(sourceProjection.entryIDs.count == 2 && sourceProjection.name == "Aurora")
        precondition(LibraryStackBrowser.representative(for: sourceProjection, in: catalog)?.id == "a")
        precondition(LibraryStackBrowser.representative(for: sourceProjection, in: catalog, query: "neb")?.id == "b")
        precondition(LibraryStackBrowser.matchingChildren(of: sourceProjection, in: catalog, query: "night").map(\.id) == ["b"])
        precondition(LibraryStackBrowser.typeHint(for: sourceProjection, in: catalog) == "MIXED")

        catalog.stacks = [.init(id: "custom", name: "Favorites Pair", sceneIDs: ["b", "a"], representativeID: "b")]
        let userProjection = LibraryStackBrowser.projections(in: catalog).first { $0.kind == .user }!
        precondition(userProjection.entryIDs == ["b", "a"])
        precondition(LibraryStackBrowser.representative(for: userProjection, in: catalog)?.id == "b")
        precondition(LibraryStackBrowser.projections(in: catalog).filter { $0.kind == .source }.isEmpty,
            "User stack membership should take presentation priority over Source stack projection")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stack-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let json = root.appendingPathComponent("index.json")
        try JSONEncoder().encode(catalog).write(to: json)
        let store = try SceneLibraryStore(file: json)
        precondition(store.catalog.stacks == catalog.stacks && store.catalog.entries[0].groupID == "aurora")
        try store.setStackRepresentative("custom", entryID: "a")
        precondition(store.catalog.stacks[0].representativeID == "a")
        try store.remove("a")
        precondition(store.catalog.stacks.isEmpty, "Stacks with fewer than two surviving members should disappear")

        try SceneLibrarySQLiteCatalog.migrate(catalog, fromJSON: json)
        let sqliteRoundTrip = try SceneLibrarySQLiteCatalog.readSelectedCatalog(for: json)
        precondition(sqliteRoundTrip == catalog, "Stack and group state must round-trip through Quarry SQLite")
        let export = try SceneLibrarySQLiteCatalog.deterministicDebugExport(catalog)
        let text = String(decoding: export, as: UTF8.self)
        precondition(text.contains("groupID") && text.contains("Favorites Pair"))

        print("Library stack checks passed: Source groups, user stacks, representative search, cleanup, SQLite round-trip")
    }
}
''')

# Build/test hooks.
replace_once('build.sh', '  "$ROOT/Sources/Harness/SceneLibraryStore.swift"\n',
             '  "$ROOT/Sources/Harness/SceneLibraryStore.swift"\n  "$ROOT/Sources/Harness/SceneLibraryStacks.swift"\n')

test_block = '''
# 10. Library stacks over stable entry identity and Quarry SQLite.
LIBRARY_STACK_SRCS=(
  Sources/Harness/SceneLibraryStore.swift
  Sources/Harness/SceneLibraryReconciliation.swift
  Sources/Harness/SceneLibrarySQLiteStore.swift
  Sources/Harness/SceneLibraryStacks.swift
  Tests/LibraryStackTests.swift
)
if needs_build "build/tests/library-stacks" "${LIBRARY_STACK_SRCS[@]}"; then
  xcrun swiftc "$OPT_FLAG" "${LIBRARY_STACK_SRCS[@]}" -lsqlite3 -o build/tests/library-stacks &
  pids+=($!)
fi

'''
replace_once('test.sh', '# Await any parallel background compilations\n', test_block + '# Await any parallel background compilations\n')
replace_once('test.sh', 'build/tests/ambient-sets\n', 'build/tests/ambient-sets\nbuild/tests/library-stacks\n')

Path('docs/library-stacks.md').write_text('''# Library stacks\n\n#36 keeps every wallpaper as an independent stable Library entry. Stacks are a browsing relationship above those entries.\n\n- Source stacks use explicit Source-scoped `groupID` with identity `(sourceID, groupID)`. Descriptive metadata such as series and character can name/filter a stack but does not create membership.\n- User stacks store an ordered list of stable `Entry.id` values and an optional remembered representative.\n- Search chooses a transient representative from the matching available children. Outside search, a remembered representative wins, then the first available child.\n- Missing entries keep their stack state through Source reconciliation. Explicit Library removal cleans stack references; a stack with fewer than two remaining entries is removed.\n- User-stack membership wins presentation priority when it overlaps a Source stack so one entry never appears in two stack cards at once.\n- Ordinary collections continue to own concrete ordered entry IDs.\n- Quarry SQLite persists `groupID`, user stack rows, ordered memberships, and remembered representatives. Media remains external.\n\nThe gallery/UI layer consumes `LibraryStackBrowser`: a card needs only the chosen representative entry, while focused stack browsing can request child artwork on demand. Flat browsing remains a presentation option.\n\n📚 Curator\n''')

print('Curator stack model patch applied')
