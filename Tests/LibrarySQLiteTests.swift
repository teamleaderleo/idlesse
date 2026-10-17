import Foundation

@main
struct LibrarySQLiteChecks {
    static func main() throws {
        unsetenv("IDLESSE_LIBRARY_BACKEND")
        try migrationRoundTripAndIndexes()
        try embeddedNULCatalogIdentitySurvivesMigration()
        try jsonFallbackPreservesDurableStackFields()
        try deterministicExportIgnoresMapInsertionOrder()
        try nilAndEmptyStateRoundTripsExactly()
        try highChurnStateDoesNotRewriteEntries()
        try staleWritersRebaseAfterActivation()
        try deletionRenumbersOrdinals()
        try failedTransactionRollsBack()
        try corruptSelectedDatabaseFailsClosed()
        try failedCandidateLeavesJSONUntouched()
        try variantAwareCollectionItemsRoundTrip()
        try jsonOverrideCannotBypassSelectedSQLite()
        try unknownSelectorFailsClosed()
        print("Library SQLite checks passed: verified migration, schema/indexes, deterministic export, exact optional state, row-local mutations, stale-writer rebasing, ordinal repair, rollback, variant-aware collection persistence, candidate safety, backend authority and selector versioning")
    }

    static func expectFailure(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError(message) } catch {}
    }

    private static func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-sqlite-\(name)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeJSON(_ catalog: SceneLibraryStore.Catalog, to file: URL) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(catalog)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return data
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

    private static func migrationRoundTripAndIndexes() throws {
        let dir = try folder("migrate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        let initial = sampleCatalog()
        let originalJSON = try writeJSON(initial, to: file)
        let store = try SceneLibraryStore(file: file)
        precondition(!store.usesSQLiteCatalog)
        precondition(store.catalog == initial)

        try store.favorite("present")
        precondition(store.usesSQLiteCatalog)
        precondition(!store.catalog.favorites.contains("present"))
        let retainedJSON = try Data(contentsOf: file)
        precondition(retainedJSON == originalJSON, "SQLite activation rewrote the JSON recovery snapshot")
        precondition(FileManager.default.fileExists(atPath: store.sqliteDatabaseURL.path))
        precondition(FileManager.default.fileExists(atPath: store.backendSelectorURL.path))
        try SceneLibrarySQLiteCatalog.verifyDatabase(at: store.sqliteDatabaseURL)

        let requiredIndexes: Set<String> = [
            "entries_source_catalog_identity", "entries_source_path", "entries_source_availability",
            "entries_media_type", "entry_tags_value", "item_state_recent", "collection_items_scene",
            "collection_items_selection", "entries_source_group", "user_stack_items_entry", "user_stacks_name_nocase"
        ]
        let indexes = try SceneLibrarySQLiteCatalog.indexNames(at: store.sqliteDatabaseURL)
        precondition(requiredIndexes.isSubset(of: indexes))
        let sourceColumns = try SceneLibrarySQLiteCatalog.columnNames(table: "sources", at: store.sqliteDatabaseURL)
        let entryColumns = try SceneLibrarySQLiteCatalog.columnNames(table: "entries", at: store.sqliteDatabaseURL)
        let itemColumns = try SceneLibrarySQLiteCatalog.columnNames(table: "collection_items", at: store.sqliteDatabaseURL)
        precondition(sourceColumns.contains("metadata_present"))
        precondition(entryColumns.isSuperset(of: ["provenance_present", "observation_present", "group_id"]))
        precondition(itemColumns.contains("variant_id"))

        let reopened = try SceneLibraryStore(file: file)
        precondition(reopened.usesSQLiteCatalog)
        precondition(!reopened.catalog.favorites.contains("present"))
        precondition(reopened.catalog.entries == initial.entries)
        precondition(reopened.catalog.sources == initial.sources)
        precondition(reopened.catalog.collections == initial.collections)
        let historicalJSON = try Data(contentsOf: file)
        precondition(historicalJSON == originalJSON)
        let exportA = try reopened.debugExportData()
        let exportB = try SceneLibrarySQLiteCatalog.deterministicDebugExport(reopened.catalog)
        precondition(exportA == exportB)
    }

    private static func embeddedNULCatalogIdentitySurvivesMigration() throws {
        let dir = try folder("embedded-nul-identity")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        var catalog = sampleCatalog()
        catalog.sources[0].id = "a\u{0}b"
        catalog.sources.append(.init(id: "a", name: "Source B", bookmark: Data([4, 5, 6])))
        catalog.entries[1].sourceID = "a\u{0}b"
        catalog.entries[1].catalogID = "c"
        catalog.entries[2].sourceID = "a"
        catalog.entries[2].catalogID = "b\u{0}c"
        let original = try writeJSON(catalog, to: file)

        let store = try SceneLibraryStore(file: file)
        precondition(store.catalog == catalog, "Embedded-NUL Source/catalog pairs were rejected on JSON open")
        try store.withIndexLock { try SceneLibrarySQLiteCatalog.migrate(store.catalog, fromJSON: file) }
        let reopened = try SceneLibraryStore(file: file)
        precondition(reopened.usesSQLiteCatalog)
        precondition(reopened.catalog == catalog, "Embedded-NUL Source/catalog pairs changed across SQLite migration")
        let historical = try Data(contentsOf: file)
        precondition(historical == original, "SQLite migration rewrote the JSON recovery snapshot")
    }

    private static func jsonFallbackPreservesDurableStackFields() throws {
        let dir = try folder("json-fallback-stack-fields")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        var catalog = sampleCatalog()
        catalog.entries[1].groupID = "night-group"
        catalog.entries[2].groupID = "night-group"
        let original = try writeJSON(catalog, to: file)
        let store = try SceneLibraryStore(file: file)

        setenv("IDLESSE_LIBRARY_SQLITE_TEST_FAIL_BEFORE_SELECTOR", "1", 1)
        defer { unsetenv("IDLESSE_LIBRARY_SQLITE_TEST_FAIL_BEFORE_SELECTOR") }
        let stack = try store.createStack(name: "Night Pair", sceneIDs: ["present", "missing"], representativeID: "present")

        let reopened = try SceneLibraryStore(file: file)
        precondition(!reopened.usesSQLiteCatalog, "Injected pre-selector failure unexpectedly selected SQLite")
        precondition(reopened.catalog.version == SceneLibraryStore.catalogVersion)
        precondition(reopened.catalog.stacks == [stack], "JSON fallback dropped the durable stack")
        precondition(reopened.catalog.entries[1].groupID == "night-group" && reopened.catalog.entries[2].groupID == "night-group",
                     "JSON fallback dropped durable Source group fields")
        let encoded = try Data(contentsOf: file)
        precondition(encoded != original, "The stack mutation did not update the JSON fallback")
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        precondition(object?["version"] as? Int == SceneLibraryStore.catalogVersion,
                     "JSON fallback wrote the old catalog version")
    }

    private static func deterministicExportIgnoresMapInsertionOrder() throws {
        var first = sampleCatalog()
        var second = sampleCatalog()
        first.sources[0].catalogMetadata = Dictionary(uniqueKeysWithValues: [
            ("publisher", "Idlesse Test"), ("catalog", "v4")
        ])
        second.sources[0].catalogMetadata = Dictionary(uniqueKeysWithValues: [
            ("catalog", "v4"), ("publisher", "Idlesse Test")
        ])
        first.entries[1].provenance = Dictionary(uniqueKeysWithValues: [
            ("license", "local"), ("origin", "catalog")
        ])
        second.entries[1].provenance = Dictionary(uniqueKeysWithValues: [
            ("origin", "catalog"), ("license", "local")
        ])
        precondition(first == second)
        let a = try SceneLibrarySQLiteCatalog.deterministicDebugExport(first)
        let b = try SceneLibrarySQLiteCatalog.deterministicDebugExport(second)
        precondition(a == b, "Equivalent catalogs produced different debug exports")
        let text = String(decoding: a, as: UTF8.self)
        precondition(text.contains("idlesse-library-debug-v3"))
        precondition(text.contains("sqliteSchemaVersion"))
    }

    private static func nilAndEmptyStateRoundTripsExactly() throws {
        let dir = try folder("optional")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        var catalog = SceneLibraryStore.Catalog()
        catalog.sources = [
            .init(id: "nil-source", name: "Nil", bookmark: Data([1]), catalogMetadata: nil),
            .init(id: "empty-source", name: "Empty", bookmark: Data([2]), catalogMetadata: [:])
        ]
        catalog.entries = [
            .init(id: "nil-entry", title: "Nil", sourceID: "nil-source", relativeMediaPath: "Nil.mp4", provenance: nil, observation: nil),
            .init(id: "empty-entry", title: "Empty", sourceID: "empty-source", relativeMediaPath: "Empty.mp4", provenance: [:], observation: .init())
        ]
        let original = try writeJSON(catalog, to: file)
        let store = try SceneLibraryStore(file: file)
        try store.withIndexLock { try SceneLibrarySQLiteCatalog.migrate(store.catalog, fromJSON: file) }
        let reopened = try SceneLibraryStore(file: file)
        precondition(reopened.catalog == catalog, "SQLite collapsed nil and empty metadata/observation state")
        let historical = try Data(contentsOf: file)
        precondition(historical == original)
    }

    private static func highChurnStateDoesNotRewriteEntries() throws {
        let dir = try folder("delta")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        let initial = sampleCatalog()
        _ = try writeJSON(initial, to: file)
        let store = try SceneLibraryStore(file: file)
        try store.favorite("present")
        try SceneLibrarySQLiteCatalog.testingExecute("""
            CREATE TRIGGER reject_entry_update BEFORE UPDATE ON entries BEGIN SELECT RAISE(ABORT, 'entry rewrite'); END;
            CREATE TRIGGER reject_entry_insert BEFORE INSERT ON entries BEGIN SELECT RAISE(ABORT, 'entry rewrite'); END;
            CREATE TRIGGER reject_entry_delete BEFORE DELETE ON entries BEGIN SELECT RAISE(ABORT, 'entry rewrite'); END;
            """, for: file)
        try store.favorite("present")
        try store.used("builtin.Undertow")
        try store.renameCollection("collection-b", name: "Manual Renamed")
        let reopened = try SceneLibraryStore(file: file)
        precondition(reopened.catalog.favorites.contains("present"))
        precondition(reopened.catalog.collections.first(where: { $0.id == "collection-b" })?.name == "Manual Renamed")
        precondition(reopened.catalog.entries == initial.entries)
    }

    private static func staleWritersRebaseAfterActivation() throws {
        let dir = try folder("stale")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        var catalog = SceneLibraryStore.Catalog()
        catalog.entries = [.init(id: "victim", title: "Victim", bookmark: Data([9]))]
        _ = try writeJSON(catalog, to: file)
        let activation = try SceneLibraryStore(file: file)
        try activation.favorite("builtin.Undertow")
        precondition(activation.usesSQLiteCatalog)

        let a = try SceneLibraryStore(file: file)
        let b = try SceneLibraryStore(file: file)
        _ = try a.createCollection(name: "A")
        _ = try b.createCollection(name: "B")
        var merged = try SceneLibraryStore(file: file).catalog
        precondition(Set(merged.collections.map(\.name)).isSuperset(of: ["A", "B"]), "SQLite stale collection writers clobbered each other")

        let remover = try SceneLibraryStore(file: file)
        let stale = try SceneLibraryStore(file: file)
        try remover.remove("victim")
        try stale.favorite("victim")
        let after = try SceneLibraryStore(file: file)
        precondition(!after.catalog.entries.contains { $0.id == "victim" }, "SQLite stale writer resurrected a deliberate removal")
        precondition(!after.catalog.favorites.contains("victim"))
        precondition(after.recentlyRemoved().contains { $0.entry.id == "victim" })
        merged = after.catalog
        precondition(Set(merged.collections.map(\.name)).isSuperset(of: ["A", "B"]))
    }

    private static func deletionRenumbersOrdinals() throws {
        let dir = try folder("ordinals")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        _ = try writeJSON(sampleCatalog(), to: file)
        let store = try SceneLibraryStore(file: file)
        try store.favorite("present")
        try store.removeCollection("collection-a")
        let added = try store.createCollection(name: "After Removal")
        let reopened = try SceneLibraryStore(file: file)
        precondition(reopened.catalog.collections.map(\.id) == ["collection-b", added.id], "SQLite collection ordinals were not compacted after deletion")
    }

    private static func failedTransactionRollsBack() throws {
        let dir = try folder("rollback")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        let initial = sampleCatalog()
        _ = try writeJSON(initial, to: file)
        let store = try SceneLibraryStore(file: file)
        try store.favorite("present")
        let before = store.catalog
        try SceneLibrarySQLiteCatalog.testingExecute("""
            CREATE TRIGGER reject_favorite_insert BEFORE INSERT ON favorites BEGIN SELECT RAISE(ABORT, 'simulated interruption'); END;
            """, for: file)
        expectFailure("SQLite transaction committed after an injected write failure") {
            try store.favorite("present")
        }
        let reopened = try SceneLibraryStore(file: file)
        precondition(reopened.catalog == before, "Failed SQLite transaction left a partial catalog mutation")
    }

    private static func corruptSelectedDatabaseFailsClosed() throws {
        let dir = try folder("corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        let original = try writeJSON(sampleCatalog(), to: file)
        let store = try SceneLibraryStore(file: file)
        try store.favorite("present")
        precondition(store.usesSQLiteCatalog)
        try Data("broken sqlite".utf8).write(to: store.sqliteDatabaseURL)
        expectFailure("A corrupt selected SQLite catalog silently fell back to historical JSON") {
            _ = try SceneLibraryStore(file: file)
        }
        let historical = try Data(contentsOf: file)
        precondition(historical == original, "Corrupt DB handling rewrote historical JSON")
    }

    private static func failedCandidateLeavesJSONUntouched() throws {
        let dir = try folder("candidate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        let originalCatalog = sampleCatalog()
        let original = try writeJSON(originalCatalog, to: file)
        let store = try SceneLibraryStore(file: file)
        var invalid = originalCatalog
        invalid.entries.append(.init(id: "duplicate-catalog", title: "Duplicate", catalogID: "catalog.present",
                                     sourceID: "source-a", relativeMediaPath: "video/Duplicate.mov"))
        expectFailure("Invalid candidate catalog was activated") {
            try store.withIndexLock { try SceneLibrarySQLiteCatalog.migrate(invalid, fromJSON: file) }
        }
        let after = try Data(contentsOf: file)
        precondition(after == original)
        precondition(!FileManager.default.fileExists(atPath: store.backendSelectorURL.path))
        let reopened = try SceneLibraryStore(file: file)
        precondition(reopened.catalog == originalCatalog)
    }

    private static func variantAwareCollectionItemsRoundTrip() throws {
        let dir = try folder("variant-aware-collection")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        _ = try writeJSON(sampleCatalog(), to: file)
        let store = try SceneLibraryStore(file: file)
        try store.favorite("present")
        let variantID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        try SceneLibrarySQLiteCatalog.testingExecute(
            "UPDATE collection_items SET variant_id='\(variantID.uuidString)' WHERE collection_id='collection-a' AND ordinal=0",
            for: file)
        let reopened = try SceneLibraryStore(file: file)
        let collection = reopened.catalog.collections.first(where: { $0.id == "collection-a" })!
        precondition(collection.items == [
            .init(sceneID: "present", variantID: variantID),
            .init(sceneID: "missing"),
            .init(sceneID: "builtin.Undertow")
        ], "SQLite dropped or reordered variant-aware collection selections")

        let legacy = Data("""
        {"id":"legacy","name":"Legacy","sceneIDs":["present","missing"]}
        """.utf8)
        let decoded = try JSONDecoder().decode(SceneLibraryStore.Collection.self, from: legacy)
        precondition(decoded.items == [.init(sceneID: "present"), .init(sceneID: "missing")],
                     "Legacy sceneIDs did not decode as default selections")

        var edited = reopened.catalog
        edited.collections[0].items = [
            .init(sceneID: "missing"),
            .init(sceneID: "present", variantID: variantID)
        ]
        try reopened.commitCatalog(edited)
        let editedStore = try SceneLibraryStore(file: file)
        precondition(editedStore.catalog.collections[0].items == edited.collections[0].items,
                     "Collection selection order did not survive a catalog mutation")
        try editedStore.remove("present")
        let removedStore = try SceneLibraryStore(file: file)
        precondition(removedStore.catalog.collections[0].items == [.init(sceneID: "missing")],
                     "Removing a scene left a stale variant selection in its collection")

        var proposed = sampleCatalog()
        proposed.collections[0].items[0] = .init(sceneID: "present", variantID: variantID)
        var disk = sampleCatalog()
        disk.collections[0].items.append(.init(sceneID: "present", variantID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!))
        let merged = SceneLibraryStore.rebase(proposed, from: sampleCatalog(), onto: disk)
        precondition(merged.collections[0].items.contains(where: { $0.variantID == variantID }) &&
                     merged.collections[0].items.contains(where: { $0.variantID?.uuidString == "22222222-2222-2222-2222-222222222222" }),
                     "Concurrent collection variant selections were not preserved during rebase")
    }

    private static func jsonOverrideCannotBypassSelectedSQLite() throws {
        let dir = try folder("json-override")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        _ = try writeJSON(sampleCatalog(), to: file)
        let store = try SceneLibraryStore(file: file)
        try store.favorite("present")
        precondition(store.usesSQLiteCatalog)
        setenv("IDLESSE_LIBRARY_BACKEND", "json", 1)
        defer { unsetenv("IDLESSE_LIBRARY_BACKEND") }
        expectFailure("JSON test override bypassed an already-selected SQLite catalog") {
            _ = try SceneLibraryStore(file: file)
        }
    }

    private static func unknownSelectorFailsClosed() throws {
        let dir = try folder("selector")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        let original = try writeJSON(sampleCatalog(), to: file)
        let paths = SceneLibrarySQLiteCatalog.paths(for: file)
        try Data("sqlite-v999\n".utf8).write(to: paths.selector)
        expectFailure("Unknown Library backend selector was accepted") { _ = try SceneLibraryStore(file: file) }
        let after = try Data(contentsOf: file)
        precondition(after == original)
    }
}
