import Foundation

@main
struct LibraryReconciliationChecks {
    static func main() throws {
        try additionsMissingAndStateSurvival()
        try catalogMoveAndReplacement()
        try digestAndProbableMoveRules()
        try packageProbableMovePreservesStableID()
        try ambiguityStaysUnresolved()
        try identityConflictsNeverFallThrough()
        try largeCatalogPureDiff()
        try cancellationLeavesBytesUntouched()
        try staleReviewLeavesCurrentCatalogUntouched()
        try diskStaleReviewRejectsConcurrentSourceMutation()
        try unrelatedConcurrentStateSurvivesApply()
        try relinkAndReconcileStaySeparate()
        try digestBudgetSkipsLargeFiles()
        try digestSkipsEscapingSymlink()
        print("Library reconciliation checks passed: additions, missing tombstones, moves, replacements, digest/probable matching, package move identity, ambiguity, identity conflicts, 4k pure diff, cancellation, in-memory and disk stale-review atomicity, concurrent state survival, relink separation, bounded hashing and symlink containment")
    }

    private static func entry(_ id: String, path: String, catalogID: String? = nil,
                              title: String? = nil, bytes: Int64? = nil,
                              digest: String? = nil, availability: SceneLibraryStore.EntryAvailability = .present) -> SceneLibraryStore.Entry {
        let observation = bytes == nil && digest == nil ? nil : SceneLibraryStore.ReconciliationObservation(
            byteLength: bytes, digestAlgorithm: digest == nil ? nil : "sha256", digest: digest)
        return .init(id: id, title: title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                     catalogID: catalogID, sourceID: "source", relativeMediaPath: path,
                     mediaType: "video", availability: availability, observation: observation)
    }

    private static func draft(_ path: String, catalogID: String? = nil,
                              title: String? = nil, bytes: Int64? = nil,
                              digest: String? = nil) -> SceneLibraryStore.SourceEntry {
        let observation = bytes == nil && digest == nil ? nil : SceneLibraryStore.ReconciliationObservation(
            byteLength: bytes, digestAlgorithm: digest == nil ? nil : "sha256", digest: digest)
        return .init(relativeMediaPath: path, title: title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                     catalogID: catalogID, mediaType: "video", observation: observation)
    }

    private static func seedStore(entries: [SceneLibraryStore.Entry]) throws -> (SceneLibraryStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-reconcile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("index.json")
        var catalog = SceneLibraryStore.Catalog()
        catalog.sources = [.init(id: "source", name: "Source", bookmark: Data([1, 2, 3]))]
        catalog.entries = entries
        let ids = entries.map(\.id)
        catalog.favorites = Set(ids.prefix(1))
        if let last = ids.last { catalog.recent[last] = Date(timeIntervalSince1970: 1234) }
        if !ids.isEmpty { catalog.collections = [.init(id: "collection", name: "Keep order", sceneIDs: ids, playback: nil)] }
        try JSONEncoder().encode(catalog).write(to: file, options: .atomic)
        return (try SceneLibraryStore(file: file), dir)
    }

    private static func additionsMissingAndStateSurvival() throws {
        let a = entry("a", path: "A.mp4", bytes: 10)
        let b = entry("b", path: "B.mp4", bytes: 20)
        let (store, dir) = try seedStore(entries: [a, b])
        defer { try? FileManager.default.removeItem(at: dir) }
        let diff = try store.prepareReconciliation(sourceID: "source", scanned: [draft("A.mp4", bytes: 10), draft("C.mp4", bytes: 30)])
        precondition(diff.summary.unchanged == 1)
        precondition(diff.summary.added == 1 && diff.summary.missing == 1)
        try store.applyReconciliation(diff)
        let keptA = store.catalog.entries.first { $0.id == "a" }!
        let keptB = store.catalog.entries.first { $0.id == "b" }!
        let added = store.catalog.entries.first { $0.relativeMediaPath == "C.mp4" }!
        precondition(keptA.availability == .present)
        precondition(keptB.availability == .missing)
        precondition(added.id != "a" && added.id != "b")
        precondition(store.catalog.favorites.contains("a"))
        precondition(store.catalog.recent["b"] != nil)
        precondition(store.catalog.collections[0].sceneIDs == ["a", "b"])
    }

    private static func catalogMoveAndReplacement() throws {
        let moved = entry("move-id", path: "old/Movie.mp4", catalogID: "catalog-7", bytes: 100)
        var diff = try SceneLibraryStore.reconciliationDiff(sourceID: "source", existing: [moved],
            scanned: [draft("new/Movie.mp4", catalogID: "catalog-7", bytes: 100)])
        precondition(diff.matches.count == 1 && diff.matches[0].entryID == "move-id")
        precondition(diff.matches[0].kind == .moved)

        let replacement = entry("old-id", path: "same.mp4", catalogID: "old-catalog", bytes: 5)
        diff = try SceneLibraryStore.reconciliationDiff(sourceID: "source", existing: [replacement],
            scanned: [draft("same.mp4", catalogID: "new-catalog", bytes: 5)])
        precondition(diff.matches.isEmpty)
        precondition(diff.missingEntryIDs == ["old-id"])
        precondition(diff.addedScannedIndices == [0])
    }

    private static func digestAndProbableMoveRules() throws {
        let digest = String(repeating: "ab", count: 32)
        let oldDigest = entry("digest-id", path: "gone.mp4", title: "Renamed", bytes: 123, digest: digest)
        var diff = try SceneLibraryStore.reconciliationDiff(sourceID: "source", existing: [oldDigest],
            scanned: [draft("elsewhere.mp4", title: "Different", bytes: 123, digest: digest)])
        precondition(diff.matches.count == 1 && diff.matches[0].entryID == "digest-id")
        precondition(diff.matches[0].kind == .moved)

        let probable = entry("probable-id", path: "old/Clip.mp4", title: "Clip", bytes: 777)
        diff = try SceneLibraryStore.reconciliationDiff(sourceID: "source", existing: [probable],
            scanned: [draft("new/Clip.mp4", title: "Clip", bytes: 777)])
        precondition(diff.matches.isEmpty)
        precondition(diff.probableMoves.count == 1)
        let (store, dir) = try seedStore(entries: [probable])
        defer { try? FileManager.default.removeItem(at: dir) }
        let review = try store.prepareReconciliation(sourceID: "source", scanned: [draft("new/Clip.mp4", title: "Clip", bytes: 777)])
        let accepted = review.acceptedMoveKeys(review.probableMoves)
        try store.applyReconciliation(review, accepting: accepted)
        let retained = store.catalog.entries.first { $0.id == "probable-id" }!
        precondition(retained.relativeMediaPath == "new/Clip.mp4" && retained.availability == .present)
    }

    private static func packageProbableMovePreservesStableID() throws {
        let revision = "manifest.json:91:1234000|scene.json:512:1234000"
        let observation = SceneLibraryStore.ReconciliationObservation(packageRevision: revision)
        let old = SceneLibraryStore.Entry(
            id: "package-id", title: "Aurora", sourceID: "source",
            relativeMediaPath: "old/Aurora.idlesse", mediaType: "scene",
            availability: .present, observation: observation)
        let incoming = SceneLibraryStore.SourceEntry(
            relativeMediaPath: "new/Aurora.idlesse", title: "Aurora",
            mediaType: "scene", observation: observation)

        let pure = try SceneLibraryStore.reconciliationDiff(sourceID: "source", existing: [old], scanned: [incoming])
        precondition(pure.matches.isEmpty)
        precondition(pure.probableMoves.count == 1)
        precondition(pure.probableMoves[0].evidence.contains("same package revision"))

        let (store, dir) = try seedStore(entries: [old])
        defer { try? FileManager.default.removeItem(at: dir) }
        let review = try store.prepareReconciliation(sourceID: "source", scanned: [incoming])
        let accepted = review.acceptedMoveKeys(review.probableMoves)
        try store.applyReconciliation(review, accepting: accepted)
        let retained = store.catalog.entries.first { $0.id == "package-id" }!
        precondition(retained.relativeMediaPath == "new/Aurora.idlesse")
        precondition(retained.availability == .present)
        precondition(store.catalog.favorites.contains("package-id"))
        precondition(store.catalog.collections[0].sceneIDs == ["package-id"])
    }

    private static func ambiguityStaysUnresolved() throws {
        let old = [
            entry("one", path: "old/one.mp4", title: "Same", bytes: 900),
            entry("two", path: "old/two.mp4", title: "Same", bytes: 900)
        ]
        let incoming = [
            draft("new/one.mp4", title: "Same", bytes: 900),
            draft("new/two.mp4", title: "Same", bytes: 900)
        ]
        var diff = try SceneLibraryStore.reconciliationDiff(sourceID: "source", existing: old, scanned: incoming)
        precondition(diff.matches.isEmpty)
        precondition(diff.probableMoves.isEmpty)
        precondition(diff.missingEntryIDs.count == 2 && diff.addedScannedIndices.count == 2)

        let duplicatePath = [
            entry("path-one", path: "duplicate.mp4", title: "One", bytes: 10),
            entry("path-two", path: "duplicate.mp4", title: "Two", bytes: 20)
        ]
        diff = try SceneLibraryStore.reconciliationDiff(sourceID: "source", existing: duplicatePath,
            scanned: [draft("duplicate.mp4", title: "Replacement", bytes: 30)])
        precondition(diff.matches.isEmpty, "Duplicate old paths must never pick one entry implicitly")
        precondition(diff.missingEntryIDs.count == 2 && diff.addedScannedIndices == [0])
    }

    private static func identityConflictsNeverFallThrough() throws {
        let digest = String(repeating: "cd", count: 32)
        let old = entry("old", path: "old.mp4", catalogID: "catalog-old", title: "Clip", bytes: 444, digest: digest)
        let incoming = draft("new.mp4", catalogID: "catalog-new", title: "Clip", bytes: 444, digest: digest)
        let diff = try SceneLibraryStore.reconciliationDiff(sourceID: "source", existing: [old], scanned: [incoming])
        precondition(diff.matches.isEmpty, "Conflicting Source catalog IDs must outrank digest evidence")
        precondition(diff.probableMoves.isEmpty, "Conflicting Source catalog IDs must not become probable relinks")
        precondition(diff.missingEntryIDs == ["old"] && diff.addedScannedIndices == [0])
    }

    private static func largeCatalogPureDiff() throws {
        let count = SceneLibraryStore.maxSourceEntries
        let existing = (0..<count).map { index in
            entry("entry-\(index)", path: "catalog/\(index).mp4", catalogID: "catalog-\(index)")
        }
        let scanned = (0..<count).map { index in
            draft("catalog/\(index).mp4", catalogID: "catalog-\(index)")
        }
        let diff = try SceneLibraryStore.reconciliationDiff(sourceID: "source", existing: existing, scanned: scanned)
        precondition(diff.matches.count == count)
        precondition(diff.summary.unchanged == count)
        precondition(diff.addedScannedIndices.isEmpty && diff.missingEntryIDs.isEmpty && diff.probableMoves.isEmpty)
    }

    private static func cancellationLeavesBytesUntouched() throws {
        let (store, dir) = try seedStore(entries: [entry("a", path: "A.mp4", bytes: 1)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try Data(contentsOf: store.file)
        _ = try store.prepareReconciliation(sourceID: "source", scanned: [draft("B.mp4", bytes: 2)])
        let after = try Data(contentsOf: store.file)
        precondition(before == after)
    }

    private static func staleReviewLeavesCurrentCatalogUntouched() throws {
        let (store, dir) = try seedStore(entries: [entry("a", path: "A.mp4", bytes: 1)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let stale = try store.prepareReconciliation(sourceID: "source", scanned: [draft("A.mp4", bytes: 1)])
        let newer = try store.prepareReconciliation(sourceID: "source", scanned: [draft("B.mp4", bytes: 2)])
        try store.applyReconciliation(newer)
        let before = try Data(contentsOf: store.file)
        let snapshot = store.catalog
        do {
            try store.applyReconciliation(stale)
            preconditionFailure("A stale reconciliation review was accepted")
        } catch {}
        precondition(store.catalog == snapshot)
        let after = try Data(contentsOf: store.file)
        precondition(after == before)
    }

    private static func diskStaleReviewRejectsConcurrentSourceMutation() throws {
        let (reviewer, dir) = try seedStore(entries: [entry("a", path: "A.mp4", bytes: 1)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let review = try reviewer.prepareReconciliation(sourceID: "source", scanned: [draft("A.mp4", title: "Reviewed A", bytes: 1)])
        let writer = try SceneLibraryStore(file: reviewer.file)
        _ = try writer.addSourceEntries("source", [draft("B.mp4", bytes: 2)])
        let before = try Data(contentsOf: reviewer.file)
        do {
            try reviewer.applyReconciliation(review)
            preconditionFailure("A review prepared before another process changed the Source was accepted")
        } catch {}
        let after = try Data(contentsOf: reviewer.file)
        precondition(after == before, "Rejected stale review rewrote the Library index")
        let disk = try SceneLibraryStore(file: reviewer.file)
        precondition(disk.catalog.entries.contains { $0.relativeMediaPath == "B.mp4" })
        precondition(disk.catalog.entries.first(where: { $0.id == "a" })?.title == "A")
    }

    private static func unrelatedConcurrentStateSurvivesApply() throws {
        let (reviewer, dir) = try seedStore(entries: [entry("a", path: "A.mp4", bytes: 1)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let review = try reviewer.prepareReconciliation(sourceID: "source", scanned: [draft("A.mp4", title: "Reviewed A", bytes: 1)])
        let writer = try SceneLibraryStore(file: reviewer.file)
        try writer.favorite("a") // seedStore starts with a favorited; the concurrent writer clears it.
        try writer.used("a")
        let concurrent = try writer.createCollection(name: "Concurrent Picks")
        try writer.toggleMembership(sceneID: "a", collectionID: concurrent.id)

        try reviewer.applyReconciliation(review)
        let disk = try SceneLibraryStore(file: reviewer.file)
        precondition(disk.catalog.entries.first(where: { $0.id == "a" })?.title == "Reviewed A")
        precondition(!disk.catalog.favorites.contains("a"), "Reconciliation erased a concurrent favorite change")
        precondition((disk.catalog.recent["a"] ?? .distantPast) > Date(timeIntervalSince1970: 1234),
                     "Reconciliation erased a concurrent recent update")
        precondition(disk.catalog.collections.first(where: { $0.id == concurrent.id })?.sceneIDs == ["a"],
                     "Reconciliation erased a concurrent collection mutation")
    }

    private static func relinkAndReconcileStaySeparate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-relink-\(UUID().uuidString)")
        let oldRoot = dir.appendingPathComponent("old")
        let newRoot = dir.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("index.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let owner = try SceneLibraryStore(file: file)
        let source = try owner.addSource(oldRoot, entries: [.init(relativeMediaPath: "A.mp4", title: "A", mediaType: "video")])
        let entryID = owner.catalog.entries.first!.id
        let beforePath = owner.catalog.entries.first!.relativeMediaPath

        let reviewer = try SceneLibraryStore(file: file)
        let preRelinkReview = try reviewer.prepareReconciliation(sourceID: source.id,
            scanned: [.init(relativeMediaPath: "A.mp4", title: "A", mediaType: "video")])
        let relinker = try SceneLibraryStore(file: file)
        try relinker.relinkSource(source.id, to: newRoot)
        precondition(relinker.catalog.entries.first!.id == entryID)
        precondition(relinker.catalog.entries.first!.relativeMediaPath == beforePath)
        precondition(relinker.catalog.entries.first!.availability == .present)

        let afterRelink = try Data(contentsOf: file)
        do {
            try reviewer.applyReconciliation(preRelinkReview)
            preconditionFailure("A review prepared before Relink was accepted")
        } catch {}
        let afterRejectedReview = try Data(contentsOf: file)
        precondition(afterRejectedReview == afterRelink, "Stale post-Relink review rewrote the catalog")

        let fresh = try SceneLibraryStore(file: file)
        let diff = try fresh.prepareReconciliation(sourceID: source.id, scanned: [])
        precondition(diff.missingEntryIDs == [entryID])
        precondition(fresh.catalog.entries.first!.availability == .present)
    }

    private static func digestBudgetSkipsLargeFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-digest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 7, count: 16).write(to: dir.appendingPathComponent("small.bin"))
        try Data(repeating: 8, count: 64).write(to: dir.appendingPathComponent("large.bin"))
        let drafts = [draft("small.bin"), draft("large.bin")]
        let observations = try SceneLibraryStore.boundedDigests(root: dir, drafts: drafts, indices: [0, 1],
            budget: .init(maximumFiles: 2, maximumTotalBytes: 32, maximumFileBytes: 32))
        precondition(observations[0]?.hasDigest == true)
        precondition(observations[1] == nil)
    }

    private static func digestSkipsEscapingSymlink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-digest-link-\(UUID().uuidString)")
        let root = dir.appendingPathComponent("source")
        let outside = dir.appendingPathComponent("outside.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 9, count: 16).write(to: outside)
        let link = root.appendingPathComponent("escape.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let observations = try SceneLibraryStore.boundedDigests(root: root, drafts: [draft("escape.bin")], indices: [0],
            budget: .init(maximumFiles: 1, maximumTotalBytes: 32, maximumFileBytes: 32))
        precondition(observations.isEmpty, "Digest reconciliation followed a symlink outside the Source root")
    }
}
