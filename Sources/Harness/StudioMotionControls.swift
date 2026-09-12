import AppKit

enum StudioMotionCommand {
    case select
    case makeStatic
    case addKey
    case removeKey
    case bindSignal(SceneParameterBinding.Signal)
    case bindControl(String)
    case createControl
    case updateMapping(scale: Double, offset: Double, period: Double, smoothing: Double)
    case interpolation(SceneKeyframeTrack.Interpolation)
    case revealTimeline
    case advancedBinding
    case advancedKeyframes
}

enum StudioTypedMotionCommand {
    case select
    case makeStatic
    case bindControl(String)
    case createControl
}

/// Compact per-property Motion affordance. The popover edits the existing binding/keyframe model;
/// it owns no document state and delegates every mutation to StudioWindowController.
final class StudioPropertyMotionButton: NSButton {
    private var scene = SceneDescriptor(title: "Motion", nodes: [SceneNode(content: .gradient)])
    private var targetAddress: ScenePropertyAddress?
    private var playhead: Double = 0
    private var enabledForEditing = false
    private var retainedActions: [NSObject] = []
    private var presentedPopover: NSPopover?
    var onCommand: ((ScenePropertyAddress, StudioMotionCommand) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        bezelStyle = .texturedRounded
        isBordered = false
        imagePosition = .imageOnly
        target = self
        action = #selector(openEditor)
        setAccessibilityLabel("Motion")
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(target: ScenePropertyAddress, scene: SceneDescriptor, time: Double, enabled: Bool) {
        targetAddress = target
        self.scene = scene
        playhead = time
        enabledForEditing = enabled
        let owner = StudioMotionAuthoring.ownership(of: target, in: scene)
        let symbol: String
        switch owner {
        case .staticValue: symbol = "circle"
        case .controlled: symbol = "slider.horizontal.3"
        case .driven: symbol = "waveform.path"
        case .keyframed: symbol = "diamond.fill"
        }
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: owner.title)
        toolTip = "Motion · \(owner.title)"
        setAccessibilityLabel("Motion · \(owner.title)")
        isEnabled = true
    }

    @objc private func openEditor() {
        guard let target = targetAddress else { return }
        retainedActions.removeAll()
        presentedPopover?.close()
        onCommand?(target, .select)
        let owner = StudioMotionAuthoring.ownership(of: target, in: scene)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let title = NSTextField(labelWithString: target.label(in: scene.nodes))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let status = NSTextField(labelWithString: owner.title)
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(status)

        let ownerRow = NSStackView()
        ownerRow.spacing = 6
        ownerRow.addArrangedSubview(commandButton("Static", command: .makeStatic))
        ownerRow.addArrangedSubview(commandButton("Keyframes", command: .addKey))
        stack.addArrangedSubview(ownerRow)

        let drivers = NSPopUpButton(frame: .zero, pullsDown: true)
        drivers.addItem(withTitle: "Driver…")
        for item in [
            ("Time", SceneParameterBinding.Signal.time),
            ("Sine", .sine),
            ("Pointer X", .pointerX),
            ("Pointer Y", .pointerY),
            ("Audio Level", .audioLevel),
            ("Audio Bass", .audioBass),
            ("Audio Mid", .audioMid),
            ("Audio Treble", .audioTreble)
        ] {
            let action = StudioMotionMenuAction { [weak self] in self?.onCommand?(target, .bindSignal(item.1)) }
            retainedActions.append(action)
            let menuItem = NSMenuItem(title: item.0, action: #selector(StudioMotionMenuAction.perform(_:)), keyEquivalent: "")
            menuItem.target = action
            drivers.menu?.addItem(menuItem)
        }
        drivers.isEnabled = enabledForEditing
        stack.addArrangedSubview(drivers)

        let control = NSPopUpButton(frame: .zero, pullsDown: true)
        control.addItem(withTitle: "Control…")
        let numeric = scene.parameters.filter { $0.value.type == .number }.sorted { $0.value.name < $1.value.name }
        for pair in numeric {
            let action = StudioMotionMenuAction { [weak self] in self?.onCommand?(target, .bindControl(pair.key)) }
            retainedActions.append(action)
            let item = NSMenuItem(title: pair.value.name, action: #selector(StudioMotionMenuAction.perform(_:)), keyEquivalent: "")
            item.target = action
            control.menu?.addItem(item)
        }
        if !numeric.isEmpty { control.menu?.addItem(.separator()) }
        let createAction = StudioMotionMenuAction { [weak self] in self?.onCommand?(target, .createControl) }
        retainedActions.append(createAction)
        let create = NSMenuItem(title: "New Numeric Control…", action: #selector(StudioMotionMenuAction.perform(_:)), keyEquivalent: "")
        create.target = createAction
        control.menu?.addItem(create)
        control.isEnabled = enabledForEditing
        stack.addArrangedSubview(control)

        if let binding = scene.bindings.first(where: { $0.target == target }) {
            stack.addArrangedSubview(separator())
            let scale = field(binding.scale, label: "Scale")
            let offset = field(binding.offset, label: "Offset")
            let period = field(binding.period, label: "Period")
            let smoothing = field(binding.smoothing, label: "Smooth")
            stack.addArrangedSubview(fieldRow("Scale", scale))
            stack.addArrangedSubview(fieldRow("Offset", offset))
            if binding.signal == .sine { stack.addArrangedSubview(fieldRow("Period", period)) }
            if binding.signal != nil || binding.keyframes != nil { stack.addArrangedSubview(fieldRow("Smooth", smoothing)) }
            let apply = NSButton(title: "Apply Mapping", target: nil, action: nil)
            let action = StudioMotionAction { [weak self] in
                guard let self, let s = Double(scale.stringValue), let o = Double(offset.stringValue),
                      let p = Double(period.stringValue), let d = Double(smoothing.stringValue) else { NSSound.beep(); return }
                self.onCommand?(target, .updateMapping(scale: s, offset: o, period: p, smoothing: d))
            }
            retainedActions.append(action)
            apply.target = action
            apply.action = #selector(StudioMotionAction.perform)
            apply.isEnabled = enabledForEditing
            stack.addArrangedSubview(apply)

            if let track = binding.keyframes {
                let atKey = StudioMotionAuthoring.keyIndex(in: track, at: playhead) != nil
                let keys = NSStackView(views: [commandButton(atKey ? "Update Key" : "Add Key", command: .addKey)])
                if atKey { keys.addArrangedSubview(commandButton("Remove Key", command: .removeKey)) }
                keys.spacing = 6
                stack.addArrangedSubview(keys)
                let interpolation = NSPopUpButton()
                interpolation.addItems(withTitles: ["Hold", "Linear", "Ease In/Out"])
                interpolation.selectItem(at: track.interpolation == .hold ? 0 : track.interpolation == .linear ? 1 : 2)
                let interpolationAction = StudioMotionAction { [weak self, weak interpolation] in
                    guard let self, let interpolation else { return }
                    let value: SceneKeyframeTrack.Interpolation = interpolation.indexOfSelectedItem == 0 ? .hold : interpolation.indexOfSelectedItem == 1 ? .linear : .easeInOut
                    self.onCommand?(target, .interpolation(value))
                }
                retainedActions.append(interpolationAction)
                interpolation.target = interpolationAction
                interpolation.action = #selector(StudioMotionAction.perform)
                interpolation.isEnabled = enabledForEditing
                stack.addArrangedSubview(fieldRow("Curve", interpolation))
            }
            if !binding.modifiers.isEmpty {
                let modifiers = NSTextField(labelWithString: "\(binding.modifiers.count) modifier\(binding.modifiers.count == 1 ? "" : "s") preserved")
                modifiers.font = .systemFont(ofSize: 10)
                modifiers.textColor = .secondaryLabelColor
                stack.addArrangedSubview(modifiers)
            }
        }

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(commandButton("Reveal in Timeline", command: .revealTimeline, enabled: true))
        if scene.bindings.contains(where: { $0.target == target }) {
            let advanced = NSStackView(views: [commandButton("Advanced Binding…", command: .advancedBinding, enabled: true),
                                               commandButton("Advanced Track…", command: .advancedKeyframes, enabled: true)])
            advanced.spacing = 6
            stack.addArrangedSubview(advanced)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 270, height: max(220, CGFloat(stack.arrangedSubviews.count * 31)))
        let controller = NSViewController()
        controller.view = stack
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        presentedPopover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
    }

    private func commandButton(_ title: String, command: StudioMotionCommand, enabled: Bool? = nil) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        let action = StudioMotionAction { [weak self] in
            guard let self, let target = self.targetAddress else { return }
            self.onCommand?(target, command)
        }
        retainedActions.append(action)
        button.target = action
        button.action = #selector(StudioMotionAction.perform)
        button.isEnabled = enabled ?? enabledForEditing
        return button
    }

    private func field(_ value: Double, label: String) -> NSTextField {
        let field = NSTextField(string: String(format: "%.4g", value))
        field.setAccessibilityLabel(label)
        field.widthAnchor.constraint(equalToConstant: 88).isActive = true
        field.isEnabled = enabledForEditing
        return field
    }

    private func fieldRow(_ title: String, _ view: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let row = NSStackView(views: [label, view])
        row.spacing = 6
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 240).isActive = true
        return box
    }
}

final class StudioTypedMotionButton: NSButton {
    private var scene = SceneDescriptor(title: "Motion", nodes: [SceneNode(content: .gradient)])
    private var propertyTarget: SceneControlTarget?
    private var enabledForEditing = false
    private var retainedActions: [NSObject] = []
    private var presentedPopover: NSPopover?
    var onCommand: ((SceneControlTarget, StudioTypedMotionCommand) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        bezelStyle = .texturedRounded
        isBordered = false
        imagePosition = .imageOnly
        target = self
        action = #selector(openEditor)
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(target: SceneControlTarget, scene: SceneDescriptor, enabled: Bool) {
        propertyTarget = target
        self.scene = scene
        enabledForEditing = enabled
        let owner = StudioMotionAuthoring.typedOwnership(of: target, in: scene)
        image = NSImage(systemSymbolName: owner == .staticValue ? "circle" : "slider.horizontal.3",
                        accessibilityDescription: owner.title)
        toolTip = "Motion · \(owner.title)"
        setAccessibilityLabel("Motion · \(owner.title)")
        isEnabled = true
    }

    @objc private func openEditor() {
        guard let target = propertyTarget else { return }
        retainedActions.removeAll()
        presentedPopover?.close()
        onCommand?(target, .select)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let title = NSTextField(labelWithString: typedLabel(target.property))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let owner = StudioMotionAuthoring.typedOwnership(of: target, in: scene)
        let status = NSTextField(labelWithString: owner.title)
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(status)
        stack.addArrangedSubview(commandButton("Static", command: .makeStatic))

        let control = NSPopUpButton(frame: .zero, pullsDown: true)
        control.addItem(withTitle: "Control…")
        let compatible = scene.parameters.filter { pair in
            switch target.property {
            case .visible: return pair.value.type == .boolean
            case .blend: return pair.value.type == .choice && pair.value.choices.allSatisfy { SceneNode.Blend(rawValue: $0) != nil }
            case .text: return pair.value.type == .string
            case .fill: return pair.value.type == .color
            }
        }.sorted { $0.value.name < $1.value.name }
        for pair in compatible {
            let action = StudioMotionMenuAction { [weak self] in self?.onCommand?(target, .bindControl(pair.key)) }
            retainedActions.append(action)
            let item = NSMenuItem(title: pair.value.name, action: #selector(StudioMotionMenuAction.perform(_:)), keyEquivalent: "")
            item.target = action
            control.menu?.addItem(item)
        }
        if !compatible.isEmpty { control.menu?.addItem(.separator()) }
        let createAction = StudioMotionMenuAction { [weak self] in self?.onCommand?(target, .createControl) }
        retainedActions.append(createAction)
        let create = NSMenuItem(title: "New Control…", action: #selector(StudioMotionMenuAction.perform(_:)), keyEquivalent: "")
        create.target = createAction
        control.menu?.addItem(create)
        control.isEnabled = enabledForEditing
        stack.addArrangedSubview(control)
        stack.frame = NSRect(x: 0, y: 0, width: 250, height: 130)
        let controller = NSViewController()
        controller.view = stack
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        presentedPopover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
    }

    private func commandButton(_ title: String, command: StudioTypedMotionCommand) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        let action = StudioMotionAction { [weak self] in
            guard let self, let target = self.propertyTarget else { return }
            self.onCommand?(target, command)
        }
        retainedActions.append(action)
        button.target = action
        button.action = #selector(StudioMotionAction.perform)
        button.isEnabled = enabledForEditing
        return button
    }

    private func typedLabel(_ property: SceneControlTarget.Property) -> String {
        switch property {
        case .visible: return "Visibility"
        case .blend: return "Blend"
        case .text: return "Text"
        case .fill: return "Fill"
        }
    }
}

private final class StudioMotionAction: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func perform() { block() }
}

private final class StudioMotionMenuAction: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func perform(_ sender: Any?) { block() }
}
