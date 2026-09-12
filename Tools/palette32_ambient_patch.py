from pathlib import Path


def replace(path, old, new, count=1):
    p = Path(path)
    s = p.read_text()
    n = s.count(old)
    if n < count:
        raise SystemExit(f"{path}: expected {count}, found {n}: {old[:100]!r}")
    p.write_text(s.replace(old, new, count))

path = "Sources/Wallpaper/AmbientSet.swift"
replace(path, '''struct AmbientWallpaperTarget: Codable, Equatable, Hashable {
    static let maxIdentifierLength = 256

    enum Kind: String, Codable { case scene, collection }
    var kind: Kind
    var id: String

    var isValid: Bool { !id.isEmpty && id.count <= Self.maxIdentifierLength }

    static func scene(_ id: String) -> Self { .init(kind: .scene, id: id) }
    static func collection(_ id: String) -> Self { .init(kind: .collection, id: id) }
}
''', '''struct AmbientWallpaperTarget: Codable, Equatable, Hashable {
    static let maxIdentifierLength = 256

    enum Kind: String, Codable { case scene, collection }
    var kind: Kind
    var id: String
    /// Requested named scene variant. Collections carry their own per-item selections.
    var variantID: UUID? = nil

    var isValid: Bool {
        !id.isEmpty && id.count <= Self.maxIdentifierLength && (kind == .scene || variantID == nil)
    }

    static func scene(_ id: String) -> Self { .init(kind: .scene, id: id) }
    static func scene(_ id: String, variantID: UUID?) -> Self {
        .init(kind: .scene, id: id, variantID: variantID)
    }
    static func collection(_ id: String) -> Self { .init(kind: .collection, id: id) }

    enum CodingKeys: String, CodingKey { case kind, id, variantID }
    init(kind: Kind, id: String, variantID: UUID? = nil) {
        self.kind = kind; self.id = id; self.variantID = variantID
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(Kind.self, forKey: .kind)
        id = try values.decode(String.self, forKey: .id)
        variantID = try values.decodeIfPresent(UUID.self, forKey: .variantID)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(variantID, forKey: .variantID)
    }
}
''')

test = "Tests/AmbientSetTests.swift"
s = Path(test).read_text()
marker = '''        // Sparse overrides inherit the arrangement default.
'''
block = '''        // Scene targets persist an explicit variant reference; legacy targets decode as Default.
        do {
            let midnight = UUID()
            let target = AmbientWallpaperTarget.scene("undertow", variantID: midnight)
            let decoded = try JSONDecoder().decode(AmbientWallpaperTarget.self, from: JSONEncoder().encode(target))
            expect(decoded == target, "scene variant reference did not round-trip")
            let legacy = Data(#"{"kind":"scene","id":"undertow"}"#.utf8)
            let legacyTarget = try JSONDecoder().decode(AmbientWallpaperTarget.self, from: legacy)
            expect(legacyTarget == .scene("undertow"), "legacy Ambient scene target did not decode as Default")
            expect(!AmbientWallpaperTarget(kind: .collection, id: "c1", variantID: midnight).isValid,
                   "collection target accepted a direct variant instead of its per-item selections")
        }

'''
if marker not in s:
    raise SystemExit("Ambient test marker missing")
Path(test).write_text(s.replace(marker, block + marker, 1))

docs = Path("docs/ambient-sets-actuation.md")
text = docs.read_text()
if "Named scene variants" not in text:
    docs.write_text(text + '''\n\n## Named scene variants\n\nA scene wallpaper target carries an optional requested variant UUID. Legacy targets without it decode as Default. The UUID is part of the target value and therefore survives resolution even while the referenced scene or variant is temporarily unavailable; collection targets continue to inherit each collection item's own scene+variant selection. Runtime application becomes a direct variant-aware wallpaper selection when the #32 host stack is reconciled with this branch.\n''')
