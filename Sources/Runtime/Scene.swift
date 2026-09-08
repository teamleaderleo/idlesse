import Foundation

/// Metadata only: resolving a scene never retains decoded pixels or a player.
struct SceneDescriptor: Sendable {
    enum Kind: String, Codable, Sendable { case image, video, gradient, group }
    let title: String
    let nodes: [SceneNode]
    var assetURL: URL? { nodes.first?.assetURL }
    var kind: Kind { nodes.first?.kind ?? .image }
    var allNodes: [SceneNode] { nodes.flatMap { $0.descendants } }
    var requiresMetal: Bool { allNodes.contains { $0.style != .plain } }
    var animated: Bool { nodes.contains { $0.animated } }
    init(title: String, assetURL: URL, kind: Kind) {
        self.title = title
        self.nodes = [SceneNode(content: kind == .video ? .video(assetURL) : .image(assetURL))]
    }
    init(title: String, nodes: [SceneNode]) { self.title = title; self.nodes = nodes }
}

struct SceneNode: Sendable {
    var id = UUID() // Document-local identity, preserved by edits and undo.
    indirect enum Content: Sendable { case image(URL), video(URL), gradient, group([SceneNode]) }
    struct Transform: Decodable, Sendable {
        let x: Double?
        let y: Double?
        let scale: Double?
        let rotation: Double?
        static let identity = Transform(x: nil, y: nil, scale: nil, rotation: nil)
    }
    struct Style: Codable, Sendable, Equatable {
        enum Mask: String, Codable, Sendable { case ellipse }
        var mask: Mask? = nil
        var exposure: Double = 0
        var saturation: Double = 1
        var vignette: Double = 0
        static let plain = Style()
        init(mask: Mask? = nil, exposure: Double = 0, saturation: Double = 1, vignette: Double = 0) {
            self.mask = mask; self.exposure = exposure; self.saturation = saturation; self.vignette = vignette
        }
        enum CodingKeys: String, CodingKey { case mask, exposure, saturation, vignette }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            mask = try values.decodeIfPresent(Mask.self, forKey: .mask)
            exposure = try values.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
            saturation = try values.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
            vignette = try values.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        }
    }
    var style: Style = .plain
    var name: String? = nil
    var displayName: String { name ?? assetURL?.deletingPathExtension().lastPathComponent ?? (kind == .group ? "Group" : "Gradient") }
    var content: Content
    var visible = true
    var locked = false
    var opacity: Double = 1
    var transform: Transform = .identity
    var kind: SceneDescriptor.Kind {
        switch content { case .image: return .image; case .video: return .video; case .gradient: return .gradient; case .group: return .group }
    }
    var children: [SceneNode] { if case .group(let nodes) = content { return nodes }; return [] }
    var descendants: [SceneNode] { [self] + children.flatMap { $0.descendants } }
    var animated: Bool { visible && (kind == .group ? children.contains { $0.animated } : kind != .image) }
    func duplicated() -> SceneNode {
        var copy = self
        copy.id = UUID()
        if kind == .group { copy.content = .group(children.map { $0.duplicated() }) }
        return copy
    }
    var assetURL: URL? {
        switch content { case .image(let url), .video(let url): return url; case .gradient, .group: return nil }
    }
}

protocol SceneSource {
    func resolve(_ url: URL) async throws -> SceneDescriptor
}

enum SceneError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

struct LocalSceneSource: SceneSource {
    private struct Manifest: Decodable {
        let version: Int
        let title: String
        let capabilities: [String]
    }
    private struct Scene: Decodable {
        let layers: [Node]?
        let nodes: [Node]?
        struct Node: Decodable {
            let style: SceneNode.Style?
            let children: [Node]?
            let name: String?
            let type: SceneDescriptor.Kind
            let asset: String?
            let visible: Bool?
            let locked: Bool?
            let opacity: Double?
            let transform: SceneNode.Transform?
        }
    }

    func resolve(_ url: URL) async throws -> SceneDescriptor {
        let task = Task.detached(priority: .userInitiated) { try Self.read(url) }
        return try await withTaskCancellationHandler(operation: {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        }, onCancel: { task.cancel() })
    }

    private static func kind(_ url: URL) throws -> SceneDescriptor.Kind {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic": return .image
        case "mp4", "mov": return .video
        default: throw SceneError.invalid("Choose an image, MP4, MOV, or .idlesse scene.")
        }
    }

    private static func contained(_ path: String, in root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":") else {
            throw SceneError.invalid("Scene assets must use relative paths inside the package.")
        }
        let resolved = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/") else {
            throw SceneError.invalid("A scene file points outside its package.")
        }
        return resolved
    }

    private static func json<T: Decodable>(_ type: T.Type, name: String, root: URL) throws -> T {
        try Task.checkCancellation()
        let url = try contained(name, in: root)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536 else { throw SceneError.invalid("Scene JSON exceeds 64 KB.") }
        return try JSONDecoder().decode(type, from: data)
    }

    fileprivate static func read(_ url: URL) throws -> SceneDescriptor {
        try Task.checkCancellation()
        guard url.isFileURL else { throw SceneError.invalid("Download this scene before opening it.") }
        if url.pathExtension.lowercased() != "idlesse" {
            return SceneDescriptor(title: url.deletingPathExtension().lastPathComponent, assetURL: url, kind: try kind(url))
        }
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        let manifest = try json(Manifest.self, name: "manifest.json", root: root)
        guard (1...5).contains(manifest.version) else { throw SceneError.invalid("This scene uses an unsupported version.") }
        guard manifest.capabilities.isEmpty else { throw SceneError.invalid("This version cannot grant scene capabilities.") }
        let scene = try json(Scene.self, name: "scene.json", root: root)
        guard (manifest.version == 1 ? scene.nodes == nil : scene.layers == nil),
              let descriptions = manifest.version == 1 ? scene.layers : scene.nodes,
              (1...SceneBudget.maxNodes).contains(descriptions.count) else {
            throw SceneError.invalid("Use 1–16 layers in v1, or nodes in v2 and later.")
        }
        func decode(_ node: Scene.Node, depth: Int) throws -> SceneNode {
            guard depth <= SceneBudget.maxGroupDepth else { throw SceneError.invalid("Groups may nest at most two levels deep.") }
            let opacity = node.opacity ?? 1
            let transform = node.transform ?? .identity
            guard opacity.isFinite, (0...1).contains(opacity),
                  [transform.x ?? 0, transform.y ?? 0, transform.rotation ?? 0, transform.scale ?? 1].allSatisfy({ $0.isFinite }),
                  abs(transform.x ?? 0) <= 2, abs(transform.y ?? 0) <= 2,
                  (0.05...4).contains(transform.scale ?? 1), abs(transform.rotation ?? 0) <= 360 else {
                throw SceneError.invalid("Invalid opacity or transform; use finite values within the scene limits.")
            }
            let content: SceneNode.Content
            if node.type == .group {
                guard manifest.version >= 3, node.asset == nil, let children = node.children, !children.isEmpty else {
                    throw SceneError.invalid("Groups require v3 or later, nonempty children, and no asset.")
                }
                content = .group(try children.map { try decode($0, depth: depth + 1) })
            } else if node.type == .gradient {
                guard node.children == nil, manifest.version >= 2, node.asset == nil else { throw SceneError.invalid("Gradient nodes require v2 and no asset.") }
                content = .gradient
            } else {
                guard node.children == nil, let path = node.asset else { throw SceneError.invalid("Media nodes need an asset.") }
                let asset = try contained(path, in: root)
                guard try kind(asset) == node.type else { throw SceneError.invalid("The asset does not match its node type.") }
                guard try asset.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw SceneError.invalid("The scene asset is not a regular file.")
                }
                content = node.type == .video ? .video(asset) : .image(asset)
            }
            guard node.style == nil || manifest.version >= 4 else { throw SceneError.invalid("Masks and color effects require scene version 4.") }
            guard (node.style?.vignette ?? 0) == 0 || manifest.version >= 5 else { throw SceneError.invalid("Vignette requires scene version 5.") }
            return SceneNode(style: node.style ?? .plain, name: node.name.map { String($0.prefix(120)) }, content: content, visible: node.visible ?? true, locked: node.locked ?? false, opacity: opacity, transform: transform)
        }
        let nodes = try descriptions.map { try decode($0, depth: 0) }
        try SceneBudget.validate(nodes)
        return SceneDescriptor(title: manifest.title, nodes: nodes)
    }
}

/// Writes a self-contained copy, leaving the source package and its assets untouched.
enum ScenePackageWriter {
    struct Revision: Equatable, Sendable {
        let manifest: Data
        let scene: Data
        let files: [String]
    }
    static func revision(of package: URL) throws -> Revision {
        let files = FileManager.default
        guard let entries = files.enumerator(at: package, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey]) else {
            throw SceneError.invalid("The scene package is no longer available.")
        }
        var records: [String] = []
        for case let url as URL in entries {
            guard records.count < 10_000 else { throw SceneError.invalid("This package contains too many files to edit safely.") }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey])
            records.append("\(url.path.replacingOccurrences(of: package.path, with: ""))|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)|\(values.isSymbolicLink ?? false)")
        }
        func json(_ name: String) throws -> Data {
            let handle = try FileHandle(forReadingFrom: package.appendingPathComponent(name))
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536 else { throw SceneError.invalid("Scene JSON exceeds 64 KB.") }
            return data
        }
        return try Revision(manifest: json("manifest.json"), scene: json("scene.json"), files: records.sorted())
    }
    static func write(_ scene: SceneDescriptor, to destination: URL, replacing expected: Revision? = nil) throws {
        try SceneBudget.validate(scene.nodes)
        let files = FileManager.default
        guard destination.isFileURL, destination.pathExtension.lowercased() == "idlesse",
              expected != nil || !files.fileExists(atPath: destination.path) else {
            throw SceneError.invalid("Choose a new .idlesse package name; existing files are never replaced.")
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".idlesse-\(UUID().uuidString).idlesse")
        defer { try? files.removeItem(at: staging) }
        if let expected {
            guard try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  try revision(of: destination) == expected else {
                throw SceneError.invalid("The package changed outside Studio. Reopen it or use Save As to keep both versions.")
            }
            try files.copyItem(at: destination, to: staging)
        }
        let assetsDirectory = staging.appendingPathComponent("assets")
        if files.fileExists(atPath: assetsDirectory.path),
           try assetsDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw SceneError.invalid("The package assets folder must be a real directory.")
        }
        try files.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        var retained = Set<String>()
        func encode(_ node: SceneNode) throws -> [String: Any] {
            try Task.checkCancellation()
            var json: [String: Any] = ["type": node.kind.rawValue, "opacity": node.opacity, "visible": node.visible, "locked": node.locked,
                "transform": ["x": node.transform.x ?? 0, "y": node.transform.y ?? 0,
                              "scale": node.transform.scale ?? 1, "rotation": node.transform.rotation ?? 0]]
            if let name = node.name { json["name"] = name }
            if node.style != .plain {
                json["style"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(node.style))
            }
            if let source = node.assetURL {
                let root = destination.resolvingSymlinksInPath().path + "/"
                let path = source.resolvingSymlinksInPath().path
                let relative: String
                if expected != nil, path.hasPrefix(root) {
                    relative = String(path.dropFirst(root.count))
                } else {
                    relative = "assets/\(UUID().uuidString).\(source.pathExtension.lowercased())"
                    try files.copyItem(at: source, to: staging.appendingPathComponent(relative))
                }
                json["asset"] = relative
                retained.insert(relative)
            }
            if node.kind == .group { json["children"] = try node.children.map(encode) }
            return json
        }
        let nodes = try scene.nodes.map(encode)
        for (name, json) in [("manifest.json", ["version": scene.allNodes.contains { $0.style.vignette != 0 } ? 5 : scene.requiresMetal ? 4 : scene.allNodes.contains { $0.kind == .group } ? 3 : 2, "title": scene.title, "capabilities": []] as [String: Any]),
                             ("scene.json", ["nodes": nodes])] {
            try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                .write(to: staging.appendingPathComponent(name), options: .atomic)
        }
        try Task.checkCancellation()
        _ = try LocalSceneSource.read(staging)
        if let expected {
            guard try revision(of: destination) == expected else {
                throw SceneError.invalid("The package changed while saving. Your draft is intact; use Save As or reopen it.")
            }
            // Remove only media referenced by the previous supported scene and deleted
            // by this edit. Preserve ancillary files, previews, and unrelated assets.
            let previous = try LocalSceneSource.read(destination)
            let root = destination.resolvingSymlinksInPath().path + "/"
            for asset in previous.allNodes.compactMap({ $0.assetURL }) {
                let path = asset.resolvingSymlinksInPath().path
                if path.hasPrefix(root) {
                    let relative = String(path.dropFirst(root.count))
                    if !retained.contains(relative) { try? files.removeItem(at: staging.appendingPathComponent(relative)) }
                }
            }
            _ = try LocalSceneSource.read(staging)
            let backup = ".idlesse-recovery-\(UUID().uuidString).idlesse"
            do {
                _ = try files.replaceItemAt(destination, withItemAt: staging, backupItemName: backup)
            } catch {
                let recovery = destination.deletingLastPathComponent().appendingPathComponent(backup)
                if files.fileExists(atPath: recovery.path) {
                    throw SceneError.invalid("Save failed. A recovery copy is at \(recovery.path). \(error.localizedDescription)")
                }
                throw error
            }
        } else {
            try files.moveItem(at: staging, to: destination)
        }
    }
}

/// Returns old resource indices in the new drawing order, only for metadata edits.
func sceneResourceOrder(from old: [SceneNode], to new: [SceneNode]) -> [Int]? {
    guard old.count == new.count, Set(old.map { $0.id }).count == old.count,
          Set(new.map { $0.id }).count == new.count else { return nil }
    var order: [Int] = []
    for node in new {
        guard let index = old.firstIndex(where: { $0.id == node.id }),
              old[index].kind == node.kind, old[index].assetURL == node.assetURL else { return nil }
        if node.kind == .group, sceneResourceOrder(from: old[index].children, to: node.children) == nil { return nil }
        order.append(index)
    }
    return order
}

/// Per-display retained image allowance; video decoder and drawable memory are separate.
enum SceneBudget {
    static let maxGroups = 4
    static let maxGroupDepth = 2
    static let intermediateTextureBytes = 128 * 1024 * 1024
    static let maxNodes = 16
    static let maxVideos = 2
    static let maxGradients = 4
    static let decodedImagePixels = 32_000_000
    static func validate(_ roots: [SceneNode]) throws {
        func walk(_ nodes: [SceneNode], depth: Int) throws -> [SceneNode] {
            guard depth <= maxGroupDepth else { throw SceneError.invalid("Groups may nest at most two levels deep.") }
            var result: [SceneNode] = []
            for node in nodes {
                guard node.style.exposure.isFinite, (-2...2).contains(node.style.exposure),
                      node.style.saturation.isFinite, (0...2).contains(node.style.saturation),
                      node.style.vignette.isFinite, (0...1).contains(node.style.vignette) else {
                    throw SceneError.invalid("Use exposure −2…2, saturation 0…2 and vignette 0…1.")
                }
                result.append(node)
                if node.kind == .group {
                    guard !node.children.isEmpty else { throw SceneError.invalid("Groups need at least one child.") }
                    result += try walk(node.children, depth: depth + 1)
                }
            }
            return result
        }
        let nodes = try walk(roots, depth: 0)
        guard Set(nodes.map { $0.id }).count == nodes.count else { throw SceneError.invalid("Scene layer identities must be unique.") }
        guard nodes.filter({ $0.kind == .group }).count <= maxGroups else { throw SceneError.invalid("A scene supports at most four groups.") }
        guard (1...maxNodes).contains(nodes.count) else { throw SceneError.invalid("A scene supports 1–16 layers.") }
        guard nodes.filter({ $0.kind == .video }).count <= maxVideos else { throw SceneError.invalid("A scene supports at most two video layers, including hidden layers.") }
        guard nodes.filter({ $0.kind == .gradient }).count <= maxGradients else { throw SceneError.invalid("A scene supports at most four gradient layers, including hidden layers.") }
    }
    /// Two in-flight frames share a fixed byte allowance. Larger group surfaces
    /// are reduced uniformly; images/video assets themselves are never rewritten.
    static func groupTargetSize(width: Double, height: Double, count: Int) -> (width: Int, height: Int)? {
        guard width.isFinite, height.isFinite, width >= 1, height >= 1, (1...maxGroups).contains(count) else { return nil }
        let pixels = Double(intermediateTextureBytes / (2 * count) - 65_536) / 4
        let scale = min(1, 16384 / max(width, height), sqrt(pixels / width / height))
        return (max(1, Int(floor(width * scale))), max(1, Int(floor(height * scale))))
    }
    static func imagePixels(_ nodes: [SceneNode]) -> Int {
        min(16_000_000, decodedImagePixels / max(1, nodes.flatMap { $0.descendants }.filter { $0.kind == .image }.count))
    }
}

/// Tree edits retain node identity so renderers can keep media resources alive.
enum SceneTree {
    static func siblings(of id: UUID, in nodes: [SceneNode]) -> [SceneNode]? {
        if nodes.contains(where: { $0.id == id }) { return nodes }
        for node in nodes { if let found = siblings(of: id, in: node.children) { return found } }
        return nil
    }
    static func edit(_ id: UUID, in nodes: inout [SceneNode], _ body: (inout [SceneNode], Int) -> Void) -> Bool {
        if let index = nodes.firstIndex(where: { $0.id == id }) { body(&nodes, index); return true }
        for index in nodes.indices where nodes[index].kind == .group {
            var children = nodes[index].children
            if edit(id, in: &children, body) { nodes[index].content = .group(children); return true }
        }
        return false
    }
}
