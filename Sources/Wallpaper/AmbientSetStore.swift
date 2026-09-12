import Foundation

struct AmbientSetCatalog: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = Self.currentVersion
    var sets: [AmbientSet] = []
    var manualHold: AmbientManualHold?
}

enum AmbientSetStoreError: Error, Equatable {
    case unsupportedVersion(Int)
    case catalogTooLarge
    case tooManySets
    case invalidSet(String)
    case duplicateID(String)
    case invalidManualHold
}

final class AmbientSetStore {
    static let maxSets = AmbientSetResolver.maxSets
    static let maxCatalogBytes = 1_048_576

    let fileURL: URL
    private(set) var catalog: AmbientSetCatalog

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            if let size = values?.fileSize, size > Self.maxCatalogBytes {
                throw AmbientSetStoreError.catalogTooLarge
            }
            let data = try Data(contentsOf: fileURL)
            guard data.count <= Self.maxCatalogBytes else { throw AmbientSetStoreError.catalogTooLarge }
            let decoded = try JSONDecoder().decode(AmbientSetCatalog.self, from: data)
            guard decoded.version == AmbientSetCatalog.currentVersion else {
                throw AmbientSetStoreError.unsupportedVersion(decoded.version)
            }
            try Self.validate(decoded.sets, manualHold: decoded.manualHold)
            catalog = decoded
        } else {
            catalog = AmbientSetCatalog()
        }
    }

    func replaceAll(_ sets: [AmbientSet]) throws {
        var hold = catalog.manualHold
        if case .set(let heldID) = hold?.intent, !sets.contains(where: { $0.id == heldID }) { hold = nil }
        let next = AmbientSetCatalog(sets: sets, manualHold: hold)
        try Self.validate(next.sets, manualHold: next.manualHold)
        try persist(next)
    }

    func setManualHold(_ hold: AmbientManualHold?) throws {
        let next = AmbientSetCatalog(sets: catalog.sets, manualHold: hold)
        try Self.validate(next.sets, manualHold: next.manualHold)
        try persist(next)
    }

    func append(_ set: AmbientSet) throws {
        var updated = catalog.sets
        updated.append(set)
        try replaceAll(updated)
    }

    func remove(id: String) throws {
        var hold = catalog.manualHold
        if case .set(let heldID) = hold?.intent, heldID == id { hold = nil }
        let next = AmbientSetCatalog(sets: catalog.sets.filter { $0.id != id }, manualHold: hold)
        try Self.validate(next.sets, manualHold: next.manualHold)
        try persist(next)
    }

    func move(id: String, to index: Int) throws {
        guard let current = catalog.sets.firstIndex(where: { $0.id == id }) else { return }
        var updated = catalog.sets
        let item = updated.remove(at: current)
        updated.insert(item, at: min(max(0, index), updated.count))
        try replaceAll(updated)
    }

    private func persist(_ next: AmbientSetCatalog) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= Self.maxCatalogBytes else { throw AmbientSetStoreError.catalogTooLarge }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        catalog = next
    }

    static func validate(_ sets: [AmbientSet], manualHold: AmbientManualHold? = nil) throws {
        guard sets.count <= maxSets else { throw AmbientSetStoreError.tooManySets }
        var ids = Set<String>()
        for set in sets {
            guard set.isValid else { throw AmbientSetStoreError.invalidSet(set.id) }
            guard ids.insert(set.id).inserted else { throw AmbientSetStoreError.duplicateID(set.id) }
        }
        if let manualHold {
            guard manualHold.isValid else { throw AmbientSetStoreError.invalidManualHold }
            if case .set(let heldID) = manualHold.intent, !ids.contains(heldID) {
                throw AmbientSetStoreError.invalidManualHold
            }
        }
    }
}
