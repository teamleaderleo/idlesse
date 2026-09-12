import AppKit

/// Presentation-only ownership state for properties shown in Studio's persistent inspector.
/// SceneParameterBinding and SceneParameter remain the source of truth for authored behavior.
enum StudioInspectorPropertyState: Equatable {
    case staticValue
    case driven
    case keyframed
    case controlled

    var title: String {
        switch self {
        case .staticValue: return "Static"
        case .driven: return "Driven"
        case .keyframed: return "Keyframed"
        case .controlled: return "Controlled"
        }
    }
}

enum StudioInspectorState {
    static func numeric(_ target: ScenePropertyAddress, in scene: SceneDescriptor) -> StudioInspectorPropertyState {
        switch StudioMotionAuthoring.ownership(of: target, in: scene) {
        case .staticValue: return .staticValue
        case .controlled: return .controlled
        case .driven: return .driven
        case .keyframed: return .keyframed
        }
    }

    static func typed(_ property: SceneControlTarget.Property, nodeID: UUID,
                      in scene: SceneDescriptor) -> StudioInspectorPropertyState {
        StudioMotionAuthoring.typedControlKey(for: .init(nodeID: nodeID, property: property), in: scene) == nil ? .staticValue : .controlled
    }

    static func numericDetail(_ target: ScenePropertyAddress, in scene: SceneDescriptor) -> String? {
        guard let binding = scene.bindings.first(where: { $0.target == target }) else { return "Authored value." }
        if binding.keyframes != nil { return "Owned by a keyframe track." }
        if let signal = binding.signal { return "Driven by \(signal.rawValue)." }
        if let parameter = scene.parameters[binding.parameter] { return "Controlled by scene control “\(parameter.name)”." }
        return "Controlled by a scene parameter."
    }

    static func typedDetail(_ property: SceneControlTarget.Property, nodeID: UUID,
                            in scene: SceneDescriptor) -> String? {
        let target = SceneControlTarget(nodeID: nodeID, property: property)
        guard let key = StudioMotionAuthoring.typedControlKey(for: target, in: scene), let parameter = scene.parameters[key] else { return nil }
        return "Controlled by scene control “\(parameter.name)”."
    }
}

private final class StudioInspectorDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class StudioInspectorSection: NSStackView {
    private let header = NSButton()
    private let body = NSStackView()
    private(set) var expanded: Bool

    init(title: String, expanded: Bool = true) {
        self.expanded = expanded
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        header.title = title
        header.isBordered = false
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.alignment = .left
        header.imagePosition = .imageLeading
        header.target = self
        header.action = #selector(toggle)
        header.setAccessibilityLabel(title.capitalized + " inspector section")
        header.widthAnchor.constraint(equalToConstant: 286).isActive = true
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 7
        body.edgeInsets = NSEdgeInsets(top: 2, left: 14, bottom: 8, right: 0)
        body.widthAnchor.constraint(equalToConstant: 286).isActive = true
        addArrangedSubview(header)
        addArrangedSubview(body)
        refreshDisclosure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setViews(_ views: [NSView]) {
        for view in body.arrangedSubviews { body.removeArrangedSubview(view); view.removeFromSuperview() }
        for view in views { body.addArrangedSubview(view) }
    }
    func setExpanded(_ value: Bool) { expanded = value; refreshDisclosure() }
    @objc private func toggle() { expanded.toggle(); refreshDisclosure() }
    private func refreshDisclosure() {
        body.isHidden = !expanded
        header.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
    }
}

/// Persistent AppKit inspector for the selected Studio layer.
final class StudioLayerInspector: NSScrollView {
    let nameField = NSTextField(string: "")
    private(set) var transformFields: [NSTextField] = []

    var onRename: (() -> Void)?
    var onTransform: (() -> Void)?
    var onNumericProperty: ((ScenePropertyAddress, Double) -> Void)?
    var onSelectMotionTarget: ((ScenePropertyAddress) -> Void)?
    var onMotionCommand: ((ScenePropertyAddress, StudioMotionCommand) -> Void)?
    var onTypedMotionCommand: ((SceneControlTarget, StudioTypedMotionCommand) -> Void)?
    var onVisibility: (() -> Void)?
    var onLock: (() -> Void)?
    var onCommitNode: ((SceneNode, String) -> Void)?
    var onChooseMaskImage: ((SceneNode) -> Void)?
    var onChooseSpriteImage: ((SceneNode) -> Void)?
    var onEditControls: (() -> Void)?
    var onEditBinding: (() -> Void)?
    var onEditKeyframes: (() -> Void)?
    var onError: ((String) -> Void)?

    private let document = StudioInspectorDocumentView()
    private let stack = NSStackView()
    private let layerSection = StudioInspectorSection(title: "LAYER")
    private let contentSection = StudioInspectorSection(title: "CONTENT")
    private let transformSection = StudioInspectorSection(title: "TRANSFORM")
    private let appearanceSection = StudioInspectorSection(title: "APPEARANCE", expanded: false)
    private let compositingSection = StudioInspectorSection(title: "COMPOSITING", expanded: false)
    private let motionSection = StudioInspectorSection(title: "MOTION", expanded: false)
    private let sceneSection = StudioInspectorSection(title: "SCENE", expanded: false)
    private let visibility = NSButton(checkboxWithTitle: "Visible", target: nil, action: nil)
    private let locked = NSButton(checkboxWithTitle: "Locked", target: nil, action: nil)
    private let visibilityState = NSTextField(labelWithString: "")
    private let visibilityMotion = StudioTypedMotionButton(frame: .zero)
    private var transformStates: [NSTextField] = []
    private var transformMotionButtons: [StudioPropertyMotionButton] = []
    private var dynamicMotionButtons: [(ScenePropertyAddress, StudioPropertyMotionButton)] = []
    private var numericTargets: [ObjectIdentifier: ScenePropertyAddress] = [:]
    private var layerActionViews: [NSView] = []
    private var motionSessionViews: [NSView] = []
    private var sceneActionViews: [NSView] = []
    private var currentScene = SceneDescriptor(title: "Inspector", nodes: [SceneNode(content: .gradient)])
    private var currentNode: SceneNode?
    private var currentTime: Double = 0
    private var currentSignals = SceneSignals()
    private var currentAutoKey = false
    private var selectedMotionTarget: ScenePropertyAddress?
    private var shaderEditor: StudioShaderEditorController?
    private var busy = false
    private var contentApply: (() throws -> Void)?
    private var appearanceApply: (() throws -> Void)?
    private var compositingApply: (() throws -> Void)?
    private let transformProperties: [ScenePropertyAddress.Property] = [.x, .y, .scale, .rotation, .opacity]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasVerticalScroller = true
        drawsBackground = false
        borderType = .noBorder
        setAccessibilityLabel("Layer inspector")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        for section in [layerSection, contentSection, transformSection, appearanceSection,
                        compositingSection, motionSection, sceneSection] { stack.addArrangedSubview(section) }
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 2),
            stack.widthAnchor.constraint(equalToConstant: 286),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -4)
        ])
        document.frame = NSRect(x: 0, y: 0, width: 292, height: 760)
        documentView = document
        nameField.placeholderString = "Layer name"
        nameField.setAccessibilityLabel("Layer name")
        nameField.target = self
        nameField.action = #selector(rename)
        nameField.widthAnchor.constraint(equalToConstant: 270).isActive = true
        visibility.target = self; visibility.action = #selector(toggleVisibility)
        locked.target = self; locked.action = #selector(toggleLock)
        visibilityState.font = .systemFont(ofSize: 10, weight: .semibold)
        visibilityState.textColor = .secondaryLabelColor
        visibilityMotion.onCommand = { [weak self] target, command in self?.onTypedMotionCommand?(target, command) }

        let labels = ["X", "Y", "Scale", "Rotation °", "Opacity"]
        var transformRows: [NSView] = []
        for index in transformProperties.indices {
            let field = NSTextField(string: "")
            field.tag = index; field.target = self; field.action = #selector(changeTransform(_:))
            field.setAccessibilityLabel(labels[index])
            field.widthAnchor.constraint(equalToConstant: 78).isActive = true
            transformFields.append(field)
            let state = stateLabel(); state.widthAnchor.constraint(equalToConstant: 62).isActive = true
            transformStates.append(state)
            let motion = StudioPropertyMotionButton(frame: .zero)
            motion.onCommand = { [weak self] target, command in self?.handleMotion(target, command: command) }
            transformMotionButtons.append(motion)
            let title = NSTextField(labelWithString: labels[index]); title.widthAnchor.constraint(equalToConstant: 68).isActive = true
            let row = NSStackView(views: [title, field, state, motion])
            row.spacing = 5; row.widthAnchor.constraint(equalToConstant: 270).isActive = true
            transformRows.append(row)
        }
        transformSection.setViews(transformRows)
        rebuildLayerSection(); rebuildMotionSection(); rebuildSceneSection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func install(layerActions: [NSView], motionSession: [NSView], sceneActions: [NSView]) {
        layerActionViews = layerActions; motionSessionViews = motionSession; sceneActionViews = sceneActions
        rebuildLayerSection(); rebuildMotionSection(); rebuildSceneSection()
    }

    func revealContent() { contentSection.setExpanded(true) }

    func revealMotionTarget(_ target: ScenePropertyAddress?) {
        selectedMotionTarget = target
        guard let target else { refreshMotionSelection(); return }
        switch target.property {
        case .x, .y, .scale, .rotation, .opacity: transformSection.setExpanded(true)
        case .particleSize, .particleWind, .particleSpeed: contentSection.setExpanded(true)
        case .exposure, .saturation, .vignette, .effectAmount: appearanceSection.setExpanded(true)
        }
        refreshMotionSelection()
        if let button = allMotionButtons().first(where: { $0.0 == target })?.1 {
            button.scrollToVisible(button.bounds)
        }
    }

    func update(scene: SceneDescriptor, node: SceneNode?, saving: Bool, time: Double = 0,
                signals: SceneSignals? = nil, autoKey: Bool = false) {
        currentScene = scene; currentNode = node; busy = saving; currentTime = time
        currentSignals = signals ?? SceneSignals(time: time); currentAutoKey = autoKey
        dynamicMotionButtons.removeAll(); numericTargets.removeAll()
        guard let node else {
            nameField.stringValue = ""; nameField.isEnabled = false; visibility.isEnabled = false; locked.isEnabled = false
            contentSection.setViews([NSTextField(labelWithString: "Select a layer to inspect it.")])
            appearanceSection.setViews([]); compositingSection.setViews([]); rebuildMotionSection(); return
        }
        if selectedMotionTarget?.nodeID != node.id { selectedMotionTarget = nil }
        let presented = (try? scene.evaluated(signals: currentSignals).allNodes.first(where: { $0.id == node.id })) ?? node
        if nameField.currentEditor() == nil { nameField.stringValue = node.displayName }
        let editable = !saving && !node.locked
        nameField.isEditable = editable; nameField.isEnabled = !saving
        visibility.state = presented.visible ? .on : .off; locked.state = node.locked ? .on : .off; locked.isEnabled = !saving
        let visibleState = StudioInspectorState.typed(.visible, nodeID: node.id, in: scene)
        visibility.isEnabled = !saving && visibleState == .staticValue
        visibilityState.stringValue = visibleState.title
        visibilityState.toolTip = StudioInspectorState.typedDetail(.visible, nodeID: node.id, in: scene)
        visibilityMotion.update(target: .init(nodeID: node.id, property: .visible), scene: scene, enabled: editable)

        let values: [Double] = [presented.transform.x ?? 0, presented.transform.y ?? 0, presented.transform.scale ?? 1,
                                presented.transform.rotation ?? 0, presented.opacity]
        for index in transformFields.indices {
            let target = ScenePropertyAddress(nodeID: node.id, property: transformProperties[index])
            let field = transformFields[index]
            if field.currentEditor() == nil { field.stringValue = String(format: "%.3f", values[index]) }
            let state = StudioInspectorState.numeric(target, in: scene)
            let disposition = StudioMotionAuthoring.writeDisposition(for: target, in: scene, time: time, autoKey: autoKey)
            transformStates[index].stringValue = state.title
            transformStates[index].toolTip = StudioInspectorState.numericDetail(target, in: scene)
            field.isEnabled = editable && disposition.writable
            field.toolTip = disposition == .blockedBetweenKeys ? "Auto-Key is off; add a key at this playhead to edit." : StudioInspectorState.numericDetail(target, in: scene)
            transformMotionButtons[index].update(target: target, scene: scene, time: time, enabled: editable)
        }

        rebuildLayerSection()
        rebuildContentSection(node: node, editable: editable)
        rebuildAppearanceSection(node: node, editable: editable)
        rebuildCompositingSection(node: node, editable: editable)
        rebuildMotionSection(); refreshMotionSelection(); updateDocumentHeight()
    }

    private func rebuildLayerSection() {
        let visibleRow = NSStackView(views: [visibility, visibilityState, visibilityMotion])
        visibleRow.spacing = 8; visibleRow.widthAnchor.constraint(equalToConstant: 270).isActive = true
        var views: [NSView] = [nameField, visibleRow, locked]
        if !layerActionViews.isEmpty { views.append(separator()); views.append(contentsOf: layerActionViews) }
        layerSection.setViews(views)
    }

    private func rebuildContentSection(node: SceneNode, editable: Bool) {
        contentApply = nil
        let views: [NSView]
        switch node.content {
        case .image(let url): views = [info("Image", value: url.lastPathComponent, tooltip: url.path)]
        case .video(let url): views = [info("Video", value: url.lastPathComponent, tooltip: url.path)]
        case .gradient: views = [NSTextField(labelWithString: "Procedural gradient")]
        case .group(let children): views = [info("Group", value: "\(children.count) child layer\(children.count == 1 ? "" : "s")")]
        case .text(let typography): views = textViews(node: node, typography: typography, editable: editable)
        case .shape(let primitive): views = shapeViews(node: node, value: primitive, editable: editable)
        case .particles(let emitter): views = emitterViews(node: node, emitter: emitter, editable: editable)
        case .shader(let shader):
            let edit = NSButton(title: "Edit Metal Shader…", target: self, action: #selector(editShader))
            edit.isEnabled = editable
            edit.setAccessibilityLabel("Edit Metal shader source")
            views = [info("Metal Shader", value: "\(shader.source.utf8.count) bytes · \(shader.speed)×",
                          tooltip: "Metal fragment source compiled by the runtime."), edit]
        }
        contentSection.setViews(views)
    }

    private func textViews(node: SceneNode, typography: SceneNode.Typography, editable: Bool) -> [NSView] {
        let source = NSPopUpButton(); source.addItems(withTitles: ["Static Text"] + SceneNode.Typography.LiveSource.allCases.map(\.title))
        if let live = typography.liveSource, let index = SceneNode.Typography.LiveSource.allCases.firstIndex(of: live) { source.selectItem(at: index + 1) }
        source.setAccessibilityLabel("Text source"); source.isEnabled = editable
        let textEditor = NSTextView(); textEditor.isRichText = false; textEditor.isAutomaticQuoteSubstitutionEnabled = false
        textEditor.isAutomaticDashSubstitutionEnabled = false; textEditor.font = .systemFont(ofSize: 13)
        textEditor.textContainerInset = NSSize(width: 5, height: 5); textEditor.string = typography.text
        let textControlled = StudioInspectorState.typed(.text, nodeID: node.id, in: currentScene)
        textEditor.isEditable = editable && textControlled == .staticValue; textEditor.setAccessibilityLabel("Text content")
        let textScroll = NSScrollView(); textScroll.borderType = .bezelBorder; textScroll.hasVerticalScroller = true; textScroll.documentView = textEditor
        textEditor.isVerticallyResizable = true; textEditor.isHorizontallyResizable = false; textEditor.autoresizingMask = [.width]
        textEditor.textContainer?.widthTracksTextView = true; textEditor.frame = NSRect(x: 0, y: 0, width: 270, height: 82)
        textScroll.widthAnchor.constraint(equalToConstant: 270).isActive = true; textScroll.heightAnchor.constraint(equalToConstant: 82).isActive = true
        let font = inspectorField(typography.font, label: "Font name"), size = inspectorField(String(typography.size), label: "Font size")
        let spacing = inspectorField(String(typography.lineSpacing), label: "Line spacing"), width = inspectorField(String(typography.width), label: "Text width")
        let height = inspectorField(String(typography.height), label: "Text height")
        for field in [font, size, spacing, width, height] { field.isEnabled = editable }
        let alignment = NSPopUpButton(); alignment.addItems(withTitles: ["Left", "Center", "Right"])
        alignment.selectItem(at: typography.alignment == .left ? 0 : typography.alignment == .center ? 1 : 2); alignment.setAccessibilityLabel("Text alignment"); alignment.isEnabled = editable
        let fill = NSColorWell(); fill.color = Self.color(from: typography.fill); fill.setAccessibilityLabel("Text fill color")
        let fillControlled = StudioInspectorState.typed(.fill, nodeID: node.id, in: currentScene); fill.isEnabled = editable && fillControlled == .staticValue
        let apply = applyButton(title: "Apply Content", selector: #selector(applyContent), enabled: editable)
        contentApply = { [weak self] in
            guard let self, var next = self.currentNode, next.id == node.id, var text = next.typography else { return }
            text.liveSource = source.indexOfSelectedItem == 0 ? nil : SceneNode.Typography.LiveSource.allCases[source.indexOfSelectedItem - 1]
            if textControlled == .staticValue { text.text = textEditor.string }
            text.font = font.stringValue; text.size = Double(size.stringValue) ?? .nan
            if fillControlled == .staticValue, let hex = Self.hex(fill.color) { text.fill = hex }
            text.lineSpacing = Double(spacing.stringValue) ?? .nan; text.width = Int(width.stringValue) ?? 0; text.height = Int(height.stringValue) ?? 0
            text.alignment = [SceneNode.Typography.Alignment.left, .center, .right][alignment.indexOfSelectedItem]
            next.content = .text(text); try SceneBudget.validate([next]); self.onCommitNode?(next, "Edit Content")
        }
        return [source,
            labeled("Text", view: textScroll, state: textControlled, detail: StudioInspectorState.typedDetail(.text, nodeID: node.id, in: currentScene), typedTarget: .init(nodeID: node.id, property: .text)),
            labeled("Font", view: font), labeled("Size", view: size),
            labeled("Fill", view: fill, state: fillControlled, detail: StudioInspectorState.typedDetail(.fill, nodeID: node.id, in: currentScene), typedTarget: .init(nodeID: node.id, property: .fill)),
            labeled("Alignment", view: alignment), labeled("Line spacing", view: spacing), labeled("Width", view: width), labeled("Height", view: height), apply]
    }

    private func shapeViews(node: SceneNode, value: SceneNode.Shape, editable: Bool) -> [NSView] {
        let primitive = NSPopUpButton(); let primitives: [SceneNode.Shape.Primitive] = [.rectangle, .ellipse, .line, .roundedRectangle]
        primitive.addItems(withTitles: ["Rectangle", "Ellipse", "Line", "Rounded Rectangle"]); primitive.selectItem(at: primitives.firstIndex(of: value.primitive) ?? 3)
        primitive.setAccessibilityLabel("Shape primitive"); primitive.isEnabled = editable
        let fill = NSColorWell(); fill.color = Self.color(from: value.fill); fill.setAccessibilityLabel("Shape fill color")
        let fillControlled = StudioInspectorState.typed(.fill, nodeID: node.id, in: currentScene); fill.isEnabled = editable && fillControlled == .staticValue
        let width = inspectorField(String(value.width), label: "Shape width"), height = inspectorField(String(value.height), label: "Shape height")
        let radius = inspectorField(String(value.cornerRadius), label: "Corner radius"), lineWidth = inspectorField(String(value.lineWidth), label: "Line width")
        for field in [width, height, radius, lineWidth] { field.isEnabled = editable }
        let apply = applyButton(title: "Apply Content", selector: #selector(applyContent), enabled: editable)
        contentApply = { [weak self] in
            guard let self, var next = self.currentNode, next.id == node.id, var graphic = next.shape else { return }
            graphic.primitive = primitives[primitive.indexOfSelectedItem]
            if fillControlled == .staticValue, let hex = Self.hex(fill.color) { graphic.fill = hex }
            graphic.width = Int(width.stringValue) ?? 0; graphic.height = Int(height.stringValue) ?? 0
            graphic.cornerRadius = Double(radius.stringValue) ?? .nan; graphic.lineWidth = Double(lineWidth.stringValue) ?? .nan
            next.content = .shape(graphic); try SceneBudget.validate([next]); self.onCommitNode?(next, "Edit Content")
        }
        return [labeled("Primitive", view: primitive),
            labeled("Fill", view: fill, state: fillControlled, detail: StudioInspectorState.typedDetail(.fill, nodeID: node.id, in: currentScene), typedTarget: .init(nodeID: node.id, property: .fill)),
            labeled("Width", view: width), labeled("Height", view: height), labeled("Corner radius", view: radius), labeled("Line width", view: lineWidth), apply]
    }

    private func emitterViews(node: SceneNode, emitter: SceneNode.Emitter, editable: Bool) -> [NSView] {
        let definitions: [(String, String, ScenePropertyAddress.Property?)] = [
            ("Count", String(emitter.count), nil), ("Lifetime", String(emitter.lifetime), nil), ("Speed", String(emitter.speed), .particleSpeed),
            ("Wind", String(emitter.wind), .particleWind), ("Gravity", String(emitter.gravity), nil), ("Size", String(emitter.size), .particleSize), ("Seed", String(emitter.seed), nil)]
        let fields = definitions.map { inspectorField($0.1, label: $0.0) }; var views: [NSView] = []
        for index in definitions.indices {
            let target = definitions[index].2.map { ScenePropertyAddress(nodeID: node.id, property: $0) }
            if let target {
                let state = StudioInspectorState.numeric(target, in: currentScene)
                configureNumeric(fields[index], target: target, editable: editable)
                views.append(labeled(definitions[index].0, view: fields[index], state: state, detail: StudioInspectorState.numericDetail(target, in: currentScene), target: target))
            } else { fields[index].isEnabled = editable; views.append(labeled(definitions[index].0, view: fields[index])) }
        }
        let sprite = NSPopUpButton(); sprite.addItems(withTitles: ["Procedural Discs", "Keep Current Sprite", "Choose Sprite Image…"])
        sprite.item(at: 1)?.isEnabled = node.sprite != nil; sprite.selectItem(at: node.sprite == nil ? 0 : 1); sprite.setAccessibilityLabel("Particle sprite"); sprite.isEnabled = editable
        views.append(labeled("Sprite", view: sprite)); views.append(applyButton(title: "Apply Emitter", selector: #selector(applyContent), enabled: editable))
        contentApply = { [weak self] in
            guard let self, var next = self.currentNode, next.id == node.id else { return }
            guard let count = Int(fields[0].stringValue), let lifetime = Double(fields[1].stringValue), let speed = Double(fields[2].stringValue),
                  let wind = Double(fields[3].stringValue), let gravity = Double(fields[4].stringValue), let size = Double(fields[5].stringValue), let seed = Int(fields[6].stringValue) else {
                throw SceneError.invalid("Enter numeric emitter values; count and seed must be integers.")
            }
            var updated = SceneNode.Emitter(count: count, lifetime: lifetime, speed: speed, wind: wind, gravity: gravity, size: size, seed: seed)
            for (index, property) in [(2, ScenePropertyAddress.Property.particleSpeed), (3, .particleWind), (5, .particleSize)] {
                let target = ScenePropertyAddress(nodeID: node.id, property: property)
                if StudioMotionAuthoring.ownership(of: target, in: self.currentScene) != .staticValue {
                    switch property {
                    case .particleSpeed: updated.speed = emitter.speed
                    case .particleWind: updated.wind = emitter.wind
                    case .particleSize: updated.size = emitter.size
                    default: break
                    }
                    _ = index
                }
            }
            try updated.validate(); next.content = .particles(updated)
            if sprite.indexOfSelectedItem == 0 { next.sprite = nil }
            if sprite.indexOfSelectedItem == 2 { self.onChooseSpriteImage?(next) } else { self.onCommitNode?(next, "Change Emitter") }
        }
        return views
    }

    private func rebuildAppearanceSection(node: SceneNode, editable: Bool) {
        let mask = NSPopUpButton(); mask.addItems(withTitles: ["No Mask", "Ellipse Mask"]); mask.selectItem(at: node.style.mask == .ellipse ? 1 : 0)
        mask.setAccessibilityLabel("Layer appearance mask"); mask.isEnabled = editable
        let exposure = inspectorField(String(node.style.exposure), label: "Exposure"), saturation = inspectorField(String(node.style.saturation), label: "Saturation")
        let vignette = NSSlider(value: node.style.vignette, minValue: 0, maxValue: 1, target: nil, action: nil); vignette.setAccessibilityLabel("Vignette strength")
        vignette.widthAnchor.constraint(equalToConstant: 150).isActive = true; vignette.isContinuous = false
        let expTarget = ScenePropertyAddress(nodeID: node.id, property: .exposure), satTarget = ScenePropertyAddress(nodeID: node.id, property: .saturation)
        let vigTarget = ScenePropertyAddress(nodeID: node.id, property: .vignette)
        configureNumeric(exposure, target: expTarget, editable: editable); configureNumeric(saturation, target: satTarget, editable: editable); configureNumeric(vignette, target: vigTarget, editable: editable)
        let effectEditor = SceneEffectsEditor(effects: node.style.effects); if !editable { Self.setControls(in: effectEditor, enabled: false) }
        var views: [NSView] = [labeled("Mask", view: mask),
            labeled("Exposure", view: exposure, state: StudioInspectorState.numeric(expTarget, in: currentScene), detail: StudioInspectorState.numericDetail(expTarget, in: currentScene), target: expTarget),
            labeled("Saturation", view: saturation, state: StudioInspectorState.numeric(satTarget, in: currentScene), detail: StudioInspectorState.numericDetail(satTarget, in: currentScene), target: satTarget),
            labeled("Vignette", view: vignette, state: StudioInspectorState.numeric(vigTarget, in: currentScene), detail: StudioInspectorState.numericDetail(vigTarget, in: currentScene), target: vigTarget),
            NSTextField(labelWithString: "Effects · drag to reorder")]
        for effect in node.style.effects {
            guard let id = effect.id else { continue }
            let target = ScenePropertyAddress(nodeID: node.id, property: .effectAmount, effectID: id)
            let state = StudioInspectorState.numeric(target, in: currentScene)
            let label = NSTextField(labelWithString: "\(effect.type.rawValue.capitalized) amount"); label.font = .systemFont(ofSize: 10)
            let status = stateLabel(); status.stringValue = state.title; status.toolTip = StudioInspectorState.numericDetail(target, in: currentScene)
            let row = NSStackView(views: [label, status, motionButton(for: target, editable: editable)]); row.spacing = 6; row.widthAnchor.constraint(equalToConstant: 270).isActive = true
            views.append(row)
        }
        views.append(effectEditor); views.append(applyButton(title: "Apply Appearance", selector: #selector(applyAppearance), enabled: editable))
        appearanceApply = { [weak self] in
            guard let self, var next = self.currentNode, next.id == node.id else { return }
            guard let ev = Double(exposure.stringValue), let sat = Double(saturation.stringValue), ev.isFinite, (-2...2).contains(ev), sat.isFinite, (0...2).contains(sat) else {
                throw SceneError.invalid("Use exposure −2…2 and saturation 0…2.")
            }
            let effects = try effectEditor.validatedEffects()
            var style = next.style
            style.mask = mask.indexOfSelectedItem == 1 ? .ellipse : nil
            if StudioMotionAuthoring.ownership(of: expTarget, in: self.currentScene) == .staticValue { style.exposure = ev }
            if StudioMotionAuthoring.ownership(of: satTarget, in: self.currentScene) == .staticValue { style.saturation = sat }
            if StudioMotionAuthoring.ownership(of: vigTarget, in: self.currentScene) == .staticValue { style.vignette = vignette.doubleValue }
            style.effects = effects
            next.style = style; try SceneBudget.validate([next]); self.onCommitNode?(next, "Change Appearance")
        }
        appearanceSection.setViews(views)
    }

    private func rebuildCompositingSection(node: SceneNode, editable: Bool) {
        let blends: [SceneNode.Blend] = [.normal, .add, .multiply, .screen]
        let blend = NSPopUpButton(); blend.addItems(withTitles: ["Normal", "Add", "Multiply", "Screen"]); blend.selectItem(at: blends.firstIndex(of: node.blend ?? .normal) ?? 0)
        blend.setAccessibilityLabel("Blend mode"); let blendState = StudioInspectorState.typed(.blend, nodeID: node.id, in: currentScene); blend.isEnabled = editable && blendState == .staticValue
        let candidates = currentScene.allNodes.filter { $0.id != node.id }; let mask = NSPopUpButton()
        mask.addItems(withTitles: ["No asset/node mask", "Choose Image…", "Keep Current Image"] + candidates.map(\.displayName)); mask.item(at: 2)?.isEnabled = node.maskAsset != nil
        if node.maskAsset != nil { mask.selectItem(at: 2) } else if let id = node.maskNodeID, let index = candidates.firstIndex(where: { $0.id == id }) { mask.selectItem(at: index + 3) } else { mask.selectItem(at: 0) }
        mask.setAccessibilityLabel("Mask source"); mask.isEnabled = editable
        let channel = NSPopUpButton(); channel.addItems(withTitles: ["Alpha", "Luminance"]); channel.selectItem(at: node.maskChannel == .luma ? 1 : 0); channel.setAccessibilityLabel("Mask channel"); channel.isEnabled = editable
        compositingApply = { [weak self] in
            guard let self, var next = self.currentNode, next.id == node.id else { return }
            if blendState == .staticValue { next.blend = blends[blend.indexOfSelectedItem] == .normal ? nil : blends[blend.indexOfSelectedItem] }
            next.maskChannel = channel.indexOfSelectedItem == 1 ? .luma : nil
            switch mask.indexOfSelectedItem {
            case 0: next.maskAsset = nil; next.maskNodeID = nil
            case 1: next.maskAsset = nil; next.maskNodeID = nil; self.onChooseMaskImage?(next); return
            case 2: next.maskNodeID = nil
            default: next.maskAsset = nil; next.maskNodeID = candidates[mask.indexOfSelectedItem - 3].id
            }
            self.onCommitNode?(next, "Change Mask and Blend")
        }
        compositingSection.setViews([
            labeled("Blend", view: blend, state: blendState, detail: StudioInspectorState.typedDetail(.blend, nodeID: node.id, in: currentScene), typedTarget: .init(nodeID: node.id, property: .blend)),
            labeled("Mask source", view: mask), labeled("Mask channel", view: channel), applyButton(title: "Apply Compositing", selector: #selector(applyCompositing), enabled: editable)])
    }

    private func rebuildMotionSection() {
        var views: [NSView] = []
        let hint = NSTextField(labelWithString: "Motion lives beside each property. Advanced editors remain for modifier chains and bulk track work.")
        hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabelColor; hint.maximumNumberOfLines = 3; hint.preferredMaxLayoutWidth = 270
        views.append(hint)
        let controls = NSStackView(views: [NSButton(title: "Controls…", target: self, action: #selector(editControls)),
                                          NSButton(title: "Advanced Binding…", target: self, action: #selector(editBinding)),
                                          NSButton(title: "Advanced Keyframes…", target: self, action: #selector(editKeyframes))])
        controls.spacing = 5; views.append(controls)
        if !motionSessionViews.isEmpty { views.append(contentsOf: motionSessionViews) }
        motionSection.setViews(views)
    }

    private func rebuildSceneSection() { sceneSection.setViews(sceneActionViews) }

    private func labeled(_ title: String, view: NSView, state: StudioInspectorPropertyState = .staticValue,
                         detail: String? = nil, target: ScenePropertyAddress? = nil,
                         typedTarget: SceneControlTarget? = nil) -> NSView {
        let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 10); heading.textColor = .secondaryLabelColor
        let status = stateLabel(); status.stringValue = state.title; status.toolTip = detail
        var topViews: [NSView] = [heading, status]
        if let target { topViews.append(motionButton(for: target, editable: currentNode?.locked == false && !busy)) }
        if let typedTarget { topViews.append(typedMotionButton(for: typedTarget, editable: currentNode?.locked == false && !busy)) }
        let top = NSStackView(views: topViews); top.spacing = 6; top.widthAnchor.constraint(equalToConstant: 270).isActive = true
        let result = NSStackView(views: [top, view]); result.orientation = .vertical; result.alignment = .leading; result.spacing = 3
        return result
    }

    private func motionButton(for target: ScenePropertyAddress, editable: Bool) -> StudioPropertyMotionButton {
        let button = StudioPropertyMotionButton(frame: .zero); button.update(target: target, scene: currentScene, time: currentTime, enabled: editable)
        button.onCommand = { [weak self] target, command in self?.handleMotion(target, command: command) }
        dynamicMotionButtons.append((target, button)); return button
    }

    private func typedMotionButton(for target: SceneControlTarget, editable: Bool) -> StudioTypedMotionButton {
        let button = StudioTypedMotionButton(frame: .zero)
        button.update(target: target, scene: currentScene, enabled: editable)
        button.onCommand = { [weak self] target, command in self?.onTypedMotionCommand?(target, command) }
        return button
    }

    private func handleMotion(_ target: ScenePropertyAddress, command: StudioMotionCommand) {
        selectedMotionTarget = target; refreshMotionSelection(); onSelectMotionTarget?(target); onMotionCommand?(target, command)
    }

    private func configureNumeric(_ control: NSControl, target: ScenePropertyAddress, editable: Bool) {
        numericTargets[ObjectIdentifier(control)] = target; control.target = self; control.action = #selector(commitNumeric(_:))
        let disposition = StudioMotionAuthoring.writeDisposition(for: target, in: currentScene, time: currentTime, autoKey: currentAutoKey)
        control.isEnabled = editable && disposition.writable
        control.toolTip = disposition == .blockedBetweenKeys ? "Auto-Key is off; add a key at this playhead to edit." : StudioInspectorState.numericDetail(target, in: currentScene)
    }

    private func allMotionButtons() -> [(ScenePropertyAddress, StudioPropertyMotionButton)] {
        var result = dynamicMotionButtons
        if let node = currentNode {
            for index in transformMotionButtons.indices { result.append((.init(nodeID: node.id, property: transformProperties[index]), transformMotionButtons[index])) }
        }
        return result
    }

    private func refreshMotionSelection() {
        for (target, button) in allMotionButtons() { button.contentTintColor = target == selectedMotionTarget ? .controlAccentColor : nil }
    }

    private func info(_ label: String, value: String, tooltip: String? = nil) -> NSView {
        let title = NSTextField(labelWithString: label); title.font = .systemFont(ofSize: 10, weight: .semibold)
        let detail = NSTextField(labelWithString: value); detail.lineBreakMode = .byTruncatingMiddle; detail.toolTip = tooltip; detail.widthAnchor.constraint(equalToConstant: 270).isActive = true
        let stack = NSStackView(views: [title, detail]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 2; return stack
    }
    private func inspectorField(_ value: String, label: String) -> NSTextField {
        let field = NSTextField(string: value); field.setAccessibilityLabel(label); field.widthAnchor.constraint(equalToConstant: 150).isActive = true; return field
    }
    private func stateLabel() -> NSTextField {
        let label = NSTextField(labelWithString: ""); label.font = .systemFont(ofSize: 10, weight: .semibold); label.textColor = .secondaryLabelColor; label.alignment = .right; return label
    }
    private func applyButton(title: String, selector: Selector, enabled: Bool) -> NSButton { let button = NSButton(title: title, target: self, action: selector); button.isEnabled = enabled; return button }
    private func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; box.widthAnchor.constraint(equalToConstant: 270).isActive = true; return box }
    private func updateDocumentHeight() { document.layoutSubtreeIfNeeded(); document.setFrameSize(NSSize(width: 292, height: max(760, stack.fittingSize.height + 12))) }
    private static func setControls(in view: NSView, enabled: Bool) { if let control = view as? NSControl { control.isEnabled = enabled }; for child in view.subviews { setControls(in: child, enabled: enabled) } }
    private static func color(from value: String) -> NSColor {
        let text = String(value.dropFirst()); guard let rgba = UInt64(text, radix: 16), text.count == 6 || text.count == 8 else { return .white }
        let rgb = text.count == 8 ? rgba >> 8 : rgba
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: text.count == 8 ? CGFloat(rgba & 255) / 255 : 1)
    }
    private static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent), byte(rgb.alphaComponent))
    }

    @objc private func rename() { onRename?() }
    @objc private func changeTransform(_ sender: NSTextField) {
        guard transformProperties.indices.contains(sender.tag), let node = currentNode, let value = Double(sender.stringValue), value.isFinite else { onTransform?(); return }
        let target = ScenePropertyAddress(nodeID: node.id, property: transformProperties[sender.tag]); selectedMotionTarget = target; refreshMotionSelection()
        onSelectMotionTarget?(target); onNumericProperty?(target, value)
    }
    @objc private func commitNumeric(_ sender: NSControl) {
        guard let target = numericTargets[ObjectIdentifier(sender)] else { return }
        let value: Double
        if let field = sender as? NSTextField, let parsed = Double(field.stringValue) { value = parsed } else { value = sender.doubleValue }
        guard value.isFinite else { NSSound.beep(); return }
        selectedMotionTarget = target; refreshMotionSelection(); onSelectMotionTarget?(target); onNumericProperty?(target, value)
    }
    @objc private func toggleVisibility() { onVisibility?() }
    @objc private func toggleLock() { onLock?() }
    @objc private func editControls() { onEditControls?() }
    @objc private func editBinding() { onEditBinding?() }
    @objc private func editKeyframes() { onEditKeyframes?() }
    @objc private func editShader() {
        guard !busy, shaderEditor == nil, let node = currentNode, !node.locked,
              let shader = node.shader, let parent = window else { return }
        let nodeID = node.id
        let editor = StudioShaderEditorController(shader: shader, title: node.displayName)
        editor.onApply = { [weak self] shader in
            guard let self, var next = self.currentNode, next.id == nodeID, !next.locked else { return }
            next.content = .shader(shader)
            self.onCommitNode?(next, "Edit Shader")
        }
        editor.onClose = { [weak self] in self?.shaderEditor = nil }
        shaderEditor = editor
        editor.present(on: parent)
    }
    @objc private func applyContent() { perform(contentApply) }
    @objc private func applyAppearance() { perform(appearanceApply) }
    @objc private func applyCompositing() { perform(compositingApply) }
    private func perform(_ operation: (() throws -> Void)?) {
        guard !busy, currentNode?.locked == false, let operation else { return }
        do { try operation() } catch { onError?(error.localizedDescription) }
    }
}

final class StudioShaderEditorController: NSObject, NSWindowDelegate {
    let window: NSWindow
    var onApply: ((SceneNode.Shader) -> Void)?
    var onClose: (() -> Void)?

    private let sourceView = NSTextView()
    private let speedField = NSTextField(string: "")
    private let presets = NSPopUpButton()
    private let diagnostics = NSTextField(wrappingLabelWithString: "Ready to compile Metal fragment source.")
    private weak var parentWindow: NSWindow?
    private var closed = false

    init(shader: SceneNode.Shader, title: String) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 590),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Metal Shader — \(title)"
        window.delegate = self
        window.minSize = NSSize(width: 620, height: 460)

        presets.addItems(withTitles: ["Templates…"] + SceneNode.Shader.studioPresets.map(\.name))
        presets.target = self
        presets.action = #selector(choosePreset)
        presets.setAccessibilityLabel("Shader template")

        speedField.stringValue = String(shader.speed)
        speedField.setAccessibilityLabel("Shader speed multiplier")
        speedField.widthAnchor.constraint(equalToConstant: 90).isActive = true

        sourceView.isRichText = false
        sourceView.isAutomaticQuoteSubstitutionEnabled = false
        sourceView.isAutomaticDashSubstitutionEnabled = false
        sourceView.isAutomaticTextReplacementEnabled = false
        sourceView.isAutomaticSpellingCorrectionEnabled = false
        sourceView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        sourceView.textContainerInset = NSSize(width: 8, height: 8)
        sourceView.string = shader.source
        sourceView.allowsUndo = true
        sourceView.setAccessibilityLabel("Metal shader source")
        sourceView.isVerticallyResizable = true
        sourceView.isHorizontallyResizable = true
        sourceView.autoresizingMask = [.width]
        sourceView.textContainer?.widthTracksTextView = false
        sourceView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let sourceScroll = NSScrollView()
        sourceScroll.borderType = .bezelBorder
        sourceScroll.hasVerticalScroller = true
        sourceScroll.hasHorizontalScroller = true
        sourceScroll.documentView = sourceView
        sourceScroll.translatesAutoresizingMaskIntoConstraints = false

        diagnostics.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnostics.textColor = .secondaryLabelColor
        diagnostics.maximumNumberOfLines = 5
        diagnostics.lineBreakMode = .byWordWrapping
        diagnostics.isSelectable = true
        diagnostics.setAccessibilityLabel("Shader compiler diagnostics")

        let compile = NSButton(title: "Compile", target: self, action: #selector(compileSource))
        compile.keyEquivalent = ""
        let apply = NSButton(title: "Apply", target: self, action: #selector(applySource))
        apply.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"

        let speedLabel = NSTextField(labelWithString: "Speed")
        let range = NSTextField(labelWithString: "0.01–10×")
        range.textColor = .secondaryLabelColor
        let top = NSStackView(views: [presets, speedLabel, speedField, range])
        top.spacing = 8
        top.alignment = .centerY

        let hint = NSTextField(wrappingLabelWithString:
            "Entry: fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]). " +
            "ShaderU provides time, resolution, pointer, audio and opacity. Custom typed uniforms remain a follow-up through scene controls.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)

        let buttons = NSStackView(views: [compile, apply, cancel])
        buttons.spacing = 8
        let spacer = NSView()
        let bottom = NSStackView(views: [diagnostics, spacer, buttons])
        bottom.spacing = 10
        bottom.alignment = .centerY
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        diagnostics.setContentHuggingPriority(.defaultLow, for: .horizontal)
        diagnostics.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let content = window.contentView!
        for view in [top, hint, sourceScroll, bottom] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            sourceScroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            sourceScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            sourceScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            sourceScroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            diagnostics.widthAnchor.constraint(greaterThanOrEqualToConstant: 300)
        ])
    }

    func present(on parent: NSWindow) {
        parentWindow = parent
        parent.beginSheet(window)
        window.makeFirstResponder(sourceView)
    }

    @objc private func choosePreset() {
        let index = presets.indexOfSelectedItem - 1
        guard SceneNode.Shader.studioPresets.indices.contains(index) else { return }
        let preset = SceneNode.Shader.studioPresets[index]
        replaceDraft(source: preset.source, speed: String(preset.speed))
        diagnostics.stringValue = "Loaded \(preset.name). Compile to validate, then Apply."
        diagnostics.textColor = .secondaryLabelColor
    }

    private func replaceDraft(source: String, speed: String) {
        let oldSource = sourceView.string
        let oldSpeed = speedField.stringValue
        sourceView.undoManager?.registerUndo(withTarget: self) { target in
            target.replaceDraft(source: oldSource, speed: oldSpeed)
        }
        sourceView.string = source
        speedField.stringValue = speed
    }

    @objc private func compileSource() { _ = compileDraft(selectFirstError: true) }

    @objc private func applySource() {
        guard let shader = compileDraft(selectFirstError: true) else { return }
        onApply?(shader)
        closeSheet()
    }

    @objc private func cancel() { closeSheet() }

    private func draft() throws -> SceneNode.Shader {
        guard let speed = Double(speedField.stringValue), speed.isFinite else {
            throw SceneError.invalid("Speed must be a finite number from 0.01 through 10.")
        }
        let shader = SceneNode.Shader(source: sourceView.string, speed: speed)
        try shader.validate()
        return shader
    }

    private func compileDraft(selectFirstError: Bool) -> SceneNode.Shader? {
        do {
            let shader = try draft()
            try MetalShaderCompiler.validate(shader)
            diagnostics.stringValue = "Compiled successfully · \(shader.source.utf8.count) bytes · \(shader.speed)×"
            diagnostics.textColor = .systemGreen
            return shader
        } catch let error as MetalShaderCompilationError {
            diagnostics.stringValue = error.errorDescription ?? error.fallback
            diagnostics.textColor = .systemRed
            if selectFirstError, let line = error.diagnostics.compactMap(\.line).first { select(line: line) }
        } catch {
            diagnostics.stringValue = error.localizedDescription
            diagnostics.textColor = .systemRed
        }
        return nil
    }

    private func select(line: Int) {
        guard line > 0 else { return }
        let ns = sourceView.string as NSString
        var current = 1
        var location = 0
        while current < line && location < ns.length {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            current += 1
        }
        guard current == line, location <= ns.length else { return }
        let range = ns.lineRange(for: NSRange(location: location, length: 0))
        sourceView.setSelectedRange(range)
        sourceView.scrollRangeToVisible(range)
        window.makeFirstResponder(sourceView)
    }

    private func closeSheet() {
        guard !closed else { return }
        closed = true
        if let parentWindow { parentWindow.endSheet(window) }
        else { window.close() }
        onClose?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeSheet()
        return false
    }
}
