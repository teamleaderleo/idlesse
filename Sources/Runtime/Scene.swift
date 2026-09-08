import Foundation

struct SceneTimeline: Codable, Sendable, Equatable {
    enum Mode: String, Codable, Sendable { case once, loop, pingPong }
    var duration: Double
    var mode: Mode
    var rate: Double = 1
    var videosFollowScene: Bool = false
    enum CodingKeys: String, CodingKey { case duration, mode, rate, videosFollowScene }
    init(duration: Double, mode: Mode, rate: Double = 1, videosFollowScene: Bool = false) {
        self.duration = duration; self.mode = mode; self.rate = rate; self.videosFollowScene = videosFollowScene
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        duration = try values.decode(Double.self, forKey: .duration)
        mode = try values.decode(Mode.self, forKey: .mode)
        rate = try values.decodeIfPresent(Double.self, forKey: .rate) ?? 1
        videosFollowScene = try values.decodeIfPresent(Bool.self, forKey: .videosFollowScene) ?? false
    }
    func validate() throws {
        guard !videosFollowScene || mode != .pingPong else {
            throw SceneError.invalid("Video transport supports Once and Loop. Disable video following to use Ping-pong.")
        }
        guard duration.isFinite, (0.01...86400).contains(duration),
              rate.isFinite, (0.1...4).contains(rate) else {
            throw SceneError.invalid("Use a duration of 0.01–86400 seconds and speed of 0.1–4.")
        }
    }
}


/// Metadata only: resolving a scene never retains decoded pixels or a player.
struct SceneDescriptor: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case image, video, gradient, group }
    let title: String
    let nodes: [SceneNode]
    var parameters: [String: SceneParameter] = [:]
    var bindings: [SceneParameterBinding] = []
    var timeline: SceneTimeline? = nil
    var assetURL: URL? { nodes.first?.assetURL }
    var kind: Kind { nodes.first?.kind ?? .image }
    var allNodes: [SceneNode] { nodes.flatMap { $0.descendants } }
    var usesSmoothing: Bool { bindings.contains { $0.smoothing > 0 } }
    var usesTracks: Bool { bindings.contains { $0.keyframes != nil } }
    var usesSignals: Bool { usesTracks || bindings.contains { $0.signal != nil } }
    var usesDrivers: Bool { bindings.contains { !$0.modifiers.isEmpty } }
    var usesPointer: Bool { bindings.contains { $0.signal == .pointerX || $0.signal == .pointerY } }
    var usesTime: Bool { usesTracks || bindings.contains { $0.signal == .time || $0.signal == .sine } }
    var requiresMetal: Bool { timeline != nil || usesDrivers || usesSignals || allNodes.contains { $0.style != .plain } || bindings.contains { [.exposure, .saturation, .vignette].contains($0.target.property) } }
    var animated: Bool { usesSignals || nodes.contains { $0.animated } }
    init(title: String, assetURL: URL, kind: Kind) {
        self.title = title
        self.nodes = [SceneNode(content: kind == .video ? .video(assetURL) : .image(assetURL))]
    }
    init(title: String, nodes: [SceneNode], parameters: [String: SceneParameter] = [:], bindings: [SceneParameterBinding] = [], timeline: SceneTimeline? = nil) {
        self.title = title; self.nodes = nodes; self.parameters = parameters; self.bindings = bindings; self.timeline = timeline
    }
    func replacingNodes(_ nodes: [SceneNode]) -> SceneDescriptor {
        let ids = Set(nodes.flatMap { $0.descendants }.map(\.id))
        return SceneDescriptor(title: title, nodes: nodes, parameters: parameters, bindings: bindings.filter { ids.contains($0.target.nodeID) }, timeline: timeline)
    }
    func evaluated(signals: SceneSignals = .init(), validating: Bool = true, smooth: ((ScenePropertyAddress, Double, Double) -> Double)? = nil) throws -> SceneDescriptor {
        if validating {
            try timeline?.validate()
            guard parameters.count <= 16, bindings.count <= 64 else { throw SceneError.invalid("Use at most 16 parameters and 64 bindings.") }
            for (id, parameter) in parameters {
                guard !id.isEmpty, id.utf8.count <= 64, !parameter.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, parameter.name.count <= 80,
                      [parameter.value, parameter.min, parameter.max].allSatisfy({ $0.isFinite }),
                      (parameter.max - parameter.min).isFinite,
                      parameter.min < parameter.max, (parameter.min...parameter.max).contains(parameter.value) else {
                    throw SceneError.invalid("Parameters need a name, finite limits, and a default within their range.")
                }
            }
        }
        var result = nodes
        var targets = Set<String>()
        for binding in bindings {
            guard binding.scale.isFinite, binding.offset.isFinite,
                  (!validating || targets.insert(binding.target.nodeID.uuidString + binding.target.property.rawValue).inserted) else {
                throw SceneError.invalid("Bindings need an existing parameter and a unique property target.")
            }
            guard binding.smoothing.isFinite, (0...5).contains(binding.smoothing),
                  binding.smoothing == 0 || binding.signal != nil || binding.keyframes != nil else {
                throw SceneError.invalid("Smoothing needs a signal or keyframe source and a duration of 0–5 seconds.")
            }
            let source: Double
            if let track = binding.keyframes {
                guard binding.signal == nil, binding.parameter.isEmpty else { throw SceneError.invalid("A keyframe track cannot also have a signal or parameter source.") }
                source = try track.sample(at: signals.time, validating: validating)
            } else if let signal = binding.signal {
                guard binding.parameter.isEmpty, binding.period.isFinite, (0.1...86400).contains(binding.period) else {
                    throw SceneError.invalid("Signal bindings need a period of 0.1–86400 seconds and no parameter source.")
                }
                switch signal {
                case .time: source = signals.time
                case .sine: source = sin(signals.time.truncatingRemainder(dividingBy: binding.period) / binding.period * 2 * .pi)
                case .pointerX: source = signals.pointerX
                case .pointerY: source = signals.pointerY
                }
            } else {
                guard let parameter = parameters[binding.parameter] else { throw SceneError.invalid("The binding parameter does not exist.") }
                source = parameter.value
            }
            var raw = source * binding.scale + binding.offset
            guard binding.modifiers.count <= 8 else { throw SceneError.invalid("Use at most eight modifiers per binding.") }
            for modifier in binding.modifiers {
                guard raw.isFinite else { throw SceneError.invalid("The binding result is not finite.") }
                let operand: Double
                if let key = modifier.parameter {
                    guard modifier.value == nil, let parameter = parameters[key] else {
                        throw SceneError.invalid("A modifier needs one existing parameter or constant.")
                    }
                    operand = parameter.value
                } else {
                    guard let value = modifier.value else { throw SceneError.invalid("A modifier needs an operand.") }
                    operand = value
                }
                guard operand.isFinite else { throw SceneError.invalid("Modifier operands must be finite.") }
                switch modifier.operation {
                case .multiply: raw *= operand
                case .add: raw += operand
                }
            }
            guard raw.isFinite else { throw SceneError.invalid("The binding result is not finite.") }
            if binding.smoothing > 0, let smooth { raw = smooth(binding.target, raw, binding.smoothing) }
            let range = binding.target.property.range
            try binding.target.set(Swift.min(range.upperBound, Swift.max(range.lowerBound, raw)), in: &result)
        }
        if validating { try SceneBudget.validate(result) }
        return SceneDescriptor(title: title, nodes: result)
    }
}

struct SceneParameter: Codable, Sendable, Equatable {
    var name: String
    var value: Double
    var min: Double
    var max: Double
    enum CodingKeys: String, CodingKey { case name, value = "default", min, max }
}

struct SceneKeyframeTrack: Codable, Sendable, Equatable {
    enum Interpolation: String, Codable, Sendable { case hold, linear, easeInOut }
    struct Key: Codable, Sendable, Equatable { var time: Double; var value: Double }
    var interpolation: Interpolation = .linear
    var keys: [Key]
    func movingKey(at index: Int, to time: Double) throws -> SceneKeyframeTrack {
        _ = try sample(at: 0)
        guard keys.indices.contains(index), time.isFinite else { throw SceneError.invalid("Choose an existing key and finite time.") }
        let lower = index == 0 ? 0 : keys[index - 1].time.nextUp
        let upper = index == keys.count - 1 ? 86400 : keys[index + 1].time.nextDown
        var result = self
        result.keys[index].time = min(upper, max(lower, time))
        return result
    }
    func sample(at time: Double, validating: Bool = true) throws -> Double {
        guard !keys.isEmpty, keys.count <= 128, time.isFinite else { throw SceneError.invalid("A track needs 1–128 keys and a finite sample time.") }
        if validating {
            var previous = -1.0
            for key in keys {
                guard key.time.isFinite, (0...86400).contains(key.time), key.time > previous,
                      key.value.isFinite, abs(key.value) <= 1_000_000 else {
                    throw SceneError.invalid("Key times must increase within 0–86400 seconds; values must be finite and within ±1000000.")
                }
                previous = key.time
            }
        }
        guard time > keys[0].time else { return keys[0].value }
        for index in 1..<keys.count where time < keys[index].time {
            let a = keys[index - 1], b = keys[index]
            var t = (time - a.time) / (b.time - a.time)
            switch interpolation {
            case .hold: t = 0
            case .linear: break
            case .easeInOut: t = t * t * (3 - 2 * t)
            }
            return a.value + (b.value - a.value) * t
        }
        return keys[keys.count - 1].value
    }
}

struct SceneParameterBinding: Codable, Sendable {
    struct Modifier: Codable, Sendable {
        enum Operation: String, Codable, Sendable { case multiply, add }
        var operation: Operation
        var parameter: String? = nil
        var value: Double? = nil
    }
    enum Signal: String, Codable, Sendable { case time, sine, pointerX = "pointer.x", pointerY = "pointer.y" }
    let target: ScenePropertyAddress
    var parameter: String = ""
    var scale: Double = 1
    var offset: Double = 0
    var signal: Signal? = nil
    var period: Double = 8
    var smoothing: Double = 0
    var keyframes: SceneKeyframeTrack? = nil
    var modifiers: [Modifier] = []
    var referencedParameters: [String] { (parameter.isEmpty ? [] : [parameter]) + modifiers.compactMap(\.parameter) }
    enum CodingKeys: String, CodingKey { case target, parameter, scale, offset, signal, period, modifiers, keyframes, smoothing }
    init(target: ScenePropertyAddress, parameter: String = "", scale: Double = 1, offset: Double = 0, signal: Signal? = nil, period: Double = 8, modifiers: [Modifier] = [], keyframes: SceneKeyframeTrack? = nil, smoothing: Double = 0) {
        self.target = target; self.parameter = parameter; self.scale = scale; self.offset = offset; self.signal = signal; self.period = period
        self.modifiers = modifiers; self.keyframes = keyframes; self.smoothing = smoothing
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        target = try values.decode(ScenePropertyAddress.self, forKey: .target)
        parameter = try values.decodeIfPresent(String.self, forKey: .parameter) ?? ""
        scale = try values.decode(Double.self, forKey: .scale)
        offset = try values.decode(Double.self, forKey: .offset)
        signal = try values.decodeIfPresent(Signal.self, forKey: .signal)
        period = try values.decodeIfPresent(Double.self, forKey: .period) ?? 8
        smoothing = try values.decodeIfPresent(Double.self, forKey: .smoothing) ?? 0
        keyframes = try values.decodeIfPresent(SceneKeyframeTrack.self, forKey: .keyframes)
        modifiers = try values.decodeIfPresent([Modifier].self, forKey: .modifiers) ?? []
    }
}

struct SceneSignals: Sendable {
    var time: Double = 0
    var pointerX: Double = 0
    var pointerY: Double = 0
}

struct SceneNode: Codable, Sendable {
    var id = UUID() // Persisted in v6 packages; duplication assigns fresh identities.
    indirect enum Content: Codable, Sendable { case image(URL), video(URL), gradient, group([SceneNode]) }
    struct Transform: Codable, Sendable {
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
        let parameters: [String: SceneParameter]?
        let bindings: [SceneParameterBinding]?
        let timeline: SceneTimeline?
        let layers: [Node]?
        let nodes: [Node]?
        struct Node: Decodable {
            let id: UUID?
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
        guard (1...13).contains(manifest.version) else { throw SceneError.invalid("This scene uses an unsupported version.") }
        guard manifest.capabilities.isEmpty || (manifest.version >= 8 && manifest.capabilities == ["pointer"]) else { throw SceneError.invalid("Unsupported scene capability.") }
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
            guard manifest.version < 6 || node.id != nil else { throw SceneError.invalid("Every v6 node needs a UUID id.") }
            return SceneNode(id: manifest.version >= 6 ? node.id! : UUID(), style: node.style ?? .plain, name: node.name.map { String($0.prefix(120)) }, content: content, visible: node.visible ?? true, locked: node.locked ?? false, opacity: opacity, transform: transform)
        }
        let nodes = try descriptions.map { try decode($0, depth: 0) }
        try SceneBudget.validate(nodes)
        guard manifest.version >= 7 || (scene.parameters == nil && scene.bindings == nil) else {
            throw SceneError.invalid("Parameters and bindings require scene version 7.")
        }
        let result = SceneDescriptor(title: manifest.title, nodes: nodes, parameters: scene.parameters ?? [:], bindings: scene.bindings ?? [], timeline: scene.timeline)
        guard scene.timeline == nil || manifest.version >= 11 else { throw SceneError.invalid("Authored playback requires scene version 11.") }
        guard result.timeline?.videosFollowScene != true || manifest.version >= 13 else { throw SceneError.invalid("Video transport requires scene version 13.") }
        guard !result.usesSmoothing || manifest.version >= 12 else { throw SceneError.invalid("Smoothing requires scene version 12.") }
        guard !result.usesTracks || manifest.version >= 10 else { throw SceneError.invalid("Keyframes require scene version 10.") }
        guard !result.usesDrivers || manifest.version >= 9 else { throw SceneError.invalid("Binding modifiers require scene version 9.") }
        guard !result.usesSignals || manifest.version >= 8 else { throw SceneError.invalid("Signal bindings require scene version 8.") }
        guard !result.usesPointer || manifest.capabilities.contains("pointer") else { throw SceneError.invalid("Pointer bindings must declare the pointer capability.") }
        _ = try result.evaluated()
        return result
    }
}

/// A typed, serializable target shared by future controls and animation tracks.
struct ScenePropertyAddress: Codable, Sendable, Hashable {
    enum Property: String, Codable, Sendable, CaseIterable {
        case x = "transform.x", y = "transform.y", scale = "transform.scale", rotation = "transform.rotation"
        case opacity, exposure = "style.exposure", saturation = "style.saturation", vignette = "style.vignette"
        var range: ClosedRange<Double> {
            switch self {
            case .x, .y, .exposure: return -2...2
            case .scale: return 0.05...4
            case .rotation: return -360...360
            case .opacity, .vignette: return 0...1
            case .saturation: return 0...2
            }
        }
    }
    let nodeID: UUID
    let property: Property

    func value(in nodes: [SceneNode]) throws -> Double {
        guard let node = nodes.flatMap({ $0.descendants }).first(where: { $0.id == nodeID }) else {
            throw SceneError.invalid("The property target no longer exists.")
        }
        switch property {
        case .x: return node.transform.x ?? 0
        case .y: return node.transform.y ?? 0
        case .scale: return node.transform.scale ?? 1
        case .rotation: return node.transform.rotation ?? 0
        case .opacity: return node.opacity
        case .exposure: return node.style.exposure
        case .saturation: return node.style.saturation
        case .vignette: return node.style.vignette
        }
    }

    /// Reject invalid values before mutation; bindings must explicitly clamp their output.
    func set(_ value: Double, in nodes: inout [SceneNode]) throws {
        guard value.isFinite, property.range.contains(value) else {
            throw SceneError.invalid("The property value is outside its supported range.")
        }
        guard SceneTree.edit(nodeID, in: &nodes, { siblings, index in
            var node = siblings[index]
            let t = node.transform
            switch property {
            case .x: node.transform = .init(x: value, y: t.y, scale: t.scale, rotation: t.rotation)
            case .y: node.transform = .init(x: t.x, y: value, scale: t.scale, rotation: t.rotation)
            case .scale: node.transform = .init(x: t.x, y: t.y, scale: value, rotation: t.rotation)
            case .rotation: node.transform = .init(x: t.x, y: t.y, scale: t.scale, rotation: value)
            case .opacity: node.opacity = value
            case .exposure: node.style.exposure = value
            case .saturation: node.style.saturation = value
            case .vignette: node.style.vignette = value
            }
            siblings[index] = node
        }) else { throw SceneError.invalid("The property target no longer exists.") }
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
        _ = try scene.evaluated()
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
            var json: [String: Any] = ["id": node.id.uuidString, "type": node.kind.rawValue, "opacity": node.opacity, "visible": node.visible, "locked": node.locked,
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
        var contents: [String: Any] = ["nodes": nodes]
        if let timeline = scene.timeline {
            try timeline.validate()
            contents["timeline"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(timeline))
        }
        let controlled = !scene.parameters.isEmpty || !scene.bindings.isEmpty
        if controlled {
            contents["parameters"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scene.parameters))
            contents["bindings"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scene.bindings))
        }
        for (name, json) in [("manifest.json", ["version": scene.timeline?.videosFollowScene == true ? 13 : scene.usesSmoothing ? 12 : scene.timeline != nil ? 11 : scene.usesTracks ? 10 : scene.usesDrivers ? 9 : scene.usesSignals ? 8 : controlled ? 7 : 6, "title": scene.title, "capabilities": scene.usesPointer ? ["pointer"] : []] as [String: Any]),
                             ("scene.json", contents)] {
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

/// Runtime-only filter memory, bounded by the scene's 64 unique binding targets.
final class SceneBindingSmoother {
    private var values: [ScenePropertyAddress: Double] = [:]
    private var lastTime: Double?
    private var revision: UInt64?
    private var delta: Double = 0
    func reset() { values.removeAll(keepingCapacity: true); lastTime = nil; revision = nil }
    func beginFrame(time: Double, revision: UInt64) {
        if self.revision != revision { reset(); self.revision = revision }
        delta = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = time
    }
    func sample(target: ScenePropertyAddress, value: Double, duration: Double) -> Double {
        guard duration > 0, let previous = values[target] else { values[target] = value; return value }
        let alpha = -expm1(-delta / duration)
        let filtered = previous * (1 - alpha) + value * alpha
        let result = filtered.isFinite ? filtered : value
        values[target] = result
        return result
    }
}
