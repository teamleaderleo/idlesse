import Foundation

/// Metadata only: resolving a scene never retains decoded pixels or a player.
struct Playable: Sendable {
    enum Kind: String, Codable, Sendable { case image, video }
    struct Layer: Sendable {
        let assetURL: URL
        let kind: Kind
        let opacity: Double
    }
    let title: String
    let layers: [Layer]
    var assetURL: URL { layers[0].assetURL }
    var kind: Kind { layers.contains { $0.kind == .video } ? .video : .image }
    init(title: String, assetURL: URL, kind: Kind) {
        self.title = title
        self.layers = [Layer(assetURL: assetURL, kind: kind, opacity: 1)]
    }
    init(title: String, layers: [Layer]) { self.title = title; self.layers = layers }
}

protocol SceneSource {
    func resolve(_ url: URL) async throws -> Playable
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
        let layers: [Layer]
        struct Layer: Decodable {
            let type: Playable.Kind
            let asset: String
            let opacity: Double?
        }
    }

    func resolve(_ url: URL) async throws -> Playable {
        let task = Task.detached(priority: .userInitiated) { try Self.read(url) }
        return try await withTaskCancellationHandler(operation: {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        }, onCancel: { task.cancel() })
    }

    private static func kind(_ url: URL) throws -> Playable.Kind {
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

    private static func read(_ url: URL) throws -> Playable {
        try Task.checkCancellation()
        guard url.isFileURL else { throw SceneError.invalid("Download this scene before opening it.") }
        if url.pathExtension.lowercased() != "idlesse" {
            return Playable(title: url.deletingPathExtension().lastPathComponent, assetURL: url, kind: try kind(url))
        }
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        let manifest = try json(Manifest.self, name: "manifest.json", root: root)
        guard manifest.version == 1 else { throw SceneError.invalid("This scene uses an unsupported version.") }
        guard manifest.capabilities.isEmpty else { throw SceneError.invalid("This version cannot grant scene capabilities.") }
        let scene = try json(Scene.self, name: "scene.json", root: root)
        guard (1...2).contains(scene.layers.count) else {
            throw SceneError.invalid("Scenes support one or two layers.")
        }
        let layers = try scene.layers.map { layer -> Playable.Layer in
            let opacity = layer.opacity ?? 1
            guard opacity.isFinite, (0...1).contains(opacity) else {
                throw SceneError.invalid("Layer opacity must be between zero and one.")
            }
            let asset = try contained(layer.asset, in: root)
            guard try kind(asset) == layer.type else { throw SceneError.invalid("The asset does not match its layer type.") }
            guard try asset.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw SceneError.invalid("The scene asset is not a regular file.")
            }
            return Playable.Layer(assetURL: asset, kind: layer.type, opacity: opacity)
        }
        return Playable(title: manifest.title, layers: layers)
    }
}
