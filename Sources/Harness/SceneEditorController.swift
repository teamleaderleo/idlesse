import AppKit

/// Editing commands work on scene metadata; the host approves each replacement first.
final class SceneEditorController {
    let document: SceneDocument
    var selection = 0
    var commit: (([SceneNode], Int, String) -> Bool)?
    init(document: SceneDocument) { self.document = document }
    func transform(_ transform: SceneNode.Transform, action: String) {
        guard document.scene.nodes.indices.contains(selection) else { return }
        var nodes = document.scene.nodes
        nodes[selection].transform = transform
        _ = commit?(nodes, selection, action)
    }
    func nudge(x: Double, y: Double) {
        guard document.scene.nodes.indices.contains(selection) else { return }
        let t = document.scene.nodes[selection].transform
        transform(.init(x: min(2, max(-2, (t.x ?? 0) + x)), y: min(2, max(-2, (t.y ?? 0) + y)),
                        scale: t.scale, rotation: t.rotation), action: "Nudge Layer")
    }
    func duplicate() {
        guard document.scene.nodes.count < 2, document.scene.nodes.indices.contains(selection) else { return }
        var nodes = document.scene.nodes
        var copy = nodes[selection]
        copy.id = UUID()
        copy.name = copy.displayName + " Copy"
        nodes.insert(copy, at: selection + 1)
        _ = commit?(nodes, selection + 1, "Duplicate Layer")
    }
    func remove() {
        guard document.scene.nodes.count > 1, document.scene.nodes.indices.contains(selection) else { return }
        var nodes = document.scene.nodes
        nodes.remove(at: selection)
        _ = commit?(nodes, max(0, selection - 1), "Delete Layer")
    }
    func rename(_ name: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !name.isEmpty, document.scene.nodes.indices.contains(selection) else { return }
        var nodes = document.scene.nodes
        guard nodes[selection].displayName != name else { return }
        nodes[selection].name = name
        _ = commit?(nodes, selection, "Rename Layer")
    }
}
