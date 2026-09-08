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
    var id = UUID() // Document-local identity, preserved by edits and undo.
    enum Content: Sendable { case image(URL), video(URL), gradient }
    struct Transform: Decodable, Sendable {
        let x: Double?
        let y: Double?
        let scale: Double?
        let rotation: Double?
        static let identity = Transform(x: nil, y: nil, scale: nil, rotation: nil)
    }
    var name: String? = nil
    var displayName: String { name ?? assetURL?.deletingPathExtension().lastPathComponent ?? "Gradient" }
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
            let name: String?
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

    fileprivate static func read(_ url: URL) throws -> SceneDescriptor {
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
            return SceneNode(name: node.name.map { String($0.prefix(120)) }, content: content, opacity: opacity, transform: transform)
        }
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
        var nodes: [[String: Any]] = []
        for (index, node) in scene.nodes.enumerated() {
            try Task.checkCancellation()
            var json: [String: Any] = ["type": node.kind.rawValue, "opacity": node.opacity,
                "transform": ["x": node.transform.x ?? 0, "y": node.transform.y ?? 0,
                              "scale": node.transform.scale ?? 1, "rotation": node.transform.rotation ?? 0]]
            if let name = node.name { json["name"] = name }
            if let source = node.assetURL {
                let root = destination.resolvingSymlinksInPath().path + "/"
                let path = source.resolvingSymlinksInPath().path
                let relative: String
                if expected != nil, path.hasPrefix(root) {
                    relative = String(path.dropFirst(root.count))
                } else {
                    relative = "assets/\(UUID().uuidString)-\(index).\(source.pathExtension.lowercased())"
                    try files.copyItem(at: source, to: staging.appendingPathComponent(relative))
                }
                json["asset"] = relative
            }
            nodes.append(json)
        }
        for (name, json) in [("manifest.json", ["version": 2, "title": scene.title, "capabilities": []] as [String: Any]),
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
            let retained = Set(nodes.compactMap { $0["asset"] as? String })
            for asset in previous.nodes.compactMap({ $0.assetURL }) {
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
        order.append(index)
    }
    return order
}
