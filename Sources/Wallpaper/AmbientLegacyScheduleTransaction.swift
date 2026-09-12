import Foundation

/// Durable recovery record for the legacy collection scheduler. Kept separate
/// from AmbientSet storage so a failed cutover can always return to the prior
/// authority path without reconstructing schedule windows from Ambient Sets.
struct AmbientLegacyCollectionScheduleBackup: Codable, Equatable {
    var collectionID: String
    var playback: SceneLibraryStore.Playback
}

/// Rewrites all legacy collection schedule windows in one atomic Library-index
/// replacement. The old implementation called `setPlayback` once per collection,
/// which could leave a partially suspended or partially restored scheduler.
enum AmbientLegacyScheduleTransaction {
    static func backup(from catalog: SceneLibraryStore.Catalog) -> [AmbientLegacyCollectionScheduleBackup] {
        catalog.collections.compactMap { collection in
            guard let playback = collection.playback,
                  playback.startMinute != nil, playback.endMinute != nil else { return nil }
            return .init(collectionID: collection.id, playback: playback)
        }
    }

    static func suspending(_ catalog: SceneLibraryStore.Catalog) -> SceneLibraryStore.Catalog {
        var next = catalog
        for index in next.collections.indices {
            guard var playback = next.collections[index].playback,
                  playback.startMinute != nil, playback.endMinute != nil else { continue }
            playback.startMinute = nil
            playback.endMinute = nil
            playback.weekdays = nil
            next.collections[index].playback = playback
        }
        return next
    }

    static func restoring(_ catalog: SceneLibraryStore.Catalog,
                          backup: [AmbientLegacyCollectionScheduleBackup]) -> SceneLibraryStore.Catalog {
        var next = catalog
        let byID = Dictionary(uniqueKeysWithValues: backup.map { ($0.collectionID, $0.playback) })
        for index in next.collections.indices {
            if let playback = byID[next.collections[index].id] {
                next.collections[index].playback = playback
            }
        }
        return next
    }

    static func write(_ catalog: SceneLibraryStore.Catalog,
                      to file: URL,
                      writer: (Data, URL) throws -> Void = atomicWriter) throws {
        let data = try JSONEncoder().encode(catalog)
        guard data.count <= SceneLibraryStore.maxIndexBytes else {
            throw AmbientSetActuationError.invalidLegacySchedule
        }
        try writer(data, file)
    }

    static func suspend(_ library: SceneLibraryStore,
                        writer: (Data, URL) throws -> Void = atomicWriter) throws {
        try write(suspending(library.catalog), to: library.file, writer: writer)
    }

    static func restore(_ library: SceneLibraryStore,
                        backup: [AmbientLegacyCollectionScheduleBackup],
                        writer: (Data, URL) throws -> Void = atomicWriter) throws {
        try write(restoring(library.catalog, backup: backup), to: library.file, writer: writer)
    }

    private static func atomicWriter(_ data: Data, _ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}
