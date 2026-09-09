import AppKit

@main struct RecoveryTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = SceneDocument(recoveryDirectory: root)
        original.recoveryEnabled = true
        var node = SceneNode(content: .gradient)
        node.transform = .init(x: 0.2, y: -0.3, scale: 0.7, rotation: 25)
        node.style.vignette = 0.4
        original.scene = SceneDescriptor(title: "Recovered", nodes: [node], timeline: .init(duration: 8, mode: .loop))
        original.draft = true
        original.flushRecovery()
        let reopened = SceneDocument(recoveryDirectory: root)
        let recovered = try reopened.readRecovery()!
        precondition(recovered.scene.nodes[0].id == node.id)
        precondition(recovered.scene.nodes[0].transform.rotation == 25)
        precondition(recovered.scene.nodes[0].style.vignette == 0.4)
        precondition(recovered.scene.timeline?.duration == 8)
        let presetID = UUID().uuidString
        let preset = try SceneComponent.capture(SceneNode(content: .text(.init(text: "Recovered preset"))), from: original.scene)
        original.scene.components = [presetID: preset]
        original.scene.metadata = .init(author: "Leo", previewTime: 5)
        original.scheduleRecovery()
        original.flushRecovery()
        let withPreset = try reopened.readRecovery()!
        precondition(withPreset.scene.components?[presetID]?.node.typography?.text == "Recovered preset")
        precondition(withPreset.scene.metadata?.previewTime == 5)
        // A different document saving must not remove a deferred recovery.
        reopened.recoveryEnabled = true
        reopened.draft = false
        let deferred = try reopened.readRecovery()
        precondition(deferred != nil)
        reopened.adoptRecovery()
        reopened.draft = false
        let cleared = try reopened.readRecovery()
        precondition(cleared == nil)
        // Missing media leaves metadata intact for a later retry.
        original.scene = SceneDescriptor(title: "Missing", nodes: [SceneNode(content: .image(root.appendingPathComponent("missing.png")))])
        original.draft = true
        original.flushRecovery()
        do { _ = try reopened.readRecovery(); fatalError("Accepted missing media") }
        catch is SceneError {}
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(files.count == 1)
        original.clearRecovery()
        print("Recovery round-trip, isolation, cleanup, and missing-media checks passed")
    }
}
