import Foundation

/// A small index of references. Original media stays where the user put it.
final class SceneLibraryStore {
    struct Entry: Codable, Equatable {
        var id: String
        var title: String
        var bookmark: Data
    }
    struct Playback: Codable, Equatable {
        var minutes: Int = 30
        var shuffle: Bool = false
        var startMinute: Int?
        var endMinute: Int?
        // Calendar weekday numbers; nil preserves legacy daily schedules.
        var weekdays: Set<Int>?
        func contains(_ minute: Int, weekday: Int = 1) -> Bool {
            guard let start = startMinute, let end = endMinute else { return false }
            let owner = start > end && minute < end ? (weekday == 1 ? 7 : weekday - 1) : weekday
            guard weekdays?.contains(owner) ?? true else { return false }
            return start < end ? minute >= start && minute < end : minute >= start || minute < end
        }
    }
    struct Collection: Codable, Equatable {
        var id: String = UUID().uuidString
        var name: String
        var sceneIDs: [String] = []
        var playback: Playback?
    }
    struct Catalog: Codable {
        var entries: [Entry] = []
        var favorites: Set<String> = []
        var recent: [String: Date] = [:]
        var collections: [Collection] = []
        init() {}
        enum CodingKeys: String, CodingKey { case entries, favorites, recent, collections }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            entries = try values.decode([Entry].self, forKey: .entries)
            favorites = try values.decode(Set<String>.self, forKey: .favorites)
            recent = try values.decode([String: Date].self, forKey: .recent)
            collections = try values.decodeIfPresent([Collection].self, forKey: .collections) ?? []
        }
    }
    private(set) var catalog = Catalog()
    let file: URL
    static let maxEntries = 128

    init(file: URL) throws {
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_048_576 else { throw failure("The Library index is too large.") }
        let decoded = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: file))
        guard decoded.entries.count <= Self.maxEntries,
              decoded.favorites.count <= 256, decoded.recent.count <= 256,
              Set(decoded.entries.map(\.id)).count == decoded.entries.count,
              decoded.entries.allSatisfy({ $0.bookmark.count <= 16_384 && $0.title.utf8.count <= 1024 })
        else { throw failure("The Library index exceeds its limits.") }
        try validateCollections(decoded)
        catalog = decoded
    }

    func resolve(_ entry: Entry) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: entry.bookmark, options: [.withSecurityScope, .withoutUI],
                       relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    @discardableResult func add(_ url: URL, title: String? = nil) throws -> Entry {
        if let existing = catalog.entries.first(where: { (try? resolve($0).standardizedFileURL) == url.standardizedFileURL }) {
            return existing
        }
        guard catalog.entries.count < Self.maxEntries else { throw failure("The Library supports up to 128 imported scenes. Remove an entry before adding another.") }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        guard bookmark.count <= 16_384 else { throw failure("That file's access reference is too large.") }
        let entry = Entry(id: UUID().uuidString, title: String((title ?? url.deletingPathExtension().lastPathComponent).prefix(200)), bookmark: bookmark)
        var next = catalog
        next.entries.append(entry)
        try save(next)
        return entry
    }

    func favorite(_ id: String) throws {
        var next = catalog
        if !next.favorites.insert(id).inserted { next.favorites.remove(id) }
        try save(next)
    }
    func used(_ id: String) throws {
        var next = catalog
        next.recent[id] = Date()
        try save(next)
    }
    func remove(_ id: String) throws {
        var next = catalog
        next.entries.removeAll { $0.id == id }
        next.favorites.remove(id)
        next.recent.removeValue(forKey: id)
        for i in next.collections.indices { next.collections[i].sceneIDs.removeAll { $0 == id } }
        try save(next)
    }
    @discardableResult func createCollection(name: String) throws -> Collection {
        let collection = Collection(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        var next = catalog
        next.collections.append(collection)
        try save(next)
        return collection
    }
    func renameCollection(_ id: String, name: String) throws {
        var next = catalog
        guard let index = next.collections.firstIndex(where: { $0.id == id }) else { throw failure("Collection no longer exists.") }
        next.collections[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try save(next)
    }
    func removeCollection(_ id: String) throws {
        var next = catalog
        next.collections.removeAll { $0.id == id }
        try save(next)
    }
    func toggleMembership(sceneID: String, collectionID: String) throws {
        var next = catalog
        guard let index = next.collections.firstIndex(where: { $0.id == collectionID }) else { throw failure("Collection no longer exists.") }
        if next.collections[index].sceneIDs.contains(sceneID) {
            next.collections[index].sceneIDs.removeAll { $0 == sceneID }
        } else { next.collections[index].sceneIDs.append(sceneID) }
        try save(next)
    }
    func moveCollection(_ id: String, by offset: Int) throws {
        var next = catalog
        guard let index = next.collections.firstIndex(where: { $0.id == id }),
              [-1, 1].contains(offset) else { throw failure("Select a collection.") }
        let destination = index + offset
        guard next.collections.indices.contains(destination) else { return }
        next.collections.swapAt(index, destination)
        try save(next)
    }
    func moveScene(_ sceneID: String, in collectionID: String, by offset: Int) throws {
        var next = catalog
        guard let collection = next.collections.firstIndex(where: { $0.id == collectionID }),
              let index = next.collections[collection].sceneIDs.firstIndex(of: sceneID),
              [-1, 1].contains(offset) else { throw failure("Select a scene in a collection.") }
        let destination = index + offset
        guard next.collections[collection].sceneIDs.indices.contains(destination) else { return }
        next.collections[collection].sceneIDs.swapAt(index, destination)
        try save(next)
    }
    func setPlayback(_ id: String, _ playback: Playback) throws {
        var next = catalog
        guard let index = next.collections.firstIndex(where: { $0.id == id }) else { throw failure("Collection no longer exists.") }
        next.collections[index].playback = playback
        try save(next)
    }
    /// Daily local-time ranges; overlaps are rejected instead of using hidden priority.
    func scheduledCollection(at date: Date, calendar: Calendar = .current) -> Collection? {
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return catalog.collections.first { $0.playback?.contains(minute, weekday: parts.weekday ?? 1) == true }
    }
    private func validateCollections(_ value: Catalog) throws {
        for collection in value.collections {
            guard let settings = collection.playback else { continue }
            guard settings.weekdays.map({ !$0.isEmpty && $0.isSubset(of: Set(1...7)) }) ?? true
            else { throw failure("Choose at least one valid schedule day.") }
            guard [5, 15, 30, 60].contains(settings.minutes),
                  (settings.startMinute == nil && settings.endMinute == nil) ||
                  (settings.startMinute != nil && settings.endMinute != nil &&
                   (0..<1440).contains(settings.startMinute!) && (0..<1440).contains(settings.endMinute!) &&
                   settings.startMinute != settings.endMinute)
            else { throw failure("Choose a supported interval and two different daily times.") }
        }
        for slot in 0..<(7 * 1440) {
            let minute = slot % 1440, weekday = slot / 1440 + 1
            guard value.collections.filter({ $0.playback?.contains(minute, weekday: weekday) == true }).count <= 1
            else { throw failure("Collection schedules cannot overlap on the same day. Adjust the other collection first.") }
        }
        guard value.collections.count <= 32,
              Set(value.collections.map(\.id)).count == value.collections.count,
              Set(value.collections.map { $0.name.lowercased() }).count == value.collections.count,
              value.collections.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.utf8.count <= 120 && $0.id.utf8.count <= 128 && $0.sceneIDs.count <= 256 && Set($0.sceneIDs).count == $0.sceneIDs.count && $0.sceneIDs.allSatisfy { $0.utf8.count <= 128 } })
        else { throw failure("Use unique collection names (1–120 bytes), with at most 32 collections and 256 scenes each.") }
    }
    private func save(_ next: Catalog) throws {
        try validateCollections(next)
        let data = try JSONEncoder().encode(next)
        guard data.count <= 1_048_576, next.favorites.count <= 256, next.recent.count <= 256 else {
            throw failure("The Library index is full.")
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        catalog = next
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "IdlesseLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

/// Session-only rotation. A shuffle bag exhausts every member before repeating.
struct SceneRotationQueue {
    private var remaining: [String] = []
    private var members: [String] = []
    private var last: String?
    mutating func next(_ ids: [String], shuffle: Bool) -> String? {
        if ids != members { members = ids; remaining = [] }
        guard !ids.isEmpty else { return nil }
        if remaining.isEmpty {
            remaining = shuffle ? ids.shuffled() : ids
            if shuffle, remaining.count > 1, remaining.first == last {
                remaining.swapAt(0, 1)
            }
        }
        let result = remaining.removeFirst()
        last = result
        return result
    }
}
