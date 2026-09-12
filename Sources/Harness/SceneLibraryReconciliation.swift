import Foundation
import CryptoKit

extension SceneLibraryStore {
    enum EntryAvailability: String, Codable, Equatable, Sendable {
        case present
        case missing
    }

    struct ReconciliationObservation: Codable, Equatable, Sendable {
        var byteLength: Int64?
        var modifiedAt: Date?
        var digestAlgorithm: String?
        var digest: String?
        var packageRevision: String?

        init(byteLength: Int64? = nil, modifiedAt: Date? = nil,
             digestAlgorithm: String? = nil, digest: String? = nil,
             packageRevision: String? = nil) {
            self.byteLength = byteLength
            self.modifiedAt = modifiedAt
            self.digestAlgorithm = digestAlgorithm
            self.digest = digest
            self.packageRevision = packageRevision
        }

        var hasDigest: Bool {
            guard let algorithm = digestAlgorithm?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let digest = digest?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return !algorithm.isEmpty && !digest.isEmpty
        }
    }

    struct ReconciliationSummary: Equatable, Sendable {
        var unchanged = 0
        var changed = 0
        var moved = 0
        var restored = 0
        var added = 0
        var missing = 0
        var probableMoves = 0
    }

    enum ReconciliationMatchKind: String, Equatable, Sendable {
        case unchanged
        case changed
        case moved
        case restored
    }

    struct ReconciliationMatch: Equatable, Sendable {
        var entryID: String
        var scannedIndex: Int
        var kind: ReconciliationMatchKind
    }

    struct ProbableMove: Hashable, Sendable {
        var entryID: String
        var scannedIndex: Int
        var fromPath: String
        var toPath: String
        var evidence: String
    }

    struct ReconciliationDiff: Sendable {
        let sourceID: String
        let basisEntries: [Entry]
        let scanned: [SourceEntry]
        let matches: [ReconciliationMatch]
        let missingEntryIDs: [String]
        let addedScannedIndices: [Int]
        let probableMoves: [ProbableMove]
        let summary: ReconciliationSummary

        func acceptedMoveKeys(_ moves: [ProbableMove]) -> Set<String> {
            Set(moves.map { Self.moveKey(entryID: $0.entryID, scannedIndex: $0.scannedIndex) })
        }

        static func moveKey(entryID: String, scannedIndex: Int) -> String {
            "\(entryID)\u{0}\(scannedIndex)"
        }
    }

    struct DigestBudget: Equatable, Sendable {
        var maximumFiles: Int = 32
        var maximumTotalBytes: Int64 = 64 * 1024 * 1024
        var maximumFileBytes: Int64 = 8 * 1024 * 1024

        init(maximumFiles: Int = 32,
             maximumTotalBytes: Int64 = 64 * 1024 * 1024,
             maximumFileBytes: Int64 = 8 * 1024 * 1024) {
            self.maximumFiles = maximumFiles
            self.maximumTotalBytes = maximumTotalBytes
            self.maximumFileBytes = maximumFileBytes
        }
    }

    /// Bounded whole-file SHA-256 for targeted candidates only. Large files are
    /// skipped instead of partially hashing them and treating weak evidence as identity.
    static func boundedDigests(root: URL, drafts: [SourceEntry], indices: [Int],
                               budget: DigestBudget = DigestBudget()) throws -> [Int: ReconciliationObservation] {
        guard budget.maximumFiles > 0, budget.maximumTotalBytes >= 0, budget.maximumFileBytes >= 0 else { return [:] }
        let selected = Array(indices.prefix(budget.maximumFiles))
        var remaining = budget.maximumTotalBytes
        var result: [Int: ReconciliationObservation] = [:]
        for index in selected {
            try Task.checkCancellation()
            guard drafts.indices.contains(index) else { continue }
            let draft = drafts[index]
            let path = try validatedRelativePath(draft.relativeMediaPath)
            let url = root.appendingPathComponent(path).standardizedFileURL
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, let bytes = values.fileSize.map(Int64.init), bytes >= 0,
                  bytes <= budget.maximumFileBytes, bytes <= remaining else { continue }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard Int64(data.count) == bytes else { continue }
            remaining -= bytes
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            var observation = draft.observation ?? ReconciliationObservation()
            observation.byteLength = bytes
            observation.modifiedAt = values.contentModificationDate
            observation.digestAlgorithm = "sha256"
            observation.digest = digest
            result[index] = observation
        }
        return result
    }

    static func reconciliationDiff(sourceID: String, existing: [Entry], scanned: [SourceEntry]) throws -> ReconciliationDiff {
        let old = existing.filter { $0.sourceID == sourceID }
        for draft in scanned { _ = try validatedRelativePath(draft.relativeMediaPath) }

        var unmatchedOld = Set(old.indices)
        var unmatchedNew = Set(scanned.indices)
        var matches: [ReconciliationMatch] = []

        func match(_ oldIndex: Int, _ newIndex: Int) {
            guard unmatchedOld.remove(oldIndex) != nil, unmatchedNew.remove(newIndex) != nil else { return }
            let oldEntry = old[oldIndex]
            let incoming = scanned[newIndex]
            matches.append(ReconciliationMatch(entryID: oldEntry.id, scannedIndex: newIndex,
                                                kind: matchKind(old: oldEntry, incoming: incoming)))
        }

        let oldCatalog = groupedIndices(old.indices, key: { normalizedIdentity(old[$0].catalogID) })
        let newCatalog = groupedIndices(scanned.indices, key: { normalizedIdentity(scanned[$0].catalogID) })
        for key in oldCatalog.keys.sorted() {
            guard let left = oldCatalog[key], left.count == 1,
                  let right = newCatalog[key], right.count == 1 else { continue }
            match(left[0], right[0])
        }

        let oldPaths = groupedIndices(unmatchedOld.sorted(), key: { old[$0].relativeMediaPath })
        let newPaths = groupedIndices(unmatchedNew.sorted(), key: { scanned[$0].relativeMediaPath })
        for path in oldPaths.keys.sorted() {
            guard let left = oldPaths[path], left.count == 1,
                  let right = newPaths[path], right.count == 1,
                  let oldIndex = left.first, let newIndex = right.first,
                  catalogIDsCompatible(old[oldIndex].catalogID, scanned[newIndex].catalogID) else { continue }
            match(oldIndex, newIndex)
        }

        let oldDigest = groupedIndices(unmatchedOld.sorted(), key: { digestIdentity(old[$0].observation) })
        let newDigest = groupedIndices(unmatchedNew.sorted(), key: { digestIdentity(scanned[$0].observation) })
        for key in oldDigest.keys.sorted() {
            guard let left = oldDigest[key], left.count == 1,
                  let right = newDigest[key], right.count == 1,
                  let oldIndex = left.first, let newIndex = right.first,
                  catalogIDsCompatible(old[oldIndex].catalogID, scanned[newIndex].catalogID) else { continue }
            match(oldIndex, newIndex)
        }

        let oldSignatures = groupedIndices(unmatchedOld.sorted(), key: { probableSignature(entry: old[$0]) })
        let newSignatures = groupedIndices(unmatchedNew.sorted(), key: { probableSignature(draft: scanned[$0]) })
        var probable: [ProbableMove] = []
        for key in oldSignatures.keys.sorted() {
            guard let left = oldSignatures[key], left.count == 1,
                  let right = newSignatures[key], right.count == 1,
                  let oldIndex = left.first, let newIndex = right.first,
                  catalogIDsCompatible(old[oldIndex].catalogID, scanned[newIndex].catalogID),
                  let from = old[oldIndex].relativeMediaPath else { continue }
            let to = scanned[newIndex].relativeMediaPath
            guard from != to else { continue }
            probable.append(ProbableMove(entryID: old[oldIndex].id, scannedIndex: newIndex,
                                         fromPath: from, toPath: to,
                                         evidence: probableEvidence(entry: old[oldIndex], draft: scanned[newIndex])))
        }

        let missingIDs = unmatchedOld.sorted().map { old[$0].id }
        let addedIndices = unmatchedNew.sorted()
        var summary = ReconciliationSummary()
        for item in matches {
            switch item.kind {
            case .unchanged: summary.unchanged += 1
            case .changed: summary.changed += 1
            case .moved: summary.moved += 1
            case .restored: summary.restored += 1
            }
        }
        summary.added = addedIndices.count
        summary.missing = missingIDs.count
        summary.probableMoves = probable.count

        return ReconciliationDiff(sourceID: sourceID, basisEntries: old, scanned: scanned,
                                  matches: matches.sorted { $0.entryID < $1.entryID },
                                  missingEntryIDs: missingIDs, addedScannedIndices: addedIndices,
                                  probableMoves: probable.sorted { ($0.fromPath, $0.toPath) < ($1.fromPath, $1.toPath) },
                                  summary: summary)
    }

    func prepareReconciliation(sourceID: String, scanned: [SourceEntry]) throws -> ReconciliationDiff {
        guard catalog.sources.contains(where: { $0.id == sourceID }) else {
            throw Self.libraryFailure("Source no longer exists.")
        }
        return try Self.reconciliationDiff(sourceID: sourceID, existing: catalog.entries, scanned: scanned)
    }

    /// Applies one reviewed diff to a copy of the current catalog and commits once.
    /// A stale review is rejected when the source slice changed after it was prepared.
    func applyReconciliation(_ diff: ReconciliationDiff, accepting accepted: Set<String> = []) throws {
        let current = catalog.entries.filter { $0.sourceID == diff.sourceID }
        guard current == diff.basisEntries else {
            throw Self.libraryFailure("The Source changed while the reconciliation review was open. Rescan it again.")
        }
        let sourceIDs = Set(catalog.sources.map(\.id))
        guard sourceIDs.contains(diff.sourceID) else { throw Self.libraryFailure("Source no longer exists.") }

        let matchByID = Dictionary(uniqueKeysWithValues: diff.matches.map { ($0.entryID, $0.scannedIndex) })
        var acceptedByOld: [String: Int] = [:]
        var acceptedNew = Set<Int>()
        for move in diff.probableMoves {
            let key = ReconciliationDiff.moveKey(entryID: move.entryID, scannedIndex: move.scannedIndex)
            guard accepted.contains(key), acceptedByOld[move.entryID] == nil, !acceptedNew.contains(move.scannedIndex) else { continue }
            acceptedByOld[move.entryID] = move.scannedIndex
            acceptedNew.insert(move.scannedIndex)
        }

        var rebuilt: [Entry] = []
        rebuilt.reserveCapacity(diff.basisEntries.count + diff.addedScannedIndices.count)
        for oldEntry in diff.basisEntries {
            if let newIndex = matchByID[oldEntry.id] {
                rebuilt.append(try Self.reconciledEntry(oldEntry, with: diff.scanned[newIndex]))
            } else if let newIndex = acceptedByOld[oldEntry.id] {
                rebuilt.append(try Self.reconciledEntry(oldEntry, with: diff.scanned[newIndex]))
            } else {
                var missing = oldEntry
                missing.availability = .missing
                rebuilt.append(missing)
            }
        }

        for newIndex in diff.addedScannedIndices where !acceptedNew.contains(newIndex) {
            rebuilt.append(try Self.newEntry(from: diff.scanned[newIndex], sourceID: diff.sourceID))
        }

        var next = catalog
        let firstSourceIndex = next.entries.firstIndex { $0.sourceID == diff.sourceID } ?? next.entries.endIndex
        next.entries.removeAll { $0.sourceID == diff.sourceID }
        next.entries.insert(contentsOf: rebuilt, at: min(firstSourceIndex, next.entries.endIndex))
        try commitCatalog(next)
    }

    private static func newEntry(from draft: SourceEntry, sourceID: String) throws -> Entry {
        let path = try validatedRelativePath(draft.relativeMediaPath)
        let poster = try draft.relativePosterPath.map(validatedRelativePath)
        let fallback = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return Entry(id: UUID().uuidString,
                     title: boundedReconciliationTitle(draft.title ?? fallback),
                     catalogID: draft.catalogID, sourceID: sourceID, relativeMediaPath: path,
                     relativePosterPath: poster, series: draft.series, character: draft.character,
                     variant: draft.variant, tags: draft.tags, mediaType: draft.mediaType,
                     width: draft.width, height: draft.height, fps: draft.fps,
                     duration: draft.duration, provenance: draft.provenance,
                     availability: .present, observation: draft.observation)
    }

    private static func reconciledEntry(_ old: Entry, with draft: SourceEntry) throws -> Entry {
        var entry = old
        entry.title = boundedReconciliationTitle(draft.title ?? URL(fileURLWithPath: draft.relativeMediaPath).deletingPathExtension().lastPathComponent)
        entry.catalogID = draft.catalogID
        entry.relativeMediaPath = try validatedRelativePath(draft.relativeMediaPath)
        entry.relativePosterPath = try draft.relativePosterPath.map(validatedRelativePath)
        entry.series = draft.series
        entry.character = draft.character
        entry.variant = draft.variant
        entry.tags = draft.tags
        entry.mediaType = draft.mediaType
        entry.width = draft.width
        entry.height = draft.height
        entry.fps = draft.fps
        entry.duration = draft.duration
        entry.provenance = draft.provenance
        entry.availability = .present
        entry.observation = draft.observation
        return entry
    }

    private static func matchKind(old: Entry, incoming: SourceEntry) -> ReconciliationMatchKind {
        if old.availability == .missing { return .restored }
        if old.relativeMediaPath != incoming.relativeMediaPath { return .moved }
        if sourceMetadataChanged(old: old, incoming: incoming) || old.observation != incoming.observation { return .changed }
        return .unchanged
    }

    private static func sourceMetadataChanged(old: Entry, incoming: SourceEntry) -> Bool {
        let incomingTitle = boundedReconciliationTitle(incoming.title ?? URL(fileURLWithPath: incoming.relativeMediaPath).deletingPathExtension().lastPathComponent)
        return old.title != incomingTitle || old.catalogID != incoming.catalogID ||
            old.relativePosterPath != incoming.relativePosterPath || old.series != incoming.series ||
            old.character != incoming.character || old.variant != incoming.variant || old.tags != incoming.tags ||
            old.mediaType != incoming.mediaType || old.width != incoming.width || old.height != incoming.height ||
            old.fps != incoming.fps || old.duration != incoming.duration || old.provenance != incoming.provenance
    }

    private static func normalizedIdentity(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func catalogIDsCompatible(_ old: String?, _ incoming: String?) -> Bool {
        guard let old = normalizedIdentity(old), let incoming = normalizedIdentity(incoming) else { return true }
        return old == incoming
    }

    private static func digestIdentity(_ observation: ReconciliationObservation?) -> String? {
        guard let observation, observation.hasDigest,
              let algorithm = normalizedIdentity(observation.digestAlgorithm)?.lowercased(),
              let digest = normalizedIdentity(observation.digest)?.lowercased() else { return nil }
        return algorithm + ":" + digest
    }

    private static func groupedIndices<S: Sequence>(_ indices: S, key: (S.Element) -> String?) -> [String: [S.Element]] {
        var groups: [String: [S.Element]] = [:]
        for index in indices {
            guard let identity = key(index) else { continue }
            groups[identity, default: []].append(index)
        }
        return groups
    }

    private static func probableSignature(entry: Entry) -> String? {
        guard let observation = entry.observation, let bytes = observation.byteLength else { return nil }
        let type = entry.mediaType ?? URL(fileURLWithPath: entry.relativeMediaPath ?? "").pathExtension.lowercased()
        let dimensions = entry.width.map(String.init).flatMap { w in entry.height.map { "\(w)x\($0)" } } ?? ""
        let duration = entry.duration.map { String(Int(($0 * 1000).rounded())) } ?? ""
        let title = entry.title.lowercased()
        guard !type.isEmpty || !dimensions.isEmpty || !duration.isEmpty || !title.isEmpty else { return nil }
        return "\(bytes)|\(type)|\(dimensions)|\(duration)|\(title)"
    }

    private static func probableSignature(draft: SourceEntry) -> String? {
        guard let observation = draft.observation, let bytes = observation.byteLength else { return nil }
        let type = draft.mediaType ?? URL(fileURLWithPath: draft.relativeMediaPath).pathExtension.lowercased()
        let dimensions = draft.width.map(String.init).flatMap { w in draft.height.map { "\(w)x\($0)" } } ?? ""
        let duration = draft.duration.map { String(Int(($0 * 1000).rounded())) } ?? ""
        let title = (draft.title ?? URL(fileURLWithPath: draft.relativeMediaPath).deletingPathExtension().lastPathComponent).lowercased()
        guard !type.isEmpty || !dimensions.isEmpty || !duration.isEmpty || !title.isEmpty else { return nil }
        return "\(bytes)|\(type)|\(dimensions)|\(duration)|\(title)"
    }

    private static func probableEvidence(entry: Entry, draft: SourceEntry) -> String {
        var evidence: [String] = []
        if entry.observation?.byteLength == draft.observation?.byteLength { evidence.append("same byte length") }
        if entry.mediaType == draft.mediaType { evidence.append("same media type") }
        if entry.width == draft.width, entry.height == draft.height, entry.width != nil { evidence.append("same dimensions") }
        if entry.duration == draft.duration, entry.duration != nil { evidence.append("same duration") }
        let incomingTitle = (draft.title ?? URL(fileURLWithPath: draft.relativeMediaPath).deletingPathExtension().lastPathComponent)
        if entry.title.caseInsensitiveCompare(incomingTitle) == .orderedSame { evidence.append("same title") }
        return evidence.joined(separator: ", ")
    }

    private static func boundedReconciliationTitle(_ value: String) -> String {
        var result = value
        while result.utf8.count > 1024 && !result.isEmpty { result.removeLast() }
        return result
    }
}
