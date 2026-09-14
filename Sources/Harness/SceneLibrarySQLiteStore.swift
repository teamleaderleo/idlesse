import Foundation
import SQLite3

/// SQLite owns catalog/state only after a verified selector-last migration.
/// Media remains external. The retained JSON file is historical recovery evidence
/// after activation and is never silently dual-written with the database.
enum SceneLibrarySQLiteCatalog {
    static let schemaVersion = 3
    static let selectorValue = "sqlite-v2\n"
    static let maxDatabaseBytes: Int64 = 64 * 1024 * 1024
    private static let pageSize = 4096
    private static let maxPageCount = Int(maxDatabaseBytes) / pageSize
    private static let shiftedOrdinalOffset = 1_000_000
    private static let stagedOrdinalOffset = 2_000_000

    struct Paths: Equatable {
        let database: URL
        let candidate: URL
        let selector: URL
        let corruptBackup: URL
    }

    static func paths(for jsonFile: URL) -> Paths {
        let base = jsonFile.deletingPathExtension()
        return Paths(database: base.appendingPathExtension("sqlite3"),
                     candidate: base.appendingPathExtension("sqlite3.candidate"),
                     selector: base.appendingPathExtension("backend"),
                     corruptBackup: base.appendingPathExtension("sqlite3.corrupt"))
    }

    static func hasSQLiteSelector(for jsonFile: URL) throws -> Bool {
        let selector = paths(for: jsonFile).selector
        guard FileManager.default.fileExists(atPath: selector.path) else { return false }
        let attributes = try FileManager.default.attributesOfItem(atPath: selector.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 64 else { throw failure("The Library backend selector is invalid.") }
        let data = try Data(contentsOf: selector)
        guard String(data: data, encoding: .utf8) == selectorValue else {
            throw failure("This Library uses an unsupported catalog backend version.")
        }
        return true
    }

    /// Builds and verifies a sibling candidate, publishes the database, then switches
    /// the tiny selector last. The caller owns the Library write lock.
    static func migrate(_ catalog: SceneLibraryStore.Catalog, fromJSON jsonFile: URL) throws {
        guard try !hasSQLiteSelector(for: jsonFile) else { return }
        let paths = paths(for: jsonFile)
        let manager = FileManager.default
        try manager.createDirectory(at: jsonFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.removeItem(at: paths.candidate)
        do {
            try buildCandidate(catalog, at: paths.candidate)
            try verifyDatabase(at: paths.candidate)
            let roundTrip = try readCatalog(at: paths.candidate)
            guard roundTrip == catalog else {
                throw failure("SQLite migration verification found a semantic mismatch.")
            }
            try synchronizeFile(at: paths.candidate)
            if getenv("IDLESSE_LIBRARY_SQLITE_TEST_FAIL_BEFORE_SELECTOR").map({ String(cString: $0) }) == "1" {
                throw failure("Injected SQLite migration failure before selector publication.")
            }
        } catch {
            try? manager.removeItem(at: paths.candidate)
            throw error
        }

        let hadExistingDatabase = manager.fileExists(atPath: paths.database.path)
        if manager.fileExists(atPath: paths.corruptBackup.path) {
            try manager.removeItem(at: paths.corruptBackup)
        }
        if hadExistingDatabase {
            try manager.moveItem(at: paths.database, to: paths.corruptBackup)
        }
        do {
            try manager.moveItem(at: paths.candidate, to: paths.database)
            try synchronizeFile(at: paths.database)
            try synchronizeDirectory(at: jsonFile.deletingLastPathComponent())
            try Data(selectorValue.utf8).write(to: paths.selector, options: .atomic)
            try synchronizeFile(at: paths.selector)
            try synchronizeDirectory(at: jsonFile.deletingLastPathComponent())
        } catch {
            // Selector publication is the authority switch. If a later selector or
            // directory sync fails, remove that selector before rolling the database
            // back so no process can observe a selected database we are discarding.
            try? manager.removeItem(at: paths.selector)
            try? manager.removeItem(at: paths.candidate)
            if manager.fileExists(atPath: paths.database.path) {
                try? manager.removeItem(at: paths.database)
            }
            if hadExistingDatabase, manager.fileExists(atPath: paths.corruptBackup.path) {
                try? manager.moveItem(at: paths.corruptBackup, to: paths.database)
            }
            try? synchronizeDirectory(at: jsonFile.deletingLastPathComponent())
            throw error
        }
    }

    static func readSelectedCatalog(for jsonFile: URL) throws -> SceneLibraryStore.Catalog {
        guard try hasSQLiteSelector(for: jsonFile) else {
            throw failure("The SQLite Library backend is not active.")
        }
        return try readCatalog(at: paths(for: jsonFile).database)
    }

    /// Called only while the caller owns the Library's external writer lock.
    /// Keeps readSelectedCatalog itself read-only so schema mutation cannot escape
    /// the flock-coordinated path.
    static func upgradeSelectedCatalogIfNeeded(for jsonFile: URL) throws {
        guard try hasSQLiteSelector(for: jsonFile) else {
            throw failure("The SQLite Library backend is not active.")
        }
        try upgradeSchemaIfNeeded(at: paths(for: jsonFile).database)
    }

    /// Applies only changed rows/relationships inside one IMMEDIATE transaction.
    /// The caller owns the cross-process Library lock and has already rebased stale
    /// in-memory state against `current`.
    static func applyCatalogDelta(current: SceneLibraryStore.Catalog,
                                  next: SceneLibraryStore.Catalog,
                                  for jsonFile: URL) throws {
        guard try hasSQLiteSelector(for: jsonFile) else {
            throw failure("The SQLite Library backend is not active.")
        }
        let url = paths(for: jsonFile).database
        try upgradeSchemaIfNeeded(at: url)
        try ensureDatabaseBound(url)
        let db = try Database(url: url, mode: .readWrite)
        try configureWritePragmas(db, isNew: false)
        let version = try db.scalarInt("PRAGMA user_version")
        guard version == schemaVersion else {
            throw failure("This Library database uses unsupported schema version \(version).")
        }

        try db.transaction {
            let actual = try readCatalog(in: db)
            guard actual == current else {
                throw failure("The Library database changed outside the coordinated writer path.")
            }
            try applyEntryDeletions(current: current.entries, next: next.entries, in: db)
            try applySources(current: current.sources, next: next.sources, in: db)
            try applyEntries(current: current.entries, next: next.entries, in: db)
            try applyStacks(current: current.stacks, next: next.stacks, in: db)
            try applyFavorites(current: current.favorites, next: next.favorites, in: db)
            try applyRecent(current: current.recent, next: next.recent, in: db)
            try applyCollections(current: current.collections, next: next.collections, in: db)
            try setCatalogVersion(next.version, in: db)
            try verifyTransaction(in: db)
            let roundTrip = try readCatalog(in: db)
            guard roundTrip == next else { throw failure("SQLite mutation verification found a semantic mismatch.") }
        }
        try ensureDatabaseBound(url)
        try synchronizeFile(at: url)
    }

    private static func upgradeSchemaIfNeeded(at url: URL) throws {
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
        try ensureDatabaseBound(url)
        let db = try Database(url: url, mode: .readOnly)
        let version = try db.scalarInt("PRAGMA user_version")
        guard version == schemaVersion else {
            throw failure("This Library database uses unsupported schema version \(version).")
        }
        try verifyTransaction(in: db)
    }

    static func indexNames(at url: URL) throws -> Set<String> {
        let db = try Database(url: url, mode: .readOnly)
        let statement = try db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        var names = Set<String>()
        while try statement.stepRow() { if let value = statement.text(0) { names.insert(value) } }
        return names
    }

    static func columnNames(table: String, at url: URL) throws -> Set<String> {
        guard ["sources", "entries", "collections", "collection_items", "user_stacks", "user_stack_items"].contains(table) else { return [] }
        let db = try Database(url: url, mode: .readOnly)
        let statement = try db.prepare("PRAGMA table_info(\(table))")
        var names = Set<String>()
        while try statement.stepRow() { if let value = statement.text(1) { names.insert(value) } }
        return names
    }

    /// Test-only hook used to prove high-churn mutations do not rewrite unrelated tables.
    static func testingExecute(_ sql: String, for jsonFile: URL) throws {
        let db = try Database(url: paths(for: jsonFile).database, mode: .readWrite)
        try db.execute(sql)
    }

    static func deterministicDebugExport(_ catalog: SceneLibraryStore.Catalog) throws -> Data {
        var root: [String: Any] = [
            "format": "idlesse-library-debug-v3",
            "catalogVersion": catalog.version,
            "sqliteSchemaVersion": schemaVersion,
            "favorites": catalog.favorites.sorted()
        ]
        root["sources"] = catalog.sources.enumerated().map { ordinal, source -> [String: Any] in
            var value: [String: Any] = [
                "ordinal": ordinal, "id": source.id, "name": source.name,
                "bookmarkBase64": source.bookmark.base64EncodedString(),
                "metadataPresent": source.catalogMetadata != nil
            ]
            if let metadata = source.catalogMetadata {
                value["metadata"] = Dictionary(uniqueKeysWithValues: metadata.keys.sorted().map { ($0, metadata[$0]!) })
            }
            return value
        }
        root["entries"] = catalog.entries.enumerated().map { ordinal, entry -> [String: Any] in
            var value: [String: Any] = [
                "ordinal": ordinal, "id": entry.id, "title": entry.title,
                "tags": entry.tags, "availability": entry.availability.rawValue,
                "provenancePresent": entry.provenance != nil,
                "observationPresent": entry.observation != nil
            ]
            if let bookmark = entry.bookmark { value["bookmarkBase64"] = bookmark.base64EncodedString() }
            put(entry.catalogID, "catalogID", into: &value)
            put(entry.groupID, "groupID", into: &value)
            put(entry.sourceID, "sourceID", into: &value)
            put(entry.relativeMediaPath, "relativeMediaPath", into: &value)
            put(entry.relativePosterPath, "relativePosterPath", into: &value)
            put(entry.series, "series", into: &value)
            put(entry.character, "character", into: &value)
            put(entry.variant, "variant", into: &value)
            put(entry.mediaType, "mediaType", into: &value)
            if let width = entry.width { value["width"] = width }
            if let height = entry.height { value["height"] = height }
            if let fps = entry.fps { value["fps"] = fps }
            if let duration = entry.duration { value["duration"] = duration }
            if let provenance = entry.provenance {
                value["provenance"] = Dictionary(uniqueKeysWithValues: provenance.keys.sorted().map { ($0, provenance[$0]!) })
            }
            if let observation = entry.observation {
                var object: [String: Any] = [:]
                if let byteLength = observation.byteLength { object["byteLength"] = byteLength }
                if let modifiedAt = observation.modifiedAt { object["modifiedAt"] = modifiedAt.timeIntervalSinceReferenceDate }
                put(observation.digestAlgorithm, "digestAlgorithm", into: &object)
                put(observation.digest, "digest", into: &object)
                put(observation.packageRevision, "packageRevision", into: &object)
                value["observation"] = object
            }
            return value
        }
        root["recents"] = catalog.recent.keys.sorted().map { id in
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
            var value: [String: Any] = [
                "ordinal": ordinal, "id": collection.id, "name": collection.name,
                "sceneIDs": collection.sceneIDs
            ]
            if let playback = collection.playback {
                var object: [String: Any] = ["minutes": playback.minutes, "shuffle": playback.shuffle]
                if let start = playback.startMinute { object["startMinute"] = start }
                if let end = playback.endMinute { object["endMinute"] = end }
                if let weekdays = playback.weekdays { object["weekdays"] = weekdays.sorted() }
                value["playback"] = object
            }
            return value
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func put(_ string: String?, _ key: String, into dictionary: inout [String: Any]) {
        if let string { dictionary[key] = string }
    }

    private static func buildCandidate(_ catalog: SceneLibraryStore.Catalog, at url: URL) throws {
        let db = try Database(url: url, mode: .create)
        try configureWritePragmas(db, isNew: true)
        try db.transaction {
            try createSchema(in: db)
            try insertCatalog(catalog, in: db)
            try verifyTransaction(in: db)
        }
        try ensureDatabaseBound(url)
    }

    private static func configureWritePragmas(_ db: Database, isNew: Bool) throws {
        try db.execute("PRAGMA foreign_keys = ON")
        try db.execute("PRAGMA journal_mode = DELETE")
        try db.execute("PRAGMA synchronous = FULL")
        if isNew { try db.execute("PRAGMA page_size = \(pageSize)") }
        try db.execute("PRAGMA max_page_count = \(maxPageCount)")
        try db.execute("PRAGMA busy_timeout = 5000")
    }

    private static func createSchema(in db: Database) throws {
        try db.execute("PRAGMA user_version = \(schemaVersion)")
        try db.execute("""
        CREATE TABLE catalog_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        ) WITHOUT ROWID;
        CREATE TABLE sources (
            id TEXT PRIMARY KEY,
            ordinal INTEGER NOT NULL UNIQUE,
            name TEXT NOT NULL,
            bookmark BLOB NOT NULL,
            metadata_present INTEGER NOT NULL CHECK(metadata_present IN (0,1))
        );
        CREATE TABLE source_metadata (
            source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY(source_id, key)
        ) WITHOUT ROWID;
        CREATE TABLE entries (
            id TEXT PRIMARY KEY,
            ordinal INTEGER NOT NULL UNIQUE,
            title TEXT NOT NULL,
            bookmark BLOB,
            catalog_id TEXT,
            source_id TEXT REFERENCES sources(id) ON DELETE CASCADE,
            relative_media_path TEXT,
            relative_poster_path TEXT,
            series TEXT,
            character TEXT,
            variant TEXT,
            media_type TEXT,
            width INTEGER,
            height INTEGER,
            fps REAL,
            duration REAL,
            availability TEXT NOT NULL CHECK(availability IN ('present','missing')),
            provenance_present INTEGER NOT NULL CHECK(provenance_present IN (0,1)),
            observation_present INTEGER NOT NULL CHECK(observation_present IN (0,1)),
            obs_byte_length INTEGER,
            obs_modified_at REAL,
            obs_digest_algorithm TEXT,
            obs_digest TEXT,
            obs_package_revision TEXT,
            group_id TEXT
        );
        CREATE TABLE entry_tags (
            entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY(entry_id, ordinal)
        ) WITHOUT ROWID;
        CREATE TABLE entry_metadata (
            entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY(entry_id, key)
        ) WITHOUT ROWID;
        CREATE TABLE favorites (item_id TEXT PRIMARY KEY) WITHOUT ROWID;
        CREATE TABLE item_state (item_id TEXT PRIMARY KEY, recent_at REAL) WITHOUT ROWID;
        CREATE TABLE collections (
            id TEXT PRIMARY KEY,
            ordinal INTEGER NOT NULL UNIQUE,
            name TEXT NOT NULL,
            playback_present INTEGER NOT NULL CHECK(playback_present IN (0,1)),
            playback_minutes INTEGER,
            playback_shuffle INTEGER,
            playback_start_minute INTEGER,
            playback_end_minute INTEGER,
            weekdays_present INTEGER NOT NULL CHECK(weekdays_present IN (0,1))
        );
        CREATE TABLE collection_weekdays (
            collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
            weekday INTEGER NOT NULL CHECK(weekday BETWEEN 1 AND 7),
            PRIMARY KEY(collection_id, weekday)
        ) WITHOUT ROWID;
        CREATE TABLE collection_items (
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
            ON entries(source_id, catalog_id)
            WHERE source_id IS NOT NULL AND catalog_id IS NOT NULL AND catalog_id <> '';
        CREATE INDEX entries_source_path ON entries(source_id, relative_media_path);
        CREATE INDEX entries_source_availability ON entries(source_id, availability);
        CREATE INDEX entries_source_group ON entries(source_id, group_id);
        CREATE INDEX entries_media_type ON entries(media_type);
        CREATE INDEX entries_series ON entries(series);
        CREATE INDEX entries_character ON entries(character);
        CREATE INDEX entry_tags_value ON entry_tags(value, entry_id);
        CREATE INDEX entry_metadata_key_value ON entry_metadata(key, value, entry_id);
        CREATE INDEX source_metadata_key_value ON source_metadata(key, value, source_id);
        CREATE INDEX item_state_recent ON item_state(recent_at DESC);
        CREATE INDEX collection_items_scene ON collection_items(scene_id, collection_id);
        CREATE UNIQUE INDEX collection_items_selection
            ON collection_items(collection_id, scene_id, ifnull(variant_id, ''));
        CREATE UNIQUE INDEX user_stack_items_entry ON user_stack_items(entry_id);
        CREATE UNIQUE INDEX user_stacks_name_nocase ON user_stacks(name COLLATE NOCASE);
        CREATE UNIQUE INDEX collections_name_nocase ON collections(name COLLATE NOCASE);
        """)
    }

    private static func insertCatalog(_ catalog: SceneLibraryStore.Catalog, in db: Database) throws {
        try insertMeta(catalog, in: db)
        try insertSources(catalog.sources, in: db)
        try insertEntries(catalog.entries, in: db)
        try insertStacks(catalog.stacks, in: db)
        try insertFavorites(catalog.favorites, in: db)
        try insertState(catalog.recent, in: db)
        try insertCollections(catalog.collections, in: db)
    }

    private static func insertMeta(_ catalog: SceneLibraryStore.Catalog, in db: Database) throws {
        let statement = try db.prepare("INSERT INTO catalog_meta(key, value) VALUES(?, ?)")
        for (key, value) in [("schema_version", String(schemaVersion)), ("catalog_version", String(catalog.version))] {
            try statement.bind(key, at: 1); try statement.bind(value, at: 2); try statement.stepDone(); statement.reset()
        }
    }

    private static func insertSources(_ sources: [SceneLibraryStore.SourceRoot], in db: Database) throws {
        for (ordinal, value) in sources.enumerated() { try upsertSource(value, ordinal: ordinal, in: db) }
    }

    private static func insertEntries(_ entries: [SceneLibraryStore.Entry], in db: Database) throws {
        for (ordinal, value) in entries.enumerated() { try upsertEntry(value, ordinal: ordinal, in: db) }
    }

    private static func insertStacks(_ stacks: [SceneLibraryStore.UserStack], in db: Database) throws {
        for (ordinal, value) in stacks.enumerated() {
            try upsertStackRow(value, ordinal: ordinal, in: db)
            try replaceStackItems(value, in: db)
        }
    }

    private static func insertFavorites(_ favorites: Set<String>, in db: Database) throws {
        let statement = try db.prepare("INSERT INTO favorites(item_id) VALUES(?)")
        for id in favorites.sorted() { try statement.bind(id, at: 1); try statement.stepDone(); statement.reset() }
    }

    private static func insertState(_ recents: [String: Date], in db: Database) throws {
        let statement = try db.prepare("INSERT INTO item_state(item_id, recent_at) VALUES(?, ?)")
        for id in recents.keys.sorted() {
            try statement.bind(id, at: 1); try statement.bind(recents[id]!.timeIntervalSinceReferenceDate, at: 2)
            try statement.stepDone(); statement.reset()
        }
    }

    private static func insertCollections(_ collections: [SceneLibraryStore.Collection], in db: Database) throws {
        for (ordinal, value) in collections.enumerated() { try upsertCollection(value, ordinal: ordinal, in: db) }
    }

    private static func applyEntryDeletions(current: [SceneLibraryStore.Entry], next: [SceneLibraryStore.Entry], in db: Database) throws {
        let keep = Set(next.map(\.id))
        let statement = try db.prepare("DELETE FROM entries WHERE id=?")
        for value in current where !keep.contains(value.id) {
            try statement.bind(value.id, at: 1); try statement.stepDone(); statement.reset()
        }
    }

    private static func applySources(current: [SceneLibraryStore.SourceRoot], next: [SceneLibraryStore.SourceRoot], in db: Database) throws {
        guard current != next else { return }
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let nextIDs = Set(next.map(\.id))
        let delete = try db.prepare("DELETE FROM sources WHERE id=?")
        for value in current where !nextIDs.contains(value.id) {
            try delete.bind(value.id, at: 1); try delete.stepDone(); delete.reset()
        }
        let orderChanged = current.map(\.id) != next.map(\.id)
        if orderChanged { try shiftOrdinals(table: "sources", in: db) }
        for (ordinal, value) in next.enumerated() where currentByID[value.id] != value || currentByID[value.id] == nil {
            try upsertSource(value, ordinal: orderChanged ? stagedOrdinalOffset + ordinal : ordinal, in: db)
        }
        if orderChanged { try setOrdinals(table: "sources", ids: next.map(\.id), in: db) }
    }

    private static func applyEntries(current: [SceneLibraryStore.Entry], next: [SceneLibraryStore.Entry], in db: Database) throws {
        guard current != next else { return }
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let orderChanged = current.map(\.id) != next.map(\.id)
        if orderChanged { try shiftOrdinals(table: "entries", in: db) }

        // Release old Source-scoped identity keys before changed rows are reassigned,
        // allowing two existing entries to swap catalog identities in one transaction.
        let clearCatalogID = try db.prepare("UPDATE entries SET catalog_id=NULL WHERE id=?")
        for value in next where currentByID[value.id] != nil && currentByID[value.id] != value {
            try clearCatalogID.bind(value.id, at: 1); try clearCatalogID.stepDone(); clearCatalogID.reset()
        }
        for (ordinal, value) in next.enumerated() where currentByID[value.id] != value || currentByID[value.id] == nil {
            try upsertEntry(value, ordinal: orderChanged ? stagedOrdinalOffset + ordinal : ordinal, in: db)
        }
        if orderChanged { try setOrdinals(table: "entries", ids: next.map(\.id), in: db) }
    }

    private static func applyStacks(current: [SceneLibraryStore.UserStack], next: [SceneLibraryStore.UserStack], in db: Database) throws {
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
        let delete = try db.prepare("DELETE FROM favorites WHERE item_id=?")
        for id in current.subtracting(next) { try delete.bind(id, at: 1); try delete.stepDone(); delete.reset() }
        let insert = try db.prepare("INSERT OR IGNORE INTO favorites(item_id) VALUES(?)")
        for id in next.subtracting(current) { try insert.bind(id, at: 1); try insert.stepDone(); insert.reset() }
    }

    private static func applyRecent(current: [String: Date], next: [String: Date], in db: Database) throws {
        let delete = try db.prepare("DELETE FROM item_state WHERE item_id=?")
        for id in current.keys where next[id] == nil { try delete.bind(id, at: 1); try delete.stepDone(); delete.reset() }
        let upsert = try db.prepare("INSERT INTO item_state(item_id, recent_at) VALUES(?, ?) ON CONFLICT(item_id) DO UPDATE SET recent_at=excluded.recent_at")
        for id in next.keys.sorted() where current[id] != next[id] {
            try upsert.bind(id, at: 1); try upsert.bind(next[id]!.timeIntervalSinceReferenceDate, at: 2)
            try upsert.stepDone(); upsert.reset()
        }
    }

    private static func applyCollections(current: [SceneLibraryStore.Collection], next: [SceneLibraryStore.Collection], in db: Database) throws {
        guard current != next else { return }
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let nextIDs = Set(next.map(\.id))
        let delete = try db.prepare("DELETE FROM collections WHERE id=?")
        for value in current where !nextIDs.contains(value.id) {
            try delete.bind(value.id, at: 1); try delete.stepDone(); delete.reset()
        }
        let orderChanged = current.map(\.id) != next.map(\.id)
        if orderChanged { try shiftOrdinals(table: "collections", in: db) }

        // Release changed unique names before writing their final values so swaps are atomic.
        let temporaryNames = try db.prepare("UPDATE collections SET name=? WHERE id=?")
        for value in next where currentByID[value.id] != nil && currentByID[value.id]?.name != value.name {
            try temporaryNames.bind("__idlesse_tmp__\(UUID().uuidString)", at: 1)
            try temporaryNames.bind(value.id, at: 2); try temporaryNames.stepDone(); temporaryNames.reset()
        }
        for (ordinal, value) in next.enumerated() where currentByID[value.id] != value || currentByID[value.id] == nil {
            try upsertCollection(value, ordinal: orderChanged ? stagedOrdinalOffset + ordinal : ordinal, in: db)
        }
        if orderChanged { try setOrdinals(table: "collections", ids: next.map(\.id), in: db) }
    }

    private static func shiftOrdinals(table: String, in db: Database) throws {
        try db.execute("UPDATE \(table) SET ordinal = ordinal + \(shiftedOrdinalOffset)")
    }

    private static func setOrdinals(table: String, ids: [String], in db: Database) throws {
        let statement = try db.prepare("UPDATE \(table) SET ordinal=? WHERE id=?")
        for (ordinal, id) in ids.enumerated() {
            try statement.bind(ordinal, at: 1); try statement.bind(id, at: 2); try statement.stepDone(); statement.reset()
        }
    }

    private static func upsertSource(_ value: SceneLibraryStore.SourceRoot, ordinal: Int, in db: Database) throws {
        let statement = try db.prepare("""
            INSERT INTO sources(id, ordinal, name, bookmark, metadata_present) VALUES(?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET ordinal=excluded.ordinal, name=excluded.name,
                bookmark=excluded.bookmark, metadata_present=excluded.metadata_present
            """)
        try statement.bind(value.id, at: 1); try statement.bind(ordinal, at: 2); try statement.bind(value.name, at: 3)
        try statement.bind(value.bookmark, at: 4); try statement.bind(value.catalogMetadata == nil ? 0 : 1, at: 5)
        try statement.stepDone()
        let clear = try db.prepare("DELETE FROM source_metadata WHERE source_id=?")
        try clear.bind(value.id, at: 1); try clear.stepDone()
        let metadata = try db.prepare("INSERT INTO source_metadata(source_id, key, value) VALUES(?, ?, ?)")
        for key in value.catalogMetadata?.keys.sorted() ?? [] {
            try metadata.bind(value.id, at: 1); try metadata.bind(key, at: 2); try metadata.bind(value.catalogMetadata![key]!, at: 3)
            try metadata.stepDone(); metadata.reset()
        }
    }

    private static func upsertEntry(_ value: SceneLibraryStore.Entry, ordinal: Int, in db: Database) throws {
        let statement = try db.prepare("""
            INSERT INTO entries(id, ordinal, title, bookmark, catalog_id, source_id, relative_media_path,
                relative_poster_path, series, character, variant, media_type, width, height, fps, duration,
                availability, provenance_present, observation_present, obs_byte_length, obs_modified_at,
                obs_digest_algorithm, obs_digest, obs_package_revision, group_id)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET ordinal=excluded.ordinal, title=excluded.title, bookmark=excluded.bookmark,
                catalog_id=excluded.catalog_id, source_id=excluded.source_id, relative_media_path=excluded.relative_media_path,
                relative_poster_path=excluded.relative_poster_path, series=excluded.series, character=excluded.character,
                variant=excluded.variant, media_type=excluded.media_type, width=excluded.width, height=excluded.height,
                fps=excluded.fps, duration=excluded.duration, availability=excluded.availability,
                provenance_present=excluded.provenance_present, observation_present=excluded.observation_present,
                obs_byte_length=excluded.obs_byte_length, obs_modified_at=excluded.obs_modified_at,
                obs_digest_algorithm=excluded.obs_digest_algorithm, obs_digest=excluded.obs_digest,
                obs_package_revision=excluded.obs_package_revision, group_id=excluded.group_id
            """)
        try statement.bind(value.id, at: 1); try statement.bind(ordinal, at: 2); try statement.bind(value.title, at: 3)
        try statement.bind(value.bookmark, at: 4); try statement.bind(value.catalogID, at: 5); try statement.bind(value.sourceID, at: 6)
        try statement.bind(value.relativeMediaPath, at: 7); try statement.bind(value.relativePosterPath, at: 8)
        try statement.bind(value.series, at: 9); try statement.bind(value.character, at: 10); try statement.bind(value.variant, at: 11)
        try statement.bind(value.mediaType, at: 12); try statement.bind(value.width, at: 13); try statement.bind(value.height, at: 14)
        try statement.bind(value.fps, at: 15); try statement.bind(value.duration, at: 16); try statement.bind(value.availability.rawValue, at: 17)
        try statement.bind(value.provenance == nil ? 0 : 1, at: 18); try statement.bind(value.observation == nil ? 0 : 1, at: 19)
        try statement.bind(value.observation?.byteLength, at: 20)
        try statement.bind(value.observation?.modifiedAt?.timeIntervalSinceReferenceDate, at: 21)
        try statement.bind(value.observation?.digestAlgorithm, at: 22); try statement.bind(value.observation?.digest, at: 23)
        try statement.bind(value.observation?.packageRevision, at: 24); try statement.bind(value.groupID, at: 25); try statement.stepDone()

        let clearTags = try db.prepare("DELETE FROM entry_tags WHERE entry_id=?")
        try clearTags.bind(value.id, at: 1); try clearTags.stepDone()
        let tag = try db.prepare("INSERT INTO entry_tags(entry_id, ordinal, value) VALUES(?, ?, ?)")
        for (tagOrdinal, tagValue) in value.tags.enumerated() {
            try tag.bind(value.id, at: 1); try tag.bind(tagOrdinal, at: 2); try tag.bind(tagValue, at: 3)
            try tag.stepDone(); tag.reset()
        }
        let clearMetadata = try db.prepare("DELETE FROM entry_metadata WHERE entry_id=?")
        try clearMetadata.bind(value.id, at: 1); try clearMetadata.stepDone()
        let metadata = try db.prepare("INSERT INTO entry_metadata(entry_id, key, value) VALUES(?, ?, ?)")
        for key in value.provenance?.keys.sorted() ?? [] {
            try metadata.bind(value.id, at: 1); try metadata.bind(key, at: 2); try metadata.bind(value.provenance![key]!, at: 3)
            try metadata.stepDone(); metadata.reset()
        }
    }

    private static func upsertStackRow(_ value: SceneLibraryStore.UserStack, ordinal: Int, in db: Database) throws {
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
        let playback = value.playback
        let statement = try db.prepare("""
            INSERT INTO collections(id, ordinal, name, playback_present, playback_minutes, playback_shuffle,
                playback_start_minute, playback_end_minute, weekdays_present) VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET ordinal=excluded.ordinal, name=excluded.name,
                playback_present=excluded.playback_present, playback_minutes=excluded.playback_minutes,
                playback_shuffle=excluded.playback_shuffle, playback_start_minute=excluded.playback_start_minute,
                playback_end_minute=excluded.playback_end_minute, weekdays_present=excluded.weekdays_present
            """)
        try statement.bind(value.id, at: 1); try statement.bind(ordinal, at: 2); try statement.bind(value.name, at: 3)
        try statement.bind(playback == nil ? 0 : 1, at: 4); try statement.bind(playback?.minutes, at: 5)
        try statement.bind(playback.map { $0.shuffle ? 1 : 0 }, at: 6); try statement.bind(playback?.startMinute, at: 7)
        try statement.bind(playback?.endMinute, at: 8); try statement.bind(playback?.weekdays == nil ? 0 : 1, at: 9)
        try statement.stepDone()
        let clearWeekdays = try db.prepare("DELETE FROM collection_weekdays WHERE collection_id=?")
        try clearWeekdays.bind(value.id, at: 1); try clearWeekdays.stepDone()
        let weekday = try db.prepare("INSERT INTO collection_weekdays(collection_id, weekday) VALUES(?, ?)")
        for day in playback?.weekdays?.sorted() ?? [] {
            try weekday.bind(value.id, at: 1); try weekday.bind(day, at: 2); try weekday.stepDone(); weekday.reset()
        }
        let clearItems = try db.prepare("DELETE FROM collection_items WHERE collection_id=?")
        try clearItems.bind(value.id, at: 1); try clearItems.stepDone()
        let item = try db.prepare("INSERT INTO collection_items(collection_id, ordinal, scene_id, variant_id) VALUES(?, ?, ?, NULL)")
        for (itemOrdinal, sceneID) in value.sceneIDs.enumerated() {
            try item.bind(value.id, at: 1); try item.bind(itemOrdinal, at: 2); try item.bind(sceneID, at: 3)
            try item.stepDone(); item.reset()
        }
    }

    private static func setCatalogVersion(_ version: Int, in db: Database) throws {
        let statement = try db.prepare("INSERT INTO catalog_meta(key, value) VALUES('catalog_version', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        try statement.bind(String(version), at: 1); try statement.stepDone()
    }

    private static func readCatalog(at url: URL) throws -> SceneLibraryStore.Catalog {
        try verifyDatabase(at: url)
        let db = try Database(url: url, mode: .readOnly)
        return try readCatalog(in: db)
    }

    private static func readCatalog(in db: Database) throws -> SceneLibraryStore.Catalog {
        try verifyRowBounds(in: db)
        guard try db.scalarText("SELECT value FROM catalog_meta WHERE key='schema_version'") == String(schemaVersion),
              let catalogVersionText = try db.scalarText("SELECT value FROM catalog_meta WHERE key='catalog_version'"),
              let catalogVersion = Int(catalogVersionText) else {
            throw failure("The Library database metadata is incomplete.")
        }
        var catalog = SceneLibraryStore.Catalog()
        catalog.version = catalogVersion
        catalog.sources = try readSources(in: db)
        catalog.entries = try readEntries(in: db)
        catalog.stacks = try readStacks(in: db)
        catalog.favorites = try readFavorites(in: db)
        catalog.recent = try readState(in: db)
        catalog.collections = try readCollections(in: db)
        return catalog
    }

    private static func verifyTransaction(in db: Database) throws {
        let check = try db.scalarText("PRAGMA quick_check")
        guard check == "ok" else { throw failure("SQLite integrity verification failed: \(check ?? "unknown error").") }
        let foreign = try db.prepare("PRAGMA foreign_key_check")
        guard try !foreign.stepRow() else { throw failure("SQLite foreign-key verification failed.") }
        try verifyRowBounds(in: db)
    }

    private static func verifyRowBounds(in db: Database) throws {
        let total = SceneLibraryStore.maxIndividualEntries + SceneLibraryStore.maxSourceEntries
        let limits: [(String, Int)] = [
            ("sources", SceneLibraryStore.maxSources), ("entries", total), ("favorites", 256),
            ("item_state", 256), ("collections", 32), ("collection_weekdays", 32 * 7),
            ("collection_items", 32 * 256), ("user_stacks", 128), ("user_stack_items", 128 * 256),
            ("entry_tags", total * 64),
            ("entry_metadata", total * 32), ("source_metadata", SceneLibraryStore.maxSources * 32)
        ]
        for (table, limit) in limits {
            guard try db.scalarInt("SELECT count(*) FROM \(table)") <= limit else {
                throw failure("The Library database exceeds the \(table) row limit.")
            }
        }
    }

    private static func readSources(in db: Database) throws -> [SceneLibraryStore.SourceRoot] {
        var metadata: [String: [String: String]] = [:]
        let rows = try db.prepare("SELECT source_id, key, value FROM source_metadata ORDER BY source_id, key")
        while try rows.stepRow() {
            guard let id = rows.text(0), let key = rows.text(1), let value = rows.text(2) else { throw failure("A Source metadata row is invalid.") }
            metadata[id, default: [:]][key] = value
        }
        let statement = try db.prepare("SELECT id, name, bookmark, metadata_present FROM sources ORDER BY ordinal")
        var result: [SceneLibraryStore.SourceRoot] = []
        while try statement.stepRow() {
            guard let id = statement.text(0), let name = statement.text(1), let bookmark = statement.data(2) else { throw failure("A Source row is invalid.") }
            let present = statement.int(3) == 1
            result.append(.init(id: id, name: name, bookmark: bookmark, catalogMetadata: present ? (metadata[id] ?? [:]) : nil))
        }
        return result
    }

    private static func readEntries(in db: Database) throws -> [SceneLibraryStore.Entry] {
        var tags: [String: [(Int, String)]] = [:]
        let tagRows = try db.prepare("SELECT entry_id, ordinal, value FROM entry_tags ORDER BY entry_id, ordinal")
        while try tagRows.stepRow() {
            guard let id = tagRows.text(0), let value = tagRows.text(2) else { throw failure("A tag row is invalid.") }
            tags[id, default: []].append((tagRows.int(1), value))
        }
        var metadata: [String: [String: String]] = [:]
        let metadataRows = try db.prepare("SELECT entry_id, key, value FROM entry_metadata ORDER BY entry_id, key")
        while try metadataRows.stepRow() {
            guard let id = metadataRows.text(0), let key = metadataRows.text(1), let value = metadataRows.text(2) else { throw failure("An entry metadata row is invalid.") }
            metadata[id, default: [:]][key] = value
        }
        let statement = try db.prepare("""
            SELECT id, title, bookmark, catalog_id, source_id, relative_media_path, relative_poster_path,
                   series, character, variant, media_type, width, height, fps, duration, availability,
                   provenance_present, observation_present, obs_byte_length, obs_modified_at,
                   obs_digest_algorithm, obs_digest, obs_package_revision, group_id
            FROM entries ORDER BY ordinal
            """)
        var result: [SceneLibraryStore.Entry] = []
        while try statement.stepRow() {
            guard let id = statement.text(0), let title = statement.text(1),
                  let availabilityText = statement.text(15),
                  let availability = SceneLibraryStore.EntryAvailability(rawValue: availabilityText) else { throw failure("An entry row is invalid.") }
            let provenance = statement.int(16) == 1 ? (metadata[id] ?? [:]) : nil
            let observation = statement.int(17) == 1 ? SceneLibraryStore.ReconciliationObservation(
                byteLength: statement.optionalInt64(18),
                modifiedAt: statement.optionalDouble(19).map { Date(timeIntervalSinceReferenceDate: $0) },
                digestAlgorithm: statement.text(20), digest: statement.text(21), packageRevision: statement.text(22)) : nil
            result.append(.init(id: id, title: title, bookmark: statement.data(2), catalogID: statement.text(3),
                groupID: statement.text(23), sourceID: statement.text(4), relativeMediaPath: statement.text(5), relativePosterPath: statement.text(6),
                series: statement.text(7), character: statement.text(8), variant: statement.text(9),
                tags: (tags[id] ?? []).sorted { $0.0 < $1.0 }.map(\.1), mediaType: statement.text(10),
                width: statement.optionalInt(11), height: statement.optionalInt(12), fps: statement.optionalDouble(13),
                duration: statement.optionalDouble(14), provenance: provenance, availability: availability,
                observation: observation))
        }
        return result
    }

    private static func readStacks(in db: Database) throws -> [SceneLibraryStore.UserStack] {
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
        let statement = try db.prepare("SELECT item_id FROM favorites ORDER BY item_id")
        var result = Set<String>()
        while try statement.stepRow() { if let id = statement.text(0) { result.insert(id) } }
        return result
    }

    private static func readState(in db: Database) throws -> [String: Date] {
        let statement = try db.prepare("SELECT item_id, recent_at FROM item_state ORDER BY item_id")
        var result: [String: Date] = [:]
        while try statement.stepRow() {
            guard let id = statement.text(0), let time = statement.optionalDouble(1) else { throw failure("An item state row is invalid.") }
            result[id] = Date(timeIntervalSinceReferenceDate: time)
        }
        return result
    }

    private static func readCollections(in db: Database) throws -> [SceneLibraryStore.Collection] {
        var weekdays: [String: Set<Int>] = [:]
        let weekdayRows = try db.prepare("SELECT collection_id, weekday FROM collection_weekdays ORDER BY collection_id, weekday")
        while try weekdayRows.stepRow() {
            guard let id = weekdayRows.text(0) else { throw failure("A collection weekday row is invalid.") }
            weekdays[id, default: []].insert(weekdayRows.int(1))
        }
        var items: [String: [(Int, String)]] = [:]
        let itemRows = try db.prepare("SELECT collection_id, ordinal, scene_id, variant_id FROM collection_items ORDER BY collection_id, ordinal")
        while try itemRows.stepRow() {
            guard let id = itemRows.text(0), let sceneID = itemRows.text(2) else { throw failure("A collection item row is invalid.") }
            guard itemRows.isNull(3) else { throw failure("This Library database contains variant-aware collection items that require a newer catalog model.") }
            items[id, default: []].append((itemRows.int(1), sceneID))
        }
        let statement = try db.prepare("""
            SELECT id, name, playback_present, playback_minutes, playback_shuffle,
                   playback_start_minute, playback_end_minute, weekdays_present
            FROM collections ORDER BY ordinal
            """)
        var result: [SceneLibraryStore.Collection] = []
        while try statement.stepRow() {
            guard let id = statement.text(0), let name = statement.text(1) else { throw failure("A collection row is invalid.") }
            let playback: SceneLibraryStore.Playback?
            if statement.int(2) == 1 {
                guard let minutes = statement.optionalInt(3), let shuffleValue = statement.optionalInt(4) else { throw failure("A collection playback row is incomplete.") }
                playback = .init(minutes: minutes, shuffle: shuffleValue != 0,
                    startMinute: statement.optionalInt(5), endMinute: statement.optionalInt(6),
                    weekdays: statement.int(7) == 1 ? (weekdays[id] ?? []) : nil)
            } else { playback = nil }
            result.append(.init(id: id, name: name,
                sceneIDs: (items[id] ?? []).sorted { $0.0 < $1.0 }.map(\.1), playback: playback))
        }
        return result
    }

    private static func ensureDatabaseBound(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw failure("The Library database is missing.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= maxDatabaseBytes else { throw failure("The Library database exceeds its 64 MiB bound.") }
    }

    private static func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    private static func synchronizeDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("The Library directory could not be opened for synchronization.") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw failure("The Library directory could not be synchronized.") }
    }

    private static func failure(_ text: String) -> NSError { SceneLibraryStore.libraryFailure(text) }

    private final class Database {
        enum Mode: Equatable { case create, readWrite, readOnly }
        private(set) var handle: OpaquePointer?

        init(url: URL, mode: Mode) throws {
            var database: OpaquePointer?
            let flags: Int32
            switch mode {
            case .create: flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            case .readWrite: flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            case .readOnly: flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            }
            let result = sqlite3_open_v2(url.path, &database, flags, nil)
            guard result == SQLITE_OK, let database else {
                let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "open failed"
                if let database { sqlite3_close(database) }
                throw failure("Could not open the Library database: \(message).")
            }
            handle = database
            if mode != .readOnly { try execute("PRAGMA foreign_keys = ON") }
        }

        deinit { if let handle { sqlite3_close(handle) } }

        func execute(_ sql: String) throws {
            guard let handle else { throw failure("The Library database is closed.") }
            var error: UnsafeMutablePointer<Int8>?
            let result = sqlite3_exec(handle, sql, nil, nil, &error)
            if result != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
                if let error { sqlite3_free(error) }
                throw failure("SQLite error: \(message).")
            }
        }

        func transaction(_ body: () throws -> Void) throws {
            try execute("BEGIN IMMEDIATE")
            do { try body(); try execute("COMMIT") }
            catch { try? execute("ROLLBACK"); throw error }
        }

        func prepare(_ sql: String) throws -> Statement {
            guard let handle else { throw failure("The Library database is closed.") }
            return try Statement(database: handle, sql: sql)
        }

        func scalarInt(_ sql: String) throws -> Int {
            let statement = try prepare(sql)
            guard try statement.stepRow() else { throw failure("SQLite query returned no value.") }
            return statement.int(0)
        }

        func scalarText(_ sql: String) throws -> String? {
            let statement = try prepare(sql)
            guard try statement.stepRow() else { return nil }
            return statement.text(0)
        }
    }

    private final class Statement {
        private let database: OpaquePointer
        private var statement: OpaquePointer?
        private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        init(database: OpaquePointer, sql: String) throws {
            self.database = database
            var prepared: OpaquePointer?
            let result = sqlite3_prepare_v2(database, sql, -1, &prepared, nil)
            guard result == SQLITE_OK, let prepared else { throw failure("SQLite prepare error: \(String(cString: sqlite3_errmsg(database))).") }
            statement = prepared
        }

        deinit { if let statement { sqlite3_finalize(statement) } }
        func reset() { if let statement { sqlite3_reset(statement); sqlite3_clear_bindings(statement) } }

        func bind(_ value: String?, at index: Int32) throws {
            guard let statement else { throw failure("SQLite statement is closed.") }
            let result: Int32
            if let value {
                let utf8 = value.utf8CString
                result = utf8.withUnsafeBufferPointer {
                    sqlite3_bind_text(statement, index, $0.baseAddress, Int32($0.count - 1), transient)
                }
            } else {
                result = sqlite3_bind_null(statement, index)
            }
            try checkBind(result)
        }

        func bind(_ value: Data?, at index: Int32) throws {
            guard let statement else { throw failure("SQLite statement is closed.") }
            let result: Int32
            if let value {
                if value.isEmpty {
                    result = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    result = value.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
                    }
                }
            } else { result = sqlite3_bind_null(statement, index) }
            try checkBind(result)
        }

        func bind(_ value: Int?, at index: Int32) throws {
            guard let statement else { throw failure("SQLite statement is closed.") }
            try checkBind(value.map { sqlite3_bind_int64(statement, index, Int64($0)) } ?? sqlite3_bind_null(statement, index))
        }
        func bind(_ value: Int64?, at index: Int32) throws {
            guard let statement else { throw failure("SQLite statement is closed.") }
            try checkBind(value.map { sqlite3_bind_int64(statement, index, $0) } ?? sqlite3_bind_null(statement, index))
        }
        func bind(_ value: Double?, at index: Int32) throws {
            guard let statement else { throw failure("SQLite statement is closed.") }
            try checkBind(value.map { sqlite3_bind_double(statement, index, $0) } ?? sqlite3_bind_null(statement, index))
        }
        private func checkBind(_ result: Int32) throws {
            guard result == SQLITE_OK else { throw failure("SQLite bind error: \(String(cString: sqlite3_errmsg(database))).") }
        }
        func stepDone() throws {
            guard let statement else { throw failure("SQLite statement is closed.") }
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else { throw failure("SQLite write error: \(String(cString: sqlite3_errmsg(database))).") }
        }
        func stepRow() throws -> Bool {
            guard let statement else { throw failure("SQLite statement is closed.") }
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW { return true }
            if result == SQLITE_DONE { return false }
            throw failure("SQLite read error: \(String(cString: sqlite3_errmsg(database))).")
        }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        func optionalInt(_ column: Int32) -> Int? { isNull(column) ? nil : int(column) }
        func optionalInt64(_ column: Int32) -> Int64? { isNull(column) ? nil : sqlite3_column_int64(statement, column) }
        func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : sqlite3_column_double(statement, column) }
        func text(_ column: Int32) -> String? {
            guard !isNull(column) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0 else { return "" }
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(bytes: UnsafeBufferPointer(start: pointer, count: count), encoding: .utf8)
        }
        func data(_ column: Int32) -> Data? {
            guard !isNull(column) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0 else { return Data() }
            guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
            return Data(bytes: pointer, count: count)
        }
    }
}