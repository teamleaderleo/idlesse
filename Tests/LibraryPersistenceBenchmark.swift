import Foundation

@main
struct LibraryPersistenceBenchmark {
    static func measure<T>(_ body: () throws -> T) rethrows -> (T, Double) {
        let start = Date()
        let result = try body()
        return (result, Date().timeIntervalSince(start) * 1000)
    }

    static func main() throws {
        unsetenv("IDLESSE_LIBRARY_BACKEND")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-library-benchmark-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index.json")

        var catalog = SceneLibraryStore.Catalog()
        catalog.sources = [.init(id: "source", name: "Measured Source", bookmark: Data(repeating: 7, count: 512),
                                 catalogMetadata: ["catalog": "benchmark-v2", "publisher": "Idlesse"])]
        catalog.entries = (0..<SceneLibraryStore.maxSourceEntries).map { index in
            .init(id: "entry-\(index)", title: "Wallpaper \(index)", catalogID: "catalog-\(index)",
                  sourceID: "source", relativeMediaPath: "wallpapers/\(index).mov",
                  relativePosterPath: "posters/\(index).jpg", series: "Series \(index % 24)",
                  character: "Character \(index % 128)", variant: "Variant \(index % 8)",
                  tags: ["night", "animated", "catalog", "tag-\(index % 16)", "mood-\(index % 7)", "source"],
                  mediaType: "video", width: 3840, height: 2160, fps: 60,
                  duration: 12.0 + Double(index % 20) / 10.0,
                  provenance: ["origin": "benchmark", "license": "local", "revision": "2", "index": "\(index)"],
                  observation: .init(byteLength: Int64(2_000_000 + index),
                                     modifiedAt: Date(timeIntervalSinceReferenceDate: Double(index))))
        }
        catalog.favorites = Set((0..<128).map { "entry-\($0)" })
        catalog.recent = Dictionary(uniqueKeysWithValues: (0..<256).map {
            ("entry-\($0)", Date(timeIntervalSinceReferenceDate: Double($0)))
        })
        catalog.collections = (0..<8).map { collection in
            let start = collection * 128
            return .init(id: "collection-\(collection)", name: "Collection \(collection)",
                         sceneIDs: (start..<(start + 128)).map { "entry-\($0)" })
        }

        let encoder = JSONEncoder()
        let (json, encodeMS) = try measure { try encoder.encode(catalog) }
        precondition(json.count <= SceneLibraryStore.maxIndexBytes, "Representative 4K JSON exceeds the active migration bound")
        try json.write(to: file, options: .atomic)

        let (store, jsonOpenMS) = try measure { try SceneLibraryStore(file: file) }
        precondition(store.catalog == catalog)
        let (_, activationMS) = try measure { try store.favorite("entry-0") }
        precondition(store.usesSQLiteCatalog)
        let (_, sqliteOpenMS) = try measure { _ = try SceneLibraryStore(file: file) }
        let (_, favoriteMS) = try measure { try store.favorite("entry-1") }
        let (_, recentMS) = try measure { try store.used("entry-4095") }

        let dbSize = ((try FileManager.default.attributesOfItem(atPath: store.sqliteDatabaseURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        precondition(dbSize <= SceneLibrarySQLiteCatalog.maxDatabaseBytes)
        let historicalJSON = try Data(contentsOf: file)
        precondition(historicalJSON == json, "Measured SQLite mutations changed the historical JSON snapshot")

        print(String(format: "Library persistence 4K rich: json=%d bytes encode=%.1fms json-open=%.1fms sqlite-activate=%.1fms sqlite-open=%.1fms favorite=%.1fms recent=%.1fms db=%lld bytes",
                     json.count, encodeMS, jsonOpenMS, activationMS, sqliteOpenMS, favoriteMS, recentMS, dbSize))
    }
}
