import Foundation

/// Session-facing ownership derived from the canonical scene binding model.
enum StudioMotionOwnership: Equatable {
    case staticValue
    case controlled(String)
    case driven(SceneParameterBinding.Signal)
    case keyframed

    var title: String {
        switch self {
        case .staticValue: return "Static"
        case .controlled: return "Controlled"
        case .driven: return "Driven"
        case .keyframed: return "Keyframed"
        }
    }
}

enum StudioMotionWriteDisposition: Equatable {
    case staticValue, keyedAtPlayhead, autoKey, blockedBetweenKeys, controlled, driven
    var writable: Bool {
        switch self {
        case .staticValue, .keyedAtPlayhead, .autoKey: return true
        case .blockedBetweenKeys, .controlled, .driven: return false
        }
    }
}

enum StudioMotionAuthoring {
    static let keyTolerance = 0.001

    static func ownership(of target: ScenePropertyAddress, in scene: SceneDescriptor) -> StudioMotionOwnership {
        guard let binding = scene.bindings.first(where: { $0.target == target }) else { return .staticValue }
        if binding.keyframes != nil { return .keyframed }
        if let signal = binding.signal { return .driven(signal) }
        return .controlled(binding.parameter)
    }

    static func typedControlKey(for target: SceneControlTarget, in scene: SceneDescriptor) -> String? {
        scene.parameters.first(where: { $0.value.targets.contains(target) })?.key
    }

    static func typedOwnership(of target: SceneControlTarget, in scene: SceneDescriptor) -> StudioMotionOwnership {
        typedControlKey(for: target, in: scene).map(StudioMotionOwnership.controlled) ?? .staticValue
    }

    static func keyIndex(in track: SceneKeyframeTrack, at time: Double) -> Int? {
        guard let index = track.keys.indices.min(by: {
            abs(track.keys[$0].time - time) < abs(track.keys[$1].time - time)
        }), abs(track.keys[index].time - time) <= keyTolerance else { return nil }
        return index
    }

    static func writeDisposition(for target: ScenePropertyAddress, in scene: SceneDescriptor,
                                 time: Double, autoKey: Bool) -> StudioMotionWriteDisposition {
        switch ownership(of: target, in: scene) {
        case .staticValue: return autoKey ? .autoKey : .staticValue
        case .controlled: return .controlled
        case .driven: return .driven
        case .keyframed:
            guard let track = scene.bindings.first(where: { $0.target == target })?.keyframes else {
                return .blockedBetweenKeys
            }
            if keyIndex(in: track, at: time) != nil { return .keyedAtPlayhead }
            return autoKey ? .autoKey : .blockedBetweenKeys
        }
    }

    static func visibleValue(of target: ScenePropertyAddress, in scene: SceneDescriptor,
                             signals: SceneSignals) throws -> Double {
        try target.value(in: scene.evaluated(signals: signals).nodes)
    }

    static func edit(_ value: Double, target: ScenePropertyAddress, time: Double, autoKey: Bool,
                     in scene: SceneDescriptor) throws -> SceneDescriptor {
        guard time.isFinite, (0...86400).contains(time), value.isFinite,
              try target.range(in: scene.nodes).contains(value) else {
            throw SceneError.invalid("The property value or playhead is outside its supported range.")
        }
        switch ownership(of: target, in: scene) {
        case .controlled:
            throw SceneError.invalid("This property is Controlled. Choose another Motion owner first.")
        case .driven:
            throw SceneError.invalid("This property is Driven. Choose another Motion owner first.")
        case .staticValue:
            if !autoKey {
                var nodes = scene.nodes
                try target.set(value, in: &nodes)
                return scene.replacingNodes(nodes)
            }
            let seed = try target.value(in: scene.nodes)
            var next = scene
            next.bindings.removeAll { $0.target == target }
            let keys: [SceneKeyframeTrack.Key] = time <= keyTolerance
                ? [.init(time: 0, value: value)]
                : [.init(time: 0, value: seed), .init(time: time, value: value)]
            next.bindings.append(.init(target: target, keyframes: .init(keys: keys)))
            _ = try next.evaluated()
            return next
        case .keyframed:
            guard let index = scene.bindings.firstIndex(where: { $0.target == target }),
                  var track = scene.bindings[index].keyframes else { return scene }
            guard autoKey || keyIndex(in: track, at: time) != nil else {
                throw SceneError.invalid("Auto-Key is off and there is no key at the current playhead.")
            }
            let source = try sourceValue(forVisibleValue: value, binding: scene.bindings[index], scene: scene)
            upsert(source, at: time, in: &track)
            var next = scene
            next.bindings[index].keyframes = track
            _ = try next.evaluated()
            return next
        }
    }

    static func promoteToKeyframes(_ target: ScenePropertyAddress, time: Double,
                                   signals: SceneSignals, in scene: SceneDescriptor) throws -> SceneDescriptor {
        guard time.isFinite, (0...86400).contains(time) else {
            throw SceneError.invalid("Choose a playhead from 0 through 86400 seconds.")
        }
        let current = try visibleValue(of: target, in: scene, signals: signals)
        if ownership(of: target, in: scene) == .staticValue {
            let seed = try target.value(in: scene.nodes)
            var next = scene
            next.bindings.removeAll { $0.target == target }
            let keys: [SceneKeyframeTrack.Key] = time <= keyTolerance
                ? [.init(time: 0, value: current)]
                : [.init(time: 0, value: seed), .init(time: time, value: current)]
            next.bindings.append(.init(target: target, keyframes: .init(keys: keys)))
            _ = try next.evaluated()
            return next
        }
        guard let index = scene.bindings.firstIndex(where: { $0.target == target }) else { return scene }
        if var track = scene.bindings[index].keyframes {
            let source = try sourceValue(forVisibleValue: current, binding: scene.bindings[index], scene: scene)
            upsert(source, at: time, in: &track)
            var next = scene
            next.bindings[index].keyframes = track
            _ = try next.evaluated()
            return next
        }
        var binding = scene.bindings[index]
        let source = try sourceValue(forVisibleValue: current, binding: binding, scene: scene)
        binding.parameter = ""
        binding.signal = nil
        binding.keyframes = .init(keys: [.init(time: time, value: source)])
        var next = scene
        next.bindings[index] = binding
        _ = try next.evaluated()
        return next
    }

    static func makeStatic(_ target: ScenePropertyAddress, signals: SceneSignals,
                           in scene: SceneDescriptor) throws -> SceneDescriptor {
        let visible = try visibleValue(of: target, in: scene, signals: signals)
        var nodes = scene.nodes
        try target.set(visible, in: &nodes)
        var next = scene.replacingNodes(nodes)
        next.bindings.removeAll { $0.target == target }
        _ = try next.evaluated()
        return next
    }

    static func makeStatic(_ target: SceneControlTarget, in scene: SceneDescriptor) throws -> SceneDescriptor {
        guard typedControlKey(for: target, in: scene) != nil else { return scene }
        let evaluated = try scene.evaluated()
        guard let presented = evaluated.allNodes.first(where: { $0.id == target.nodeID }) else {
            throw SceneError.invalid("The controlled property is missing.")
        }
        var nodes = scene.nodes
        guard SceneTree.edit(target.nodeID, in: &nodes, { siblings, index in
            switch target.property {
            case .visible:
                siblings[index].visible = presented.visible
            case .blend:
                siblings[index].blend = presented.blend
            case .text:
                if var value = siblings[index].typography, let source = presented.typography {
                    value.text = source.text
                    siblings[index].content = .text(value)
                }
            case .fill:
                if var value = siblings[index].typography, let source = presented.typography {
                    value.fill = source.fill
                    siblings[index].content = .text(value)
                } else if var value = siblings[index].shape, let source = presented.shape {
                    value.fill = source.fill
                    siblings[index].content = .shape(value)
                }
            }
        }) else {
            throw SceneError.invalid("The controlled property is missing.")
        }
        var next = scene
        for key in next.parameters.keys { next.parameters[key]?.targets.removeAll { $0 == target } }
        next = next.replacingNodes(nodes)
        _ = try next.evaluated()
        return next
    }

    static func bind(_ target: ScenePropertyAddress, to signal: SceneParameterBinding.Signal,
                     in scene: SceneDescriptor) throws -> SceneDescriptor {
        var next = scene
        if let index = next.bindings.firstIndex(where: { $0.target == target }) {
            next.bindings[index].parameter = ""
            next.bindings[index].signal = signal
            next.bindings[index].keyframes = nil
        } else {
            next.bindings.append(.init(target: target, signal: signal))
        }
        _ = try next.evaluated()
        return next
    }

    static func bind(_ target: ScenePropertyAddress, toParameter key: String,
                     in scene: SceneDescriptor) throws -> SceneDescriptor {
        guard scene.parameters[key]?.type == .number else {
            throw SceneError.invalid("Choose a numeric scene control.")
        }
        var next = scene
        if let index = next.bindings.firstIndex(where: { $0.target == target }) {
            next.bindings[index].parameter = key
            next.bindings[index].signal = nil
            next.bindings[index].keyframes = nil
        } else {
            next.bindings.append(.init(target: target, parameter: key))
        }
        _ = try next.evaluated()
        return next
    }

    static func bind(_ target: SceneControlTarget, toParameter key: String,
                     in scene: SceneDescriptor) throws -> SceneDescriptor {
        guard let parameter = scene.parameters[key], try typedParameter(parameter, supports: target, in: scene.nodes) else {
            throw SceneError.invalid("Choose a compatible scene control.")
        }
        var next = scene
        for existing in next.parameters.keys { next.parameters[existing]?.targets.removeAll { $0 == target } }
        next.parameters[key]?.targets.append(target)
        _ = try next.evaluated()
        return next
    }

    static func newControl(for target: SceneControlTarget, name: String,
                           in scene: SceneDescriptor) throws -> SceneParameter {
        guard let node = scene.allNodes.first(where: { $0.id == target.nodeID }) else {
            throw SceneError.invalid("The property is missing.")
        }
        var parameter: SceneParameter
        switch target.property {
        case .visible:
            parameter = .init(name: name, type: .boolean, boolean: node.visible)
        case .blend:
            parameter = .init(name: name, type: .choice, text: (node.blend ?? .normal).rawValue,
                              choices: ["normal", "add", "multiply", "screen"])
        case .text:
            guard let text = node.typography?.text else { throw SceneError.invalid("Text controls need a text layer.") }
            parameter = .init(name: name, type: .string, text: text)
        case .fill:
            if let fill = node.typography?.fill ?? node.shape?.fill {
                parameter = .init(name: name, type: .color, text: fill)
            } else {
                throw SceneError.invalid("Fill controls need a text or shape layer.")
            }
        }
        parameter.targets = [target]
        guard parameter.isValid else { throw SceneError.invalid("The new control default is invalid.") }
        return parameter
    }

    static func updateMapping(_ target: ScenePropertyAddress, scale: Double, offset: Double,
                              period: Double, smoothing: Double,
                              in scene: SceneDescriptor) throws -> SceneDescriptor {
        guard scale.isFinite, offset.isFinite, period.isFinite, (0.1...86400).contains(period),
              smoothing.isFinite, (0...5).contains(smoothing),
              let index = scene.bindings.firstIndex(where: { $0.target == target }) else {
            throw SceneError.invalid("Use finite scale/offset, period 0.1–86400 seconds and smoothing 0–5 seconds.")
        }
        var next = scene
        next.bindings[index].scale = scale
        next.bindings[index].offset = offset
        next.bindings[index].period = period
        next.bindings[index].smoothing = smoothing
        _ = try next.evaluated()
        return next
    }

    static func setInterpolation(_ interpolation: SceneKeyframeTrack.Interpolation,
                                 target: ScenePropertyAddress, in scene: SceneDescriptor) throws -> SceneDescriptor {
        guard let index = scene.bindings.firstIndex(where: { $0.target == target }),
              var track = scene.bindings[index].keyframes else {
            throw SceneError.invalid("This property has no keyframe track.")
        }
        track.interpolation = interpolation
        var next = scene
        next.bindings[index].keyframes = track
        _ = try next.evaluated()
        return next
    }

    static func removeKey(_ target: ScenePropertyAddress, time: Double, signals: SceneSignals,
                          in scene: SceneDescriptor) throws -> SceneDescriptor {
        guard let index = scene.bindings.firstIndex(where: { $0.target == target }),
              var track = scene.bindings[index].keyframes,
              let key = keyIndex(in: track, at: time) else { return scene }
        if track.keys.count == 1 { return try makeStatic(target, signals: signals, in: scene) }
        track.keys.remove(at: key)
        var next = scene
        next.bindings[index].keyframes = track
        _ = try next.evaluated()
        return next
    }

    static func sourceValue(forVisibleValue value: Double, binding: SceneParameterBinding,
                            scene: SceneDescriptor) throws -> Double {
        var raw = value
        for modifier in binding.modifiers.reversed() {
            let operand: Double
            if let key = modifier.parameter, let parameter = scene.parameters[key], parameter.type == .number {
                operand = parameter.value
            } else if let value = modifier.value {
                operand = value
            } else {
                throw SceneError.invalid("A binding modifier references a missing control.")
            }
            switch modifier.operation {
            case .add: raw -= operand
            case .multiply:
                guard abs(operand) > Double.ulpOfOne else {
                    throw SceneError.invalid("A zero modifier cannot be inverted.")
                }
                raw /= operand
            }
        }
        guard abs(binding.scale) > Double.ulpOfOne else {
            throw SceneError.invalid("A zero binding scale cannot be inverted.")
        }
        let source = (raw - binding.offset) / binding.scale
        guard source.isFinite, abs(source) <= 1_000_000 else {
            throw SceneError.invalid("The key source is outside its supported range.")
        }
        return source
    }

    private static func typedParameter(_ parameter: SceneParameter, supports target: SceneControlTarget,
                                       in nodes: [SceneNode]) throws -> Bool {
        guard let node = nodes.flatMap({ $0.descendants }).first(where: { $0.id == target.nodeID }) else { return false }
        switch target.property {
        case .visible: return parameter.type == .boolean
        case .blend:
            return parameter.type == .choice && parameter.choices.allSatisfy { SceneNode.Blend(rawValue: $0) != nil }
        case .text: return parameter.type == .string && node.typography != nil
        case .fill: return parameter.type == .color && (node.typography != nil || node.shape != nil)
        }
    }

    private static func upsert(_ value: Double, at time: Double, in track: inout SceneKeyframeTrack) {
        if let index = keyIndex(in: track, at: time) {
            track.keys[index].value = value
            return
        }
        track.keys.append(.init(time: time, value: value))
        track.keys.sort { $0.time < $1.time }
    }
}
