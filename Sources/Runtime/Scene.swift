import Foundation

/// Metadata only: resolving a scene never retains decoded pixels or a player.
struct Playable: Sendable {
    enum Kind: String, Codable, Sendable { case image, video }
    let title: String
    let assetURL: URL
    let kind: Kind
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
        guard scene.layers.count == 1, let layer = scene.layers.first else {
            throw SceneError.invalid("Version 1 scenes need exactly one image or video layer.")
        }
        let asset = try contained(layer.asset, in: root)
        guard try kind(asset) == layer.type else { throw SceneError.invalid("The asset does not match its layer type.") }
        guard try asset.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw SceneError.invalid("The scene asset is not a regular file.")
        }
        return Playable(title: manifest.title, assetURL: asset, kind: layer.type)
    }
}
