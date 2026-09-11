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
        case .staticValue: return ""
        case .driven: return "Driven"
        case .keyframed: return "Keyframed"
        case .controlled: return "Controlled"
        }
    }
}

enum StudioInspectorState {
    static func numeric(_ target: ScenePropertyAddress, in scene: SceneDescriptor) -> StudioInspectorPropertyState {
        guard let binding = scene.bindings.first(where: { $0.target == target }) else { return .staticValue }
        return binding.keyframes == nil ? .driven : .keyframed
    }

    static func typed(_ property: SceneControlTarget.Property, nodeID: UUID,
                      in scene: SceneDescriptor) -> StudioInspectorPropertyState {
        scene.parameters.values.contains { parameter in
            parameter.targets.contains { $0.nodeID == nodeID && $0.property == property }
        } ? .controlled : .staticValue
    }

    static func numericDetail(_ target: ScenePropertyAddress, in scene: SceneDescriptor) -> String? {
        guard let binding = scene.bindings.first(where: { $0.target == target }) else { return nil }
        if binding.keyframes != nil { return "Owned by a keyframe track." }
        if let signal = binding.signal { return "Driven by \(signal.rawValue)." }
        if let parameter = scene.parameters[binding.parameter] { return "Driven by scene control “\(parameter.name)”." }
        return "Driven by a binding."
    }

    static func typedDetail(_ property: SceneControlTarget.Property, nodeID: UUID,
                            in scene: SceneDescriptor) -> String? {
        for parameter in scene.parameters.values where parameter.targets.contains(where: {
            $0.nodeID == nodeID && $0.property == property
        }) {
            return "Driven by scene control “\(parameter.name)”."
        }
        return nil
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

    func setExpanded(_ value: Bool) {
        expanded = value
        refreshDisclosure()
    }

    @objc private func toggle() {
        expanded.toggle()
        refreshDisclosure()
    }

    private func refreshDisclosure() {
        body.isHidden = !expanded
        let symbol = expanded ? "chevron.down" : "chevron.right"
        header.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }
}

/// Persistent AppKit inspector for the selected Studio layer.
/// It owns view state and local Apply drafts; StudioWindowController still owns scene mutation,
/// renderer updates, lock checks and Undo registration through its existing editor commit path.
final class StudioLayerInspector: NSScrollView {
    let nameField = NSTextField(string: "")
    private(set) var transformFields: [NSTextField] = []

    var onRename: (() -> Void)?
    var onTransform: (() -> Void)?
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
    private var transformStates: [NSTextField] = []
    private var layerActionViews: [NSView] = []
    private var motionSessionViews: [NSView] = []
    private var sceneActionViews: [NSView] = []
    private var currentScene = SceneDescriptor(title: "Inspector", nodes: [SceneNode(content: .gradient)])
    private var currentNode: SceneNode?
    private var busy = false
    private var contentApply: (() throws -> Void)?
    private var appearanceApply: (() throws -> Void)?
    private var compositingApply: (() throws -> Void)?

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
                        compositingSection, motionSection, sceneSection] {
            stack.addArrangedSubview(section)
        }
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

        let transformProperties: [(String, ScenePropertyAddress.Property)] = [
            ("X", .x), ("Y", .y), ("Scale", .scale), ("Rotation °", .rotation), ("Opacity", .opacity)
        ]
        var transformRows: [NSView] = []
        for (index, entry) in transformProperties.enumerated() {
            let field = NSTextField(string: "")
            field.tag = index
            field.target = self
            field.action = #selector(changeTransform)
            field.setAccessibilityLabel(entry.0)
            field.widthAnchor.constraint(equalToConstant: 92).isActive = true
            transformFields.append(field)
            let state = stateLabel()
            state.widthAnchor.constraint(equalToConstant: 70).isActive = true
            transformStates.append(state)
            let row = NSStackView(views: [NSTextField(labelWithString: entry.0), field, state])
            row.distribution = .fill
            row.spacing = 7
            row.widthAnchor.constraint(equalToConstant: 270).isActive = true
            row.arrangedSubviews[0].widthAnchor.constraint(equalToConstant: 82).isActive = true
            transformRows.append(row)
        }
        transformSection.setViews(transformRows)
        rebuildLayerSection()
        rebuildMotionSection()
        rebuildSceneSection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func install(layerActions: [NSView], motionSession: [NSView], sceneActions: [NSView]) {
        layerActionViews = layerActions
        motionSessionViews = motionSession
        sceneActionViews = sceneActions
        rebuildLayerSection()
        rebuildMotionSection()
        rebuildSceneSection()
    }

    func revealContent() { contentSection.setExpanded(true) }

    func update(scene: SceneDescriptor, node: SceneNode?, saving: Bool) {
        currentScene = scene
        currentNode = node
        busy = saving
        guard let node else {
            nameField.stringValue = ""
            nameField.isEnabled = false
            visibility.isEnabled = false
            locked.isEnabled = false
            contentSection.setViews([NSTextField(labelWithString: "Select a layer to inspect it.")])
            appearanceSection.setViews([])
            compositingSection.setViews([])
            rebuildMotionSection()
            return
        }

        if nameField.currentEditor() == nil { nameField.stringValue = node.displayName }
        let editable = !saving && !node.locked
        nameField.isEditable = editable
        nameField.isEnabled = !saving
        visibility.state = node.visible ? .on : .off
        locked.state = node.locked ? .on : .off
        locked.isEnabled = !saving
        let visibleState = StudioInspectorState.typed(.visible, nodeID: node.id, in: scene)
        visibility.isEnabled = !saving && visibleState == .staticValue
        visibilityState.stringValue = visibleState.title
        visibilityState.toolTip = StudioInspectorState.typedDetail(.visible, nodeID: node.id, in: scene)

        let values: [Double] = [node.transform.x ?? 0, node.transform.y ?? 0, node.transform.scale ?? 1,
                                node.transform.rotation ?? 0, node.opacity]
        let properties: [ScenePropertyAddress.Property] = [.x, .y, .scale, .rotation, .opacity]
        for index in transformFields.indices {
            let field = transformFields[index]
            if field.currentEditor() == nil { field.stringValue = String(format: "%.3f", values[index]) }
            let target = ScenePropertyAddress(nodeID: node.id, property: properties[index])
            let state = StudioInspectorState.numeric(target, in: scene)
            transformStates[index].stringValue = state.title
            transformStates[index].toolTip = StudioInspectorState.numericDetail(target, in: scene)
            field.isEnabled = editable && state == .staticValue
            field.toolTip = StudioInspectorState.numericDetail(target, in: scene)
        }

        rebuildLayerSection()
        rebuildContentSection(node: node, editable: editable)
        rebuildAppearanceSection(node: node, editable: editable)
        rebuildCompositingSection(node: node, editable: editable)
        rebuildMotionSection()
        updateDocumentHeight()
    }

    private func rebuildLayerSection() {
        let visibleRow = NSStackView(views: [visibility, visibilityState])
        visibleRow.distribution = .fill
        visibleRow.spacing = 8
        visibleRow.widthAnchor.constraint(equalToConstant: 270).isActive = true
        var views: [NSView] = [nameField, visibleRow, locked]
        if !layerActionViews.isEmpty {
            views.append(separator())
            views.append(contentsOf: layerActionViews)
        }
        layerSection.setViews(views)
    }

    private func rebuildContentSection(node: SceneNode, editable: Bool) {
        contentApply = nil
        var views: [NSView] = []
        switch node.content {
        case .image(let url):
            views = [info("Image", value: url.lastPathComponent, tooltip: url.path)]
        case .video(let url):
            views = [info("Video", value: url.lastPathComponent, tooltip: url.path)]
        case .gradient:
            views = [NSTextField(labelWithString: "Procedural gradient")]
        case .group(let children):
            views = [info("Group", value: "\(children.count) child layer\(children.count == 1 ? "" : "s")")]
        case .text(let typography):
            views = textViews(node: node, typography: typography, editable: editable)
        case .shape(let primitive):
            views = shapeViews(node: node, value: primitive, editable: editable)
        case .particles(let emitter):
            views = emitterViews(node: node, emitter: emitter, editable: editable)
        case .shader(let shader):
            views = [info("Shader", value: "\(shader.source.utf8.count) chars · ×\(shader.speed)", tooltip: "Metal fragment snippet; edit the source in the scene JSON.")]
        }
        contentSection.setViews(views)
    }

    private func textViews(node: SceneNode, typography: SceneNode.Typography, editable: Bool) -> [NSView] {
        let source = NSPopUpButton()
        source.addItems(withTitles: ["Static Text"] + SceneNode.Typography.LiveSource.allCases.map(\.title))
        if let live = typography.liveSource, let index = SceneNode.Typography.LiveSource.allCases.firstIndex(of: live) {
            source.selectItem(at: index + 1)
        }
        source.setAccessibilityLabel("Text source")
        source.isEnabled = editable

        let textEditor = NSTextView()
        textEditor.isRichText = false
        textEditor.isAutomaticQuoteSubstitutionEnabled = false
        textEditor.isAutomaticDashSubstitutionEnabled = false
        textEditor.font = .systemFont(ofSize: 13)
        textEditor.textContainerInset = NSSize(width: 5, height: 5)
        textEditor.string = typography.text
        let textControlled = StudioInspectorState.typed(.text, nodeID: node.id, in: currentScene)
        textEditor.isEditable = editable && textControlled == .staticValue
        textEditor.setAccessibilityLabel("Text content")
        let textScroll = NSScrollView()
        textScroll.borderType = .bezelBorder
        textScroll.hasVerticalScroller = true
        textScroll.documentView = textEditor
        textEditor.isVerticallyResizable = true
        textEditor.isHorizontallyResizable = false
        textEditor.autoresizingMask = [.width]
        textEditor.textContainer?.widthTracksTextView = true
        textEditor.frame = NSRect(x: 0, y: 0, width: 270, height: 82)
        textScroll.widthAnchor.constraint(equalToConstant: 270).isActive = true
        textScroll.heightAnchor.constraint(equalToConstant: 82).isActive = true

        let font = inspectorField(typography.font, label: "Font name")
        let size = inspectorField(String(typography.size), label: "Font size")
        let spacing = inspectorField(String(typography.lineSpacing), label: "Line spacing")
        let width = inspectorField(String(typography.width), label: "Text width")
        let height = inspectorField(String(typography.height), label: "Text height")
        for field in [font, size, spacing, width, height] { field.isEnabled = editable }
        let alignment = NSPopUpButton()
        alignment.addItems(withTitles: ["Left", "Center", "Right"])
        alignment.selectItem(at: typography.alignment == .left ? 0 : typography.alignment == .center ? 1 : 2)
        alignment.setAccessibilityLabel("Text alignment")
        alignment.isEnabled = editable
        let fill = NSColorWell()
        fill.color = Self.color(from: typography.fill)
        fill.setAccessibilityLabel("Text fill color")
        let fillControlled = StudioInspectorState.typed(.fill, nodeID: node.id, in: currentScene)
        fill.isEnabled = editable && fillControlled == .staticValue

        let apply = applyButton(title: "Apply Content", selector: #selector(applyContent), enabled: editable)
        contentApply = { [weak self] in
            guard let self, var next = self.currentNode, next.id == node.id, var text = next.typography else { return }
            text.liveSource = source.indexOfSelectedItem == 0 ? nil : SceneNode.Typography.LiveSource.allCases[source.indexOfSelectedItem - 1]
            text.text = textEditor.string
            text.font = font.stringValue
            text.size = Double(size.stringValue) ?? .nan
            if let hex = Self.hex(fill.color) { text.fill = hex }
            text.lineSpacing = Double(spacing.stringValue) ?? .nan
            text.width = Int(width.stringValue) ?? 0
            text.height = Int(height.stringValue) ?? 0
            text.alignment = [SceneNode.Typography.Alignment.left, .center, .right][alignment.indexOfSelectedItem]
            next.content = .text(text)
            try SceneBudget.validate([next])
            self.onCommitNode?(next, "Edit Content")
        }

        return [source,
            labeled("Text", view: textScroll, state: textControlled,
                    detail: StudioInspectorState.typedDetail(.text, nodeID: node.id, in: currentScene)),
            labeled("Font", view: font), labeled("Size", view: size),
            labeled("Fill", view: fill, state: fillControlled,
                    detail: StudioInspectorState.typedDetail(.fill, nodeID: node.id, in: currentScene)),
            labeled("Alignment", view: alignment), labeled("Line spacing", view: spacing),
            labeled("Width", view: width), labeled("Height", view: height), apply]
    }

    private func shapeViews(node: SceneNode, value: SceneNode.Shape, editable: Bool) -> [NSView] {
        let primitive = NSPopUpButton()
        let primitives: [SceneNode.Shape.Primitive] = [.rectangle, .ellipse, .line, .roundedRectangle]
        primitive.addItems(withTitles: ["Rectangle", "Ellipse", "Line", "Rounded Rectangle"])
        primitive.selectItem(at: primitives.firstIndex(of: value.primitive) ?? 3)
        primitive.setAccessibilityLabel("Shape primitive")
        primitive.isEnabled = editable
        let fill = NSColorWell(); fill.color = Self.color(from: value.fill); fill.setAccessibilityLabel("Shape fill color")
        let fillControlled = StudioInspectorState.typed(.fill, nodeID: node.id, in: currentScene)
        fill.isEnabled = editable && fillControlled == .staticValue
        let width = inspectorField(String(value.width), label: "Shape width")
        let height = inspectorField(String(value.height), label: "Shape height")
        let radius = inspectorField(String(value.cornerRadius), label: "Corner radius")
        let lineWidth = inspectorField(String(value.lineWidth), label: "Line width")
        for field in [width, height, radius, lineWidth] { field.isEnabled = editable }
        let apply = applyButton(title: "Apply Content", selector: #selector(applyContent), enabled: editable)
        contentApply = { [weak self] in
            guard let self, var next = self.currentNode, next.id == node.id, var graphic = next.shape else { return }
            graphic.primitive = primitives[primitive.indexOfSelectedItem]
            if let hex = Self.hex(fill.color) { graphic.fill = hex }
            graphic.width = Int(width.stringValue) ?? 0
            graphic.height = Int(height.stringValue) ?? 0
            graphic.cornerRadius = Double(radius.stringValue) ?? .nan
            graphic.lineWidth = Double(lineWidth.stringValue) ?? .nan
            next.content = .shape(graphic)
            try SceneBudget.validate([next])
            self.onCommitNode?(next, "Edit Content")
        }
        return [labeled("Primitive", view: primitive),
            labeled("Fill", view: fill, state: fillControlled,
                    detail: StudioInspectorState.typedDetail(.fill, nodeID: node.id, in: currentScene)),
            labeled("Width", view: width), labeled("Height", view: height),
            labeled("Corner radius", view: radius), labeled("Line width", view: lineWidth), apply]
    }

    private func emitterViews(node: SceneNode, emitter: SceneNode.Emitter, editable: Bool) -> [NSView] {
        let definitions: [(String, String, ScenePropertyAddress.Property?)] = [
            ("Count", String(emitter.count), nil), ("Lifetime", String(emitter.lifetime), nil),
            ("Speed", String(emitter.speed), .particleSpeed), ("Wind", String(emitter.wind), .particleWind),
            ("Gravity", String(emitter.gravity), nil), ("Size", String(emitter.size), .particleSize),
            ("Seed", String(emitter.seed), nil)
        ]
        let fields = definitions.map { inspectorField($0.1, label: $0.0) }
        var views: [NSView] = []
        for index in definitions.indices {
            let property = definitions[index].2
            let target = property.map { ScenePropertyAddress(nodeID: node.id, property: $0) }
            let state = target.map { StudioInspectorState.numeric($0, in: currentScene) } ?? .staticValue
            fields[index].isEnabled = editable && state == .staticValue
            let detail = target.flatMap { StudioInspectorState.numericDetail($0, in: currentScene) }
            views.append(labeled(definitions[index].0, view: fields[index], state: state, detail: detail))
        }
        let sprite = NSPopUpButton()
        sprite.addItems(withTitles: ["Procedural Discs", "Keep Current Sprite", "Choose Sprite Image…"])
        sprite.item(at: 1)?.isEnabled = node.sprite != nil
        sprite.selectItem(at: node.sprite == nil ? 0 : 1)
        sprite.setAccessibilityLabel("Particle sprite")
        sprite.isEnabled = editable
        views.append(labeled("Sprite", view: sprite))
        let apply = applyButton(title: "Apply Emitter", selector: #selector(applyContent), enabled: editable)
        views.append(apply)
        contentApply = { [weak self] in
            guard let self, var next = self.currentNode, next.id == node.id else { return }
            guard let count = Int(fields[0].stringValue), let lifetime = Double(fields[1].stringValue),
                  let speed = Double(fields[2].stringValue), let wind = Double(fields[3].stringValue),
                  let gravity = Double(fields[4].stringValue), let size = Double(fields[5].stringValue),
                  let seed = Int(fields[6].stringValue) else {
                throw SceneError.invalid("Enter numeric emitter values; count and seed must be integers.")
            }
            let updated = SceneNode.Emitter(count: count, lifetime: lifetime, speed: speed, wind: wind,
                                            gravity: gravity, size: size, seed: seed)
            try updated.validate()
            next.content = .particles(updated)
            if sprite.indexOfSelectedItem == 0 { next.sprite = nil }
            if sprite.indexOfSelectedItem == 2 { self.onChooseSpriteImage?(next) }
            else { self.onCommitNode?(next, "Change Emitter") }
        }
        return views
    }

    private func rebuildAppearanceSection(node: SceneNode, editable: Bool) {
        let mask = NSPopUpButton()
        mask.addItems(withTitles: ["No Mask", "Ellipse Mask"])
        mask.selectItem(at: node.style.mask == .ellipse ? 1 : 0)
        mask.setAccessibilityLabel("Layer appearance mask")
        mask.isEnabled = editable

        let exposure = inspectorField(String(node.style.exposure), label: "Exposure")
        let saturation = inspectorField(String(node.style.saturation), label: "Saturation")
        let vignette = NSSlider(value: node.style.vignette, minValue: 0, maxValue: 1, target: nil, action: nil)
        vignette.setAccessibilityLabel("Vignette strength")
        vignette.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let expTarget = ScenePropertyAddress(nodeID: node.id, property: .exposure)
        let satTarget = ScenePropertyAddress(nodeID: node.id, property: .saturation)
        let vigTarget = ScenePropertyAddress(nodeID: node.id, property: .vignette)
        let expState = StudioInspectorState.numeric(expTarget, in: currentScene)
        let satState = StudioInspectorState.numeric(satTarget, in: currentScene)
        let vigState = StudioInspectorState.numeric(vigTarget, in: currentScene)
        exposure.isEnabled = editable && expState == .staticValue
        saturation.isEnabled = editable && satState == .staticValue
        vignette.isEnabled = editable && vigState == .staticValue

        let effectEditor = SceneEffectsEditor(effects: node.style.effects)
        if !editable { Self.setControls(in: effectEditor, enabled: false) }
        var views: [NSView] = [labeled("Mask", view: mask),
            labeled("Exposure", view: exposure, state: expState, detail: StudioInspectorState.numericDetail(expTarget, in: currentScene)),
            labeled("Saturation", view: saturation, state: satState, detail: StudioInspectorState.numericDetail(satTarget, in: currentScene)),
            labeled("Vignette", view: vignette, state: vigState, detail: StudioInspectorState.numericDetail(vigTarget, in: currentScene)),
            NSTextField(labelWithString: "Effects · drag to reorder")]
        for effect in node.style.effects {
            guard let id = effect.id else { continue }
            let target = ScenePropertyAddress(nodeID: node.id, property: .effectAmount, effectID: id)
            let state = StudioInspectorState.numeric(target, in: currentScene)
            if state != .staticValue {
                let text = NSTextField(labelWithString: "\(effect.type.rawValue.capitalized) amount · \(state.title)")
                text.font = .systemFont(ofSize: 10, weight: .semibold)
                text.textColor = .secondaryLabelColor
                text.toolTip = StudioInspectorState.numericDetail(target, in: currentScene)
                views.append(text)
            }
        }
        views.append(effectEditor)
        let apply = applyButton(title: "Apply Appearance", selector: #selector(applyAppearance), enabled: editable)
        views.append(apply)
        appearanceApply = { [weak self] in
            guard let self, var next = self.currentNode, next.id == node.id else { return }
            guard let ev = Double(exposure.stringValue), let sat = Double(saturation.stringValue),
                  ev.isFinite, (-2...2).contains(ev), sat.isFinite, (0...2).contains(sat) else {
                throw SceneError.invalid("Use exposure −2…2 and saturation 0…2.")
            }
            let effects = try effectEditor.validatedEffects()
            next.style = .init(mask: mask.indexOfSelectedItem == 1 ? .ellipse : nil,
                               exposure: ev, saturation: sat, vignette: vignette.doubleValue)
            next.style.effects = effects
            try SceneBudget.validate([next])
            self.onCommitNode?(next, "Change Appearance")
        }
        appearanceSection.setViews(views)
    }

    private func rebuildCompositingSection(node: SceneNode, editable: Bool) {
        let blends: [SceneNode.Blend] = [.normal, .add, .multiply, .screen]
        let blend = NSPopUpButton()
        blend.addItems(withTitles: ["Normal", "Add", "Multiply", "Screen"])
        blend.selectItem(at: blends.firstIndex(of: node.blend ?? .normal) ?? 0)
        blend.setAccessibilityLabel("Blend mode")
        let blendState = StudioInspectorState.typed(.blend, nodeID: node.id, in: currentScene)
        blend.isEnabled = editable && blendState == .staticValue

        let candidates = currentScene.allNodes.filter { $0.id != node.id }
        let mask = NSPopUpButton()
        mask.addItems(withTitles: ["No asset/node mask", "Choose Image…", "Keep Current Image"] + candidates.map(\.displayName))
        mask.item(at: 2)?.isEnabled = node.maskAsset != nil
        if node.maskAsset != nil { mask.selectItem(at: 2) }
        else if let id = node.maskNodeID, let index = candidates.firstIndex(where: { $0.id == id }) { mask.selectItem(at: index + 3) }
        else { mask.selectItem(at: 0) }
        mask.setAccessibilityLabel("Mask source")
        mask.isEnabled = editable

        let channel = NSPopUpButton()
        channel.addItems(withTitles: ["Alpha", "Luminance"])
        channel.selectItem(at: node.maskChannel == .luma ? 1 : 0)
        channel.setAccessibilityLabel("Mask channel")
        channel.isEnabled = editable
        let apply = applyButton(title: "Apply Compositing", selector: #selector(applyCompositing), enabled: editable)
        compositingApply = { [weak self] in
            guard let self, var next = self.currentNode, next.id == node.id else { return }
            next.blend = blends[blend.indexOfSelectedItem] == .normal ? nil : blends[blend.indexOfSelectedItem]
            next.maskChannel = channel.indexOfSelectedItem == 1 ? .luma : nil
            let choice = mask.indexOfSelectedItem
            switch choice {
            case 0:
                next.maskAsset = nil; next.maskNodeID = nil
            case 1:
                next.maskAsset = nil; next.maskNodeID = nil
                self.onChooseMaskImage?(next)
                return
            case 2:
                next.maskNodeID = nil
            default:
                next.maskAsset = nil
                next.maskNodeID = candidates[choice - 3].id
            }
            self.onCommitNode?(next, "Change Mask and Blend")
        }
        compositingSection.setViews([
            labeled("Blend", view: blend, state: blendState,
                    detail: StudioInspectorState.typedDetail(.blend, nodeID: node.id, in: currentScene)),
            labeled("Mask source", view: mask), labeled("Mask channel", view: channel), apply
        ])
    }

    private func rebuildMotionSection() {
        var views: [NSView] = []
        if let node = currentNode {
            let active = currentScene.bindings.filter { $0.target.nodeID == node.id }
            if active.isEmpty {
                let label = NSTextField(labelWithString: "No driven numeric properties")
                label.textColor = .secondaryLabelColor
                label.font = .systemFont(ofSize: 10)
                views.append(label)
            } else {
                for binding in active {
                    let state: StudioInspectorPropertyState = binding.keyframes == nil ? .driven : .keyframed
                    let row = NSTextField(labelWithString: "\(motionLabel(binding.target)) · \(state.title)")
                    row.font = .systemFont(ofSize: 10, weight: .semibold)
                    row.textColor = .secondaryLabelColor
                    row.toolTip = StudioInspectorState.numericDetail(binding.target, in: currentScene)
                    views.append(row)
                }
            }
            let typed: [(SceneControlTarget.Property, String)] = [(.visible, "Visibility"), (.blend, "Blend"), (.text, "Text"), (.fill, "Fill")]
            for (property, label) in typed where StudioInspectorState.typed(property, nodeID: node.id, in: currentScene) == .controlled {
                let row = NSTextField(labelWithString: "\(label) · Controlled")
                row.font = .systemFont(ofSize: 10, weight: .semibold)
                row.textColor = .secondaryLabelColor
                row.toolTip = StudioInspectorState.typedDetail(property, nodeID: node.id, in: currentScene)
                views.append(row)
            }
        }
        let controls = NSStackView(views: [
            NSButton(title: "Controls…", target: self, action: #selector(editControls)),
            NSButton(title: "Bind…", target: self, action: #selector(editBinding)),
            NSButton(title: "Keyframes…", target: self, action: #selector(editKeyframes))
        ])
        controls.spacing = 5
        views.append(controls)
        if !motionSessionViews.isEmpty { views.append(contentsOf: motionSessionViews) }
        motionSection.setViews(views)
    }

    private func rebuildSceneSection() {
        sceneSection.setViews(sceneActionViews)
    }

    private func motionLabel(_ target: ScenePropertyAddress) -> String {
        if target.property == .effectAmount { return target.label(in: currentScene.nodes) }
        switch target.property {
        case .x: return "X"
        case .y: return "Y"
        case .scale: return "Scale"
        case .rotation: return "Rotation"
        case .opacity: return "Opacity"
        case .exposure: return "Exposure"
        case .saturation: return "Saturation"
        case .vignette: return "Vignette"
        case .particleSize: return "Particle Size"
        case .particleWind: return "Particle Wind"
        case .particleSpeed: return "Particle Speed"
        case .effectAmount: return "Effect Amount"
        }
    }

    private func labeled(_ title: String, view: NSView, state: StudioInspectorPropertyState = .staticValue,
                         detail: String? = nil) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 10)
        heading.textColor = .secondaryLabelColor
        let status = stateLabel()
        status.stringValue = state.title
        status.toolTip = detail
        let top = NSStackView(views: [heading, status])
        top.distribution = .fill
        top.spacing = 6
        top.widthAnchor.constraint(equalToConstant: 270).isActive = true
        let result = NSStackView(views: [top, view])
        result.orientation = .vertical
        result.alignment = .leading
        result.spacing = 3
        return result
    }

    private func info(_ label: String, value: String, tooltip: String? = nil) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        let detail = NSTextField(labelWithString: value)
        detail.lineBreakMode = .byTruncatingMiddle
        detail.toolTip = tooltip
        detail.widthAnchor.constraint(equalToConstant: 270).isActive = true
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 2
        return stack
    }

    private func inspectorField(_ value: String, label: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.setAccessibilityLabel(label)
        field.widthAnchor.constraint(equalToConstant: 150).isActive = true
        return field
    }

    private func stateLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    private func applyButton(title: String, selector: Selector, enabled: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.isEnabled = enabled
        return button
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 270).isActive = true
        return box
    }

    private func updateDocumentHeight() {
        document.layoutSubtreeIfNeeded()
        document.setFrameSize(NSSize(width: 292, height: max(760, stack.fittingSize.height + 12)))
    }

    private static func setControls(in view: NSView, enabled: Bool) {
        if let control = view as? NSControl { control.isEnabled = enabled }
        for child in view.subviews { setControls(in: child, enabled: enabled) }
    }

    private static func color(from value: String) -> NSColor {
        let text = String(value.dropFirst())
        guard let rgba = UInt64(text, radix: 16), text.count == 6 || text.count == 8 else { return .white }
        let rgb = text.count == 8 ? rgba >> 8 : rgba
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255,
                       alpha: text.count == 8 ? CGFloat(rgba & 255) / 255 : 1)
    }

    private static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent),
                      byte(rgb.blueComponent), byte(rgb.alphaComponent))
    }

    @objc private func rename() { onRename?() }
    @objc private func changeTransform() { onTransform?() }
    @objc private func toggleVisibility() { onVisibility?() }
    @objc private func toggleLock() { onLock?() }
    @objc private func editControls() { onEditControls?() }
    @objc private func editBinding() { onEditBinding?() }
    @objc private func editKeyframes() { onEditKeyframes?() }
    @objc private func applyContent() { perform(contentApply) }
    @objc private func applyAppearance() { perform(appearanceApply) }
    @objc private func applyCompositing() { perform(compositingApply) }

    private func perform(_ operation: (() throws -> Void)?) {
        guard !busy, currentNode?.locked == false, let operation else { return }
        do { try operation() }
        catch { onError?(error.localizedDescription) }
    }
}
