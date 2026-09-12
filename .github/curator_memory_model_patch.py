from pathlib import Path


def read(path): return Path(path).read_text()
def write(path, text): Path(path).write_text(text)
def replace_once(path, old, new):
    text = read(path)
    if old not in text:
        raise SystemExit(f'missing patch anchor in {path}: {old[:120]!r}')
    write(path, text.replace(old, new, 1))

store = 'Sources/Harness/SceneLibraryStore.swift'
sqlite = 'Sources/Harness/SceneLibrarySQLiteStore.swift'

# Playback modes grow without changing the legacy shuffle bit.
replace_once(store, '''    struct Playback: Codable, Equatable {
        var minutes: Int = 30
        var shuffle: Bool = false
''', '''    struct Playback: Codable, Equatable {
        enum SelectionMode: String, Codable, Sendable { case ordered, shuffle, weighted, surprise }
        var minutes: Int = 30
        var shuffle: Bool = false
        var mode: SelectionMode? = nil
        var effectiveMode: SelectionMode { mode ?? (shuffle ? .shuffle : .ordered) }
''')

replace_once(store, '''    struct UserStack: Codable, Equatable, Sendable {
        var id: String = UUID().uuidString
        var name: String
        var sceneIDs: [String]
        var representativeID: String?
    }
''', '''    struct UserStack: Codable, Equatable, Sendable {
        var id: String = UUID().uuidString
        var name: String
        var sceneIDs: [String]
        var representativeID: String?
    }
    struct ItemMemory: Codable, Equatable, Sendable {
        var rating: Int? = nil
        var playCount: Int = 0
    }
    enum SmartPredicate: Codable, Equatable, Sendable {
        case favorite(Bool)
        case ratingAtLeast(Int)
        case playedAtLeast(Int)
        case unplayed
        case mediaType(String)
        case series(String)
        case character(String)
        case tag(String)
        case sourceID(String)
        case duplicate
    }
    enum SmartSort: String, Codable, Sendable { case name, rating, recent, playCount }
    struct SmartCollection: Codable, Equatable, Sendable {
        var id: String = UUID().uuidString
        var name: String
        var predicates: [SmartPredicate]
        var sort: SmartSort = .name
    }
''')
replace_once(store, '        var stacks: [UserStack] = []\n',
             '        var stacks: [UserStack] = []\n        var memory: [String: ItemMemory] = [:]\n        var smartCollections: [SmartCollection] = []\n')
replace_once(store, '        enum CodingKeys: String, CodingKey { case version, entries, sources, favorites, recent, collections, stacks }\n',
             '        enum CodingKeys: String, CodingKey { case version, entries, sources, favorites, recent, collections, stacks, memory, smartCollections }\n')
replace_once(store, '            stacks = try values.decodeIfPresent([UserStack].self, forKey: .stacks) ?? []\n',
             '            stacks = try values.decodeIfPresent([UserStack].self, forKey: .stacks) ?? []\n            memory = try values.decodeIfPresent([String: ItemMemory].self, forKey: .memory) ?? [:]\n            smartCollections = try values.decodeIfPresent([SmartCollection].self, forKey: .smartCollections) ?? []\n')

replace_once(store, '        for entryID in removed { next.recent.removeValue(forKey: entryID) }\n',
             '        for entryID in removed { next.recent.removeValue(forKey: entryID); next.memory.removeValue(forKey: entryID) }\n')
replace_once(store, '''    func used(_ id: String) throws {
        var next = catalog
        next.recent[id] = Date()
        while next.recent.count > 256, let oldest = next.recent.min(by: { $0.value < $1.value })?.key {
            next.recent.removeValue(forKey: oldest)
        }
        try save(next)
    }
''', '''    func used(_ id: String, at date: Date = Date()) throws {
        var next = catalog
        next.recent[id] = date
        if next.entries.contains(where: { $0.id == id }) {
            var memory = next.memory[id] ?? ItemMemory()
            memory.playCount = min(1_000_000_000, memory.playCount + 1)
            next.memory[id] = memory
        }
        while next.recent.count > 256, let oldest = next.recent.min(by: { $0.value < $1.value })?.key {
            next.recent.removeValue(forKey: oldest)
        }
        try save(next)
    }
    func rate(_ id: String, rating: Int?) throws {
        guard catalog.entries.contains(where: { $0.id == id }), rating.map({ (1...5).contains($0) }) ?? true else {
            throw failure("Ratings use one to five stars for an existing Library wallpaper.")
        }
        var next = catalog
        var memory = next.memory[id] ?? ItemMemory()
        memory.rating = rating
        if memory.rating == nil && memory.playCount == 0 { next.memory.removeValue(forKey: id) }
        else { next.memory[id] = memory }
        try save(next)
    }
''')
replace_once(store, '        next.recent.removeValue(forKey: id)\n',
             '        next.recent.removeValue(forKey: id)\n        next.memory.removeValue(forKey: id)\n')

smart_methods = '''
    @discardableResult func createSmartCollection(name: String, predicates: [SmartPredicate], sort: SmartSort = .name) throws -> SmartCollection {
        let collection = SmartCollection(name: name.trimmingCharacters(in: .whitespacesAndNewlines), predicates: predicates, sort: sort)
        var next = catalog
        next.smartCollections.append(collection)
        try save(next)
        return collection
    }
    func updateSmartCollection(_ collection: SmartCollection) throws {
        var next = catalog
        guard let index = next.smartCollections.firstIndex(where: { $0.id == collection.id }) else { throw failure("Smart Collection no longer exists.") }
        next.smartCollections[index] = collection
        try save(next)
    }
    func removeSmartCollection(_ id: String) throws {
        var next = catalog
        next.smartCollections.removeAll { $0.id == id }
        try save(next)
    }
'''
replace_once(store, '    @discardableResult func createCollection(name: String) throws -> Collection {\n',
             smart_methods + '    @discardableResult func createCollection(name: String) throws -> Collection {\n')

replace_once(store, '              value.favorites.count <= 256, value.recent.count <= 256,\n',
             '              value.favorites.count <= 256, value.recent.count <= 256, value.memory.count <= value.entries.count,\n')
replace_once(store, '        try validateStacks(value)\n        try validateCollections(value)\n',
             '        try validateMemory(value)\n        try validateSmartCollections(value)\n        try validateStacks(value)\n        try validateCollections(value)\n')

validators = '''
    private func validateMemory(_ value: Catalog) throws {
        let ids = Set(value.entries.map(\\.id))
        guard value.memory.allSatisfy({ key, state in
            ids.contains(key) && state.playCount >= 0 && state.playCount <= 1_000_000_000 && (state.rating.map { (1...5).contains($0) } ?? true)
        }) else { throw failure("Library ratings and play counts reference invalid wallpapers or values.") }
    }
    private func validateSmartCollections(_ value: Catalog) throws {
        let ordinaryNames = Set(value.collections.map { $0.name.lowercased() })
        let smartNames = value.smartCollections.map { $0.name.lowercased() }
        guard value.smartCollections.count <= 32,
              Set(value.smartCollections.map(\\.id)).count == value.smartCollections.count,
              Set(smartNames).count == smartNames.count,
              ordinaryNames.isDisjoint(with: Set(smartNames)) else {
            throw failure("Use at most 32 Smart Collections with names distinct from ordinary collections.")
        }
        for collection in value.smartCollections {
            guard !collection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  collection.name.utf8.count <= 120, collection.id.utf8.count <= 128,
                  (1...8).contains(collection.predicates.count),
                  collection.predicates.allSatisfy(Self.validSmartPredicate) else {
                throw failure("Smart Collections need 1–8 supported predicates with bounded values.")
            }
        }
    }
    private static func validSmartPredicate(_ predicate: SmartPredicate) -> Bool {
        switch predicate {
        case .favorite: return true
        case .ratingAtLeast(let value): return (1...5).contains(value)
        case .playedAtLeast(let value): return (1...1_000_000_000).contains(value)
        case .unplayed, .duplicate: return true
        case .mediaType(let value): return !value.isEmpty && value.utf8.count <= 64
        case .series(let value), .character(let value), .tag(let value), .sourceID(let value):
            return !value.isEmpty && value.utf8.count <= 512
        }
    }
'''
replace_once(store, '    private func validateStacks(_ value: Catalog) throws {\n',
             validators + '    private func validateStacks(_ value: Catalog) throws {\n')

# New engine: understandable Smart predicates, exact duplicate groups, deterministic weighted/surprise selection.
Path('Sources/Harness/SceneLibraryMemory.swift').write_text(r'''import Foundation

struct LibraryDuplicateGroup: Equatable, Sendable {
    let entryIDs: [String]
    let evidence: String
}

enum LibraryDuplicateDetector {
    static func exactGroups(in catalog: SceneLibraryStore.Catalog) -> [LibraryDuplicateGroup] {
        var digests: [String: [String]] = [:]
        for entry in catalog.entries where entry.availability == .present {
            guard let observation = entry.observation,
                  let algorithm = observation.digestAlgorithm?.lowercased(), !algorithm.isEmpty,
                  let digest = observation.digest?.lowercased(), !digest.isEmpty else { continue }
            digests[algorithm + ":" + digest, default: []].append(entry.id)
        }
        return digests.values.filter { $0.count > 1 }.map {
            LibraryDuplicateGroup(entryIDs: $0.sorted(), evidence: "identical verified content digest")
        }.sorted { $0.entryIDs.lexicographicallyPrecedes($1.entryIDs) }
    }
    static func duplicateIDs(in catalog: SceneLibraryStore.Catalog) -> Set<String> {
        Set(exactGroups(in: catalog).flatMap(\.entryIDs))
    }
}

enum LibrarySmartCollectionEngine {
    static func members(of collection: SceneLibraryStore.SmartCollection,
                        in catalog: SceneLibraryStore.Catalog) -> [SceneLibraryStore.Entry] {
        let duplicates = LibraryDuplicateDetector.duplicateIDs(in: catalog)
        var entries = catalog.entries.filter { $0.availability == .present && matches($0, collection.predicates, catalog, duplicates) }
        entries.sort { lhs, rhs in
            switch collection.sort {
            case .name:
                let order = lhs.title.localizedStandardCompare(rhs.title)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            case .rating:
                let a = catalog.memory[lhs.id]?.rating ?? 0, b = catalog.memory[rhs.id]?.rating ?? 0
                return a == b ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending : a > b
            case .recent:
                let a = catalog.recent[lhs.id] ?? .distantPast, b = catalog.recent[rhs.id] ?? .distantPast
                return a == b ? lhs.id < rhs.id : a > b
            case .playCount:
                let a = catalog.memory[lhs.id]?.playCount ?? 0, b = catalog.memory[rhs.id]?.playCount ?? 0
                return a == b ? lhs.id < rhs.id : a > b
            }
        }
        return entries
    }

    private static func matches(_ entry: SceneLibraryStore.Entry,
                                _ predicates: [SceneLibraryStore.SmartPredicate],
                                _ catalog: SceneLibraryStore.Catalog,
                                _ duplicates: Set<String>) -> Bool {
        let memory = catalog.memory[entry.id] ?? .init()
        return predicates.allSatisfy { predicate in
            switch predicate {
            case .favorite(let value): return catalog.favorites.contains(entry.id) == value
            case .ratingAtLeast(let value): return (memory.rating ?? 0) >= value
            case .playedAtLeast(let value): return memory.playCount >= value
            case .unplayed: return memory.playCount == 0
            case .mediaType(let value): return normalizedMediaType(entry) == value.lowercased()
            case .series(let value): return entry.series?.caseInsensitiveCompare(value) == .orderedSame
            case .character(let value): return entry.character?.caseInsensitiveCompare(value) == .orderedSame
            case .tag(let value): return entry.tags.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
            case .sourceID(let value): return entry.sourceID == value
            case .duplicate: return duplicates.contains(entry.id)
            }
        }
    }

    static func normalizedMediaType(_ entry: SceneLibraryStore.Entry) -> String {
        if let type = entry.mediaType?.lowercased(), !type.isEmpty { return type }
        let path = entry.relativeMediaPath?.lowercased() ?? ""
        if path.hasSuffix(".mp4") || path.hasSuffix(".mov") || path.hasSuffix(".m4v") { return "video" }
        if path.hasSuffix(".idlesse") { return "scene" }
        return "image"
    }
}

struct LibrarySeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

enum LibraryMemoryPlayback {
    static func select(from entryIDs: [String], catalog: SceneLibraryStore.Catalog,
                       mode: SceneLibraryStore.Playback.SelectionMode, seed: UInt64,
                       now: Date = Date()) -> String? {
        let available = entryIDs.filter { id in catalog.entries.contains { $0.id == id && $0.availability == .present } }
        guard !available.isEmpty else { return nil }
        if mode == .ordered { return available.first }
        var random = LibrarySeededRandom(seed: seed)
        if mode == .shuffle { return available[Int(random.next() % UInt64(available.count))] }
        let weighted = available.map { id -> (String, Double) in
            let state = catalog.memory[id] ?? .init()
            let rating = Double(state.rating ?? 0)
            let favorite = catalog.favorites.contains(id)
            let weight: Double
            if mode == .weighted {
                weight = max(0.05, 1 + rating * 0.65 + (favorite ? 1.5 : 0))
            } else {
                let count = Double(state.playCount)
                let ageBoost: Double
                if let recent = catalog.recent[id] {
                    ageBoost = min(3, max(0.25, now.timeIntervalSince(recent) / 86_400 + 0.25))
                } else { ageBoost = 3 }
                weight = max(0.05, ageBoost * (1 + rating * 0.15 + (favorite ? 0.35 : 0)) / (1 + count * 0.4))
            }
            return (id, weight)
        }
        let total = weighted.reduce(0) { $0 + $1.1 }
        var cursor = random.unit() * total
        for (id, weight) in weighted {
            cursor -= weight
            if cursor <= 0 { return id }
        }
        return weighted.last?.0
    }
}
''')

# SQLite extends existing normalized catalog rows; no second store.
replace_once(sqlite, '            var object: [String: Any] = ["minutes": playback.minutes, "shuffle": playback.shuffle]\n',
             '            var object: [String: Any] = ["minutes": playback.minutes, "shuffle": playback.shuffle]\n                if let mode = playback.mode { object["mode"] = mode.rawValue }\n')
replace_once(sqlite, '        root["collections"] = catalog.collections.enumerated().map { ordinal, collection -> [String: Any] in\n',
'''        root["memory"] = catalog.memory.keys.sorted().map { id -> [String: Any] in
            let memory = catalog.memory[id]!
            var value: [String: Any] = ["id": id, "playCount": memory.playCount]
            if let rating = memory.rating { value["rating"] = rating }
            return value
        }
        root["smartCollections"] = catalog.smartCollections.enumerated().map { ordinal, collection -> [String: Any] in
            ["ordinal": ordinal, "id": collection.id, "name": collection.name,
             "sort": collection.sort.rawValue, "predicates": collection.predicates.map(String.init(describing:))]
        }
        root["collections"] = catalog.collections.enumerated().map { ordinal, collection -> [String: Any] in
''')
replace_once(sqlite, '''        CREATE TABLE item_state (
            item_id TEXT PRIMARY KEY,
            recent_at REAL,
            play_position REAL
        ) WITHOUT ROWID;
''', '''        CREATE TABLE item_state (
            item_id TEXT PRIMARY KEY,
            recent_at REAL,
            play_position REAL,
            rating INTEGER CHECK(rating BETWEEN 1 AND 5),
            play_count INTEGER NOT NULL DEFAULT 0 CHECK(play_count >= 0)
        ) WITHOUT ROWID;
''')
replace_once(sqlite, '            playback_shuffle INTEGER,\n            playback_start_minute INTEGER,\n',
             '            playback_shuffle INTEGER,\n            playback_mode TEXT,\n            playback_start_minute INTEGER,\n')
replace_once(sqlite, '''        CREATE TABLE user_stack_items (
            stack_id TEXT NOT NULL REFERENCES user_stacks(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
            PRIMARY KEY(stack_id, ordinal),
            UNIQUE(stack_id, entry_id)
        ) WITHOUT ROWID;
''', '''        CREATE TABLE user_stack_items (
            stack_id TEXT NOT NULL REFERENCES user_stacks(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
            PRIMARY KEY(stack_id, ordinal),
            UNIQUE(stack_id, entry_id)
        ) WITHOUT ROWID;
        CREATE TABLE smart_collections (
            id TEXT PRIMARY KEY,
            ordinal INTEGER NOT NULL UNIQUE,
            name TEXT NOT NULL,
            sort TEXT NOT NULL
        );
        CREATE TABLE smart_collection_predicates (
            collection_id TEXT NOT NULL REFERENCES smart_collections(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            kind TEXT NOT NULL,
            text_value TEXT,
            int_value INTEGER,
            bool_value INTEGER,
            PRIMARY KEY(collection_id, ordinal)
        ) WITHOUT ROWID;
''')
replace_once(sqlite, '        CREATE INDEX user_stack_items_entry ON user_stack_items(entry_id, stack_id);\n',
             '        CREATE INDEX user_stack_items_entry ON user_stack_items(entry_id, stack_id);\n        CREATE INDEX smart_predicates_kind ON smart_collection_predicates(kind, collection_id);\n')
replace_once(sqlite, '        CREATE UNIQUE INDEX collections_name_nocase ON collections(name COLLATE NOCASE);\n',
             '        CREATE UNIQUE INDEX collections_name_nocase ON collections(name COLLATE NOCASE);\n        CREATE UNIQUE INDEX smart_collections_name_nocase ON smart_collections(name COLLATE NOCASE);\n')
replace_once(sqlite, '        for table in ["user_stack_items", "user_stacks", "collection_items", "collection_weekdays", "collections", "item_state", "favorites",\n',
             '        for table in ["smart_collection_predicates", "smart_collections", "user_stack_items", "user_stacks", "collection_items", "collection_weekdays", "collections", "item_state", "favorites",\n')
replace_once(sqlite, '        try insertFavorites(catalog.favorites, in: db)\n        try insertState(catalog.recent, in: db)\n        try insertCollections(catalog.collections, in: db)\n',
             '        try insertFavorites(catalog.favorites, in: db)\n        try insertState(catalog.recent, memory: catalog.memory, in: db)\n        try insertSmartCollections(catalog.smartCollections, in: db)\n        try insertCollections(catalog.collections, in: db)\n')
replace_once(sqlite, '''    private static func insertState(_ recents: [String: Date], in db: Database) throws {
        let statement = try db.prepare("INSERT INTO item_state(item_id, recent_at, play_position) VALUES(?, ?, NULL)")
        for id in recents.keys.sorted() {
            try statement.bind(id, at: 1); try statement.bind(recents[id]!.timeIntervalSinceReferenceDate, at: 2)
            try statement.stepDone(); statement.reset()
        }
    }
''', '''    private static func insertState(_ recents: [String: Date], memory: [String: SceneLibraryStore.ItemMemory], in db: Database) throws {
        let statement = try db.prepare("INSERT INTO item_state(item_id, recent_at, play_position, rating, play_count) VALUES(?, ?, NULL, ?, ?)")
        let ids = Set(recents.keys).union(memory.keys)
        for id in ids.sorted() {
            try statement.bind(id, at: 1)
            if let recent = recents[id] { try statement.bind(recent.timeIntervalSinceReferenceDate, at: 2) } else { try statement.bindNull(at: 2) }
            try statement.bind(memory[id]?.rating, at: 3); try statement.bind(memory[id]?.playCount ?? 0, at: 4)
            try statement.stepDone(); statement.reset()
        }
    }
''')

smart_sql = '''
    private static func insertSmartCollections(_ collections: [SceneLibraryStore.SmartCollection], in db: Database) throws {
        let collection = try db.prepare("INSERT INTO smart_collections(id, ordinal, name, sort) VALUES(?, ?, ?, ?)")
        let predicate = try db.prepare("INSERT INTO smart_collection_predicates(collection_id, ordinal, kind, text_value, int_value, bool_value) VALUES(?, ?, ?, ?, ?, ?)")
        for (ordinal, value) in collections.enumerated() {
            try collection.bind(value.id, at: 1); try collection.bind(ordinal, at: 2); try collection.bind(value.name, at: 3)
            try collection.bind(value.sort.rawValue, at: 4); try collection.stepDone(); collection.reset()
            for (predicateOrdinal, valuePredicate) in value.predicates.enumerated() {
                let encoded = encodePredicate(valuePredicate)
                try predicate.bind(value.id, at: 1); try predicate.bind(predicateOrdinal, at: 2); try predicate.bind(encoded.kind, at: 3)
                try predicate.bind(encoded.text, at: 4); try predicate.bind(encoded.int, at: 5)
                if let bool = encoded.bool { try predicate.bind(bool ? 1 : 0, at: 6) } else { try predicate.bindNull(at: 6) }
                try predicate.stepDone(); predicate.reset()
            }
        }
    }
    private static func encodePredicate(_ predicate: SceneLibraryStore.SmartPredicate) -> (kind: String, text: String?, int: Int?, bool: Bool?) {
        switch predicate {
        case .favorite(let value): return ("favorite", nil, nil, value)
        case .ratingAtLeast(let value): return ("ratingAtLeast", nil, value, nil)
        case .playedAtLeast(let value): return ("playedAtLeast", nil, value, nil)
        case .unplayed: return ("unplayed", nil, nil, nil)
        case .mediaType(let value): return ("mediaType", value, nil, nil)
        case .series(let value): return ("series", value, nil, nil)
        case .character(let value): return ("character", value, nil, nil)
        case .tag(let value): return ("tag", value, nil, nil)
        case .sourceID(let value): return ("sourceID", value, nil, nil)
        case .duplicate: return ("duplicate", nil, nil, nil)
        }
    }
'''
replace_once(sqlite, '    private static func insertCollections(_ collections: [SceneLibraryStore.Collection], in db: Database) throws {\n',
             smart_sql + '    private static func insertCollections(_ collections: [SceneLibraryStore.Collection], in db: Database) throws {\n')
replace_once(sqlite, '''            INSERT INTO collections(id, ordinal, name, playback_present, playback_minutes, playback_shuffle,
                playback_start_minute, playback_end_minute, weekdays_present) VALUES(?,?,?,?,?,?,?,?,?)
''', '''            INSERT INTO collections(id, ordinal, name, playback_present, playback_minutes, playback_shuffle,
                playback_mode, playback_start_minute, playback_end_minute, weekdays_present) VALUES(?,?,?,?,?,?,?,?,?,?)
''')
replace_once(sqlite, '''            try collection.bind(playback == nil ? 0 : 1, at: 4); try collection.bind(playback?.minutes, at: 5)
            try collection.bind(playback.map { $0.shuffle ? 1 : 0 }, at: 6); try collection.bind(playback?.startMinute, at: 7)
            try collection.bind(playback?.endMinute, at: 8); try collection.bind(playback?.weekdays == nil ? 0 : 1, at: 9)
''', '''            try collection.bind(playback == nil ? 0 : 1, at: 4); try collection.bind(playback?.minutes, at: 5)
            try collection.bind(playback.map { $0.shuffle ? 1 : 0 }, at: 6); try collection.bind(playback?.mode?.rawValue, at: 7)
            try collection.bind(playback?.startMinute, at: 8); try collection.bind(playback?.endMinute, at: 9); try collection.bind(playback?.weekdays == nil ? 0 : 1, at: 10)
''')
replace_once(sqlite, '        catalog.recent = try readState(in: db)\n        catalog.stacks = try readStacks(in: db)\n',
             '        let state = try readState(in: db)\n        catalog.recent = state.recent\n        catalog.memory = state.memory\n        catalog.smartCollections = try readSmartCollections(in: db)\n        catalog.stacks = try readStacks(in: db)\n')
replace_once(sqlite, '            ("item_state", 256),\n',
             '            ("item_state", SceneLibraryStore.maxIndividualEntries + SceneLibraryStore.maxSourceEntries),\n            ("smart_collections", 32),\n            ("smart_collection_predicates", 32 * 8),\n')

# Replace state reader with combined recent + memory state.
start = read(sqlite)
old = '''    private static func readState(in db: Database) throws -> [String: Date] {
        let statement = try db.prepare("SELECT item_id, recent_at FROM item_state WHERE recent_at IS NOT NULL")
        var result: [String: Date] = [:]
        while try statement.stepRow() {
            guard let id = statement.text(0) else { throw failure("An item state row is invalid.") }
            result[id] = Date(timeIntervalSinceReferenceDate: statement.double(1))
        }
        return result
    }
'''
new = '''    private static func readState(in db: Database) throws -> (recent: [String: Date], memory: [String: SceneLibraryStore.ItemMemory]) {
        let statement = try db.prepare("SELECT item_id, recent_at, rating, play_count FROM item_state")
        var recent: [String: Date] = [:]
        var memory: [String: SceneLibraryStore.ItemMemory] = [:]
        while try statement.stepRow() {
            guard let id = statement.text(0) else { throw failure("An item state row is invalid.") }
            if !statement.isNull(1) { recent[id] = Date(timeIntervalSinceReferenceDate: statement.double(1)) }
            let rating = statement.isNull(2) ? nil : statement.int(2)
            let playCount = statement.int(3)
            if rating != nil || playCount > 0 { memory[id] = .init(rating: rating, playCount: playCount) }
        }
        return (recent, memory)
    }
'''
if old not in start: raise SystemExit('missing readState')
write(sqlite, start.replace(old, new, 1))

read_smart = '''
    private static func readSmartCollections(in db: Database) throws -> [SceneLibraryStore.SmartCollection] {
        var predicates: [String: [(Int, SceneLibraryStore.SmartPredicate)]] = [:]
        let rows = try db.prepare("SELECT collection_id, ordinal, kind, text_value, int_value, bool_value FROM smart_collection_predicates ORDER BY collection_id, ordinal")
        while try rows.stepRow() {
            guard let id = rows.text(0), let kind = rows.text(2) else { throw failure("A Smart Collection predicate row is invalid.") }
            predicates[id, default: []].append((rows.int(1), try decodePredicate(kind: kind, text: rows.text(3), int: rows.isNull(4) ? nil : rows.int(4), bool: rows.isNull(5) ? nil : rows.int(5) != 0)))
        }
        let statement = try db.prepare("SELECT id, name, sort FROM smart_collections ORDER BY ordinal")
        var result: [SceneLibraryStore.SmartCollection] = []
        while try statement.stepRow() {
            guard let id = statement.text(0), let name = statement.text(1), let rawSort = statement.text(2), let sort = SceneLibraryStore.SmartSort(rawValue: rawSort) else {
                throw failure("A Smart Collection row is invalid.")
            }
            result.append(.init(id: id, name: name, predicates: (predicates[id] ?? []).sorted { $0.0 < $1.0 }.map(\\.1), sort: sort))
        }
        return result
    }
    private static func decodePredicate(kind: String, text: String?, int: Int?, bool: Bool?) throws -> SceneLibraryStore.SmartPredicate {
        switch kind {
        case "favorite": if let bool { return .favorite(bool) }
        case "ratingAtLeast": if let int { return .ratingAtLeast(int) }
        case "playedAtLeast": if let int { return .playedAtLeast(int) }
        case "unplayed": return .unplayed
        case "mediaType": if let text { return .mediaType(text) }
        case "series": if let text { return .series(text) }
        case "character": if let text { return .character(text) }
        case "tag": if let text { return .tag(text) }
        case "sourceID": if let text { return .sourceID(text) }
        case "duplicate": return .duplicate
        default: break
        }
        throw failure("A Smart Collection predicate is invalid.")
    }
'''
replace_once(sqlite, '    private static func readCollections(in db: Database) throws -> [SceneLibraryStore.Collection] {\n',
             read_smart + '    private static func readCollections(in db: Database) throws -> [SceneLibraryStore.Collection] {\n')
replace_once(sqlite, '            SELECT id, name, playback_present, playback_minutes, playback_shuffle, playback_start_minute, playback_end_minute, weekdays_present\n',
             '            SELECT id, name, playback_present, playback_minutes, playback_shuffle, playback_mode, playback_start_minute, playback_end_minute, weekdays_present\n')
replace_once(sqlite, '''                var settings = SceneLibraryStore.Playback(minutes: statement.int(3), shuffle: statement.int(4) != 0,
                    startMinute: statement.isNull(5) ? nil : statement.int(5),
                    endMinute: statement.isNull(6) ? nil : statement.int(6),
                    weekdays: statement.int(7) == 0 ? nil : Set(weekdays[id] ?? []))
''', '''                var settings = SceneLibraryStore.Playback(minutes: statement.int(3), shuffle: statement.int(4) != 0,
                    mode: statement.text(5).flatMap(SceneLibraryStore.Playback.SelectionMode.init(rawValue:)),
                    startMinute: statement.isNull(6) ? nil : statement.int(6),
                    endMinute: statement.isNull(7) ? nil : statement.int(7),
                    weekdays: statement.int(8) == 0 ? nil : Set(weekdays[id] ?? []))
''')

# Tests.
Path('Tests/LibraryMemoryTests.swift').write_text(r'''import Foundation

@main
struct LibraryMemoryChecks {
    static func main() throws {
        let source = SceneLibraryStore.SourceRoot(id: "s", name: "Source", bookmark: Data([1]))
        func entry(_ id: String, _ title: String, series: String, type: String, tags: [String] = [], digest: String? = nil) -> SceneLibraryStore.Entry {
            var observation: SceneLibraryStore.ReconciliationObservation? = nil
            if let digest { observation = .init(byteLength: 10, digestAlgorithm: "sha256", digest: digest) }
            return .init(id: id, title: title, sourceID: source.id, relativeMediaPath: id + ".jpg",
                         series: series, tags: tags, mediaType: type, availability: .present, observation: observation)
        }
        var catalog = SceneLibraryStore.Catalog()
        catalog.sources = [source]
        catalog.entries = [
            entry("a", "Aurora", series: "Sky", type: "image", tags: ["calm"], digest: "same"),
            entry("b", "Borealis", series: "Sky", type: "video", tags: ["calm"], digest: "same"),
            entry("c", "City", series: "Urban", type: "image"),
            entry("d", "Desert", series: "Earth", type: "image")
        ]
        catalog.favorites = ["a", "c"]
        catalog.memory = ["a": .init(rating: 5, playCount: 8), "b": .init(rating: 4, playCount: 1), "c": .init(rating: 2, playCount: 0)]
        catalog.recent = ["a": Date(timeIntervalSinceReferenceDate: 1000), "b": Date(timeIntervalSinceReferenceDate: 500)]

        let smart = SceneLibraryStore.SmartCollection(id: "smart", name: "Loved Sky",
            predicates: [.favorite(true), .ratingAtLeast(4), .series("Sky")], sort: .rating)
        catalog.smartCollections = [smart]
        precondition(LibrarySmartCollectionEngine.members(of: smart, in: catalog).map(\.id) == ["a"])
        let unplayed = SceneLibraryStore.SmartCollection(id: "u", name: "Unplayed Images", predicates: [.unplayed, .mediaType("image")])
        precondition(LibrarySmartCollectionEngine.members(of: unplayed, in: catalog).map(\.id) == ["c", "d"])
        let duplicates = LibraryDuplicateDetector.exactGroups(in: catalog)
        precondition(duplicates.count == 1 && Set(duplicates[0].entryIDs) == ["a", "b"])
        let dupSmart = SceneLibraryStore.SmartCollection(id: "dup", name: "Duplicates", predicates: [.duplicate])
        precondition(Set(LibrarySmartCollectionEngine.members(of: dupSmart, in: catalog).map(\.id)) == ["a", "b"])

        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let w1 = LibraryMemoryPlayback.select(from: ["a", "b", "c", "d"], catalog: catalog, mode: .weighted, seed: 42, now: now)
        let w2 = LibraryMemoryPlayback.select(from: ["a", "b", "c", "d"], catalog: catalog, mode: .weighted, seed: 42, now: now)
        precondition(w1 == w2 && w1 != nil)
        let s1 = LibraryMemoryPlayback.select(from: ["a", "b", "c", "d"], catalog: catalog, mode: .surprise, seed: 77, now: now)
        let s2 = LibraryMemoryPlayback.select(from: ["a", "b", "c", "d"], catalog: catalog, mode: .surprise, seed: 77, now: now)
        precondition(s1 == s2 && s1 != nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let json = root.appendingPathComponent("index.json")
        try JSONEncoder().encode(catalog).write(to: json)
        let store = try SceneLibraryStore(file: json)
        try store.rate("d", rating: 3)
        try store.used("d", at: Date(timeIntervalSinceReferenceDate: 11_000))
        precondition(store.catalog.memory["d"] == .init(rating: 3, playCount: 1))
        precondition(store.catalog.recent["d"] == Date(timeIntervalSinceReferenceDate: 11_000))

        var roundTripCatalog = store.catalog
        roundTripCatalog.smartCollections = [smart, unplayed, dupSmart]
        try SceneLibrarySQLiteCatalog.migrate(roundTripCatalog, fromJSON: json)
        let sqlite = try SceneLibrarySQLiteCatalog.readSelectedCatalog(for: json)
        precondition(sqlite == roundTripCatalog, "Ratings, play counts, modes and Smart Collections must round-trip through SQLite")

        print("Library memory checks passed: ratings, play counts, Smart Collections, weighted/surprise selection, duplicates, SQLite")
    }
}
''')

# Hook focused suite into test.sh.
test_block = '''
# 11. Library memory, Smart Collections, weighted playback and duplicate detection.
LIBRARY_MEMORY_SRCS=(
  Sources/Harness/SceneLibraryStore.swift
  Sources/Harness/SceneLibraryReconciliation.swift
  Sources/Harness/SceneLibrarySQLiteStore.swift
  Sources/Harness/SceneLibraryStacks.swift
  Sources/Harness/SceneLibraryMemory.swift
  Tests/LibraryMemoryTests.swift
)
if needs_build "build/tests/library-memory" "${LIBRARY_MEMORY_SRCS[@]}"; then
  xcrun swiftc "$OPT_FLAG" "${LIBRARY_MEMORY_SRCS[@]}" -lsqlite3 -o build/tests/library-memory &
  pids+=($!)
fi

'''
replace_once('test.sh', '# Await any parallel background compilations\n', test_block + '# Await any parallel background compilations\n')
replace_once('test.sh', 'build/tests/library-stacks\n', 'build/tests/library-stacks\nbuild/tests/library-memory\n')

Path('docs/library-memory.md').write_text('''# Library memory and Smart Collections\n\nThis #25 slice stays inside the Quarry catalog. Ratings and play counts are keyed by stable `Entry.id` in SQLite `item_state`; ordinary collections remain concrete ordered entry IDs.\n\nSmart Collections are saved definitions, not copied membership. Each uses 1–8 predicates from a bounded vocabulary: favorite, minimum rating, minimum plays, unplayed, media type, series, character, tag, Source ID, and exact duplicate. Predicates combine with AND and members are recomputed from current catalog state. Sort choices are name, rating, recent use, or play count.\n\nWeighted playback boosts ratings/favorites. Surprise playback favors less-played and less-recent entries while still allowing modest favorite/rating bias. Both accept a deterministic seed for tests. Repetition history belongs to Drift (#37), which stacks next.\n\nDuplicate detection is conservative: individual imports already coalesce the same resolved file, while catalog duplicate groups require identical verified content digests. It never silently merges entries or user state.\n\nA disk thumbnail cache is intentionally deferred: #35/#36 already bound live thumbnail work, and this slice has no repeated-browsing measurement showing disk caching would repay its invalidation and storage cost.\n\n📚 Curator\n''')

print('Curator memory model patch applied')
