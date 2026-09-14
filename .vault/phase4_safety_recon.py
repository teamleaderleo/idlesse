from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:80]!r}")
    p.write_text(text.replace(old, new, 1))


safety = "Sources/Harness/SceneLibrarySafety.swift"
replace_once(safety, r'''        result.collections = mergeCollections(proposed, base, disk)
        result.favorites = disk.favorites
''', r'''        result.collections = mergeCollections(proposed, base, disk)
        result.stacks = mergeStacks(proposed, base, disk)
        result.favorites = disk.favorites
''')
replace_once(safety, r'''        for index in result.collections.indices { result.collections[index].sceneIDs.removeAll { gone.contains($0) } }
        while result.recent.count > 256, let oldest = result.recent.min(by: { $0.value < $1.value })?.key {
''', r'''        for index in result.collections.indices { result.collections[index].sceneIDs.removeAll { gone.contains($0) } }
        pruneStacks(&result.stacks, removing: gone)
        while result.recent.count > 256, let oldest = result.recent.min(by: { $0.value < $1.value })?.key {
''')
replace_once(safety, r'''    /// Collections carry several independent pieces of state. Merge them at that
    /// granularity so a rename in one process does not erase membership work in another.
    private static func mergeCollections(_ proposed: Catalog, _ base: Catalog, _ disk: Catalog) -> [Collection] {
''', r'''    /// User stacks carry independent name, membership, representative and ordering state.
    /// Merge those deltas separately; deletion on disk wins over a stale local edit.
    private static func mergeStacks(_ proposed: Catalog, _ base: Catalog, _ disk: Catalog) -> [UserStack] {
        let before = Dictionary(base.stacks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Set(proposed.stacks.map(\.id))
        var result = disk.stacks.filter { before[$0.id] == nil || now.contains($0.id) }

        for local in proposed.stacks {
            guard let old = before[local.id] else {
                if !result.contains(where: { $0.id == local.id }) { result.append(local) }
                continue
            }
            guard local != old, let index = result.firstIndex(where: { $0.id == local.id }) else { continue }
            var merged = result[index]
            if local.name != old.name { merged.name = local.name }
            if local.representativeID != old.representativeID { merged.representativeID = local.representativeID }
            if local.sceneIDs != old.sceneIDs {
                merged.sceneIDs = mergeOrderedIDs(proposed: local.sceneIDs, base: old.sceneIDs, disk: merged.sceneIDs)
            }
            if let representative = merged.representativeID, !merged.sceneIDs.contains(representative) {
                merged.representativeID = nil
            }
            result[index] = merged
        }

        let order = mergeOrderedIDs(proposed: proposed.stacks.map(\.id), base: base.stacks.map(\.id), disk: result.map(\.id))
        let byID = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byID[$0] }
    }

    /// Collections carry several independent pieces of state. Merge them at that
    /// granularity so a rename in one process does not erase membership work in another.
    private static func mergeCollections(_ proposed: Catalog, _ base: Catalog, _ disk: Catalog) -> [Collection] {
''')

recon = "Sources/Harness/SceneLibraryReconciliation.swift"
replace_once(recon, r'''                     catalogID: draft.catalogID, sourceID: sourceID, relativeMediaPath: path,
''', r'''                     catalogID: draft.catalogID, groupID: draft.groupID, sourceID: sourceID, relativeMediaPath: path,
''')
replace_once(recon, r'''        entry.catalogID = draft.catalogID
        entry.relativeMediaPath = try validatedRelativePath(draft.relativeMediaPath)
''', r'''        entry.catalogID = draft.catalogID
        entry.groupID = draft.groupID
        entry.relativeMediaPath = try validatedRelativePath(draft.relativeMediaPath)
''')
replace_once(recon, r'''        return old.title != incomingTitle || old.catalogID != incoming.catalogID ||
            old.relativePosterPath != incoming.relativePosterPath || old.series != incoming.series ||
''', r'''        return old.title != incomingTitle || old.catalogID != incoming.catalogID || old.groupID != incoming.groupID ||
            old.relativePosterPath != incoming.relativePosterPath || old.series != incoming.series ||
''')

print("safety/reconciliation transformed")
