from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:80]!r}")
    p.write_text(text.replace(old, new, 1))


store = "Sources/Harness/SceneLibraryStore.swift"
replace_once(store, r'''        var bookmark: Data?
        var catalogID: String?
        var sourceID: String?
''', r'''        var bookmark: Data?
        var catalogID: String?
        var groupID: String?
        var sourceID: String?
''')
replace_once(store, r'''        init(id: String, title: String, bookmark: Data? = nil, catalogID: String? = nil,
             sourceID: String? = nil, relativeMediaPath: String? = nil,
''', r'''        init(id: String, title: String, bookmark: Data? = nil, catalogID: String? = nil,
             groupID: String? = nil, sourceID: String? = nil, relativeMediaPath: String? = nil,
''')
replace_once(store, r'''            self.bookmark = bookmark
            self.catalogID = catalogID
            self.sourceID = sourceID
''', r'''            self.bookmark = bookmark
            self.catalogID = catalogID
            self.groupID = groupID
            self.sourceID = sourceID
''')
replace_once(store, r'''            case id, title, bookmark, catalogID, sourceID, relativeMediaPath, relativePosterPath
''', r'''            case id, title, bookmark, catalogID, groupID, sourceID, relativeMediaPath, relativePosterPath
''')
replace_once(store, r'''            catalogID = try values.decodeIfPresent(String.self, forKey: .catalogID)
            sourceID = try values.decodeIfPresent(String.self, forKey: .sourceID)
''', r'''            catalogID = try values.decodeIfPresent(String.self, forKey: .catalogID)
            groupID = try values.decodeIfPresent(String.self, forKey: .groupID)
            sourceID = try values.decodeIfPresent(String.self, forKey: .sourceID)
''')
replace_once(store, r'''            try values.encodeIfPresent(catalogID, forKey: .catalogID)
            try values.encodeIfPresent(sourceID, forKey: .sourceID)
''', r'''            try values.encodeIfPresent(catalogID, forKey: .catalogID)
            try values.encodeIfPresent(groupID, forKey: .groupID)
            try values.encodeIfPresent(sourceID, forKey: .sourceID)
''')
replace_once(store, r'''        var title: String?
        var catalogID: String?
        var relativePosterPath: String?
''', r'''        var title: String?
        var catalogID: String?
        var groupID: String?
        var relativePosterPath: String?
''')
replace_once(store, r'''        init(relativeMediaPath: String, title: String? = nil, catalogID: String? = nil,
             relativePosterPath: String? = nil, series: String? = nil,
''', r'''        init(relativeMediaPath: String, title: String? = nil, catalogID: String? = nil,
             groupID: String? = nil, relativePosterPath: String? = nil, series: String? = nil,
''')
replace_once(store, r'''            self.title = title
            self.catalogID = catalogID
            self.relativePosterPath = relativePosterPath
''', r'''            self.title = title
            self.catalogID = catalogID
            self.groupID = groupID
            self.relativePosterPath = relativePosterPath
''')
replace_once(store, r'''    struct Collection: Codable, Equatable {
        var id: String = UUID().uuidString
        var name: String
        var sceneIDs: [String] = []
        var playback: Playback?
    }
    struct Catalog: Codable, Equatable {
        var version: Int = SceneLibraryStore.catalogVersion
        var entries: [Entry] = []
        var sources: [SourceRoot] = []
        var favorites: Set<String> = []
        var recent: [String: Date] = [:]
        var collections: [Collection] = []
        init() {}
        enum CodingKeys: String, CodingKey { case version, entries, sources, favorites, recent, collections }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
            entries = try values.decode([Entry].self, forKey: .entries)
            sources = try values.decodeIfPresent([SourceRoot].self, forKey: .sources) ?? []
            favorites = try values.decode(Set<String>.self, forKey: .favorites)
            recent = try values.decode([String: Date].self, forKey: .recent)
            collections = try values.decodeIfPresent([Collection].self, forKey: .collections) ?? []
        }
    }
''', r'''    struct Collection: Codable, Equatable {
        var id: String = UUID().uuidString
        var name: String
        var sceneIDs: [String] = []
        var playback: Playback?
    }
    struct UserStack: Codable, Equatable, Sendable {
        var id: String = UUID().uuidString
        var name: String
        var sceneIDs: [String] = []
        var representativeID: String?
    }
    struct Catalog: Codable, Equatable {
        var version: Int = SceneLibraryStore.catalogVersion
        var entries: [Entry] = []
        var sources: [SourceRoot] = []
        var favorites: Set<String> = []
        var recent: [String: Date] = [:]
        var stacks: [UserStack] = []
        var collections: [Collection] = []
        init() {}
        enum CodingKeys: String, CodingKey { case version, entries, sources, favorites, recent, stacks, collections }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
            entries = try values.decode([Entry].self, forKey: .entries)
            sources = try values.decodeIfPresent([SourceRoot].self, forKey: .sources) ?? []
            favorites = try values.decode(Set<String>.self, forKey: .favorites)
            recent = try values.decode([String: Date].self, forKey: .recent)
            stacks = try values.decodeIfPresent([UserStack].self, forKey: .stacks) ?? []
            collections = try values.decodeIfPresent([Collection].self, forKey: .collections) ?? []
        }
    }
''')
replace_once(store, r'''        for index in next.collections.indices { next.collections[index].sceneIDs.removeAll { removed.contains($0) } }
        try save(next)
''', r'''        for index in next.collections.indices { next.collections[index].sceneIDs.removeAll { removed.contains($0) } }
        Self.pruneStacks(&next.stacks, removing: removed)
        try save(next)
''')
replace_once(store, r'''        for i in next.collections.indices { next.collections[i].sceneIDs.removeAll { $0 == id } }
        try save(next)
    }
    @discardableResult func createCollection(name: String) throws -> Collection {
''', r'''        for i in next.collections.indices { next.collections[i].sceneIDs.removeAll { $0 == id } }
        Self.pruneStacks(&next.stacks, removing: [id])
        try save(next)
    }
    @discardableResult func createStack(name: String, sceneIDs: [String], representativeID: String? = nil) throws -> UserStack {
        let stack = UserStack(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                              sceneIDs: sceneIDs, representativeID: representativeID)
        var next = catalog
        next.stacks.append(stack)
        try save(next)
        return stack
    }
    func renameStack(_ id: String, name: String) throws {
        var next = catalog
        guard let index = next.stacks.firstIndex(where: { $0.id == id }) else { throw failure("Stack no longer exists.") }
        next.stacks[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try save(next)
    }
    func removeStack(_ id: String) throws {
        var next = catalog
        next.stacks.removeAll { $0.id == id }
        try save(next)
    }
    func setStackRepresentative(_ id: String, entryID: String?) throws {
        var next = catalog
        guard let index = next.stacks.firstIndex(where: { $0.id == id }) else { throw failure("Stack no longer exists.") }
        next.stacks[index].representativeID = entryID
        try save(next)
    }
    func moveStack(_ id: String, by offset: Int) throws {
        var next = catalog
        guard let index = next.stacks.firstIndex(where: { $0.id == id }), [-1, 1].contains(offset) else {
            throw failure("Select a stack.")
        }
        let destination = index + offset
        guard next.stacks.indices.contains(destination) else { return }
        next.stacks.swapAt(index, destination)
        try save(next)
    }
    func moveStackScene(_ sceneID: String, in stackID: String, by offset: Int) throws {
        var next = catalog
        guard let stack = next.stacks.firstIndex(where: { $0.id == stackID }),
              let index = next.stacks[stack].sceneIDs.firstIndex(of: sceneID),
              [-1, 1].contains(offset) else { throw failure("Select a stack item.") }
        let destination = index + offset
        guard next.stacks[stack].sceneIDs.indices.contains(destination) else { return }
        next.stacks[stack].sceneIDs.swapAt(index, destination)
        try save(next)
    }
    @discardableResult func createCollection(name: String) throws -> Collection {
''')
replace_once(store, r'''                catalogID: draft.catalogID, sourceID: sourceID, relativeMediaPath: path,
''', r'''                catalogID: draft.catalogID, groupID: draft.groupID, sourceID: sourceID, relativeMediaPath: path,
''')
replace_once(store, r'''                  entry.catalogID.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
                  entry.series.map({ $0.utf8.count <= 512 }) ?? true,
''', r'''                  entry.catalogID.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
                  entry.groupID.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
                  entry.series.map({ $0.utf8.count <= 512 }) ?? true,
''')
replace_once(store, r'''                      entry.sourceID == nil, entry.relativeMediaPath == nil, entry.relativePosterPath == nil,
                      entry.observation == nil else {
''', r'''                      entry.sourceID == nil, entry.relativeMediaPath == nil, entry.relativePosterPath == nil,
                      entry.groupID == nil, entry.observation == nil else {
''')
replace_once(store, r'''        try validateCollections(value)
    }

    private func validateCollections(_ value: Catalog) throws {
''', r'''        try validateStacks(value)
        try validateCollections(value)
    }

    private func validateStacks(_ value: Catalog) throws {
        let entryIDs = Set(value.entries.map(\.id))
        guard value.stacks.count <= 128,
              Set(value.stacks.map(\.id)).count == value.stacks.count,
              Set(value.stacks.map { $0.name.lowercased() }).count == value.stacks.count else {
            throw failure("Use unique stack names, with at most 128 stacks.")
        }
        var claimed = Set<String>()
        for stack in value.stacks {
            guard !stack.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  stack.name.utf8.count <= 120, !stack.id.isEmpty, stack.id.utf8.count <= 128,
                  (2...256).contains(stack.sceneIDs.count), Set(stack.sceneIDs).count == stack.sceneIDs.count,
                  stack.sceneIDs.allSatisfy({ $0.utf8.count <= 128 && entryIDs.contains($0) }),
                  stack.sceneIDs.allSatisfy({ claimed.insert($0).inserted }),
                  stack.representativeID.map({ stack.sceneIDs.contains($0) }) ?? true else {
                throw failure("Stacks need 2–256 unique Library items, exclusive membership, and an optional representative from the stack.")
            }
        }
    }

    static func pruneStacks(_ stacks: inout [UserStack], removing removed: Set<String>) {
        guard !removed.isEmpty else { return }
        for index in stacks.indices {
            stacks[index].sceneIDs.removeAll { removed.contains($0) }
            if let representative = stacks[index].representativeID, removed.contains(representative) {
                stacks[index].representativeID = nil
            }
        }
        stacks.removeAll { $0.sceneIDs.count < 2 }
    }

    private func validateCollections(_ value: Catalog) throws {
''')

print("store transformed")
