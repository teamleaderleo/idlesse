import Foundation

@main struct ShaderEffectSceneTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idlesse-shader-effect-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = """
        fragment float4 effectMain(V in [[stage_in]], constant EffectU &u [[buffer(1)]], constant ShaderInputs &inputs [[buffer(2)]], texture2d<float> source [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float4 pixel = source.sample(s, in.uv);
            return mix(pixel, float4(pixel.b, pixel.r, pixel.g, pixel.a), u.viewport.w);
        }
        """
        let savedShader = SceneNode.Shader(source: source, speed: 1.75)
        var node = SceneNode(content: .shape(.init(primitive: .rectangle, fill: "#55AAFF", width: 256, height: 256)))
        node.style.effects = [.init(type: .displacement, amount: 0.65, shader: savedShader)]
        let scene = SceneDescriptor(title: "Shader Effect", nodes: [node])

        try SceneBudget.validate(scene.nodes)
        let features = SceneFormat.features(scene)
        precondition(features.contains("effects") && features.contains("shader-effects"))
        precondition(!features.contains("shaders"), "Texture effects must stay distinct from procedural shader nodes")

        let package = root.appendingPathComponent("Effect.idlesse")
        try ScenePackageWriter.write(scene, to: package)
        let loaded = try await LocalSceneSource().resolve(package)
        guard let effect = loaded.nodes.first?.style.effects.first else {
            preconditionFailure("Saved shader effect disappeared")
        }
        precondition(effect.shader == savedShader && effect.amount == 0.65)
        precondition(effect.range == 0...1)

        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("manifest.json"))) as! [String: Any]
        let manifestFeatures = Set(manifest["features"] as! [String])
        precondition(manifestFeatures.contains("shader-effects"))

        var fiveNodes: [SceneNode] = []
        for index in 0...SceneBudget.maxShaderEffects {
            var n = SceneNode(content: .shape(.init(primitive: .rectangle, fill: "#FFFFFF", width: 64, height: 64)))
            n.name = "Effect \(index)"
            n.style.effects = [.init(type: .displacement, amount: 1, shader: savedShader)]
            fiveNodes.append(n)
        }
        do {
            try SceneBudget.validate(fiveNodes)
            preconditionFailure("Custom shader effect count must be bounded")
        } catch { }

        var procedural = SceneNode(content: .shader(.init()))
        procedural.style.effects = [.init(type: .displacement, amount: 1, shader: savedShader)]
        do {
            try SceneBudget.validate([procedural])
            preconditionFailure("Procedural shader nodes must remain independent from texture-sampling effects")
        } catch { }

        var oversized = node
        oversized.style.effects[0].shader = .init(source: String(repeating: "x", count: 32_769), speed: 1)
        do {
            try SceneBudget.validate([oversized])
            preconditionFailure("Shader effect source size must be bounded")
        } catch { }

        print("Shader effect scene tests passed: feature gate, package round-trip, source limits, effect cap and procedural compatibility")
    }
}
