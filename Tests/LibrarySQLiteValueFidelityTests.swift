import Foundation

@main
struct LibrarySQLiteValueFidelityChecks {
    static func main() throws {
        unsetenv("IDLESSE_LIBRARY_BACKEND")
        unsetenv("IDLESSE_LIBRARY_SQLITE_TEST_FAIL_BEFORE_SELECTOR")
        try embeddedNULAndEmptyBlobsRoundTripExactly()
        try sourceCatalogIdentityUsesExactPair()
        try storeFallbackPersistsMutationAndRetriesMigration()
        print("Library SQLite value fidelity checks passed: embedded-NUL text, empty blobs, exact Source/catalog identity, JSON fallback and healthy retry")
    }

    private static func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("idlesse-sqlite-values-\(name)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private static func writeJSON(_ catalog: SceneLibraryStore.Catalog, to file: URL) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(catalog)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return data
    }

    private static func embeddedNULAndEmptyBlobsRoundTripExactly() throws {
        let dir = try folder("round-trip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")

        var catalog = SceneLibraryStore.Catalog()
        catalog.sources = [
            .init(id: "source-empty", name: "Empty Bookmark", bookmark: Data(),
                  catalogMetadata: ["note": "alpha\u{0}omega"])
        ]
        catalog.entries = [
            .init(id: "individual-empty", title: "Lead\u{0}Tail", bookmark: Data())
        ]
        let originalJSON = try writeJSON(catalog, to: file)

        let store = try SceneLibraryStore(file: file)
        precondition(!store.usesSQLiteCatalog)
        try store.withIndexLock {
            try SceneLibrarySQLiteCatalog.migrate(store.catalog, fromJSON: file)
        }
        precondition(store.usesSQLiteCatalog, "Value-fidelity migration did not select SQLite")

        let reopened = try SceneLibraryStore(file: file)
        precondition(reopened.usesSQLiteCatalog)
        precondition(reopened.catalog == catalog, "SQLite changed a valid persisted text/blob value")
        precondition(reopened.catalog.entries[0].title == "Lead\u{0}Tail")
        precondition(reopened.catalog.entries[0].bookmark == Data())
        precondition(reopened.catalog.sources[0].bookmark == Data())
        precondition(reopened.catalog.sources[0].catalogMetadata?["note"] == "alpha\u{0}omega")
        let retainedJSON = try Data(contentsOf: file)
        precondition(retainedJSON == originalJSON, "Migration rewrote the JSON recovery snapshot")
    }

    private static func sourceCatalogIdentityUsesExactPair() throws {
        let dir = try folder("catalog-pair")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")

        var catalog = SceneLibraryStore.Catalog()
        catalog.sources = [
            .init(id: "a\u{0}b", name: "NUL Source", bookmark: Data([1])),
            .init(id: "a", name: "Plain Source", bookmark: Data([2]))
        ]
        catalog.entries = [
            .init(id: "left", title: "Left", catalogID: "c", sourceID: "a\u{0}b", relativeMediaPath: "left.jpg"),
            .init(id: "right", title: "Right", catalogID: "b\u{0}c", sourceID: "a", relativeMediaPath: "right.jpg")
        ]
        _ = try writeJSON(catalog, to: file)

        let store = try SceneLibraryStore(file: file)
        precondition(store.catalog.entries == catalog.entries,
                     "Distinct Source/catalog identity pairs collided during validation")
        try store.favorite("left")
        precondition(store.usesSQLiteCatalog)
        let reopened = try SceneLibraryStore(file: file)
        precondition(reopened.usesSQLiteCatalog)
        precondition(reopened.catalog.sources == catalog.sources)
        precondition(reopened.catalog.entries == catalog.entries)
        precondition(reopened.catalog.favorites == ["left"])

        let duplicateDir = try folder("catalog-duplicate")
        defer { try? FileManager.default.removeItem(at: duplicateDir) }
        let duplicateFile = duplicateDir.appendingPathComponent("index.json")
        var duplicate = SceneLibraryStore.Catalog()
        duplicate.sources = [.init(id: "same", name: "Same", bookmark: Data([3]))]
        duplicate.entries = [
            .init(id: "one", title: "One", catalogID: "dup", sourceID: "same", relativeMediaPath: "one.jpg"),
            .init(id: "two", title: "Two", catalogID: "dup", sourceID: "same", relativeMediaPath: "two.jpg")
        ]
        _ = try writeJSON(duplicate, to: duplicateFile)
        var rejected = false
        do { _ = try SceneLibraryStore(file: duplicateFile) } catch { rejected = true }
        precondition(rejected, "Duplicate catalog IDs within one Source must still fail validation")
    }

    private static func storeFallbackPersistsMutationAndRetriesMigration() throws {
        let dir = try folder("fallback")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")

        var catalog = SceneLibraryStore.Catalog()
        catalog.entries = [.init(id: "entry", title: "Entry", bookmark: Data([1, 2, 3]))]
        catalog.favorites = ["entry"]
        _ = try writeJSON(catalog, to: file)

        let store = try SceneLibraryStore(file: file)
        setenv("IDLESSE_LIBRARY_SQLITE_TEST_FAIL_BEFORE_SELECTOR", "1", 1)
        do {
            defer { unsetenv("IDLESSE_LIBRARY_SQLITE_TEST_FAIL_BEFORE_SELECTOR") }
            try store.favorite("entry")
        }

        let paths = SceneLibrarySQLiteCatalog.paths(for: file)
        precondition(!store.usesSQLiteCatalog, "Injected pre-selector failure activated SQLite")
        precondition(!FileManager.default.fileExists(atPath: paths.selector.path))
        precondition(!FileManager.default.fileExists(atPath: paths.database.path))
        precondition(!FileManager.default.fileExists(atPath: paths.candidate.path))

        let fallbackJSON = try Data(contentsOf: file)
        let reopenedJSON = try SceneLibraryStore(file: file)
        precondition(!reopenedJSON.usesSQLiteCatalog)
        precondition(!reopenedJSON.catalog.favorites.contains("entry"),
                     "Store mutation was lost when SQLite candidate migration failed")

        try reopenedJSON.favorite("entry")
        precondition(reopenedJSON.usesSQLiteCatalog, "Healthy mutation did not retry SQLite activation")
        precondition(reopenedJSON.catalog.favorites.contains("entry"))
        let postRetryJSON = try Data(contentsOf: file)
        precondition(postRetryJSON == fallbackJSON,
                     "Successful retry rewrote the authoritative JSON fallback snapshot")

        let reopenedSQLite = try SceneLibraryStore(file: file)
        precondition(reopenedSQLite.usesSQLiteCatalog)
        precondition(reopenedSQLite.catalog.favorites.contains("entry"),
                     "Mutation after healthy SQLite retry did not survive reopen")
    }
}
