import Foundation

@main
struct LibrarySQLiteChecks {
    static func main() throws {
        try migrationRoundTripAndIndexes()
        try deterministicExportIgnoresMapInsertionOrder()
        try corruptSQLiteFallsBackAndRebuilds()
        try unknownSelectorFailsClosed()
        print("Library SQLite checks passed: schema/indexes, exact migration, stale JSON retention, deterministic export, corrupt-database recovery and selector versioning")
    }

    private static func sampleCatalog() -> SceneLibraryStore.Catalog {
        let fixed = Date(timeIntervalSinceReferenceDate: 123_456.75)
        let observation = SceneLibraryStore.ReconciliationObservation(
            byteLength: 4_096, modifiedAt: fixed, digestAlgorithm: "sha256",
            digest: String(repeating: "ab", count: 32), packageRevision: "manifest.json:72:100")
        var catalog = SceneLibraryStore.Catalog()
        catalog.sources = [
            .init(id: "source-a", name: "Source A", bookmark: Data([1, 2, 3]),
                  catalogMetadata: ["catalog": "v4", "publisher": "Idlesse Test"])
        ]
        catalog.entries = [
            .init(id: "individual", title: "Individual", bookmark: Data([7, 8, 9])),
            .init(id: "present", title: "Present", catalogID: "catalog.present", sourceID: "source-a",
                  relativeMediaPath: "video/Present.mov", relativePosterPath: "poster/Present.jpg",
                  series: "Series", character: "Character", variant: "Night", tags: ["night", "dress"],
                  mediaType: "video", width: 3840, height: 2160, fps: 60, duration: 12.5,
                  provenance: ["origin": "catalog", "license": "local"], observation: observation),
            .init(id: "missing", title: "Missing", catalogID: "catalog.missing", sourceID: "source-a",
                  relativeMediaPath: "video/Missing.mov", tags: ["archived"], mediaType: "video",
                  availability: .missing, observation: .init(byteLength: 9_999, modifiedAt: fixed))
        ]
        catalog.favorites = ["present", "builtin.Undertow"]
        catalog.recent = ["present": fixed, "builtin.Undertow": Date(timeIntervalSinceReferenceDate: 42)]
        catalog.collections = [
            .init(id: "collection-a", name: "Night", sceneIDs: ["present", "missing", "builtin.Undertow"],
                  playback: .init(minutes: 15, shuffle: true, startMinute: 1320, endMinute: 420, weekdays: [2, 4, 6])),
            .init(id: "collection-b", name: "Manual", sceneIDs: ["individual"], playback: .init(minutes: 30))
        ]
        return catalog
    }

    private static func writeJSON(_ catalog: SceneLibraryStore.Catalog, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(catalog).write(to: file, options: .atomic)
    }

    private static func migrationRoundTripAndIndexes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-sqlite-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        let expected = sampleCatalog()
        try writeJSON(expected, to: file)
        let originalJSON = try Data(contentsOf: file)

        let store = try SceneLibraryStore(file: file)
        precondition(!store.usesSQLiteCatalog)
        precondition(store.catalog == expected)
        let beforeExport = try store.debugExportData()
        precondition(try store.migrateToSQLiteIfNeeded())
        precondition(store.usesSQLiteCatalog)
        precondition(try Data(contentsOf: file) == originalJSON, "Migration must retain the JSON recovery snapshot byte-for-byte")
        precondition(FileManager.default.fileExists(atPath: store.sqliteDatabaseURL.path))
        precondition(FileManager.default.fileExists(atPath: store.backendSelectorURL.path))
        precondition(!FileManager.default.fileExists(atPath: SceneLibrarySQLiteCatalog.paths(for: file).candidate.path))
        try SceneLibrarySQLiteCatalog.verifyDatabase(at: store.sqliteDatabaseURL)

        let requiredIndexes: Set<String> = [
            "entries_source_catalog_identity", "entries_source_path", "entries_source_availability",
            "entries_media_type", "entry_tags_value", "item_state_recent", "collection_items_scene"
        ]
        let indexes = try SceneLibrarySQLiteCatalog.indexNames(at: store.sqliteDatabaseURL)
        precondition(requiredIndexes.isSubset(of: indexes))

        let reopened = try SceneLibraryStore(file: file)
        precondition(reopened.usesSQLiteCatalog)
        precondition(reopened.catalog == expected)
        precondition(try reopened.debugExportData() == beforeExport)

        let jsonSnapshot = try Data(contentsOf: file)
        try reopened.favorite("present")
        precondition(!reopened.catalog.favorites.contains("present"))
        precondition(try Data(contentsOf: file) == jsonSnapshot, "SQLite mutations must leave the recovery JSON historical")
        let reopenedAgain = try SceneLibraryStore(file: file)
        precondition(!reopenedAgain.catalog.favorites.contains("present"))
        precondition(reopenedAgain.catalog.entries.map(\.id) == expected.entries.map(\.id))
        precondition(reopenedAgain.catalog.collections.map(\.sceneIDs) == expected.collections.map(\.sceneIDs))
    }

    private static func deterministicExportIgnoresMapInsertionOrder() throws {
        var first = sampleCatalog()
        var second = sampleCatalog()
        first.sources[0].catalogMetadata = Dictionary(uniqueKeysWithValues: [("publisher", "Idlesse Test"), ("catalog", "v4")])
        second.sources[0].catalogMetadata = Dictionary(uniqueKeysWithValues: [("catalog", "v4"), ("publisher", "Idlesse Test")])
        first.entries[1].provenance = Dictionary(uniqueKeysWithValues: [("license", "local"), ("origin", "catalog")])
        second.entries[1].provenance = Dictionary(uniqueKeysWithValues: [("origin", "catalog"), ("license", "local")])
        precondition(first == second)
        let a = try SceneLibrarySQLiteCatalog.deterministicDebugExport(first)
        let b = try SceneLibrarySQLiteCatalog.deterministicDebugExport(second)
        precondition(a == b)
        let text = String(decoding: a, as: UTF8.self)
        precondition(text.contains("idlesse-library-debug-v1"))
        precondition(text.contains("sqliteSchemaVersion"))
    }

    private static func corruptSQLiteFallsBackAndRebuilds() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-sqlite-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("library.json")
        let expected = sampleCatalog()
        try writeJSON(expected, to: file)
        let paths = SceneLibrarySQLiteCatalog.paths(for: file)
        try Data("broken sqlite".utf8).write(to: paths.database)
        try Data(SceneLibrarySQLiteCatalog.selectorValue.utf8).write(to: paths.selector)

        let recovered = try SceneLibraryStore(file: file)
        precondition(!recovered.usesSQLiteCatalog)
        precondition(recovered.recoveryMessage != nil)
        precondition(recovered.catalog == expected)

        try recovered.favorite("missing")
        precondition(recovered.usesSQLiteCatalog, recovered.recoveryMessage ?? "SQLite rebuild did not activate")
        precondition(recovered.catalog.favorites.contains("missing"))
        precondition(FileManager.default.fileExists(atPath: paths.corruptBackup.path))
        try SceneLibrarySQLiteCatalog.verifyDatabase(at: paths.database)
        let reopened = try SceneLibraryStore(file: file)
        precondition(reopened.usesSQLiteCatalog)
        precondition(reopened.catalog.favorites.contains("missing"))
    }

    private static func unknownSelectorFailsClosed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-sqlite-selector-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        let expected = sampleCatalog()
        try writeJSON(expected, to: file)
        let before = try Data(contentsOf: file)
        let paths = SceneLibrarySQLiteCatalog.paths(for: file)
        try Data("sqlite-v99\n".utf8).write(to: paths.selector)
        do {
            _ = try SceneLibraryStore(file: file)
            preconditionFailure("Unknown Library backend selector was accepted")
        } catch {}
        precondition(try Data(contentsOf: file) == before)
    }
}
