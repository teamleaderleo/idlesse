import Foundation

@main struct LibraryTests {
    static func main() throws {
        var ordered = SceneRotationQueue()
        precondition((0..<7).compactMap { _ in ordered.next(["a", "b", "c"], shuffle: false) } == ["a", "b", "c", "a", "b", "c", "a"])
        var shuffled = SceneRotationQueue()
        var previous: String?
        for _ in 0..<100 {
            let cycle = (0..<3).compactMap { _ in shuffled.next(["a", "b", "c"], shuffle: true) }
            precondition(Set(cycle) == Set(["a", "b", "c"]))
            precondition(cycle.first != previous)
            previous = cycle.last
        }
        precondition(shuffled.next([], shuffle: true) == nil)
        precondition(shuffled.next(["only"], shuffle: true) == "only")
        precondition(shuffled.next(["only"], shuffle: true) == "only")
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
        try store.setPlayback(collection.id, .init(minutes: 15, shuffle: true, startMinute: 1320, endMinute: 420))
        let other = try store.createCollection(name: "Day")
        do {
            try store.setPlayback(other.id, .init(startMinute: 400, endMinute: 600))
            fatalError("Overlapping schedule accepted")
        } catch {}
        try store.setPlayback(other.id, .init(startMinute: 420, endMinute: 1320))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        let base = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9))!
        for minute in 0..<1440 {
            let date = calendar.date(byAdding: .minute, value: minute, to: base)!
            let expected = minute < 420 || minute >= 1320 ? collection.id : other.id
            precondition(store.scheduledCollection(at: date, calendar: calendar)?.id == expected)
        }
        do { try store.setPlayback(other.id, .init(startMinute: 0, endMinute: 0)); fatalError("Empty range accepted") } catch {}
        do { try store.setPlayback(other.id, .init(minutes: 1)); fatalError("Invalid interval accepted") } catch {}
        try store.removeCollection(other.id)
        try store.setPlayback(collection.id, .init(startMinute: 1320, endMinute: 420, weekdays: [6]))
        let friday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 23))!
        let saturday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 6))!
        precondition(store.scheduledCollection(at: friday, calendar: calendar)?.id == collection.id)
        precondition(store.scheduledCollection(at: saturday, calendar: calendar)?.id == collection.id)
        precondition(store.scheduledCollection(at: saturday.addingTimeInterval(3600), calendar: calendar) == nil)
        precondition(store.scheduledCollection(at: friday.addingTimeInterval(86400), calendar: calendar) == nil)
        let weekend = try store.createCollection(name: "Weekend")
        do {
            try store.setPlayback(weekend.id, .init(startMinute: 360, endMinute: 480, weekdays: [7]))
            fatalError("Overnight spill overlap accepted")
        } catch {}
        try store.setPlayback(weekend.id, .init(startMinute: 1320, endMinute: 420, weekdays: [7]))
        do { try store.setPlayback(weekend.id, .init(weekdays: [])); fatalError("Empty days accepted") } catch {}
        do { try store.setPlayback(weekend.id, .init(weekdays: [8])); fatalError("Invalid day accepted") } catch {}
        try store.moveCollection(weekend.id, by: -1)
        let collectionOrder = try SceneLibraryStore(file: file)
        precondition(collectionOrder.catalog.collections.first?.id == weekend.id)
        try store.moveCollection(weekend.id, by: 1)
        try store.removeCollection(weekend.id)
        try store.moveScene("builtin.Undertow", in: collection.id, by: -1)
        let reorderedStore = try SceneLibraryStore(file: file)
        precondition(reorderedStore.catalog.collections.first?.sceneIDs == ["builtin.Undertow", entry.id])
        try store.moveScene("builtin.Undertow", in: collection.id, by: -1)
        try store.moveScene("builtin.Undertow", in: collection.id, by: 1)
        try store.setPlayback(collection.id, .init(minutes: 15, shuffle: true, startMinute: 1320, endMinute: 420))
        let reopened = try SceneLibraryStore(file: file)
        precondition(reopened.catalog.collections.first?.playback?.minutes == 15)
        precondition(reopened.catalog.collections.first?.playback?.shuffle == true)
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
