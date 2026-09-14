import Foundation

@main
struct LibraryStackChecks {
    static func main() throws {
        unsetenv("IDLESSE_LIBRARY_BACKEND")
        try sourceGroupsAndSearchProjection()
        try userStackCRUDAndSQLiteRoundTrip()
        try staleWritersMergeStackDeltas()
        try reconciliationPreservesStableStackMembership()
        try schemaV2UpgradesInPlace()
        try validationRejectsAmbiguousMembership()
        print("Library stack checks passed: source groups, reversible user stacks, representatives/search, stale writers, reconciliation identity, SQLite v2→v3 migration and exclusive membership")
    }

    private static func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-stacks-\(name)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeJSON(_ catalog: SceneLibraryStore.Catalog, to file: URL) throws {
        let data = try JSONEncoder().encode(catalog)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    private static func baseCatalog() -> SceneLibraryStore.Catalog {
        var catalog = SceneLibraryStore.Catalog()
        catalog.sources = [
            .init(id: "source-a", name: "A", bookmark: Data([1])),
            .init(id: "source-b", name: "B", bookmark: Data([2]))
        ]
        catalog.entries = [
            .init(id: "a", title: "Aurora Dawn", catalogID: "a", groupID: "aurora", sourceID: "source-a",
                  relativeMediaPath: "a.jpg", series: "Aurora", character: "Mira", tags: ["warm"], mediaType: "image"),
            .init(id: "b", title: "Nebula Night", catalogID: "b", groupID: "aurora", sourceID: "source-a",
                  relativeMediaPath: "b.mov", series: "Aurora", character: "Mira", tags: ["night"], mediaType: "video"),
            .init(id: "c", title: "Solo", catalogID: "c", sourceID: "source-a",
                  relativeMediaPath: "c.jpg", series: "Elsewhere", mediaType: "image"),
            .init(id: "d", title: "Other Source One", catalogID: "d", groupID: "aurora", sourceID: "source-b",
                  relativeMediaPath: "d.jpg", series: "Elsewhere", mediaType: "image"),
            .init(id: "e", title: "Other Source Two", catalogID: "e", groupID: "aurora", sourceID: "source-b",
                  relativeMediaPath: "e.jpg", series: "Elsewhere", mediaType: "image")
        ]
        return catalog
    }

    private static func sourceGroupsAndSearchProjection() throws {
        let catalog = baseCatalog()
        let source = LibraryStackBrowser.projections(in: catalog).filter { $0.kind == .source }
        precondition(source.count == 2, "Source-scoped group IDs must not merge across Sources")
        let a = source.first { $0.entryIDs.contains("a") }!
        precondition(a.entryIDs == ["a", "b"] && a.name == "Aurora")
        precondition(LibraryStackBrowser.representative(for: a, in: catalog)?.id == "a")
        precondition(LibraryStackBrowser.representative(for: a, in: catalog, query: "neb")?.id == "b")
        precondition(LibraryStackBrowser.matchingChildren(of: a, in: catalog, query: "night").map(\.id) == ["b"])
        precondition(LibraryStackBrowser.typeHint(for: a, in: catalog) == "MIXED")
        precondition(LibraryStackBrowser.score(query: "Mira", stack: a, in: catalog) != nil)
    }

    private static func userStackCRUDAndSQLiteRoundTrip() throws {
        let dir = try folder("crud")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        var catalog = baseCatalog()
        catalog.stacks = [.init(id: "custom", name: "Favorites Pair", sceneIDs: ["b", "a"], representativeID: "b")]
        try writeJSON(catalog, to: file)
        let store = try SceneLibraryStore(file: file)
        let projections = LibraryStackBrowser.projections(in: store.catalog)
        let custom = projections.first { $0.kind == .user }!
        precondition(custom.entryIDs == ["b", "a"])
        precondition(LibraryStackBrowser.representative(for: custom, in: store.catalog)?.id == "b")
        precondition(projections.filter { $0.kind == .source && $0.entryIDs.contains("a") }.isEmpty,
                     "Explicit user stacks must take presentation priority over Source groups")

        try store.setStackRepresentative("custom", entryID: "a")
        try store.moveStackScene("a", in: "custom", by: -1)
        try store.renameStack("custom", name: "Pair Renamed")
        precondition(store.usesSQLiteCatalog)
        let reopened = try SceneLibraryStore(file: file)
        precondition(reopened.catalog.stacks == [.init(id: "custom", name: "Pair Renamed", sceneIDs: ["a", "b"], representativeID: "a")])
        precondition(reopened.catalog.entries.first(where: { $0.id == "a" })?.groupID == "aurora")
        try SceneLibrarySQLiteCatalog.verifyDatabase(at: reopened.sqliteDatabaseURL)
        let indexes = try SceneLibrarySQLiteCatalog.indexNames(at: reopened.sqliteDatabaseURL)
        precondition(indexes.isSuperset(of: ["entries_source_group", "user_stack_items_entry", "user_stacks_name_nocase"]))
        let entryColumns = try SceneLibrarySQLiteCatalog.columnNames(table: "entries", at: reopened.sqliteDatabaseURL)
        precondition(entryColumns.contains("group_id"))

        let export = try reopened.debugExportData()
        let text = String(decoding: export, as: UTF8.self)
        precondition(text.contains("idlesse-library-debug-v3") && text.contains("groupID") && text.contains("Pair Renamed"))

        try reopened.remove("a")
        precondition(reopened.catalog.stacks.isEmpty, "A stack with fewer than two surviving members must disappear")
        precondition(reopened.catalog.entries.contains { $0.id == "b" }, "Stack cleanup must never delete child media entries")
    }

    private static func staleWritersMergeStackDeltas() throws {
        let dir = try folder("stale")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        var catalog = baseCatalog()
        catalog.stacks = [.init(id: "stack", name: "Original", sceneIDs: ["a", "b"], representativeID: "a")]
        try writeJSON(catalog, to: file)
        let activate = try SceneLibraryStore(file: file)
        try activate.renameStack("stack", name: "Activated")

        let a = try SceneLibraryStore(file: file)
        let b = try SceneLibraryStore(file: file)
        try a.renameStack("stack", name: "Renamed")
        try b.setStackRepresentative("stack", entryID: "b")
        let merged = try SceneLibraryStore(file: file).catalog.stacks.first { $0.id == "stack" }!
        precondition(merged.name == "Renamed" && merged.representativeID == "b",
                     "Independent stale stack edits must merge at field granularity")

        let remover = try SceneLibraryStore(file: file)
        let stale = try SceneLibraryStore(file: file)
        try remover.removeStack("stack")
        do { try stale.renameStack("stack", name: "Must Not Return") } catch {}
        let afterDeletion = try SceneLibraryStore(file: file)
        precondition(afterDeletion.catalog.stacks.isEmpty,
                     "A stale writer must not resurrect a stack deleted by another process")
    }

    private static func reconciliationPreservesStableStackMembership() throws {
        let dir = try folder("reconcile")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        var catalog = baseCatalog()
        catalog.stacks = [.init(id: "stack", name: "Stable IDs", sceneIDs: ["a", "b"], representativeID: "a")]
        try writeJSON(catalog, to: file)
        let store = try SceneLibraryStore(file: file)
        let scanned: [SceneLibraryStore.SourceEntry] = [
            .init(relativeMediaPath: "a-new.jpg", title: "Aurora Dawn", catalogID: "a", groupID: "new-group",
                  series: "Aurora", character: "Mira", tags: ["warm"], mediaType: "image"),
            .init(relativeMediaPath: "b.mov", title: "Nebula Night", catalogID: "b", groupID: "new-group",
                  series: "Aurora", character: "Mira", tags: ["night"], mediaType: "video"),
            .init(relativeMediaPath: "c.jpg", title: "Solo", catalogID: "c", series: "Elsewhere", mediaType: "image")
        ]
        let diff = try store.prepareReconciliation(sourceID: "source-a", scanned: scanned)
        try store.applyReconciliation(diff)
        let entries = Dictionary(uniqueKeysWithValues: store.catalog.entries.map { ($0.id, $0) })
        precondition(entries["a"]?.relativeMediaPath == "a-new.jpg" && entries["a"]?.groupID == "new-group")
        precondition(store.catalog.stacks.first(where: { $0.id == "stack" })?.sceneIDs == ["a", "b"],
                     "Reconciliation must preserve user stack relationships through stable Entry IDs")
    }

    private static func schemaV2UpgradesInPlace() throws {
        let dir = try folder("upgrade")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        var catalog = SceneLibraryStore.Catalog()
        catalog.entries = [.init(id: "individual", title: "Individual", bookmark: Data([7]))]
        try writeJSON(catalog, to: file)
        let store = try SceneLibraryStore(file: file)
        try store.favorite("builtin.Undertow")
        precondition(store.usesSQLiteCatalog)
        try SceneLibrarySQLiteCatalog.testingExecute("""
            DROP INDEX entries_source_group;
            DROP INDEX user_stack_items_entry;
            DROP INDEX user_stacks_name_nocase;
            DROP TABLE user_stack_items;
            DROP TABLE user_stacks;
            ALTER TABLE entries DROP COLUMN group_id;
            UPDATE catalog_meta SET value='2' WHERE key='schema_version';
            PRAGMA user_version = 2;
            """, for: file)
        let reopened = try SceneLibraryStore(file: file)
        precondition(reopened.catalog == store.catalog, "SQLite v2→v3 migration changed catalog semantics")
        try SceneLibrarySQLiteCatalog.verifyDatabase(at: reopened.sqliteDatabaseURL)
        let upgradedColumns = try SceneLibrarySQLiteCatalog.columnNames(table: "entries", at: reopened.sqliteDatabaseURL)
        precondition(upgradedColumns.contains("group_id"))
    }

    private static func validationRejectsAmbiguousMembership() throws {
        let dir = try folder("validation")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.json")
        try writeJSON(baseCatalog(), to: file)
        let store = try SceneLibraryStore(file: file)
        _ = try store.createStack(name: "First", sceneIDs: ["a", "b"])
        do {
            _ = try store.createStack(name: "Second", sceneIDs: ["a", "c"])
            fatalError("An entry was allowed into two user stacks")
        } catch {}
        precondition(store.catalog.stacks.count == 1)
    }
}
