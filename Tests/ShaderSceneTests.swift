import Foundation

@main struct ShaderSceneTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shader-scene-\(UUID().uuidString).idlesse")
        defer { try? FileManager.default.removeItem(at: root) }

        let customSource = SceneNode.Shader.plasma.replacingOccurrences(of: "float t = u.time;", with: "float t = u.time * 0.5;")
        let authored = SceneNode.Shader(source: customSource, speed: 2.5)
        let node = SceneNode(name: "Custom Shader", content: .shader(authored))
        let scene = SceneDescriptor(title: "Shader Round Trip", nodes: [node])

        try ScenePackageWriter.write(scene, to: root)
        let loaded = try await LocalSceneSource().resolve(root)
        guard let shader = loaded.nodes.first?.shader else { fatalError("Shader payload did not round-trip") }
        precondition(shader == authored)
        precondition(SceneFormat.revision == 21)

        var speedOnly = node
        speedOnly.content = .shader(.init(source: customSource, speed: 4))
        precondition(sceneResourceOrder(from: [node], to: [speedOnly]) == [0],
                     "Speed-only edits should reuse the existing compiled pipeline")

        var sourceEdit = node
        sourceEdit.content = .shader(.init(source: customSource + "\n// source edit", speed: authored.speed))
        precondition(sceneResourceOrder(from: [node], to: [sourceEdit]) == nil,
                     "Source edits must force shader resource replacement")

        var invalidSpeed = authored
        invalidSpeed.speed = 12
        do {
            try invalidSpeed.validate()
            fatalError("Accepted shader speed outside the existing runtime range")
        } catch is SceneError {}

        print("Shader scene checks passed: source/speed round-trip and source invalidation")
    }
}
