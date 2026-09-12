import Foundation

struct LibraryDuplicateGroup: Equatable, Sendable {
    let entryIDs: [String]
    let evidence: String
}

enum LibraryDuplicateDetector {
    static func exactGroups(in catalog: SceneLibraryStore.Catalog) -> [LibraryDuplicateGroup] {
        var digests: [String: [String]] = [:]
        for entry in catalog.entries where entry.availability == .present {
            guard let observation = entry.observation,
                  let algorithm = observation.digestAlgorithm?.lowercased(), !algorithm.isEmpty,
                  let digest = observation.digest?.lowercased(), !digest.isEmpty else { continue }
            digests[algorithm + ":" + digest, default: []].append(entry.id)
        }
        return digests.values.filter { $0.count > 1 }.map {
            LibraryDuplicateGroup(entryIDs: $0.sorted(), evidence: "identical verified content digest")
        }.sorted { $0.entryIDs.lexicographicallyPrecedes($1.entryIDs) }
    }
    static func duplicateIDs(in catalog: SceneLibraryStore.Catalog) -> Set<String> {
        Set(exactGroups(in: catalog).flatMap(\.entryIDs))
    }
}

enum LibrarySmartCollectionEngine {
    static func members(of collection: SceneLibraryStore.SmartCollection,
                        in catalog: SceneLibraryStore.Catalog) -> [SceneLibraryStore.Entry] {
        let duplicates = LibraryDuplicateDetector.duplicateIDs(in: catalog)
        var entries = catalog.entries.filter { $0.availability == .present && matches($0, collection.predicates, catalog, duplicates) }
        entries.sort { lhs, rhs in
            switch collection.sort {
            case .name:
                let order = lhs.title.localizedStandardCompare(rhs.title)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            case .rating:
                let a = catalog.memory[lhs.id]?.rating ?? 0, b = catalog.memory[rhs.id]?.rating ?? 0
                return a == b ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending : a > b
            case .recent:
                let a = catalog.recent[lhs.id] ?? .distantPast, b = catalog.recent[rhs.id] ?? .distantPast
                return a == b ? lhs.id < rhs.id : a > b
            case .playCount:
                let a = catalog.memory[lhs.id]?.playCount ?? 0, b = catalog.memory[rhs.id]?.playCount ?? 0
                return a == b ? lhs.id < rhs.id : a > b
            }
        }
        return entries
    }

    private static func matches(_ entry: SceneLibraryStore.Entry,
                                _ predicates: [SceneLibraryStore.SmartPredicate],
                                _ catalog: SceneLibraryStore.Catalog,
                                _ duplicates: Set<String>) -> Bool {
        let memory = catalog.memory[entry.id] ?? .init()
        return predicates.allSatisfy { predicate in
            switch predicate {
            case .favorite(let value): return catalog.favorites.contains(entry.id) == value
            case .ratingAtLeast(let value): return (memory.rating ?? 0) >= value
            case .playedAtLeast(let value): return memory.playCount >= value
            case .unplayed: return memory.playCount == 0
            case .mediaType(let value): return normalizedMediaType(entry) == value.lowercased()
            case .series(let value): return entry.series?.caseInsensitiveCompare(value) == .orderedSame
            case .character(let value): return entry.character?.caseInsensitiveCompare(value) == .orderedSame
            case .tag(let value): return entry.tags.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
            case .sourceID(let value): return entry.sourceID == value
            case .duplicate: return duplicates.contains(entry.id)
            }
        }
    }

    static func normalizedMediaType(_ entry: SceneLibraryStore.Entry) -> String {
        if let type = entry.mediaType?.lowercased(), !type.isEmpty { return type }
        let path = entry.relativeMediaPath?.lowercased() ?? ""
        if path.hasSuffix(".mp4") || path.hasSuffix(".mov") || path.hasSuffix(".m4v") { return "video" }
        if path.hasSuffix(".idlesse") { return "scene" }
        return "image"
    }
}

struct LibrarySeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

enum LibraryMemoryPlayback {
    static func select(from entryIDs: [String], catalog: SceneLibraryStore.Catalog,
                       mode: SceneLibraryStore.Playback.SelectionMode, seed: UInt64,
                       now: Date = Date()) -> String? {
        let available = entryIDs.filter { id in catalog.entries.contains { $0.id == id && $0.availability == .present } }
        guard !available.isEmpty else { return nil }
        if mode == .ordered { return available.first }
        var random = LibrarySeededRandom(seed: seed)
        if mode == .shuffle { return available[Int(random.next() % UInt64(available.count))] }
        let weighted = available.map { id -> (String, Double) in
            let state = catalog.memory[id] ?? .init()
            let rating = Double(state.rating ?? 0)
            let favorite = catalog.favorites.contains(id)
            let weight: Double
            if mode == .weighted {
                weight = max(0.05, 1 + rating * 0.65 + (favorite ? 1.5 : 0))
            } else {
                let count = Double(state.playCount)
                let ageBoost: Double
                if let recent = catalog.recent[id] {
                    ageBoost = min(3, max(0.25, now.timeIntervalSince(recent) / 86_400 + 0.25))
                } else { ageBoost = 3 }
                weight = max(0.05, ageBoost * (1 + rating * 0.15 + (favorite ? 0.35 : 0)) / (1 + count * 0.4))
            }
            return (id, weight)
        }
        let total = weighted.reduce(0) { $0 + $1.1 }
        var cursor = random.unit() * total
        for (id, weight) in weighted {
            cursor -= weight
            if cursor <= 0 { return id }
        }
        return weighted.last?.0
    }
}
