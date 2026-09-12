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
        try Self.validate(sets, manualHold: hold)
        catalog.sets = sets
        catalog.manualHold = hold
        try persist()
    }

    func setManualHold(_ hold: AmbientManualHold?) throws {
        try Self.validate(catalog.sets, manualHold: hold)
        catalog.manualHold = hold
        try persist()
    }

    func append(_ set: AmbientSet) throws {
        var updated = catalog.sets
        updated.append(set)
        try replaceAll(updated)
    }

    func remove(id: String) throws {
        var hold = catalog.manualHold
        if case .set(let heldID) = hold?.intent, heldID == id { hold = nil }
        let updated = catalog.sets.filter { $0.id != id }
        try Self.validate(updated, manualHold: hold)
        catalog.sets = updated
        catalog.manualHold = hold
        try persist()
    }

    func move(id: String, to index: Int) throws {
        guard let current = catalog.sets.firstIndex(where: { $0.id == id }) else { return }
        var updated = catalog.sets
        let item = updated.remove(at: current)
        updated.insert(item, at: min(max(0, index), updated.count))
        try replaceAll(updated)
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(catalog)
        guard data.count <= Self.maxCatalogBytes else { throw AmbientSetStoreError.catalogTooLarge }
        try data.write(to: fileURL, options: .atomic)
    }

    static func validate(_ sets: [AmbientSet], manualHold: AmbientManualHold? = nil) throws {
        guard sets.count <= maxSets else { throw AmbientSetStoreError.tooManySets }
        var ids = Set<String>()
        for set in sets {
            guard set.isValid else { throw AmbientSetStoreError.invalidSet(set.id) }
            guard ids.insert(set.id).inserted else { throw AmbientSetStoreError.duplicateID(set.id) }
        }
        if let manualHold, !manualHold.isValid { throw AmbientSetStoreError.invalidManualHold }
    }
}
