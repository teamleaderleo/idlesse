from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:80]!r}")
    p.write_text(text.replace(old, new, 1))


sqlite = "Sources/Harness/SceneLibrarySQLiteStore.swift"
replace_once(sqlite, '    static let schemaVersion = 2\n', '    static let schemaVersion = 3\n')
replace_once(sqlite, r'''        return try readCatalog(at: paths(for: jsonFile).database)
    }

    /// Applies only changed rows/relationships inside one IMMEDIATE transaction.
''', r'''        let url = paths(for: jsonFile).database
        try upgradeSchemaIfNeeded(at: url)
        return try readCatalog(at: url)
    }

    /// Applies only changed rows/relationships inside one IMMEDIATE transaction.
''')
replace_once(sqlite, r'''        let url = paths(for: jsonFile).database
        try ensureDatabaseBound(url)
        let db = try Database(url: url, mode: .readWrite)
''', r'''        let url = paths(for: jsonFile).database
        try upgradeSchemaIfNeeded(at: url)
        try ensureDatabaseBound(url)
        let db = try Database(url: url, mode: .readWrite)
''')
replace_once(sqlite, r'''            try applyEntries(current: current.entries, next: next.entries, in: db)
            try applyFavorites(current: current.favorites, next: next.favorites, in: db)
''', r'''            try applyEntries(current: current.entries, next: next.entries, in: db)
            try applyStacks(current: current.stacks, next: next.stacks, in: db)
            try applyFavorites(current: current.favorites, next: next.favorites, in: db)
''')
replace_once(sqlite, r'''    static func verifyDatabase(at url: URL) throws {
''', r'''    private static func upgradeSchemaIfNeeded(at url: URL) throws {
        try ensureDatabaseBound(url)
        let db = try Database(url: url, mode: .readWrite)
        try configureWritePragmas(db, isNew: false)
        var changed = false
        try db.transaction {
            let version = try db.scalarInt("PRAGMA user_version")
            if version == schemaVersion { return }
            guard version == 2 else {
                throw failure("This Library database uses unsupported schema version \(version).")
            }
            try db.execute("""
                ALTER TABLE entries ADD COLUMN group_id TEXT;
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
                CREATE INDEX entries_source_group ON entries(source_id, group_id);
                CREATE UNIQUE INDEX user_stack_items_entry ON user_stack_items(entry_id);
                CREATE UNIQUE INDEX user_stacks_name_nocase ON user_stacks(name COLLATE NOCASE);
                UPDATE catalog_meta SET value='3' WHERE key='schema_version';
                PRAGMA user_version = 3;
                """)
            try verifyTransaction(in: db)
            changed = true
        }
        try ensureDatabaseBound(url)
        if changed { try synchronizeFile(at: url) }
    }

    static func verifyDatabase(at url: URL) throws {
''')
replace_once(sqlite, r'''        guard ["sources", "entries", "collections", "collection_items"].contains(table) else { return [] }
''', r'''        guard ["sources", "entries", "collections", "collection_items", "user_stacks", "user_stack_items"].contains(table) else { return [] }
''')
replace_once(sqlite, '            "format": "idlesse-library-debug-v2",\n', '            "format": "idlesse-library-debug-v3",\n')
replace_once(sqlite, r'''            put(entry.catalogID, "catalogID", into: &value)
            put(entry.sourceID, "sourceID", into: &value)
''', r'''            put(entry.catalogID, "catalogID", into: &value)
            put(entry.groupID, "groupID", into: &value)
            put(entry.sourceID, "sourceID", into: &value)
''')
replace_once(sqlite, r'''        root["recents"] = catalog.recent.keys.sorted().map { id in
            ["id": id, "usedAt": catalog.recent[id]!.timeIntervalSinceReferenceDate] as [String: Any]
        }
        root["collections"] = catalog.collections.enumerated().map { ordinal, collection -> [String: Any] in
''', r'''        root["recents"] = catalog.recent.keys.sorted().map { id in
            ["id": id, "usedAt": catalog.recent[id]!.timeIntervalSinceReferenceDate] as [String: Any]
        }
        root["stacks"] = catalog.stacks.enumerated().map { ordinal, stack -> [String: Any] in
            var value: [String: Any] = [
                "ordinal": ordinal, "id": stack.id, "name": stack.name, "sceneIDs": stack.sceneIDs
            ]
            put(stack.representativeID, "representativeID", into: &value)
            return value
        }
        root["collections"] = catalog.collections.enumerated().map { ordinal, collection -> [String: Any] in
''')
replace_once(sqlite, r'''            obs_digest_algorithm TEXT,
            obs_digest TEXT,
            obs_package_revision TEXT
        );
''', r'''            obs_digest_algorithm TEXT,
            obs_digest TEXT,
            obs_package_revision TEXT,
            group_id TEXT
        );
''')
replace_once(sqlite, r'''        CREATE TABLE collection_items (
            collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            scene_id TEXT NOT NULL,
            variant_id TEXT,
            PRIMARY KEY(collection_id, ordinal)
        ) WITHOUT ROWID;
        CREATE UNIQUE INDEX entries_source_catalog_identity
''', r'''        CREATE TABLE collection_items (
            collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            scene_id TEXT NOT NULL,
            variant_id TEXT,
            PRIMARY KEY(collection_id, ordinal)
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
        CREATE UNIQUE INDEX entries_source_catalog_identity
''')
replace_once(sqlite, r'''        CREATE INDEX entries_source_availability ON entries(source_id, availability);
        CREATE INDEX entries_media_type ON entries(media_type);
''', r'''        CREATE INDEX entries_source_availability ON entries(source_id, availability);
        CREATE INDEX entries_source_group ON entries(source_id, group_id);
        CREATE INDEX entries_media_type ON entries(media_type);
''')
replace_once(sqlite, r'''        CREATE UNIQUE INDEX collection_items_selection
            ON collection_items(collection_id, scene_id, ifnull(variant_id, ''));
        CREATE UNIQUE INDEX collections_name_nocase ON collections(name COLLATE NOCASE);
''', r'''        CREATE UNIQUE INDEX collection_items_selection
            ON collection_items(collection_id, scene_id, ifnull(variant_id, ''));
        CREATE UNIQUE INDEX user_stack_items_entry ON user_stack_items(entry_id);
        CREATE UNIQUE INDEX user_stacks_name_nocase ON user_stacks(name COLLATE NOCASE);
        CREATE UNIQUE INDEX collections_name_nocase ON collections(name COLLATE NOCASE);
''')
replace_once(sqlite, r'''        try insertSources(catalog.sources, in: db)
        try insertEntries(catalog.entries, in: db)
        try insertFavorites(catalog.favorites, in: db)
''', r'''        try insertSources(catalog.sources, in: db)
        try insertEntries(catalog.entries, in: db)
        try insertStacks(catalog.stacks, in: db)
        try insertFavorites(catalog.favorites, in: db)
''')
replace_once(sqlite, r'''    private static func insertFavorites(_ favorites: Set<String>, in db: Database) throws {
''', r'''    private static func insertStacks(_ stacks: [SceneLibraryStore.UserStack], in db: Database) throws {
        for (ordinal, value) in stacks.enumerated() {
            try upsertStackRow(value, ordinal: ordinal, in: db)
            try replaceStackItems(value, in: db)
        }
    }

    private static func insertFavorites(_ favorites: Set<String>, in db: Database) throws {
''')
replace_once(sqlite, r'''    private static func applyFavorites(current: Set<String>, next: Set<String>, in db: Database) throws {
''', r'''    private static func applyStacks(current: [SceneLibraryStore.UserStack], next: [SceneLibraryStore.UserStack], in db: Database) throws {
        guard current != next else { return }
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let nextIDs = Set(next.map(\.id))
        let delete = try db.prepare("DELETE FROM user_stacks WHERE id=?")
        for value in current where !nextIDs.contains(value.id) {
            try delete.bind(value.id, at: 1); try delete.stepDone(); delete.reset()
        }
        let orderChanged = current.map(\.id) != next.map(\.id)
        if orderChanged { try shiftOrdinals(table: "user_stacks", in: db) }

        let temporaryNames = try db.prepare("UPDATE user_stacks SET name=? WHERE id=?")
        for value in next where currentByID[value.id] != nil && currentByID[value.id]?.name != value.name {
            try temporaryNames.bind("__idlesse_tmp__\(UUID().uuidString)", at: 1)
            try temporaryNames.bind(value.id, at: 2); try temporaryNames.stepDone(); temporaryNames.reset()
        }
        for (ordinal, value) in next.enumerated() {
            let old = currentByID[value.id]
            if old == nil || old?.name != value.name || old?.representativeID != value.representativeID {
                try upsertStackRow(value, ordinal: orderChanged ? stagedOrdinalOffset + ordinal : ordinal, in: db)
            }
            if old == nil || old?.sceneIDs != value.sceneIDs { try replaceStackItems(value, in: db) }
        }
        if orderChanged { try setOrdinals(table: "user_stacks", ids: next.map(\.id), in: db) }
    }

    private static func applyFavorites(current: Set<String>, next: Set<String>, in db: Database) throws {
''')
replace_once(sqlite, r'''                obs_digest_algorithm, obs_digest, obs_package_revision)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
''', r'''                obs_digest_algorithm, obs_digest, obs_package_revision, group_id)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
''')
replace_once(sqlite, r'''                obs_digest_algorithm=excluded.obs_digest_algorithm, obs_digest=excluded.obs_digest,
                obs_package_revision=excluded.obs_package_revision
''', r'''                obs_digest_algorithm=excluded.obs_digest_algorithm, obs_digest=excluded.obs_digest,
                obs_package_revision=excluded.obs_package_revision, group_id=excluded.group_id
''')
replace_once(sqlite, r'''        try statement.bind(value.observation?.digestAlgorithm, at: 22); try statement.bind(value.observation?.digest, at: 23)
        try statement.bind(value.observation?.packageRevision, at: 24); try statement.stepDone()
''', r'''        try statement.bind(value.observation?.digestAlgorithm, at: 22); try statement.bind(value.observation?.digest, at: 23)
        try statement.bind(value.observation?.packageRevision, at: 24); try statement.bind(value.groupID, at: 25); try statement.stepDone()
''')
replace_once(sqlite, r'''    private static func upsertCollection(_ value: SceneLibraryStore.Collection, ordinal: Int, in db: Database) throws {
''', r'''    private static func upsertStackRow(_ value: SceneLibraryStore.UserStack, ordinal: Int, in db: Database) throws {
        let statement = try db.prepare("""
            INSERT INTO user_stacks(id, ordinal, name, representative_entry_id) VALUES(?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET ordinal=excluded.ordinal, name=excluded.name,
                representative_entry_id=excluded.representative_entry_id
            """)
        try statement.bind(value.id, at: 1); try statement.bind(ordinal, at: 2); try statement.bind(value.name, at: 3)
        try statement.bind(value.representativeID, at: 4); try statement.stepDone()
    }

    private static func replaceStackItems(_ value: SceneLibraryStore.UserStack, in db: Database) throws {
        let clear = try db.prepare("DELETE FROM user_stack_items WHERE stack_id=?")
        try clear.bind(value.id, at: 1); try clear.stepDone()
        let item = try db.prepare("INSERT INTO user_stack_items(stack_id, ordinal, entry_id) VALUES(?,?,?)")
        for (ordinal, entryID) in value.sceneIDs.enumerated() {
            try item.bind(value.id, at: 1); try item.bind(ordinal, at: 2); try item.bind(entryID, at: 3)
            try item.stepDone(); item.reset()
        }
    }

    private static func upsertCollection(_ value: SceneLibraryStore.Collection, ordinal: Int, in db: Database) throws {
''')
replace_once(sqlite, r'''        catalog.entries = try readEntries(in: db)
        catalog.favorites = try readFavorites(in: db)
''', r'''        catalog.entries = try readEntries(in: db)
        catalog.stacks = try readStacks(in: db)
        catalog.favorites = try readFavorites(in: db)
''')
replace_once(sqlite, r'''            ("item_state", 256), ("collections", 32), ("collection_weekdays", 32 * 7),
            ("collection_items", 32 * 256), ("entry_tags", total * 64),
''', r'''            ("item_state", 256), ("collections", 32), ("collection_weekdays", 32 * 7),
            ("collection_items", 32 * 256), ("user_stacks", 128), ("user_stack_items", 128 * 256),
            ("entry_tags", total * 64),
''')
replace_once(sqlite, r'''                   provenance_present, observation_present, obs_byte_length, obs_modified_at,
                   obs_digest_algorithm, obs_digest, obs_package_revision
            FROM entries ORDER BY ordinal
''', r'''                   provenance_present, observation_present, obs_byte_length, obs_modified_at,
                   obs_digest_algorithm, obs_digest, obs_package_revision, group_id
            FROM entries ORDER BY ordinal
''')
replace_once(sqlite, r'''            result.append(.init(id: id, title: title, bookmark: statement.data(2), catalogID: statement.text(3),
                sourceID: statement.text(4), relativeMediaPath: statement.text(5), relativePosterPath: statement.text(6),
''', r'''            result.append(.init(id: id, title: title, bookmark: statement.data(2), catalogID: statement.text(3),
                groupID: statement.text(23), sourceID: statement.text(4), relativeMediaPath: statement.text(5), relativePosterPath: statement.text(6),
''')
replace_once(sqlite, r'''    private static func readFavorites(in db: Database) throws -> Set<String> {
''', r'''    private static func readStacks(in db: Database) throws -> [SceneLibraryStore.UserStack] {
        var items: [String: [(Int, String)]] = [:]
        let itemRows = try db.prepare("SELECT stack_id, ordinal, entry_id FROM user_stack_items ORDER BY stack_id, ordinal")
        while try itemRows.stepRow() {
            guard let stackID = itemRows.text(0), let entryID = itemRows.text(2) else { throw failure("A stack item row is invalid.") }
            items[stackID, default: []].append((itemRows.int(1), entryID))
        }
        let statement = try db.prepare("SELECT id, name, representative_entry_id FROM user_stacks ORDER BY ordinal")
        var result: [SceneLibraryStore.UserStack] = []
        while try statement.stepRow() {
            guard let id = statement.text(0), let name = statement.text(1) else { throw failure("A stack row is invalid.") }
            result.append(.init(id: id, name: name,
                sceneIDs: (items[id] ?? []).sorted { $0.0 < $1.0 }.map(\.1), representativeID: statement.text(2)))
        }
        return result
    }

    private static func readFavorites(in db: Database) throws -> Set<String> {
''')

print("sqlite transformed")
