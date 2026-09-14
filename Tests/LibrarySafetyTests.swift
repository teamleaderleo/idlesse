import Foundation

@main struct LibrarySafetyTests {
    static func expectFailure(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError(message) } catch {}
    }

    static func folder(_ root: URL, _ name: String) throws -> URL {
        let result = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    static func media(_ directory: URL, _ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    static func waitForFiles(_ urls: [URL], timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
            if Date() >= deadline { throw SceneLibraryStore.libraryFailure("Timed out waiting for Library concurrency workers.") }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    static func workerAdd(arguments: [String]) throws {
        precondition(arguments.count == 6)
        let index = URL(fileURLWithPath: arguments[2])
        let media = URL(fileURLWithPath: arguments[3])
        let ready = URL(fileURLWithPath: arguments[4])
        let go = URL(fileURLWithPath: arguments[5])
        let store = try SceneLibraryStore(file: index)
        FileManager.default.createFile(atPath: ready.path, contents: Data())
        while !FileManager.default.fileExists(atPath: go.path) { Thread.sleep(forTimeInterval: 0.001) }
        _ = try store.add(media)
    }

    static func launchAddWorker(index: URL, media: URL, ready: URL, go: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--worker-add", index.path, media.path, ready.path, go.path]
        try process.run()
        return process
    }

    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "--worker-add" {
            try workerAdd(arguments: CommandLine.arguments)
            return
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-library-safety-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Real processes: both load the same empty index, wait at a barrier, then add
        // different entries. The exclusive lock + rebase must retain both commits.
        do {
            let dir = try folder(root, "cross-process-add")
            let index = dir.appendingPathComponent("index.json")
            let first = try media(dir, "first.png", [1, 2, 3])
            let second = try media(dir, "second.png", [4, 5, 6])
            let readyA = dir.appendingPathComponent("ready-a")
            let readyB = dir.appendingPathComponent("ready-b")
            let go = dir.appendingPathComponent("go")
            let a = try launchAddWorker(index: index, media: first, ready: readyA, go: go)
            let b = try launchAddWorker(index: index, media: second, ready: readyB, go: go)
            defer { if a.isRunning { a.terminate() }; if b.isRunning { b.terminate() } }
            try waitForFiles([readyA, readyB])
            try Data().write(to: go)
            a.waitUntilExit(); b.waitUntilExit()
            precondition(a.terminationStatus == 0 && b.terminationStatus == 0, "Library concurrency worker failed")
            let final = try SceneLibraryStore(file: index).catalog
            precondition(final.entries.count == 2, "Two stale process additions clobbered one another")
            precondition(try Data(contentsOf: first) == Data([1, 2, 3]))
            precondition(try Data(contentsOf: second) == Data([4, 5, 6]))
        }

        // A stale writer can update unrelated state after a removal without bringing
        // the removed entry back. Recovery preserves favorite/recent/collection state.
        do {
            let dir = try folder(root, "stale-vs-removal")
            let index = dir.appendingPathComponent("index.json")
            let url = try media(dir, "victim.png", [7, 8, 9])
            let seed = try SceneLibraryStore(file: index)
            let victim = try seed.add(url, title: "Victim")
            try seed.favorite(victim.id)
            try seed.used(victim.id)
            let collection = try seed.createCollection(name: "Keep State")
            try seed.toggleMembership(sceneID: victim.id, collectionID: collection.id)
            let remover = try SceneLibraryStore(file: index)
            let stale = try SceneLibraryStore(file: index)
            try remover.remove(victim.id)
            try stale.used(victim.id)
            let after = try SceneLibraryStore(file: index)
            precondition(!after.catalog.entries.contains { $0.id == victim.id }, "A stale writer resurrected a removed entry")
            precondition(!after.catalog.favorites.contains(victim.id) && after.catalog.recent[victim.id] == nil)
            precondition(after.catalog.collections.first(where: { $0.id == collection.id })?.sceneIDs.contains(victim.id) == false)
            precondition(after.recentlyRemoved().contains { $0.entry.id == victim.id })
            let restored = try after.restoreRemoved(victim.id)
            precondition(restored.id == victim.id)
            precondition(after.catalog.favorites.contains(victim.id) && after.catalog.recent[victim.id] != nil)
            precondition(after.catalog.collections.first(where: { $0.id == collection.id })?.sceneIDs.contains(victim.id) == true)
            precondition(try Data(contentsOf: url) == Data([7, 8, 9]), "Library recovery modified original media")
        }

        // Favorites, recents, and collection fields merge independently.
        do {
            let dir = try folder(root, "state-merge")
            let index = dir.appendingPathComponent("index.json")
            let oneURL = try media(dir, "one.png", [10])
            let twoURL = try media(dir, "two.png", [11])
            let seed = try SceneLibraryStore(file: index)
            let one = try seed.add(oneURL)
            let two = try seed.add(twoURL)
            let collection = try seed.createCollection(name: "Original")

            let favoriteA = try SceneLibraryStore(file: index)
            let favoriteB = try SceneLibraryStore(file: index)
            try favoriteA.favorite(one.id)
            try favoriteB.favorite(two.id)
            var merged = try SceneLibraryStore(file: index).catalog
            precondition(merged.favorites.isSuperset(of: [one.id, two.id]), "Concurrent favorites clobbered one another")

            let recentA = try SceneLibraryStore(file: index)
            let recentB = try SceneLibraryStore(file: index)
            var high = recentA.catalog
            high.recent[one.id] = Date(timeIntervalSince1970: 300)
            try recentA.commitCatalog(high)
            var low = recentB.catalog
            low.recent[one.id] = Date(timeIntervalSince1970: 200)
            low.recent[two.id] = Date(timeIntervalSince1970: 250)
            try recentB.commitCatalog(low)
            merged = try SceneLibraryStore(file: index).catalog
            precondition(merged.recent[one.id] == Date(timeIntervalSince1970: 300), "A stale recent timestamp replaced a newer one")
            precondition(merged.recent[two.id] == Date(timeIntervalSince1970: 250))

            let collectionA = try SceneLibraryStore(file: index)
            let collectionB = try SceneLibraryStore(file: index)
            try collectionA.renameCollection(collection.id, name: "Renamed")
            try collectionB.toggleMembership(sceneID: one.id, collectionID: collection.id)
            let collectionC = try SceneLibraryStore(file: index)
            let collectionD = try SceneLibraryStore(file: index)
            try collectionC.toggleMembership(sceneID: two.id, collectionID: collection.id)
            try collectionD.toggleMembership(sceneID: "builtin.Undertow", collectionID: collection.id)
            merged = try SceneLibraryStore(file: index).catalog
            let finalCollection = merged.collections.first { $0.id == collection.id }!
            precondition(finalCollection.name == "Renamed", "Concurrent membership erased a collection rename")
            precondition(Set(finalCollection.sceneIDs).isSuperset(of: [one.id, two.id, "builtin.Undertow"]),
                         "Concurrent collection memberships clobbered one another")
        }

        // Removing a Source wins over stale edits, journals every dropped entry in
        // the full backup, and keeps enough Source evidence for explicit restoration.
        do {
            let dir = try folder(root, "source-removal")
            let sourceDir = try folder(dir, "Source")
            let firstURL = try media(sourceDir, "first.png", [20, 21])
            _ = try media(sourceDir, "second.png", [22, 23])
            let index = dir.appendingPathComponent("index.json")
            let seed = try SceneLibraryStore(file: index)
            let source = try seed.addSource(sourceDir, name: "Source", entries: [
                .init(relativeMediaPath: "first.png", title: "First"),
                .init(relativeMediaPath: "second.png", title: "Second")
            ])
            let sourceEntries = seed.catalog.entries.filter { $0.sourceID == source.id }
            precondition(sourceEntries.count == 2)
            let restoredID = sourceEntries[0].id
            try seed.favorite(restoredID)
            let collection = try seed.createCollection(name: "Source Picks")
            try seed.toggleMembership(sceneID: restoredID, collectionID: collection.id)

            let remover = try SceneLibraryStore(file: index)
            let stale = try SceneLibraryStore(file: index)
            try remover.removeSource(source.id)
            try stale.used(restoredID)
            let after = try SceneLibraryStore(file: index)
            precondition(!after.catalog.sources.contains { $0.id == source.id })
            precondition(after.catalog.entries.allSatisfy { $0.sourceID != source.id }, "Stale Source entries survived Source removal")
            let removed = after.recentlyRemoved().filter { $0.entry.sourceID == source.id }
            precondition(removed.count == 2 && removed.allSatisfy { $0.source?.id == source.id },
                         "Source removal did not retain Source recovery evidence")
            _ = try after.restoreRemoved(restoredID)
            precondition(after.catalog.sources.contains { $0.id == source.id })
            precondition(after.catalog.entries.contains { $0.id == restoredID && $0.sourceID == source.id })
            precondition(after.catalog.favorites.contains(restoredID))
            precondition(after.catalog.collections.first(where: { $0.id == collection.id })?.sceneIDs.contains(restoredID) == true)
            precondition(try Data(contentsOf: firstURL) == Data([20, 21]), "Source removal or restore modified original media")
        }

        // Corrupt and future-version disk state is protected byte-for-byte from a stale save.
        do {
            let dir = try folder(root, "protected-index")
            let index = dir.appendingPathComponent("index.json")
            let url = try media(dir, "entry.png", [30])
            let writer = try SceneLibraryStore(file: index)
            let entry = try writer.add(url)

            let garbage = Data("not json".utf8)
            try garbage.write(to: index, options: .atomic)
            expectFailure("A stale writer overwrote an unreadable Library index") { try writer.used(entry.id) }
            precondition(try Data(contentsOf: index) == garbage)

            var future = writer.catalog
            future.version = SceneLibraryStore.catalogVersion + 100
            let futureData = try JSONEncoder().encode(future)
            try futureData.write(to: index, options: .atomic)
            expectFailure("A stale writer overwrote a future-version Library index") { try writer.favorite(entry.id) }
            precondition(try Data(contentsOf: index) == futureData)
        }

        // Simulate a process dying after recovery evidence is durable but before the
        // atomic index replacement. The canonical catalog stays intact and the prepared
        // record remains hidden until a removal actually commits.
        do {
            let dir = try folder(root, "interrupted-removal")
            let index = dir.appendingPathComponent("index.json")
            let url = try media(dir, "entry.png", [40])
            let store = try SceneLibraryStore(file: index)
            let entry = try store.add(url)
            let (before, bytes) = try store.readIndex()
            try store.withIndexLock { try store.journalRemoval([entry], previous: before, previousData: bytes) }
            let reopened = try SceneLibraryStore(file: index)
            precondition(reopened.catalog.entries.contains { $0.id == entry.id }, "Prepared recovery changed the canonical index")
            precondition(reopened.recentlyRemoved().isEmpty, "Uncommitted removal appeared in Recently Removed")
            precondition(FileManager.default.fileExists(atPath: reopened.removalLog.path))
            precondition(!(try FileManager.default.contentsOfDirectory(atPath: reopened.backupsFolder.path)).isEmpty)
            try reopened.remove(entry.id)
            precondition(reopened.recentlyRemoved().contains { $0.entry.id == entry.id })
        }

        // Recovery evidence is a prerequisite for a destructive commit. A corrupt
        // recovery ledger blocks the removal and leaves the canonical index unchanged.
        do {
            let dir = try folder(root, "recovery-failure")
            let index = dir.appendingPathComponent("index.json")
            let url = try media(dir, "entry.png", [50])
            let store = try SceneLibraryStore(file: index)
            let entry = try store.add(url)
            try Data("corrupt recovery ledger".utf8).write(to: store.removedFile)
            expectFailure("Removal committed without a readable recovery ledger") { try store.remove(entry.id) }
            precondition(try SceneLibraryStore(file: index).catalog.entries.contains { $0.id == entry.id })
            try FileManager.default.removeItem(at: store.removedFile)
            try store.remove(entry.id)
            precondition(!store.catalog.entries.contains { $0.id == entry.id })
        }

        // Backups stay bounded even across repeated remove/restore cycles.
        do {
            let dir = try folder(root, "bounded-backups")
            let index = dir.appendingPathComponent("index.json")
            let url = try media(dir, "entry.png", [60])
            let store = try SceneLibraryStore(file: index)
            let entry = try store.add(url)
            for _ in 0..<(SceneLibraryStore.keptBackups + 3) {
                try store.remove(entry.id)
                _ = try store.restoreRemoved(entry.id)
            }
            let backups = try FileManager.default.contentsOfDirectory(atPath: store.backupsFolder.path)
                .filter { $0.hasPrefix("index-") && $0.hasSuffix(".json") }
            precondition(backups.count == SceneLibraryStore.keptBackups, "Library backups exceeded their bound")
        }

        // Scratch resolution is deterministic and a smoke write stays away from the
        // pretend production Application Support Library. Explicit overrides still win.
        do {
            let dir = try folder(root, "scratch-isolation")
            let support = try folder(dir, "Application Support")
            let temporary = try folder(dir, "Temporary")
            let production = support.appendingPathComponent("Idlesse/Library/index.json")
            let scratch = SceneLibraryStore.resolvedIndexURL(environment: [:],
                arguments: ["Idlesse", "--smoke-library"], applicationSupport: support,
                temporaryDirectory: temporary, processIdentifier: 4242)
            precondition(scratch != production && scratch.path.hasPrefix(temporary.path), "Smoke Library did not resolve to scratch storage")
            let smokeStore = try SceneLibraryStore(file: scratch)
            _ = try smokeStore.createCollection(name: "Scratch Only")
            precondition(FileManager.default.fileExists(atPath: scratch.path))
            precondition(!FileManager.default.fileExists(atPath: production.path), "Smoke Library mutated the production catalog")

            let override = dir.appendingPathComponent("explicit/index.json")
            let resolvedOverride = SceneLibraryStore.resolvedIndexURL(environment: ["IDLESSE_LIBRARY_INDEX": override.path],
                arguments: ["Idlesse", "--smoke-library"], applicationSupport: support,
                temporaryDirectory: temporary, processIdentifier: 4242)
            precondition(resolvedOverride.standardizedFileURL == override.standardizedFileURL)
        }

        print("Library safety checks passed: cross-process merge, removal dominance, concurrent state, collection deltas, Source recovery, protected indexes, interrupted writes, durable recovery, bounded backups, and scratch isolation")
    }
}
