import Foundation

@main
struct LibrarySQLiteValueFidelityChecks {
    static func main() throws {
        unsetenv("IDLESSE_LIBRARY_BACKEND")
        unsetenv("IDLESSE_LIBRARY_SQLITE_TEST_FAIL_BEFORE_SELECTOR")
        try embeddedNULAndEmptyBlobsRoundTripExactly()
        try storeFallbackPersistsMutationAndRetriesMigration()
        print("Library SQLite value fidelity checks passed: embedded-NUL text, empty blobs, JSON fallback and healthy retry")
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
        precondition(try Data(contentsOf: file) == originalJSON, "Migration rewrote the JSON recovery snapshot")
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
        precondition(try Data(contentsOf: file) == fallbackJSON,
                     "Successful retry rewrote the authoritative JSON fallback snapshot")

        let reopenedSQLite = try SceneLibraryStore(file: file)
        precondition(reopenedSQLite.usesSQLiteCatalog)
        precondition(reopenedSQLite.catalog.favorites.contains("entry"),
                     "Mutation after healthy SQLite retry did not survive reopen")
    }
}
