import Foundation

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
