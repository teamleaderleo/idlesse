import Foundation

/// Metadata only: resolving a scene never retains decoded pixels or a player.
struct SceneDescriptor: Sendable {
    enum Kind: String, Codable, Sendable { case image, video, gradient }
    let title: String
    let nodes: [SceneNode]
    var assetURL: URL? { nodes.first?.assetURL }
    var kind: Kind { nodes.first?.kind ?? .image }
    var animated: Bool { nodes.contains { $0.kind != .image } }
    init(title: String, assetURL: URL, kind: Kind) {
        self.title = title
        self.nodes = [SceneNode(content: kind == .video ? .video(assetURL) : .image(assetURL))]
    }
    init(title: String, nodes: [SceneNode]) { self.title = title; self.nodes = nodes }
}

struct SceneNode: Sendable {
    enum Content: Sendable { case image(URL), video(URL), gradient }
    struct Transform: Decodable, Sendable {
        let x: Double?
        let y: Double?
        let scale: Double?
        let rotation: Double?
        static let identity = Transform(x: nil, y: nil, scale: nil, rotation: nil)
    }
    let content: Content
    var opacity: Double = 1
    var transform: Transform = .identity
    var kind: SceneDescriptor.Kind {
        switch content { case .image: return .image; case .video: return .video; case .gradient: return .gradient }
    }
    var assetURL: URL? {
        switch content { case .image(let url), .video(let url): return url; case .gradient: return nil }
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
            let type: SceneDescriptor.Kind
            let asset: String?
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

    private static func read(_ url: URL) throws -> SceneDescriptor {
        try Task.checkCancellation()
        guard url.isFileURL else { throw SceneError.invalid("Download this scene before opening it.") }
        if url.pathExtension.lowercased() != "idlesse" {
            return SceneDescriptor(title: url.deletingPathExtension().lastPathComponent, assetURL: url, kind: try kind(url))
        }
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        let manifest = try json(Manifest.self, name: "manifest.json", root: root)
        guard (1...2).contains(manifest.version) else { throw SceneError.invalid("This scene uses an unsupported version.") }
        guard manifest.capabilities.isEmpty else { throw SceneError.invalid("This version cannot grant scene capabilities.") }
        let scene = try json(Scene.self, name: "scene.json", root: root)
        guard (manifest.version == 1 ? scene.nodes == nil : scene.layers == nil),
              let descriptions = manifest.version == 1 ? scene.layers : scene.nodes,
              (1...2).contains(descriptions.count) else {
            throw SceneError.invalid("Use one or two layers in v1, or nodes in v2.")
        }
        let nodes = try descriptions.map { node -> SceneNode in
            let opacity = node.opacity ?? 1
            let transform = node.transform ?? .identity
            guard opacity.isFinite, (0...1).contains(opacity),
                  [transform.x ?? 0, transform.y ?? 0, transform.rotation ?? 0, transform.scale ?? 1].allSatisfy({ $0.isFinite }),
                  abs(transform.x ?? 0) <= 2, abs(transform.y ?? 0) <= 2,
                  (0.05...4).contains(transform.scale ?? 1), abs(transform.rotation ?? 0) <= 360 else {
                throw SceneError.invalid("Invalid opacity or transform; use finite values within the scene limits.")
            }
            let content: SceneNode.Content
            if node.type == .gradient {
                guard manifest.version == 2, node.asset == nil else { throw SceneError.invalid("Gradient nodes require v2 and no asset.") }
                content = .gradient
            } else {
                guard let path = node.asset else { throw SceneError.invalid("Media nodes need an asset.") }
                let asset = try contained(path, in: root)
                guard try kind(asset) == node.type else { throw SceneError.invalid("The asset does not match its node type.") }
                guard try asset.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw SceneError.invalid("The scene asset is not a regular file.")
                }
                content = node.type == .video ? .video(asset) : .image(asset)
            }
            return SceneNode(content: content, opacity: opacity, transform: transform)
        }
        return SceneDescriptor(title: manifest.title, nodes: nodes)
    }
}
