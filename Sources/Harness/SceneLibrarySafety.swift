import Foundation

/// Keeps the Library index safe when more than one Idlesse process writes it,
/// and makes every destructive entry removal recoverable.
///
/// Each store rewrites the whole index from its in-memory catalog. A development
/// build, a smoke probe, or a second copy of the app can therefore hold an older
/// catalog than the file. Writers take an exclusive lock and replay only their
/// own changes onto the current disk catalog. Before a write can drop entries,
/// the previous index and a bounded recovery ledger are durably written first.
extension SceneLibraryStore {
    struct RemovedEntry: Codable, Equatable {
        var entry: Entry
        var source: SourceRoot?
        var favorite: Bool
        var recent: Date?
        var collectionIDs: [String]
        var removedAt: Date
    }

    static let keptBackups = 30
    static let keptRemovedEntries = 100
    static let maxRemovalLogBytes = 1_048_576
    static let maxRemovedLedgerBytes = 16_777_216

    /// Resolves the Library index for a process. Explicit overrides win; smoke
    /// processes are isolated automatically so a UI probe cannot touch the real Library.
    static var defaultIndexURL: URL {
        resolvedIndexURL(environment: ProcessInfo.processInfo.environment,
                         arguments: ProcessInfo.processInfo.arguments,
                         applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory,
                                                                      in: .userDomainMask).first!,
                         temporaryDirectory: FileManager.default.temporaryDirectory,
                         processIdentifier: ProcessInfo.processInfo.processIdentifier)
    }

    static func resolvedIndexURL(environment: [String: String], arguments: [String],
                                 applicationSupport: URL, temporaryDirectory: URL,
                                 processIdentifier: Int32) -> URL {
        if let override = environment["IDLESSE_LIBRARY_INDEX"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        if arguments.dropFirst().contains(where: { $0.hasPrefix("--smoke") }) {
            return temporaryDirectory
                .appendingPathComponent("Idlesse/LibrarySmoke/\(processIdentifier)", isDirectory: true)
                .appendingPathComponent("index.json")
        }
        return applicationSupport.appendingPathComponent("Idlesse/Library/index.json")
    }

    var backupsFolder: URL { file.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true) }
    var removalLog: URL { file.deletingLastPathComponent().appendingPathComponent("removals.log") }
    var removedFile: URL { file.deletingLastPathComponent().appendingPathComponent("Removed.json") }

    // MARK: Concurrent writers

    func withIndexLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw Self.libraryFailure("The Library index could not be locked.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw Self.libraryFailure("The Library index could not be locked.") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// The index as it is on disk now, and its exact bytes for recovery backup.
    func readIndex() throws -> (Catalog, Data?) {
        guard FileManager.default.fileExists(atPath: file.path) else { return (Catalog(), nil) }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= Self.maxIndexBytes else {
            throw Self.libraryFailure("The Library index is too large.")
        }
        let data = try Data(contentsOf: file)
        let decoded: Catalog
        do { decoded = try JSONDecoder().decode(Catalog.self, from: data) } catch {
            throw Self.libraryFailure("The Library index on disk is unreadable, so it was left untouched.")
        }
        guard (1...Self.catalogVersion).contains(decoded.version) else {
            throw Self.libraryFailure("This Library index was written by a newer Idlesse version.")
        }
        return (decoded, data)
    }

    /// Replays the change from `base` to `proposed` onto `disk`, the index another writer left.
    /// Removals elsewhere win over stale edits; additions on both sides are kept.
    static func rebase(_ proposed: Catalog, from base: Catalog, onto disk: Catalog) -> Catalog {
        var result = disk
        result.entries = merge(proposed.entries, base.entries, disk.entries, id: \.id)
        result.sources = merge(proposed.sources, base.sources, disk.sources, id: \.id)
        result.collections = mergeCollections(proposed, base, disk)
        result.favorites = disk.favorites
            .subtracting(base.favorites.subtracting(proposed.favorites))
            .union(proposed.favorites.subtracting(base.favorites))

        // `used(_:)` only advances a timestamp. If two stale writers update the
        // same entry, retain the newest observation rather than replaying an older one.
        for (key, date) in proposed.recent where base.recent[key] != date {
            if let current = result.recent[key] { result.recent[key] = max(current, date) }
            else { result.recent[key] = date }
        }

        let sourceIDs = Set(result.sources.map(\.id))
        result.entries.removeAll { entry in entry.sourceID.map { !sourceIDs.contains($0) } ?? false }

        // Built-in scenes can appear in favorites and recents without an Entry.
        // Prune only references to real entries that existed somewhere and are now gone.
        let kept = Set(result.entries.map(\.id))
        let gone = Set((base.entries + disk.entries + proposed.entries).map(\.id)).subtracting(kept)
        result.favorites.subtract(gone)
        for key in gone { result.recent.removeValue(forKey: key) }
        for index in result.collections.indices { result.collections[index].sceneIDs.removeAll { gone.contains($0) } }
        while result.recent.count > 256, let oldest = result.recent.min(by: { $0.value < $1.value })?.key {
            result.recent.removeValue(forKey: oldest)
        }
        return result
    }

    private static func merge<T: Equatable>(_ proposed: [T], _ base: [T], _ disk: [T], id: (T) -> String) -> [T] {
        let before = Dictionary(base.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        let now = Set(proposed.map(id))
        var result = disk.filter { before[id($0)] == nil || now.contains(id($0)) }
        for item in proposed where before[id(item)] != item {
            if let index = result.firstIndex(where: { id($0) == id(item) }) {
                result[index] = item
            } else if before[id(item)] == nil {
                result.append(item)
            }
        }
        return result
    }

    /// Collections carry several independent pieces of state. Merge them at that
    /// granularity so a rename in one process does not erase membership work in another.
    private static func mergeCollections(_ proposed: Catalog, _ base: Catalog, _ disk: Catalog) -> [Collection] {
        let before = Dictionary(base.collections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Set(proposed.collections.map(\.id))
        var result = disk.collections.filter { before[$0.id] == nil || now.contains($0.id) }

        for local in proposed.collections {
            guard let old = before[local.id] else {
                if !result.contains(where: { $0.id == local.id }) { result.append(local) }
                continue
            }
            guard local != old, let index = result.firstIndex(where: { $0.id == local.id }) else {
                // A collection removed on disk stays removed; stale edits cannot resurrect it.
                continue
            }
            var merged = result[index]
            if local.name != old.name { merged.name = local.name }
            if local.playback != old.playback { merged.playback = local.playback }
            if local.sceneIDs != old.sceneIDs {
                merged.sceneIDs = mergeOrderedIDs(proposed: local.sceneIDs, base: old.sceneIDs, disk: merged.sceneIDs)
            }
            result[index] = merged
        }

        let order = mergeOrderedIDs(proposed: proposed.collections.map(\.id),
                                    base: base.collections.map(\.id), disk: result.map(\.id))
        let byID = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byID[$0] }
    }

    /// Applies local add/remove/order deltas to a disk order while retaining IDs
    /// another writer added. Local reordering only moves IDs that existed in `base`.
    private static func mergeOrderedIDs(proposed: [String], base: [String], disk: [String]) -> [String] {
        let baseSet = Set(base)
        let proposedSet = Set(proposed)
        let removed = baseSet.subtracting(proposedSet)
        var result = disk.filter { !removed.contains($0) }

        for id in proposed where !baseSet.contains(id) && !result.contains(id) { result.append(id) }

        let baseCommon = base.filter { proposedSet.contains($0) }
        let proposedCommon = proposed.filter { baseSet.contains($0) }
        guard baseCommon != proposedCommon else { return result }

        let resultSet = Set(result)
        let ordered = proposedCommon.filter { resultSet.contains($0) }
        let touched = Set(ordered)
        var iterator = ordered.makeIterator()
        return result.map { touched.contains($0) ? (iterator.next() ?? $0) : $0 }
    }

    // MARK: Durable writes and removals

    /// Atomic replacement plus a file sync. A process crash can leave the old or
    /// the new complete file, never a partially encoded catalog.
    func writeIndexData(_ data: Data) throws { try durableWrite(data, to: file) }

    private func durableWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.libraryFailure("A Library recovery file could not be reopened after writing.") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw Self.libraryFailure("A Library recovery file could not be synchronized to disk.") }
    }

    /// Called under the index lock before a write that drops `removed` from `previous`.
    /// Every required recovery artifact succeeds before the destructive index commit.
    func journalRemoval(_ removed: [Entry], previous: Catalog, previousData: Data?) throws {
        guard !removed.isEmpty else { return }
        guard let previousData else {
            throw Self.libraryFailure("The Library could not preserve the previous index before removing items.")
        }
        let manager = FileManager.default
        let now = Date()
        let process = ProcessInfo.processInfo
        let transaction = UUID().uuidString.lowercased()

        try manager.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
        var backups = try manager.contentsOfDirectory(atPath: backupsFolder.path)
            .filter { $0.hasPrefix("index-") && $0.hasSuffix(".json") }.sorted()
        while backups.count >= Self.keptBackups, let oldest = backups.first {
            try manager.removeItem(at: backupsFolder.appendingPathComponent(oldest))
            backups.removeFirst()
        }
        let backupName = "index-\(Self.stampFormatter.string(from: now))-\(process.processIdentifier)-\(transaction).json"
        try durableWrite(previousData, to: backupsFolder.appendingPathComponent(backupName))

        var records = try readRemovedRecords()
        let currentIDs = Set(previous.entries.map(\.id))
        // Records for restored/current entries are historical; the backup/log keep
        // that history, while the bounded recovery ledger prioritizes active removals.
        records.removeAll { currentIDs.contains($0.entry.id) }
        let sources = Dictionary(previous.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newRecords = removed.prefix(Self.keptRemovedEntries).map { entry in
            RemovedEntry(entry: entry, source: entry.sourceID.flatMap { sources[$0] },
                         favorite: previous.favorites.contains(entry.id), recent: previous.recent[entry.id],
                         collectionIDs: previous.collections.filter { $0.sceneIDs.contains(entry.id) }.map(\.id),
                         removedAt: now)
        }
        let removedIDs = Set(removed.map(\.id))
        records.removeAll { removedIDs.contains($0.entry.id) }
        records.insert(contentsOf: newRecords, at: 0)
        var bounded = Array(records.prefix(Self.keptRemovedEntries))
        var removedData = try JSONEncoder().encode(bounded)
        while removedData.count > Self.maxRemovedLedgerBytes, bounded.count > 1 {
            bounded.removeLast()
            removedData = try JSONEncoder().encode(bounded)
        }
        guard removedData.count <= Self.maxRemovedLedgerBytes else {
            throw Self.libraryFailure("The Recently Removed recovery ledger is full, so the Library was left unchanged.")
        }
        try durableWrite(removedData, to: removedFile)

        let shown = removed.prefix(32).map { "\($0.title) [\($0.id)]" }.joined(separator: ", ")
        let extra = removed.count > 32 ? ", +\(removed.count - 32) more" : ""
        let arguments = String(process.arguments.dropFirst().joined(separator: " ").prefix(4096))
        let line = "\(ISO8601DateFormatter().string(from: now)) tx=\(transaction) pid=\(process.processIdentifier) \(process.processName)"
            + (arguments.isEmpty ? "" : " args=\(arguments)")
            + " prepared-remove \(removed.count) backup=\(backupName): \(shown)\(extra)\n"
        try appendRemovalLog(Data(line.utf8))
    }

    private func appendRemovalLog(_ line: Data) throws {
        let manager = FileManager.default
        let rotated = removalLog.appendingPathExtension("1")
        let size = ((try? manager.attributesOfItem(atPath: removalLog.path)[.size]) as? NSNumber)?.intValue ?? 0
        if size + line.count > Self.maxRemovalLogBytes, manager.fileExists(atPath: removalLog.path) {
            if manager.fileExists(atPath: rotated.path) { try manager.removeItem(at: rotated) }
            try manager.moveItem(at: removalLog, to: rotated)
            try durableWrite(line, to: removalLog)
            return
        }
        var data = manager.fileExists(atPath: removalLog.path) ? try Data(contentsOf: removalLog) : Data()
        data.append(line)
        try durableWrite(data, to: removalLog)
    }

    private func readRemovedRecords() throws -> [RemovedEntry] {
        guard FileManager.default.fileExists(atPath: removedFile.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: removedFile.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= Self.maxRemovedLedgerBytes else {
            throw Self.libraryFailure("The Recently Removed recovery ledger is too large, so the Library was left unchanged.")
        }
        let data = try Data(contentsOf: removedFile)
        do { return try JSONDecoder().decode([RemovedEntry].self, from: data) }
        catch {
            throw Self.libraryFailure("The Recently Removed recovery ledger is unreadable, so the Library was left unchanged.")
        }
    }

    /// Newest active removals first. Restored records remain as bounded evidence
    /// until the next removal compacts them, but disappear from this state immediately.
    func recentlyRemoved() -> [RemovedEntry] {
        guard let records = try? readRemovedRecords() else { return [] }
        let present = Set(catalog.entries.map(\.id))
        return records.filter { !present.contains($0.entry.id) }
    }

    /// Puts a removed entry back with its Source reference, favorite, recent date,
    /// and memberships in collections that still exist. This is an explicit recovery
    /// action, so it may deliberately reintroduce an item that another write removed.
    @discardableResult
    func restoreRemoved(_ id: String) throws -> Entry {
        try reloadFromDisk()
        guard let record = try readRemovedRecords().first(where: { $0.entry.id == id }) else {
            throw Self.libraryFailure("That wallpaper is no longer in Recently Removed.")
        }
        if catalog.entries.contains(where: { $0.id == id }) { return record.entry }

        var next = catalog
        if let sourceID = record.entry.sourceID, !next.sources.contains(where: { $0.id == sourceID }) {
            guard let source = record.source, source.id == sourceID else {
                throw Self.libraryFailure("Its Source recovery record is unavailable. Restore the index backup or add the folder again.")
            }
            next.sources.append(source)
        }
        next.entries.append(record.entry)
        if record.favorite { next.favorites.insert(id) }
        if let recent = record.recent { next.recent[id] = recent }
        while next.recent.count > 256, let oldest = next.recent.min(by: { $0.value < $1.value })?.key {
            next.recent.removeValue(forKey: oldest)
        }
        for index in next.collections.indices where record.collectionIDs.contains(next.collections[index].id) {
            if !next.collections[index].sceneIDs.contains(id), next.collections[index].sceneIDs.count < 256 {
                next.collections[index].sceneIDs.append(id)
            }
        }
        try commitCatalog(next)
        guard catalog.entries.contains(where: { $0.id == id }) else {
            throw Self.libraryFailure("The item could not be restored because its Source changed. Refresh Recently Removed and try again.")
        }
        return record.entry
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()
}
