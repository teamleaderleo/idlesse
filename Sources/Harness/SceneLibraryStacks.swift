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

        var groups: [String: [SceneLibraryStore.Entry]] = [:]
        for entry in catalog.entries where !claimed.contains(entry.id) {
            guard let sourceID = entry.sourceID, let groupID = normalized(entry.groupID) else { continue }
            groups[sourceID + "\u{0}" + groupID, default: []].append(entry)
        }
        for key in groups.keys.sorted() {
            guard let entries = groups[key], entries.count >= 2,
                  let sourceID = entries.first?.sourceID, let groupID = normalized(entries.first?.groupID) else { continue }
            let ordered = entries.sorted { $0.id < $1.id }.map(\.id)
            let encoded = Data(groupID.utf8).base64EncodedString()
            result.append(.init(id: "source:" + sourceID + ":" + encoded,
                                name: sourceName(groupID: groupID, entries: entries), entryIDs: ordered,
                                representativeEntryID: nil, kind: .source, userStackID: nil))
        }
        return result
    }

    static func projection(id: String, in catalog: SceneLibraryStore.Catalog) -> LibraryStackProjection? {
        projections(in: catalog).first { $0.id == id }
    }

    static func representative(for stack: LibraryStackProjection, in catalog: SceneLibraryStore.Catalog,
                               query: String = "") -> SceneLibraryStore.Entry? {
        let byID = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.id, $0) })
        let available = stack.entryIDs.compactMap { byID[$0] }.filter { $0.availability == .present }
        guard !available.isEmpty else { return nil }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let ranked = available.compactMap { entry -> (SceneLibraryStore.Entry, Double)? in
                entryScore(query: q, entry: entry).map { (entry, $0) }
            }.sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0.id < rhs.0.id : lhs.1 < rhs.1 }
            if let first = ranked.first { return first.0 }
            guard fuzzyScore(query: q, in: stack.name) != nil else { return nil }
        }
        if let remembered = stack.representativeEntryID,
           let entry = available.first(where: { $0.id == remembered }) { return entry }
        return available.first
    }

    static func matchingChildren(of stack: LibraryStackProjection, in catalog: SceneLibraryStore.Catalog,
                                 query: String) -> [SceneLibraryStore.Entry] {
        let byID = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.id, $0) })
        let available = stack.entryIDs.compactMap { byID[$0] }.filter { $0.availability == .present }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return available }
        return available.filter { entryScore(query: q, entry: $0) != nil }
    }

    static func score(query: String, stack: LibraryStackProjection, in catalog: SceneLibraryStore.Catalog) -> Double? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return 0 }
        var scores = matchingChildren(of: stack, in: catalog, query: q).compactMap { entryScore(query: q, entry: $0) }
        if let name = fuzzyScore(query: q, in: stack.name) { scores.append(name) }
        return scores.min()
    }

    static func entryScore(query: String, entry: SceneLibraryStore.Entry) -> Double? {
        let fields = [entry.title, entry.series, entry.character, entry.variant].compactMap { $0 }
            + entry.tags + (entry.provenance?.values.sorted() ?? [])
        return fields.compactMap { fuzzyScore(query: query, in: $0) }.min()
    }

    static func typeHint(for stack: LibraryStackProjection, in catalog: SceneLibraryStore.Catalog) -> String {
        let ids = Set(stack.entryIDs)
        let types = Set(catalog.entries.filter { ids.contains($0.id) }.map { entry -> String in
            let path = entry.relativeMediaPath?.lowercased() ?? ""
            if entry.mediaType == "video" || path.hasSuffix(".mp4") || path.hasSuffix(".mov") { return "video" }
            if entry.mediaType == "scene" || path.hasSuffix(".idlesse") { return "scene" }
            return "image"
        })
        if types.count == 1 { return types.first!.uppercased() }
        return "MIXED"
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

    static func fuzzyScore(query: String, in text: String) -> Double? {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return 0 }
        let t = Array(text.lowercased())
        if text.localizedCaseInsensitiveContains(query) {
            return (t.starts(with: q) ? 0 : 0.5) + 1 + Double(t.count) / 1000
        }
        var ti = 0, last = -2
        var score = 4.0
        for qc in q {
            var found = false
            while ti < t.count {
                let c = t[ti]; ti += 1
                if c == qc {
                    if ti - 1 == 0 || t[ti - 2] == " " || t[ti - 2] == "-" { score -= 0.3 }
                    if ti - 1 == last + 1 { score -= 0.2 }
                    last = ti - 1; found = true; break
                }
                score += 0.05
            }
            if !found { return nil }
        }
        return score + Double(t.count) / 1000
    }
}
