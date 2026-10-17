import Foundation

struct LibraryStackProjection: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable { case source, user }
    let id: String
    let name: String
    let entryIDs: [String]
    let representativeEntryID: String?
    let kind: Kind
    let userStackID: String?
}

enum LibraryStackBrowser {
    private struct SourceGroupKey: Hashable {
        let sourceID: String
        let groupID: String
    }

    static func projections(in catalog: SceneLibraryStore.Catalog) -> [LibraryStackProjection] {
        let entriesByID = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.id, $0) })
        var claimed = Set<String>()
        var result: [LibraryStackProjection] = []

        for stack in catalog.stacks {
            let ids = stack.sceneIDs.filter { entriesByID[$0] != nil }
            guard ids.count >= 2 else { continue }
            result.append(.init(id: "user:" + stack.id, name: stack.name, entryIDs: ids,
                                representativeEntryID: stack.representativeID, kind: .user, userStackID: stack.id))
            claimed.formUnion(ids)
        }

        var groups: [SourceGroupKey: [SceneLibraryStore.Entry]] = [:]
        for entry in catalog.entries where !claimed.contains(entry.id) {
            guard let sourceID = entry.sourceID, let groupID = entry.groupID, !groupID.isEmpty else { continue }
            groups[.init(sourceID: sourceID, groupID: groupID), default: []].append(entry)
        }
        let keys = groups.keys.sorted {
            $0.sourceID == $1.sourceID ? $0.groupID < $1.groupID : $0.sourceID < $1.sourceID
        }
        for key in keys {
            guard let entries = groups[key], entries.count >= 2 else { continue }
            let ids = entries.sorted { $0.id < $1.id }.map(\.id)
            let encodedSource = Data(key.sourceID.utf8).base64EncodedString()
            let encodedGroup = Data(key.groupID.utf8).base64EncodedString()
            result.append(.init(id: "source:" + encodedSource + ":" + encodedGroup,
                                name: sourceName(groupID: key.groupID, entries: entries), entryIDs: ids,
                                representativeEntryID: nil, kind: .source, userStackID: nil))
        }
        return result
    }

    static func projection(id: String, in catalog: SceneLibraryStore.Catalog) -> LibraryStackProjection? {
        projections(in: catalog).first { $0.id == id }
    }

    static func representative(for stack: LibraryStackProjection, in catalog: SceneLibraryStore.Catalog,
                               query: String = "") -> SceneLibraryStore.Entry? {
        let entriesByID = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.id, $0) })
        let available = stack.entryIDs.compactMap { entriesByID[$0] }.filter { $0.availability == .present }
        guard !available.isEmpty else { return nil }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let best = available.compactMap({ entry -> (SceneLibraryStore.Entry, Double)? in
               guard let score = entryScore(query: query, entry: entry) else { return nil }
               return (entry, score)
           }).min(by: { $0.1 < $1.1 })?.0 { return best }
        if let remembered = stack.representativeEntryID,
           let entry = available.first(where: { $0.id == remembered }) { return entry }
        return available.first
    }

    static func matchingChildren(of stack: LibraryStackProjection, in catalog: SceneLibraryStore.Catalog,
                                 query: String) -> [SceneLibraryStore.Entry] {
        let entriesByID = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.id, $0) })
        let available = stack.entryIDs.compactMap { entriesByID[$0] }.filter { $0.availability == .present }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return available }
        return available.filter { entryScore(query: trimmed, entry: $0) != nil }
            .sorted { (entryScore(query: trimmed, entry: $0) ?? .infinity) < (entryScore(query: trimmed, entry: $1) ?? .infinity) }
    }

    static func score(query: String, stack: LibraryStackProjection, in catalog: SceneLibraryStore.Catalog) -> Double? {
        let stackScore = fuzzyScore(query: query, in: stack.name)
        let entriesByID = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.id, $0) })
        let childScore = stack.entryIDs.compactMap { entriesByID[$0] }.compactMap { entryScore(query: query, entry: $0) }.min()
        return [stackScore, childScore].compactMap { $0 }.min()
    }

    static func entryScore(query: String, entry: SceneLibraryStore.Entry) -> Double? {
        let fields = [entry.title, entry.series, entry.character, entry.variant]
            .compactMap { $0 } + entry.tags + Array(entry.provenance?.values ?? Dictionary<String, String>().values)
        return fields.compactMap { fuzzyScore(query: query, in: $0) }.min()
    }

    static func typeHint(for stack: LibraryStackProjection, in catalog: SceneLibraryStore.Catalog) -> String {
        let ids = Set(stack.entryIDs)
        let types = Set(catalog.entries.filter { ids.contains($0.id) }.compactMap { $0.inferredMediaType?.uppercased() })
        if types.count == 1 { return types.first ?? "STACK" }
        return types.isEmpty ? "STACK" : "MIXED"
    }

    private static func sourceName(groupID: String, entries: [SceneLibraryStore.Entry]) -> String {
        let series = Set(entries.compactMap { normalized($0.series) })
        if series.count == 1, let value = series.first { return value }
        let characters = Set(entries.compactMap { normalized($0.character) })
        if characters.count == 1, let value = characters.first { return value }
        return groupID
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func fuzzyScore(query: String, in candidate: String) -> Double? {
        let query = Array(query.lowercased())
        guard !query.isEmpty else { return 0 }
        let text = Array(candidate.lowercased())
        var qi = 0, score = 0.0, last = -2
        for (index, character) in text.enumerated() where qi < query.count && character == query[qi] {
            if qi == 0 { score += Double(index) * 0.2 }
            if index != last + 1 { score += 1 }
            if index > 0, text[index - 1] == " " || text[index - 1] == "-" || text[index - 1] == "_" { score -= 0.35 }
            last = index; qi += 1
        }
        guard qi == query.count else { return nil }
        if candidate.lowercased().hasPrefix(String(query)) { score -= 1 }
        return score + Double(text.count) / 1000
    }
}
