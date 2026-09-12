import Foundation

@main
enum DesktopAttentionTests {
    static func main() throws {
        let node = SceneNode(id: UUID(uuidString: "A42A0000-0000-4000-8000-000000000001")!, content: .gradient)
        let target = ScenePropertyAddress(nodeID: node.id, property: .opacity)
        let binding = SceneParameterBinding(target: target, scale: 0.8, offset: 0.1,
            signal: .desktopAttention, smoothing: 1.0)
        let scene = SceneDescriptor(title: "Attention", nodes: [node], bindings: [binding])
        precondition(scene.usesDesktopAttention && scene.usesSignals && scene.requiresMetal)
        precondition(SceneParameterBinding.Signal(rawValue: "desktop.attention") == .desktopAttention)

        var hidden = SceneSignals(); hidden.desktopAttention = 0
        var exposed = SceneSignals(); exposed.desktopAttention = 1
        let hiddenScene = try scene.evaluated(signals: hidden)
        let exposedScene = try scene.evaluated(signals: exposed)
        precondition(abs(hiddenScene.nodes[0].opacity - 0.1) < 0.000001)
        precondition(abs(exposedScene.nodes[0].opacity - 0.9) < 0.000001)

        let smoother = SceneBindingSmoother()
        smoother.beginFrame(time: 0, revision: 1)
        let first = smoother.sample(target: target, value: 0.1, duration: 1)
        smoother.beginFrame(time: 0.5, revision: 1)
        let halfway = smoother.sample(target: target, value: 0.9, duration: 1)
        precondition(first == 0.1 && halfway > 0.1 && halfway < 0.9,
            "Existing binding smoothing must interpolate desktop attention")
        smoother.reset()
        smoother.beginFrame(time: 10, revision: 2)
        precondition(smoother.sample(target: target, value: 0.9, duration: 1) == 0.9,
            "A reset must restart smoothing deterministically")

        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Examples/DesktopAttention.idlesse")
        let loaded = try LocalSceneSource.read(fixture)
        precondition(loaded.usesDesktopAttention && loaded.bindings.count >= 2,
            "The bundled attention example must exercise the host signal")

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("idlesse-attention-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let missingCapability = folder.appendingPathComponent("MissingCapability.idlesse")
        try FileManager.default.copyItem(at: fixture, to: missingCapability)
        let manifestURL = missingCapability.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifest["capabilities"] = []
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: manifestURL, options: .atomic)
        do {
            _ = try LocalSceneSource.read(missingCapability)
            preconditionFailure("Desktop attention must require its explicit capability")
        } catch is SceneError { }

        let written = folder.appendingPathComponent("Written.idlesse")
        try ScenePackageWriter.write(scene, to: written)
        let writtenManifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: written.appendingPathComponent("manifest.json"))) as! [String: Any]
        let capabilities = writtenManifest["capabilities"] as! [String]
        precondition(capabilities.contains("desktop-attention"),
            "Package writing must preserve the desktop-attention capability")
        _ = try LocalSceneSource.read(written)

        let loops = 20_000
        let baseline = SceneDescriptor(title: "Baseline", nodes: [node])
        var sink = 0.0
        let baselineStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<loops {
            sink += try baseline.evaluated(signals: exposed, validating: false).nodes[0].opacity
        }
        let baselineSeconds = ProcessInfo.processInfo.systemUptime - baselineStart
        let attentionStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<loops {
            sink += try scene.evaluated(signals: exposed, validating: false).nodes[0].opacity
        }
        let attentionSeconds = ProcessInfo.processInfo.systemUptime - attentionStart
        withExtendedLifetime(sink) {}
        let baselineUS = baselineSeconds / Double(loops) * 1_000_000
        let attentionUS = attentionSeconds / Double(loops) * 1_000_000
        print(String(format: "Desktop attention binding benchmark: baseline=%.3f us/eval attention=%.3f us/eval delta=%.3f us/eval",
            baselineUS, attentionUS, attentionUS - baselineUS))
        print("Desktop attention checks passed: normalized binding, smoothing, capability gate, writer round-trip and example")
    }
}
