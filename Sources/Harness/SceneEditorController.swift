import AppKit

/// Selection indexes the document's preorder traversal, never a visible table row.
final class SceneEditorController {
    let document: SceneDocument
    var selection = 0
    var commit: (([SceneNode], Int, String) -> Bool)?
    var onError: ((String) -> Void)?
    init(document: SceneDocument) { self.document = document }
    var selectedNode: SceneNode? {
        let nodes = document.scene.allNodes
        return nodes.indices.contains(selection) ? nodes[selection] : nil
    }
    var siblings: [SceneNode] { selectedNode.flatMap { SceneTree.siblings(of: $0.id, in: document.scene.nodes) } ?? [] }
    @discardableResult private func edit(_ index: Int, name: String, _ body: (inout [SceneNode], Int) -> UUID) -> Bool {
        let all = document.scene.allNodes
        guard all.indices.contains(index) else { return false }
        var roots = document.scene.nodes
        var selectedID = all[index].id
        guard SceneTree.edit(selectedID, in: &roots, { nodes, offset in selectedID = body(&nodes, offset) }) else { return false }
        let next = roots.flatMap { $0.descendants }.firstIndex { $0.id == selectedID } ?? 0
        return commit?(roots, next, name) ?? false
    }
    func replaceSelected(_ node: SceneNode, name: String) {
        edit(selection, name: name) { nodes, index in nodes[index] = node; return node.id }
    }
    func transform(_ transform: SceneNode.Transform, action: String) {
        guard var node = selectedNode, !node.locked else { return }
        node.transform = transform
        replaceSelected(node, name: action)
    }
    func nudge(x: Double, y: Double) {
        guard let node = selectedNode, !node.locked else { return }
        let t = node.transform
        transform(.init(x: min(2, max(-2, (t.x ?? 0) + x)), y: min(2, max(-2, (t.y ?? 0) + y)),
                        scale: t.scale, rotation: t.rotation), action: "Nudge Layer")
    }
    @discardableResult func add(_ node: SceneNode) -> Bool {
        edit(selection, name: "Add Layer") { nodes, index in
            if nodes[index].kind == .group { nodes[index].content = .group(nodes[index].children + [node]) }
            else { nodes.insert(node, at: index + 1) }
            return node.id
        }
    }
    func duplicate() {
        edit(selection, name: "Duplicate Layer") { nodes, index in
            var copy = nodes[index].duplicated(); copy.name = copy.displayName + " Copy"
            nodes.insert(copy, at: index + 1); return copy.id
        }
    }
    func groupWithNext() {
        edit(selection, name: "Group Layers") { nodes, index in
            guard nodes.indices.contains(index + 1) else { return nodes[index].id }
            let group = SceneNode(name: "Group", content: .group(Array(nodes[index...index + 1])))
            nodes.replaceSubrange(index...index + 1, with: [group]); return group.id
        }
    }
    func ungroup() {
        guard let group = selectedNode, group.kind == .group else { return }
        // Removing an isolated translucent or transformed canvas cannot generally
        // preserve its clipping/overlap appearance as independent child layers.
        let t = group.transform
        guard group.style == .plain, group.opacity == 1, (t.x ?? 0) == 0, (t.y ?? 0) == 0,
              (t.scale ?? 1) == 1, (t.rotation ?? 0) == 0 else {
            onError?("Reset the group's transform, opacity and appearance before ungrouping to preserve its appearance.")
            return
        }
        edit(selection, name: "Ungroup Layers") { nodes, index in
            let children = group.children.map { child -> SceneNode in
                var child = child; child.visible = group.visible && child.visible; child.locked = group.locked || child.locked; return child
            }
            nodes.replaceSubrange(index...index, with: children); return children[0].id
        }
    }
    func reorder(_ source: Int, _ destination: Int) {
        let all = document.scene.allNodes
        guard all.indices.contains(source), all.indices.contains(destination) else { return }
        let target = all[destination].id
        guard SceneTree.siblings(of: all[source].id, in: document.scene.nodes)?.contains(where: { $0.id == target }) == true else {
            onError?("Reorder layers within the same group."); return
        }
        edit(source, name: "Reorder Layer") { nodes, index in
            let destination = nodes.firstIndex { $0.id == target }!
            let node = nodes.remove(at: index); nodes.insert(node, at: destination); return node.id
        }
    }
    func reorderAdjacent() {
        guard let selectedNode, let index = siblings.firstIndex(where: { $0.id == selectedNode.id }), siblings.count > 1 else { return }
        let next = siblings[index == 0 ? 1 : index - 1].id
        if let destination = document.scene.allNodes.firstIndex(where: { $0.id == next }) { reorder(selection, destination) }
    }
    func toggleVisibility(_ index: Int) {
        edit(index, name: "Toggle Layer Visibility") { nodes, offset in nodes[offset].visible.toggle(); return nodes[offset].id }
    }
    func toggleLock(_ index: Int) {
        edit(index, name: "Toggle Layer Lock") { nodes, offset in nodes[offset].locked.toggle(); return nodes[offset].id }
    }
    func remove() {
        guard siblings.count > 1 else { return }
        edit(selection, name: "Delete Layer") { nodes, index in nodes.remove(at: index); return nodes[max(0, index - 1)].id }
    }
    func rename(_ name: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard var node = selectedNode, !name.isEmpty, node.displayName != name else { return }
        node.name = name; replaceSelected(node, name: "Rename Layer")
    }
}
