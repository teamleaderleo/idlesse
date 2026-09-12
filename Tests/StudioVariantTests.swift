import Foundation

@main struct StudioVariantTests {
    static func main() throws {
        var scene = SceneDescriptor(title: "Studio variants", nodes: [SceneNode(content: .gradient)], parameters: [
            "amount": .init(name: "Amount", value: 0.25, min: 0, max: 1),
            "enabled": .init(name: "Enabled", type: .boolean, boolean: true),
            "mode": .init(name: "Mode", type: .choice, text: "soft", choices: ["soft", "hard"])
        ])
        var state = SceneVariantAuthoringState(scene: scene)
        precondition(state.selectedID == nil)
        precondition(state.origin(for: "amount") == .defaultValue)

        let calm = try state.create(name: "Calm")
        precondition(state.selectedID == calm)
        precondition(state.selectedVariant?.values.isEmpty == true)
        precondition(state.origin(for: "amount") == .inherited)

        var values = state.visibleParameters
        values["amount"]?.value = 0.6
        values["enabled"]?.boolean = false
        try state.updateVisibleParameters(values)
        precondition(state.selectedVariant?.values == ["amount": .number(0.6), "enabled": .boolean(false)])
        precondition(state.origin(for: "amount") == .overridden)
        precondition(state.origin(for: "mode") == .inherited)

        state.useDefault("enabled")
        precondition(state.selectedVariant?.values["enabled"] == nil)
        precondition(state.visibleParameters["enabled"]?.boolean == true)

        // Default edits flow through inherited controls but preserve authored overrides.
        state.select(nil)
        values = state.visibleParameters
        values["amount"]?.value = 0.4
        values["mode"]?.text = "hard"
        try state.updateVisibleParameters(values)
        state.select(calm)
        precondition(state.visibleParameters["amount"]?.value == 0.6)
        precondition(state.visibleParameters["mode"]?.text == "hard")

        let copy = try state.duplicateSelected()
        precondition(copy != calm)
        precondition(state.selectedVariant?.values["amount"] == .number(0.6))
        let beforeRename = state.selectedID
        try state.renameSelected("Evening")
        precondition(state.selectedID == beforeRename)
        precondition(state.selectedVariant?.name == "Evening")

        do {
            try state.renameSelected("Calm")
            fatalError("Accepted duplicate case-insensitive variant name")
        } catch is SceneError {}

        state.deleteSelected()
        precondition(state.selectedID == nil)
        precondition(state.scene.variants.count == 1)

        // Authoring save repairs stale values without sacrificing compatible overrides.
        scene = state.scene
        scene.variants.append(.init(id: UUID(), name: "Legacy", values: [
            "amount": .number(0.8),
            "missing": .text("gone"),
            "mode": .text("removed-choice")
        ]))
        state = SceneVariantAuthoringState(scene: scene)
        let removed = state.normalizeStaleOverrides()
        let legacy = state.scene.variants.first { $0.name == "Legacy" }!
        precondition(legacy.values == ["amount": .number(0.8)])
        precondition(removed.count == 2)

        // Removing a scene control prunes the matching override across every variant.
        scene = state.scene
        scene.parameters.removeValue(forKey: "amount")
        state = SceneVariantAuthoringState(scene: scene)
        state.pruneRemovedControls()
        precondition(state.scene.variants.allSatisfy { $0.values["amount"] == nil })

        // A named look authored in Studio survives serialization/reopen with sparse values.
        scene = SceneDescriptor(title: "Undertow", nodes: [SceneNode(content: .gradient)], parameters: [
            "depth": .init(name: "Depth", value: 0.2, min: 0, max: 1)
        ])
        state = SceneVariantAuthoringState(scene: scene)
        let midnight = try state.create(name: "Midnight")
        var midnightValues = state.visibleParameters
        midnightValues["depth"]?.value = 0.85
        try state.updateVisibleParameters(midnightValues)
        let reopened = try JSONDecoder().decode(SceneDescriptor.self, from: JSONEncoder().encode(state.scene))
        let reopenedMidnight = reopened.variants.first { $0.id == midnight }
        precondition(reopenedMidnight?.name == "Midnight")
        precondition(reopenedMidnight?.values == ["depth": .number(0.85)])
        precondition(reopened.applyingVariant(id: midnight).scene.parameters["depth"]?.value == 0.85)

        // The 16-variant limit is enforced by the authoring layer as well as package validation.
        scene = SceneDescriptor(title: "Limit", nodes: [SceneNode(content: .gradient)])
        scene.variants = (0..<16).map { .init(id: UUID(), name: "Look \($0)", values: [:]) }
        state = SceneVariantAuthoringState(scene: scene)
        do {
            _ = try state.create(name: "Seventeen")
            fatalError("Accepted a seventeenth variant")
        } catch is SceneError {}

        print("studio variant tests passed")
    }
}
