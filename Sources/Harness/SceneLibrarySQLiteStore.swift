import Foundation
import SQLite3

/// Durable Library persistence behind the existing in-memory Catalog API.
/// Media never enters this database: bookmarks, relative paths, metadata and
/// user state are the only stored values.
enum SceneLibrarySQLiteCatalog {
    static let schemaVersion = 1
    static let selectorValue = "sqlite-v1\n"
    static let maxDatabaseBytes: Int64 = 64 * 1024 * 1024
    private static let pageSize = 4096
    private static let maxPageCount = Int(maxDatabaseBytes) / pageSize

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

    static func migrate(_ catalog: SceneLibraryStore.Catalog, fromJSON jsonFile: URL) throws {
        let paths = paths(for: jsonFile)
        try FileManager.default.createDirectory(at: jsonFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: paths.candidate)
        try buildCandidate(catalog, at: paths.candidate)
        let roundTrip = try readCatalog(at: paths.candidate)
        guard roundTrip == catalog else {
            try? FileManager.default.removeItem(at: paths.candidate)
            throw failure("SQLite migration verification found a semantic mismatch.")
        }
        try verifyDatabase(at: paths.candidate)
        try synchronizeFile(at: paths.candidate)

        if FileManager.default.fileExists(atPath: paths.corruptBackup.path) {
            try FileManager.default.removeItem(at: paths.corruptBackup)
        }
        if FileManager.default.fileExists(atPath: paths.database.path) {
            try FileManager.default.moveItem(at: paths.database, to: paths.corruptBackup)
        }
        do {
            try FileManager.default.moveItem(at: paths.candidate, to: paths.database)
            try synchronizeFile(at: paths.database)
            try Data(selectorValue.utf8).write(to: paths.selector, options: .atomic)
            try synchronizeFile(at: paths.selector)
        } catch {
            if !FileManager.default.fileExists(atPath: paths.database.path),
               FileManager.default.fileExists(atPath: paths.corruptBackup.path) {
                try? FileManager.default.moveItem(at: paths.corruptBackup, to: paths.database)
            }
            throw error
        }
    }

    static func readSelectedCatalog(for jsonFile: URL) throws -> SceneLibraryStore.Catalog {
        guard try hasSQLiteSelector(for: jsonFile) else {
            throw failure("The SQLite Library backend is not active.")
        }
        return try readCatalog(at: paths(for: jsonFile).database)
    }

    static func writeSelectedCatalog(_ catalog: SceneLibraryStore.Catalog, for jsonFile: URL) throws {
        guard try hasSQLiteSelector(for: jsonFile) else {
            throw failure("The SQLite Library backend is not active.")
        }
        let url = paths(for: jsonFile).database
        try ensureDatabaseBound(url)
        let db = try Database(url: url, mode: .readWrite)
        try configureWritePragmas(db, isNew: false)
        let version = try db.scalarInt("PRAGMA user_version")
        guard version == schemaVersion else {
            throw failure("This Library database uses unsupported schema version \(version).")
        }
        try db.transaction {
            try clearCatalog(in: db)
            try insertCatalog(catalog, in: db)
        }
        try ensureDatabaseBound(url)
    }

    static func verifyDatabase(at url: URL) throws {
        try ensureDatabaseBound(url)
        let db = try Database(url: url, mode: .readOnly)
        let version = try db.scalarInt("PRAGMA user_version")
        guard version == schemaVersion else {
            throw failure("This Library database uses unsupported schema version \(version).")
        }
        let check = try db.scalarText("PRAGMA quick_check")
        guard check == "ok" else { throw failure("SQLite integrity verification failed: \(check ?? "unknown error").") }
        let foreign = try db.prepare("PRAGMA foreign_key_check")
        guard try !foreign.stepRow() else { throw failure("SQLite foreign-key verification failed.") }
    }

    static func indexNames(at url: URL) throws -> Set<String> {
        let db = try Database(url: url, mode: .readOnly)
        let statement = try db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        var names = Set<String>()
        while try statement.stepRow() {
            if let value = statement.text(0) { names.insert(value) }
        }
        return names
    }

    static func deterministicDebugExport(_ catalog: SceneLibraryStore.Catalog) throws -> Data {
        var root: [String: Any] = [
            "format": "idlesse-library-debug-v1",
            "catalogVersion": catalog.version,
            "sqliteSchemaVersion": schemaVersion,
            "favorites": catalog.favorites.sorted()
        ]
        root["sources"] = catalog.sources.enumerated().map { ordinal, source -> [String: Any] in
            var value: [String: Any] = [
                "ordinal": ordinal,
                "id": source.id,
                "name": source.name,
                "bookmarkBase64": source.bookmark.base64EncodedString()
            ]
            if let metadata = source.catalogMetadata { value["metadata"] = metadata }
            return value
        }
        root["entries"] = catalog.entries.enumerated().map { ordinal, entry -> [String: Any] in
            var value: [String: Any] = [
                "ordinal": ordinal,
                "id": entry.id,
                "title": entry.title,
                "tags": entry.tags,
                "availability": entry.availability.rawValue
            ]
            if let bookmark = entry.bookmark { value["bookmarkBase64"] = bookmark.base64EncodedString() }
            put(entry.catalogID, "catalogID", into: &value)
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
            if let provenance = entry.provenance { value["provenance"] = provenance }
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
        root["collections"] = catalog.collections.enumerated().map { ordinal, collection -> [String: Any] in
            var value: [String: Any] = [
                "ordinal": ordinal,
                "id": collection.id,
                "name": collection.name,
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
        return try JSONSerialization.data(withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
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
        }
        try ensureDatabaseBound(url)
    }

    private static func configureWritePragmas(_ db: Database, isNew: Bool) throws {
        try db.execute("PRAGMA foreign_keys = ON")
        try db.execute("PRAGMA journal_mode = DELETE")
        try db.execute("PRAGMA synchronous = FULL")
        if isNew { try db.execute("PRAGMA page_size = \(pageSize)") }
        try db.execute("PRAGMA max_page_count = \(maxPageCount)")
        try db.execute("PRAGMA busy_timeout = 3000")
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
            bookmark BLOB NOT NULL
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
            obs_byte_length INTEGER,
            obs_modified_at REAL,
            obs_digest_algorithm TEXT,
            obs_digest TEXT,
            obs_package_revision TEXT
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
        CREATE TABLE favorites (
            item_id TEXT PRIMARY KEY
        ) WITHOUT ROWID;
        CREATE TABLE item_state (
            item_id TEXT PRIMARY KEY,
            recent_at REAL,
            play_position REAL
        ) WITHOUT ROWID;
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
            PRIMARY KEY(collection_id, ordinal),
            UNIQUE(collection_id, scene_id)
        ) WITHOUT ROWID;
        CREATE UNIQUE INDEX entries_source_catalog_identity
            ON entries(source_id, catalog_id)
            WHERE source_id IS NOT NULL AND catalog_id IS NOT NULL AND catalog_id <> '';
        CREATE INDEX entries_source_path ON entries(source_id, relative_media_path);
        CREATE INDEX entries_source_availability ON entries(source_id, availability);
        CREATE INDEX entries_media_type ON entries(media_type);
        CREATE INDEX entries_series ON entries(series);
        CREATE INDEX entries_character ON entries(character);
        CREATE INDEX entry_tags_value ON entry_tags(value, entry_id);
        CREATE INDEX entry_metadata_key_value ON entry_metadata(key, value, entry_id);
        CREATE INDEX source_metadata_key_value ON source_metadata(key, value, source_id);
        CREATE INDEX item_state_recent ON item_state(recent_at DESC);
        CREATE INDEX collection_items_scene ON collection_items(scene_id, collection_id);
        CREATE UNIQUE INDEX collections_name_nocase ON collections(name COLLATE NOCASE);
        """)
    }

    private static func clearCatalog(in db: Database) throws {
        for table in ["collection_items", "collection_weekdays", "collections", "item_state", "favorites",
                      "entry_metadata", "entry_tags", "entries", "source_metadata", "sources", "catalog_meta"] {
            try db.execute("DELETE FROM \(table)")
        }
    }

    private static func insertCatalog(_ catalog: SceneLibraryStore.Catalog, in db: Database) throws {
        try insertMeta(catalog, in: db)
        try insertSources(catalog.sources, in: db)
        try insertEntries(catalog.entries, in: db)
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
        let source = try db.prepare("INSERT INTO sources(id, ordinal, name, bookmark) VALUES(?, ?, ?, ?)")
        let metadata = try db.prepare("INSERT INTO source_metadata(source_id, key, value) VALUES(?, ?, ?)")
        for (ordinal, value) in sources.enumerated() {
            try source.bind(value.id, at: 1); try source.bind(ordinal, at: 2); try source.bind(value.name, at: 3)
            try source.bind(value.bookmark, at: 4); try source.stepDone(); source.reset()
            for key in value.catalogMetadata?.keys.sorted() ?? [] {
                try metadata.bind(value.id, at: 1); try metadata.bind(key, at: 2)
                try metadata.bind(value.catalogMetadata![key]!, at: 3); try metadata.stepDone(); metadata.reset()
            }
        }
    }

    private static func insertEntries(_ entries: [SceneLibraryStore.Entry], in db: Database) throws {
        let entry = try db.prepare("""
            INSERT INTO entries(id, ordinal, title, bookmark, catalog_id, source_id, relative_media_path,
                relative_poster_path, series, character, variant, media_type, width, height, fps, duration,
                availability, obs_byte_length, obs_modified_at, obs_digest_algorithm, obs_digest, obs_package_revision)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
        let tag = try db.prepare("INSERT INTO entry_tags(entry_id, ordinal, value) VALUES(?, ?, ?)")
        let metadata = try db.prepare("INSERT INTO entry_metadata(entry_id, key, value) VALUES(?, ?, ?)")
        for (ordinal, value) in entries.enumerated() {
            try entry.bind(value.id, at: 1); try entry.bind(ordinal, at: 2); try entry.bind(value.title, at: 3)
            try entry.bind(value.bookmark, at: 4); try entry.bind(value.catalogID, at: 5); try entry.bind(value.sourceID, at: 6)
            try entry.bind(value.relativeMediaPath, at: 7); try entry.bind(value.relativePosterPath, at: 8)
            try entry.bind(value.series, at: 9); try entry.bind(value.character, at: 10); try entry.bind(value.variant, at: 11)
            try entry.bind(value.mediaType, at: 12); try entry.bind(value.width, at: 13); try entry.bind(value.height, at: 14)
            try entry.bind(value.fps, at: 15); try entry.bind(value.duration, at: 16); try entry.bind(value.availability.rawValue, at: 17)
            try entry.bind(value.observation?.byteLength, at: 18)
            try entry.bind(value.observation?.modifiedAt?.timeIntervalSinceReferenceDate, at: 19)
            try entry.bind(value.observation?.digestAlgorithm, at: 20); try entry.bind(value.observation?.digest, at: 21)
            try entry.bind(value.observation?.packageRevision, at: 22); try entry.stepDone(); entry.reset()
            for (tagOrdinal, tagValue) in value.tags.enumerated() {
                try tag.bind(value.id, at: 1); try tag.bind(tagOrdinal, at: 2); try tag.bind(tagValue, at: 3)
                try tag.stepDone(); tag.reset()
            }
            for key in value.provenance?.keys.sorted() ?? [] {
                try metadata.bind(value.id, at: 1); try metadata.bind(key, at: 2); try metadata.bind(value.provenance![key]!, at: 3)
                try metadata.stepDone(); metadata.reset()
            }
        }
    }

    private static func insertFavorites(_ favorites: Set<String>, in db: Database) throws {
        let statement = try db.prepare("INSERT INTO favorites(item_id) VALUES(?)")
        for id in favorites.sorted() { try statement.bind(id, at: 1); try statement.stepDone(); statement.reset() }
    }

    private static func insertState(_ recents: [String: Date], in db: Database) throws {
        let statement = try db.prepare("INSERT INTO item_state(item_id, recent_at, play_position) VALUES(?, ?, NULL)")
        for id in recents.keys.sorted() {
            try statement.bind(id, at: 1); try statement.bind(recents[id]!.timeIntervalSinceReferenceDate, at: 2)
            try statement.stepDone(); statement.reset()
        }
    }

    private static func insertCollections(_ collections: [SceneLibraryStore.Collection], in db: Database) throws {
        let collection = try db.prepare("""
            INSERT INTO collections(id, ordinal, name, playback_present, playback_minutes, playback_shuffle,
                playback_start_minute, playback_end_minute, weekdays_present) VALUES(?,?,?,?,?,?,?,?,?)
            """)
        let weekday = try db.prepare("INSERT INTO collection_weekdays(collection_id, weekday) VALUES(?, ?)")
        let item = try db.prepare("INSERT INTO collection_items(collection_id, ordinal, scene_id) VALUES(?, ?, ?)")
        for (ordinal, value) in collections.enumerated() {
            let playback = value.playback
            try collection.bind(value.id, at: 1); try collection.bind(ordinal, at: 2); try collection.bind(value.name, at: 3)
            try collection.bind(playback == nil ? 0 : 1, at: 4); try collection.bind(playback?.minutes, at: 5)
            try collection.bind(playback.map { $0.shuffle ? 1 : 0 }, at: 6); try collection.bind(playback?.startMinute, at: 7)
            try collection.bind(playback?.endMinute, at: 8); try collection.bind(playback?.weekdays == nil ? 0 : 1, at: 9)
            try collection.stepDone(); collection.reset()
            for day in playback?.weekdays?.sorted() ?? [] {
                try weekday.bind(value.id, at: 1); try weekday.bind(day, at: 2); try weekday.stepDone(); weekday.reset()
            }
            for (itemOrdinal, sceneID) in value.sceneIDs.enumerated() {
                try item.bind(value.id, at: 1); try item.bind(itemOrdinal, at: 2); try item.bind(sceneID, at: 3)
                try item.stepDone(); item.reset()
            }
        }
    }

    private static func readCatalog(at url: URL) throws -> SceneLibraryStore.Catalog {
        try verifyDatabase(at: url)
        let db = try Database(url: url, mode: .readOnly)
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
        catalog.favorites = try readFavorites(in: db)
        catalog.recent = try readState(in: db)
        catalog.collections = try readCollections(in: db)
        return catalog
    }

    private static func verifyRowBounds(in db: Database) throws {
        let limits: [(String, Int)] = [
            ("sources", SceneLibraryStore.maxSources),
            ("entries", SceneLibraryStore.maxIndividualEntries + SceneLibraryStore.maxSourceEntries),
            ("favorites", 256),
            ("item_state", 256),
            ("collections", 32),
            ("collection_items", 32 * 256),
            ("entry_tags", (SceneLibraryStore.maxIndividualEntries + SceneLibraryStore.maxSourceEntries) * 64),
            ("entry_metadata", (SceneLibraryStore.maxIndividualEntries + SceneLibraryStore.maxSourceEntries) * 32),
            ("source_metadata", SceneLibraryStore.maxSources * 32)
        ]
        for (table, limit) in limits {
            guard try db.scalarInt("SELECT count(*) FROM \(table)") <= limit else {
                throw failure("The Library database exceeds the \(table) row limit.")
            }
        }
    }

    private static func readSources(in db: Database) throws -> [SceneLibraryStore.SourceRoot] {
        var metadata: [String: [String: String]] = [:]
        let metadataRows = try db.prepare("SELECT source_id, key, value FROM source_metadata ORDER BY source_id, key")
        while try metadataRows.stepRow() {
            guard let id = metadataRows.text(0), let key = metadataRows.text(1), let value = metadataRows.text(2) else {
                throw failure("A Source metadata row is invalid.")
            }
            metadata[id, default: [:]][key] = value
        }
        let statement = try db.prepare("SELECT id, name, bookmark FROM sources ORDER BY ordinal")
        var result: [SceneLibraryStore.SourceRoot] = []
        while try statement.stepRow() {
            guard let id = statement.text(0), let name = statement.text(1), let bookmark = statement.data(2) else {
                throw failure("A Source row is invalid.")
            }
            result.append(.init(id: id, name: name, bookmark: bookmark, catalogMetadata: metadata[id]))
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
            guard let id = metadataRows.text(0), let key = metadataRows.text(1), let value = metadataRows.text(2) else {
                throw failure("An entry metadata row is invalid.")
            }
            metadata[id, default: [:]][key] = value
        }
        let statement = try db.prepare("""
            SELECT id, title, bookmark, catalog_id, source_id, relative_media_path, relative_poster_path,
                   series, character, variant, media_type, width, height, fps, duration, availability,
                   obs_byte_length, obs_modified_at, obs_digest_algorithm, obs_digest, obs_package_revision
            FROM entries ORDER BY ordinal
            """)
        var result: [SceneLibraryStore.Entry] = []
        while try statement.stepRow() {
            guard let id = statement.text(0), let title = statement.text(1),
                  let availabilityText = statement.text(15),
                  let availability = SceneLibraryStore.EntryAvailability(rawValue: availabilityText) else {
                throw failure("An entry row is invalid.")
            }
            let hasObservation = !statement.isNull(16) || !statement.isNull(17) || !statement.isNull(18) ||
                !statement.isNull(19) || !statement.isNull(20)
            let observation = hasObservation ? SceneLibraryStore.ReconciliationObservation(
                byteLength: statement.optionalInt64(16),
                modifiedAt: statement.optionalDouble(17).map(Date.init(timeIntervalSinceReferenceDate:)),
                digestAlgorithm: statement.text(18), digest: statement.text(19), packageRevision: statement.text(20)) : nil
            result.append(.init(id: id, title: title, bookmark: statement.data(2), catalogID: statement.text(3),
                sourceID: statement.text(4), relativeMediaPath: statement.text(5), relativePosterPath: statement.text(6),
                series: statement.text(7), character: statement.text(8), variant: statement.text(9),
                tags: (tags[id] ?? []).sorted { $0.0 < $1.0 }.map(\.1), mediaType: statement.text(10),
                width: statement.optionalInt(11), height: statement.optionalInt(12), fps: statement.optionalDouble(13),
                duration: statement.optionalDouble(14), provenance: metadata[id], availability: availability,
                observation: observation))
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
        let statement = try db.prepare("SELECT item_id, recent_at FROM item_state WHERE recent_at IS NOT NULL ORDER BY item_id")
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
        let itemRows = try db.prepare("SELECT collection_id, ordinal, scene_id FROM collection_items ORDER BY collection_id, ordinal")
        while try itemRows.stepRow() {
            guard let id = itemRows.text(0), let sceneID = itemRows.text(2) else { throw failure("A collection item row is invalid.") }
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
                guard let minutes = statement.optionalInt(3), let shuffleValue = statement.optionalInt(4) else {
                    throw failure("A collection playback row is incomplete.")
                }
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

    private static func failure(_ text: String) -> NSError {
        SceneLibraryStore.libraryFailure(text)
    }

    private final class Database {
        enum Mode { case create, readWrite, readOnly }
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
                let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "open failed"
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
                let message = error.map(String.init(cString:)) ?? String(cString: sqlite3_errmsg(handle))
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
            guard result == SQLITE_OK, let prepared else {
                throw failure("SQLite prepare error: \(String(cString: sqlite3_errmsg(database))).")
            }
            statement = prepared
        }

        deinit { if let statement { sqlite3_finalize(statement) } }

        func reset() { if let statement { sqlite3_reset(statement); sqlite3_clear_bindings(statement) } }

        func bind(_ value: String?, at index: Int32) throws {
            guard let statement else { throw failure("SQLite statement is closed.") }
            let result: Int32
            if let value { result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) } }
            else { result = sqlite3_bind_null(statement, index) }
            try checkBind(result)
        }

        func bind(_ value: Data?, at index: Int32) throws {
            guard let statement else { throw failure("SQLite statement is closed.") }
            let result: Int32
            if let value {
                result = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
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
            guard !isNull(column), let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
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
