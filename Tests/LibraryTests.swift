import Foundation

@main struct LibraryTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-library-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let media = folder.appendingPathComponent("Example.png")
        try Data([1, 2, 3]).write(to: media)
        let file = folder.appendingPathComponent("Index/library.json")
        let store = try SceneLibraryStore(file: file)
        let entry = try store.add(media)
        let duplicate = try store.add(media)
        precondition(duplicate == entry)
        try store.favorite(entry.id)
        try store.used(entry.id)
        let collection = try store.createCollection(name: " Chill ")
        try store.toggleMembership(sceneID: entry.id, collectionID: collection.id)
        try store.toggleMembership(sceneID: "builtin.Undertow", collectionID: collection.id)
        do { _ = try store.createCollection(name: "chill"); fatalError("Duplicate collection accepted") } catch {}
        do { _ = try store.createCollection(name: "  "); fatalError("Empty collection accepted") } catch {}
        let reopened = try SceneLibraryStore(file: file)
        precondition(reopened.catalog.collections.first?.sceneIDs == [entry.id, "builtin.Undertow"])
        try reopened.renameCollection(collection.id, name: "Evening")
        precondition(reopened.catalog.entries == [entry])
        precondition(reopened.catalog.favorites.contains(entry.id) && reopened.catalog.recent[entry.id] != nil)
        let resolved = try reopened.resolve(entry)
        precondition(resolved.standardizedFileURL == media.standardizedFileURL)
        try reopened.remove(entry.id)
        precondition(reopened.catalog.collections.first?.sceneIDs == ["builtin.Undertow"])
        try reopened.removeCollection(collection.id)
        precondition(reopened.catalog.collections.isEmpty)
        precondition(reopened.catalog.entries.isEmpty && reopened.catalog.favorites.isEmpty && reopened.catalog.recent.isEmpty)
        let original = try Data(contentsOf: media)
        precondition(original == Data([1, 2, 3]), "Removing a reference must preserve the original")
        try Data(#"{"entries":[],"favorites":[],"recent":{}}"#.utf8).write(to: file)
        let legacy = try SceneLibraryStore(file: file)
        precondition(legacy.catalog.collections.isEmpty, "Old Library indexes must migrate")
        try Data("invalid".utf8).write(to: file)
        do { _ = try SceneLibraryStore(file: file); fatalError("Corrupt index accepted") } catch {}
        let corrupt = try Data(contentsOf: file)
        precondition(corrupt == Data("invalid".utf8), "A bad index must be preserved")
        try Data(repeating: 0, count: 1_048_577).write(to: file)
        do { _ = try SceneLibraryStore(file: file); fatalError("Oversized index accepted") } catch {}
        print("Library checks passed: bookmarks, duplicate references, favorites, recents, removal, corrupt/oversized index preservation")
    }
}
