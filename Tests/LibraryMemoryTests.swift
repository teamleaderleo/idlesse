import Foundation

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
