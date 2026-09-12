import Foundation

@main struct StudioMotionTests {
    static func main() throws {
        try staticPromotionSeedsTimeZero()
        try keyedEditUpsertsAndPreservesModifiers()
        try autoKeyOffBlocksBetweenKeys()
        try ownershipKeepsControlsAndDriversDistinct()
        try makeStaticBakesCurrentValue()
        try driverChangesPreserveMapping()
        try channelEditOnlyCreatesChangedTrack()
        print("Studio motion tests passed")
    }

    private static func node(x: Double = 0.1, y: Double = 0.2, opacity: Double = 0.25) -> SceneNode {
        SceneNode(content: .gradient, opacity: opacity,
                  transform: .init(x: x, y: y, scale: 1, rotation: 0))
    }

    private static func staticPromotionSeedsTimeZero() throws {
        let layer = node(opacity: 0.25)
        let target = ScenePropertyAddress(nodeID: layer.id, property: .opacity)
        let scene = SceneDescriptor(title: "Seed", nodes: [layer])
        let edited = try StudioMotionAuthoring.edit(0.8, target: target, time: 3, autoKey: true, in: scene)
        let track = edited.bindings.first(where: { $0.target == target })!.keyframes!
        precondition(track.keys == [.init(time: 0, value: 0.25), .init(time: 3, value: 0.8)])
        let authored = try target.value(in: edited.nodes)
        precondition(authored == 0.25)
        precondition(StudioMotionAuthoring.ownership(of: target, in: edited) == .keyframed)
    }

    private static func keyedEditUpsertsAndPreservesModifiers() throws {
        let layer = node(opacity: 0.25)
        let target = ScenePropertyAddress(nodeID: layer.id, property: .opacity)
        let modifier = SceneParameterBinding.Modifier(operation: .multiply, parameter: "gain")
        let binding = SceneParameterBinding(target: target, scale: 2, offset: 0.1,
            modifiers: [modifier], keyframes: .init(keys: [.init(time: 0, value: 0.1), .init(time: 3, value: 0.2)]))
        let scene = SceneDescriptor(title: "Mapped", nodes: [layer],
            parameters: ["gain": .init(name: "Gain", value: 2, min: 0.1, max: 4)], bindings: [binding])
        let edited = try StudioMotionAuthoring.edit(0.8, target: target, time: 3.0005, autoKey: false, in: scene)
        let result = edited.bindings[0]
        precondition(result.keyframes!.keys.count == 2)
        precondition(abs(result.keyframes!.keys[1].value - 0.15) < 0.000001)
        precondition(result.modifiers.count == 1 && result.modifiers[0].parameter == "gain")
        precondition(result.scale == 2 && result.offset == 0.1)
    }

    private static func autoKeyOffBlocksBetweenKeys() throws {
        let layer = node()
        let target = ScenePropertyAddress(nodeID: layer.id, property: .x)
        let scene = SceneDescriptor(title: "Between", nodes: [layer], bindings: [
            .init(target: target, keyframes: .init(keys: [.init(time: 0, value: 0.1), .init(time: 4, value: 0.4)]))
        ])
        precondition(StudioMotionAuthoring.writeDisposition(for: target, in: scene, time: 2, autoKey: false) == .blockedBetweenKeys)
        do {
            _ = try StudioMotionAuthoring.edit(0.2, target: target, time: 2, autoKey: false, in: scene)
            preconditionFailure("between-key edit should be blocked")
        } catch { }
        let keyed = try StudioMotionAuthoring.edit(0.2, target: target, time: 2, autoKey: true, in: scene)
        precondition(keyed.bindings[0].keyframes!.keys.map(\.time) == [0, 2, 4])
    }

    private static func ownershipKeepsControlsAndDriversDistinct() throws {
        let layer = node()
        let x = ScenePropertyAddress(nodeID: layer.id, property: .x)
        let y = ScenePropertyAddress(nodeID: layer.id, property: .y)
        let scene = SceneDescriptor(title: "Owners", nodes: [layer],
            parameters: ["x": .init(name: "Horizontal", value: 0.1, min: -2, max: 2)],
            bindings: [.init(target: x, parameter: "x"), .init(target: y, signal: .sine)])
        precondition(StudioMotionAuthoring.ownership(of: x, in: scene) == .controlled("x"))
        precondition(StudioMotionAuthoring.ownership(of: y, in: scene) == .driven(.sine))
        precondition(StudioMotionAuthoring.writeDisposition(for: x, in: scene, time: 1, autoKey: true) == .controlled)
        precondition(StudioMotionAuthoring.writeDisposition(for: y, in: scene, time: 1, autoKey: true) == .driven)
    }

    private static func makeStaticBakesCurrentValue() throws {
        let layer = node(opacity: 0.1)
        let target = ScenePropertyAddress(nodeID: layer.id, property: .opacity)
        let scene = SceneDescriptor(title: "Bake", nodes: [layer],
            parameters: ["spare": .init(name: "Spare", value: 0.5, min: 0, max: 1)],
            bindings: [.init(target: target, scale: 0.1, offset: 0.2, signal: .time)])
        let baked = try StudioMotionAuthoring.makeStatic(target,
            signals: SceneSignals(time: 3), in: scene)
        precondition(baked.bindings.isEmpty)
        let bakedValue = try target.value(in: baked.nodes)
        precondition(abs(bakedValue - 0.5) < 0.000001)
        precondition(baked.parameters["spare"] != nil, "owner changes keep scene controls")
    }

    private static func driverChangesPreserveMapping() throws {
        let layer = node()
        let target = ScenePropertyAddress(nodeID: layer.id, property: .x)
        let modifier = SceneParameterBinding.Modifier(operation: .add, value: 0.1)
        let scene = SceneDescriptor(title: "Driver", nodes: [layer], bindings: [
            .init(target: target, scale: 0.2, offset: -0.1, signal: .time, period: 7,
                  modifiers: [modifier], smoothing: 0.4)
        ])
        let changed = try StudioMotionAuthoring.bind(target, to: .pointerX, in: scene)
        let binding = changed.bindings[0]
        precondition(binding.signal == .pointerX && binding.scale == 0.2 && binding.offset == -0.1)
        precondition(binding.period == 7 && binding.smoothing == 0.4 && binding.modifiers.count == 1)
    }

    private static func channelEditOnlyCreatesChangedTrack() throws {
        let layer = node(x: 0.1, y: 0.2)
        let x = ScenePropertyAddress(nodeID: layer.id, property: .x)
        let y = ScenePropertyAddress(nodeID: layer.id, property: .y)
        let scene = SceneDescriptor(title: "Channels", nodes: [layer])
        let edited = try StudioMotionAuthoring.edit(0.6, target: x, time: 2, autoKey: true, in: scene)
        precondition(edited.bindings.count == 1 && edited.bindings[0].target == x)
        precondition(StudioMotionAuthoring.ownership(of: y, in: edited) == .staticValue)
    }
}
