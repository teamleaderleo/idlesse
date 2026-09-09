import Foundation

/// A small index of references. Original media stays where the user put it.
final class SceneLibraryStore {
    struct Entry: Codable, Equatable {
        var id: String
        var title: String
        var bookmark: Data
    }
    struct Catalog: Codable {
        var entries: [Entry] = []
        var favorites: Set<String> = []
        var recent: [String: Date] = [:]
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
        catalog = decoded
    }

    func resolve(_ entry: Entry) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: entry.bookmark, options: [.withSecurityScope, .withoutUI],
                       relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    @discardableResult func add(_ url: URL) throws -> Entry {
        if let existing = catalog.entries.first(where: { (try? resolve($0).standardizedFileURL) == url.standardizedFileURL }) {
            return existing
        }
        guard catalog.entries.count < Self.maxEntries else { throw failure("The Library supports up to 128 imported scenes. Remove an entry before adding another.") }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        guard bookmark.count <= 16_384 else { throw failure("That file's access reference is too large.") }
        let entry = Entry(id: UUID().uuidString, title: String(url.deletingPathExtension().lastPathComponent.prefix(200)), bookmark: bookmark)
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
        try save(next)
    }
    private func save(_ next: Catalog) throws {
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
