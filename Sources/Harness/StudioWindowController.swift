import AppKit
import UniformTypeIdentifiers

extension StudioWindowController {
    /// Exercises recovery without opening a window or touching user media.
    static func smokeTestResetRecovery() {
        let editor = StudioWindowController { _ in }
        editor.window.contentView?.layoutSubtreeIfNeeded()
        editor.fitCanvas()
        precondition(editor.renderer != nil)
        let original = editor.scene
        precondition(editor.applyEdit([SceneNode(content: .gradient), SceneNode(content: .gradient)], selected: 1))
        editor.document.undoManager.undo()
        precondition(editor.scene.nodes.count == 1 && !editor.draft && editor.document.undoManager.canRedo)
        editor.document.undoManager.redo()
        precondition(editor.scene.nodes.count == 2 && editor.draft && editor.nodePicker.indexOfSelectedItem == 1)
        editor.editor.toggleVisibility(1)
        precondition(!editor.scene.nodes[1].visible)
        editor.document.undoManager.undo()
        precondition(editor.scene.nodes[1].visible)
        editor.editor.toggleLock(1)
        let lockedTransform = editor.scene.nodes[1].transform.x
        editor.editor.selection = 1
        editor.editor.nudge(x: 0.1, y: 0)
        precondition(editor.scene.nodes[1].transform.x == lockedTransform)
        editor.document.undoManager.undo()
        precondition(!editor.scene.nodes[1].locked)
        let running = editor.renderer
        var moved = editor.scene.nodes
        moved[1].transform = .init(x: 0.2, y: 0, scale: 0.6, rotation: 15)
        precondition(editor.applyEdit(moved, selected: 1, name: "Move Layer"))
        precondition(editor.renderer === running)
        editor.document.undoManager.undo()
        precondition(editor.renderer === running)
        editor.document.undoManager.redo()
        precondition(editor.renderer === running)
        editor.document.undoManager.undo()
        editor.savedScene = SceneDescriptor(title: "Missing source", nodes: [
            SceneNode(content: .image(URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString + ".png")))
        ])
        precondition(!editor.restoreSavedScene())
        precondition(editor.renderer === running && editor.draft)
        precondition(editor.scene.nodes.count == 2 && editor.nodePicker.indexOfSelectedItem == 1)
        precondition(editor.undoEdits.count == 1 && editor.savedScene != nil)
        editor.savedScene = original
        precondition(editor.restoreSavedScene())
        precondition(!editor.draft && editor.savedScene == nil && editor.undoEdits.isEmpty)
        precondition(editor.scene.nodes.count == 1 && editor.renderer !== running)
        precondition(editor.applyEdit([SceneNode(content: .gradient), SceneNode(content: .gradient)], selected: 0))
        editor.editor.groupWithNext()
        precondition(editor.scene.nodes.count == 1 && editor.scene.nodes[0].children.count == 2)
        let groupedRenderer = editor.renderer
        editor.editor.nudge(x: 0.1, y: 0)
        precondition(editor.renderer === groupedRenderer && editor.scene.nodes[0].transform.x == 0.1)
        editor.document.undoManager.undo()
        editor.document.undoManager.undo()
        precondition(editor.scene.nodes.count == 2)
        editor.document.undoManager.redo()
        precondition(editor.scene.nodes.count == 1 && editor.scene.nodes[0].children.count == 2)
        editor.nodePicker.selectItem(at: 1)
        editor.selectNode()
        let childID = editor.editor.selectedNode!.id
        let nestedRenderer = editor.renderer
        editor.editor.rename("Inner light")
        precondition(editor.scene.nodes[0].children[0].name == "Inner light" && editor.renderer === nestedRenderer)
        editor.document.undoManager.undo()
        precondition(editor.editor.selectedNode?.id == childID)
        editor.editor.reorder(1, 2)
        precondition(editor.scene.nodes[0].children[1].id == childID && editor.renderer === nestedRenderer)
        editor.nodePicker.selectItem(at: 0); editor.selectNode()
        editor.editor.ungroup()
        precondition(editor.scene.nodes.count == 2 && editor.scene.nodes[1].id == childID)
        editor.document.undoManager.undo()
        precondition(editor.scene.nodes[0].kind == .group)
        editor.nodePicker.selectItem(at: 1); editor.selectNode()
        var styledChild = editor.editor.selectedNode!
        styledChild.style = .init(mask: .ellipse, exposure: -0.5, saturation: 0)
        editor.editor.replaceSelected(styledChild, name: "Change Appearance")
        precondition(editor.renderer is MetalSceneRenderer && editor.engine.indexOfSelectedItem == 1)
        let styledRenderer = editor.renderer
        editor.document.undoManager.undo()
        precondition(editor.editor.selectedNode?.style == .plain && editor.renderer === styledRenderer)
        editor.renderer?.releaseResources()
    }
}

/// A small scene workbench. Previewing never changes the running desktop scene.
final class StudioWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let canvas = NSView()
    private let viewport = NSScrollView()
    private let dragOverlay = SceneDragOverlay()
    private let addMediaButton = NSButton(title: "+ Image / Video…", target: nil, action: nil)
    private let addGradientButton = NSButton(title: "+ Gradient", target: nil, action: nil)
    private let removeNodeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let reorderButton = NSButton(title: "Bring Forward", target: nil, action: nil)
    private let document = SceneDocument()
    private let fieldEditor = StudioFieldEditor()
    private weak var editingClient: NSTextField?
    private lazy var editor = SceneEditorController(document: document)
    private let nameField = NSTextField(string: "")
    private let ungroupButton = NSButton(title: "Ungroup", target: nil, action: nil)
    private let groupButton = NSButton(title: "Group with Next Layer", target: nil, action: nil)
    private let duplicateButton = NSButton(title: "Duplicate Layer", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private typealias EditSnapshot = SceneDocument.Snapshot
    private var importedScopes: [URL] { get { document.workingAssets } set { document.workingAssets = newValue } }
    private var undoEdits: [EditSnapshot] { document.undoTargets }
    private var redoEdits: [EditSnapshot] { document.redoTargets }
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let redoButton = NSButton(title: "Redo", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "Aurora")
    private let performanceLabel = NSTextField(labelWithString: "")
    private var performanceTimer: Timer? { get { host.performanceTimer } set { host.performanceTimer = newValue } }
    private let measureButton = NSButton(title: "Measure 10s", target: nil, action: nil)
    private var measurement: (time: Double, count: Int, gpuSeconds: Double, gpuFrames: Int)? { get { host.measurement } set { host.measurement = newValue } }
    private var measurementResult: String? { get { host.measurementResult } set { host.measurementResult = newValue } }
    private var presentationSample: PresentationRateSample { get { host.presentationSample } set { host.presentationSample = newValue } }
    private let detailLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private let engine = NSPopUpButton()
    private let frameRate = NSPopUpButton()
    private let applyButton = NSButton(title: "Use on Desktop", target: nil, action: nil)
    private let nodePicker = SceneLayerList()
    private var transformFields: [NSTextField] = []
    private let saveCopyButton = NSButton(title: "Save As…", target: nil, action: nil)
    private var draft: Bool { get { document.draft } set { document.draft = newValue } }
    private var saving: Bool { get { document.busy } set { document.busy = newValue } }
    private var savedScene: SceneDescriptor? { get { document.savedScene } set { document.savedScene = newValue } }
    private let host = ScenePreviewHost()
    private var renderer: SceneRenderer? { get { host.renderer } set { host.renderer = newValue } }
    private var scene: SceneDescriptor { get { document.scene } set { document.scene = newValue } }
    private var selectedURL: URL? { get { document.sourceURL } set { document.sourceURL = newValue } }
    private var scopedURL: URL? { get { document.scopedURL } set { document.scopedURL = newValue } }
    private var watcher: SceneWatcher?
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var paused = false
    private var asleep = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var clock: SceneClock { host.clock }
    private let apply: (URL) -> Void
    var onClose: (() -> Void)?

    init(apply: @escaping (URL) -> Void) {
        self.apply = apply
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Idlesse Studio"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1040, height: 820)
        window.delegate = self
        fieldEditor.isFieldEditor = true
        fieldEditor.allowsUndo = true
        editor.onError = { [weak self] message in self?.detailLabel.stringValue = message }
        editor.commit = { [weak self] nodes, selected, name in self?.applyEdit(nodes, selected: selected, name: name) ?? false }
        document.currentSelection = { [weak self] in self?.nodePicker.indexOfSelectedItem ?? 0 }
        document.prepareRestore = { [weak self] target in
            guard let self else { return false }
            let previous = self.scene
            let selection = self.nodePicker.indexOfSelectedItem
            let renderer = self.renderer
            self.scene = target.scene
            let updated = self.renderer?.updateScene(target.scene) ?? false
            if !updated { self.rebuild() }
            self.scene = previous
            self.updateInspector()
            self.nodePicker.selectItem(at: selection)
            return updated || self.renderer !== renderer
        }
        document.didRestore = { [weak self] target in
            guard let self else { return }
            self.cancelLoading()
            self.watcher = nil
            self.updateInspector()
            self.nodePicker.selectItem(at: target.selected)
            self.selectNode()
            self.detailLabel.stringValue = target.draft ? "Unsaved scene" : "Original scene · Redo is available"
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, sleeping) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.asleep = sleeping
                self?.updatePlayback()
            }
            observers.append((workspace, token))
        }
        let token = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main) { [weak self] _ in self?.updatePlayback() }
        observers.append((NotificationCenter.default, token))
        window.center()
        let root = window.contentView!
        frameRate.addItems(withTitles: SceneFrameRate.allCases.map { $0.title })
        frameRate.selectItem(at: SceneFrameRate.allCases.firstIndex(of: SceneFrameRate.selected) ?? 0)
        frameRate.target = self
        frameRate.action = #selector(changeFrameRate)
        frameRate.toolTip = "Scene redraw rate for preview and desktop. Videos retain their source frame rate. Auto uses the renderer default."
        let rateToken = NotificationCenter.default.addObserver(forName: SceneFrameRate.changed,
            object: nil, queue: .main) { [weak self] _ in self?.updateFrameRate() }
        observers.append((NotificationCenter.default, rateToken))
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        performanceLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        performanceLabel.textColor = .secondaryLabelColor
        performanceLabel.toolTip = "Measured Metal drawable presentations per second. Video source frames may repeat. Native video and multiple standard layers are not measured."
        let heading = NSStackView(views: [titleLabel, detailLabel, performanceLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 4
        let open = NSButton(title: "Open Scene…", target: self, action: #selector(choose))
        let sample = NSButton(title: "Aurora", target: self, action: #selector(showSample))
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.toolTip = "Pause or resume this preview"
        engine.addItems(withTitles: ["Standard", "Metal · Experimental"])
        engine.target = self
        engine.action = #selector(changeEngine)
        engine.toolTip = "Compare the same scene using the two renderers"
        applyButton.target = self
        applyButton.action = #selector(useOnDesktop)
        applyButton.isEnabled = false
        measureButton.target = self
        measureButton.action = #selector(measure)
        measureButton.toolTip = "Measure this preview for ten seconds without changing the scene. GPU time excludes display scheduling and other apps."
        let zoomOut = NSButton(title: "−", target: self, action: #selector(zoomOut))
        zoomOut.toolTip = "Zoom out"
        let zoomIn = NSButton(title: "+", target: self, action: #selector(zoomIn))
        zoomIn.toolTip = "Zoom in"
        let fit = NSButton(title: "Fit", target: self, action: #selector(fitCanvas))
        let controls = NSStackView(views: [open, sample, pauseButton, engine, zoomOut, fit, zoomIn, measureButton, applyButton])
        controls.spacing = 10
        nodePicker.onVisibility = { [weak self] in self?.editor.toggleVisibility($0) }
        nodePicker.onLock = { [weak self] in self?.editor.toggleLock($0) }
        nodePicker.target = self
        nodePicker.action = #selector(selectNode)
        let inspector = NSStackView()
        inspector.orientation = .vertical
        inspector.alignment = .leading
        inspector.spacing = 10
        inspector.addArrangedSubview(NSTextField(labelWithString: "LAYERS"))
        nodePicker.onReorder = { [weak self] source, destination in
            guard let self, !self.saving else { return }
            self.editor.reorder(source, destination)
        }
        nodePicker.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(nodePicker)
        undoButton.target = self
        undoButton.action = #selector(undoEdit)
        redoButton.target = self
        redoButton.action = #selector(redoEdit)
        inspector.addArrangedSubview(NSStackView(views: [undoButton, redoButton]))
        for (button, action) in [(addMediaButton, #selector(addMedia)), (addGradientButton, #selector(addGradient)),
                                  (reorderButton, #selector(reorderNode)), (removeNodeButton, #selector(removeNode))] {
            button.target = self
            button.action = action
            inspector.addArrangedSubview(button)
        }
        dragOverlay.onSelect = { [weak self] index in
            guard let self, self.scene.allNodes.indices.contains(index) else { return }
            self.nodePicker.selectItem(at: index); self.selectNode()
        }
        dragOverlay.onPreviewTransform = { [weak self] transform in
            guard let self, !self.saving else { return }
            var nodes = self.scene.nodes
            guard let id = self.editor.selectedNode?.id else { return }
            _ = SceneTree.edit(id, in: &nodes) { siblings, index in siblings[index].transform = transform }
            _ = self.renderer?.updateScene(SceneDescriptor(title: self.scene.title, nodes: nodes))
        }
        dragOverlay.onTransform = { [weak self] t, name in self?.editor.transform(t, action: name) }
        dragOverlay.onNudge = { [weak self] x, y in self?.editor.nudge(x: x, y: y) }
        dragOverlay.onDelete = { [weak self] in self?.editor.remove() }
        nameField.placeholderString = "Layer name"
        nameField.target = self
        nameField.action = #selector(renameNode)
        nameField.setAccessibilityLabel("Layer name")
        nameField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        inspector.addArrangedSubview(nameField)
        duplicateButton.target = self
        duplicateButton.action = #selector(duplicateNode)
        inspector.addArrangedSubview(duplicateButton)
        groupButton.target = self
        groupButton.action = #selector(groupNodes)
        groupButton.toolTip = "Combine this layer and the next layer in drawing order. Undo restores the individual layers."
        inspector.addArrangedSubview(groupButton)
        ungroupButton.target = self; ungroupButton.action = #selector(ungroupNodes)
        ungroupButton.toolTip = "Restore the child layers. Reset group transform, opacity and appearance first."
        inspector.addArrangedSubview(ungroupButton)
        for (index, label) in ["X", "Y", "Scale", "Rotation °", "Opacity"].enumerated() {
            let field = NSTextField(string: "")
            field.tag = index
            field.target = self
            field.action = #selector(editTransform)
            field.setAccessibilityLabel(label)
            field.widthAnchor.constraint(equalToConstant: 76).isActive = true
            transformFields.append(field)
            let row = NSStackView(views: [NSTextField(labelWithString: label), field])
            row.distribution = .equalSpacing
            row.widthAnchor.constraint(equalToConstant: 160).isActive = true
            inspector.addArrangedSubview(row)
        }
        inspector.addArrangedSubview(NSButton(title: "Appearance…", target: self, action: #selector(editAppearance)))
        saveCopyButton.target = self
        saveCopyButton.action = #selector(saveCopy)
        saveButton.target = self
        saveButton.action = #selector(saveDocument)
        inspector.addArrangedSubview(saveButton)
        inspector.addArrangedSubview(saveCopyButton)
        inspector.addArrangedSubview(NSButton(title: "Reset Changes", target: self, action: #selector(resetChanges)))
        let hint = NSTextField(wrappingLabelWithString: "Expand groups to edit children. Drag rows to reorder siblings.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.widthAnchor.constraint(equalToConstant: 160).isActive = true
        inspector.addArrangedSubview(hint)
        inspector.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(inspector)
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        canvas.layer?.cornerRadius = 12
        canvas.layer?.masksToBounds = true
        canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        viewport.documentView = canvas
        viewport.allowsMagnification = true
        viewport.minMagnification = 0.25
        viewport.maxMagnification = 4
        viewport.hasHorizontalScroller = true
        viewport.hasVerticalScroller = true
        viewport.backgroundColor = .underPageBackgroundColor
        viewport.setAccessibilityLabel("Scene canvas; pinch to zoom and scroll to pan")
        for child in [heading, viewport, controls, frameRate] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: frameRate.leadingAnchor, constant: -16),
            frameRate.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            frameRate.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            viewport.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 18),
            viewport.leadingAnchor.constraint(equalTo: nodePicker.trailingAnchor, constant: 12),
            nodePicker.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            nodePicker.widthAnchor.constraint(equalToConstant: 230),
            nodePicker.topAnchor.constraint(equalTo: viewport.topAnchor),
            nodePicker.bottomAnchor.constraint(equalTo: viewport.bottomAnchor),
            viewport.trailingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: -18),
            inspector.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            inspector.topAnchor.constraint(equalTo: viewport.topAnchor),
            inspector.widthAnchor.constraint(equalToConstant: 160),
            viewport.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -18),
            controls.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
    }
    func show() {
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        if renderer == nil { fitCanvas() }
        watchPackage()
        updatePlayback()
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func zoomIn() { viewport.setMagnification(min(4, viewport.magnification * 1.25), centeredAt: NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)) }
    @objc private func zoomOut() { viewport.setMagnification(max(0.25, viewport.magnification / 1.25), centeredAt: NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)) }
    @objc private func fitCanvas() {
        viewport.magnification = 1
        canvas.setFrameSize(viewport.contentView.bounds.size)
        viewport.contentView.scroll(to: .zero)
        viewport.reflectScrolledClipView(viewport.contentView)
        rebuild()
    }
    private func rebuild() {
        let next: SceneRenderer
        let onError: (String) -> Void = { [weak self] message in self?.detailLabel.stringValue = message }
        do {
            let bounds = NSRect(origin: .zero, size: canvas.bounds.insetBy(dx: 40, dy: 40).size)
            guard bounds.width > 0, bounds.height > 0 else { return }
            next = try host.prepare(scene: scene, bounds: bounds, scale: window.backingScaleFactor,
                                    metal: engine.indexOfSelectedItem == 1, onError: onError)
        } catch {
            detailLabel.stringValue = error.localizedDescription
            return
        }
        let restoreFocus = window.firstResponder === dragOverlay
        renderer?.releaseResources()
        canvas.subviews.forEach { $0.removeFromSuperview() }
        next.view.frame = canvas.bounds.insetBy(dx: 40, dy: 40)
        next.view.autoresizingMask = [.width, .height]
        canvas.addSubview(next.view)
        dragOverlay.frame = canvas.bounds
        dragOverlay.autoresizingMask = [.width, .height]
        canvas.addSubview(dragOverlay)
        if restoreFocus { window.makeFirstResponder(dragOverlay) }
        cancelMeasurement()
        renderer = next
        engine.selectItem(at: next is MetalSceneRenderer ? 1 : 0)
        presentationSample = PresentationRateSample()
        updateFrameRate()
        titleLabel.stringValue = scene.title
        detailLabel.stringValue = "\(scene.nodes.count) layer\(scene.nodes.count == 1 ? "" : "s") · \(engine.indexOfSelectedItem == 1 ? "Experimental SDR preview" : "Standard preview")"
        updateInspector()
        updatePlayback()
    }
    private func updateInspector() {
        let selected = max(0, nodePicker.indexOfSelectedItem)
        nodePicker.removeAllItems()
        nodePicker.setNodes(scene.nodes)
        nodePicker.selectItem(at: min(selected, scene.allNodes.count - 1))
        selectNode()
        applyButton.isEnabled = selectedURL != nil && !draft && !saving
        saveCopyButton.isEnabled = !saving
        saveButton.isEnabled = !saving
        nameField.isEditable = !saving
        duplicateButton.isEnabled = !saving && scene.allNodes.count < SceneBudget.maxNodes
        addMediaButton.isEnabled = !saving && scene.allNodes.count < SceneBudget.maxNodes
        addGradientButton.isEnabled = addMediaButton.isEnabled
        removeNodeButton.isEnabled = !saving && editor.siblings.count > 1
        reorderButton.isEnabled = !saving && editor.siblings.count > 1
        dragOverlay.isEnabled = !saving
        undoButton.isEnabled = !saving && !undoEdits.isEmpty
        redoButton.isEnabled = !saving && !redoEdits.isEmpty
        window.isDocumentEdited = draft
        window.title = "Idlesse Studio — " + (selectedURL?.pathExtension.lowercased() == "idlesse" ? scene.title : "Untitled (\(scene.title))")
    }
    @objc private func selectNode() {
        editor.selection = nodePicker.indexOfSelectedItem
        guard let node = editor.selectedNode else { return }
        let siblings = editor.siblings
        let offset = siblings.firstIndex { $0.id == node.id } ?? 0
        groupButton.isEnabled = !saving && offset + 1 < siblings.count && scene.allNodes.count < SceneBudget.maxNodes
        ungroupButton.isEnabled = !saving && node.kind == .group
        removeNodeButton.isEnabled = !saving && siblings.count > 1
        reorderButton.isEnabled = !saving && siblings.count > 1
        nameField.stringValue = node.displayName
        dragOverlay.roots = scene.nodes
        dragOverlay.isEnabled = !saving
        dragOverlay.selected = editor.selection
        dragOverlay.transform = node.transform
        reorderButton.title = offset == 0 ? "Bring Forward" : "Send Backward"
        let values = [node.transform.x ?? 0, node.transform.y ?? 0, node.transform.scale ?? 1,
                      node.transform.rotation ?? 0, node.opacity]
        for (field, value) in zip(transformFields, values) { field.stringValue = String(format: "%.3f", value) }
    }
    @objc private func editTransform() {
        guard !saving, let current = editor.selectedNode else { return }
        let values = transformFields.compactMap { Double($0.stringValue) }
        let ranges = [-2.0...2.0, -2.0...2.0, 0.05...4.0, -360.0...360.0, 0.0...1.0]
        guard values.count == 5, zip(values, ranges).allSatisfy({ $0.isFinite && $1.contains($0) }) else {
            detailLabel.stringValue = "Use X/Y −2…2, scale 0.05…4, rotation −360…360, opacity 0…1."
            selectNode()
            return
        }
        let existing = [current.transform.x ?? 0, current.transform.y ?? 0, current.transform.scale ?? 1,
                        current.transform.rotation ?? 0, current.opacity]
        // Display rounds to three decimals; unchanged fields must not create edits.
        guard zip(values, existing).contains(where: { abs($0 - $1) > 0.0005 }) else { return }
        var node = current
        node.transform = .init(x: values[0], y: values[1], scale: values[2], rotation: values[3])
        node.opacity = values[4]
        editor.replaceSelected(node, name: "Change Layer")
    }
    @discardableResult private func applyEdit(_ nodes: [SceneNode], selected: Int, name: String = "Change Layer") -> Bool {
        guard !saving, (1...SceneBudget.maxNodes).contains(nodes.count) else { return false }
        do { try SceneBudget.validate(nodes) } catch { detailLabel.stringValue = error.localizedDescription; return false }
        let previous = scene
        let snapshot = EditSnapshot(scene: previous, selected: nodePicker.indexOfSelectedItem, draft: draft)
        let previousRenderer = renderer
        scene = SceneDescriptor(title: scene.title, nodes: nodes)
        let updated = renderer?.updateScene(scene) ?? false
        if !updated { rebuild() }
        guard updated || renderer !== previousRenderer else { scene = previous; updateInspector(); return false }
        document.record(snapshot, name: name)
        if savedScene == nil { savedScene = previous }
        cancelLoading()
        watcher = nil
        draft = true
        updateInspector()
        pruneImportedScopes()
        nodePicker.selectItem(at: selected)
        selectNode()
        detailLabel.stringValue = "Unsaved scene · Save to keep changes"
        window.makeFirstResponder(dragOverlay)
        fieldEditor.undoManager?.removeAllActions()
        return true
    }
    private func pruneImportedScopes() { document.pruneAssets() }
    @objc private func undoEdit() { document.undoManager.undo() }
    @objc private func redoEdit() { document.undoManager.redo() }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard let client = client as? NSTextField else { return nil }
        if editingClient !== client { fieldEditor.undoManager?.removeAllActions(); editingClient = client }
        return fieldEditor
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        window.firstResponder === fieldEditor ? fieldEditor.undoManager : document.undoManager
    }
    private func clearEditHistory() { document.clearHistory(); fieldEditor.undoManager?.removeAllActions() }
    @objc private func renameNode() { editor.rename(nameField.stringValue) }
    @objc private func editAppearance() {
        guard !saving, var node = editor.selectedNode else { return }
        let dialog = NSAlert()
        dialog.messageText = "Appearance — " + node.displayName
        dialog.informativeText = "Mask and color effects use Metal. Exposure: −2…2 stops. Saturation: 0…2 (1 is original). Vignette darkens the edges; 0 turns it off."
        dialog.addButton(withTitle: "Apply"); dialog.addButton(withTitle: "Cancel")
        let mask = NSPopUpButton(frame: .zero, pullsDown: false)
        mask.addItems(withTitles: ["No Mask", "Ellipse Mask"])
        mask.selectItem(at: node.style.mask == .ellipse ? 1 : 0)
        let exposure = NSTextField(string: String(node.style.exposure))
        exposure.setAccessibilityLabel("Exposure")
        let saturation = NSTextField(string: String(node.style.saturation))
        saturation.setAccessibilityLabel("Saturation")
        let vignette = NSSlider(value: node.style.vignette, minValue: 0, maxValue: 1, target: nil, action: nil)
        vignette.setAccessibilityLabel("Vignette strength")
        let fields = NSStackView(views: [mask, NSTextField(labelWithString: "Exposure"), exposure,
                                        NSTextField(labelWithString: "Saturation"), saturation,
                                        NSTextField(labelWithString: "Vignette"), vignette])
        fields.orientation = .vertical; fields.alignment = .leading
        fields.frame = NSRect(x: 0, y: 0, width: 280, height: 200)
        exposure.widthAnchor.constraint(equalToConstant: 260).isActive = true
        saturation.widthAnchor.constraint(equalToConstant: 260).isActive = true
        vignette.widthAnchor.constraint(equalToConstant: 260).isActive = true
        dialog.accessoryView = fields
        dialog.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard self.editor.selectedNode?.id == node.id else {
                self.detailLabel.stringValue = "The scene changed while Appearance was open. Reopen Appearance and try again."; return
            }
            guard let ev = Double(exposure.stringValue), let sat = Double(saturation.stringValue),
                  ev.isFinite, (-2...2).contains(ev), sat.isFinite, (0...2).contains(sat) else {
                self.detailLabel.stringValue = "Use exposure −2…2 and saturation 0…2."; return
            }
            node.style = .init(mask: mask.indexOfSelectedItem == 1 ? .ellipse : nil, exposure: ev, saturation: sat, vignette: vignette.doubleValue)
            self.editor.replaceSelected(node, name: "Change Appearance")
        }
    }
    @objc private func ungroupNodes() { editor.ungroup() }
    @objc private func groupNodes() { editor.groupWithNext() }
    @objc private func duplicateNode() { editor.duplicate() }
    @objc private func addGradient() {
        guard scene.allNodes.count < SceneBudget.maxNodes else { return }
        _ = editor.add(SceneNode(name: "Gradient \(scene.allNodes.count + 1)", content: .gradient, transform: .init(x: 0, y: 0, scale: 0.6, rotation: 0)))
    }
    @objc private func removeNode() { editor.remove() }
    @objc private func reorderNode() { editor.reorderAdjacent() }
    @objc private func addMedia() {
        guard !saving, scene.allNodes.count < SceneBudget.maxNodes else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .mpeg4Movie, .quickTimeMovie]
        panel.prompt = "Add Layer"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.cancelLoading()
            self.watcher = nil
            self.saving = true
            self.updateInspector()
            self.detailLabel.stringValue = "Opening new layer…"
            self.loadTask = Task { @MainActor [weak self] in
                let accessed = url.startAccessingSecurityScopedResource()
                var adopted = false
                defer { if accessed && !adopted { url.stopAccessingSecurityScopedResource() } }
                do {
                    let loaded = try await SceneDocument.read(url).scene
                    try Task.checkCancellation()
                    guard let self else { return }
                    self.saving = false
                    var node = loaded.nodes[0]
                    node.transform = .init(x: 0, y: 0, scale: 0.6, rotation: 0)
                    if self.editor.add(node) {
                        if accessed && !self.importedScopes.contains(url) {
                            self.importedScopes.append(url)
                            adopted = true
                        }
                    }
                    self.loadTask = nil
                    self.updateInspector()
                } catch {
                    self?.saving = false
                    self?.loadTask = nil
                    self?.updateInspector()
                    self?.detailLabel.stringValue = error.localizedDescription
                    self?.watchPackage()
                }
            }
        }
    }
    private func releaseImportedScopes() { document.releaseWorkingAssets() }
    @objc private func resetChanges() {
        _ = restoreSavedScene()
    }
    private func restoreSavedScene() -> Bool {
        guard !saving else { return false }
        guard let savedScene else { return true }
        let previous = scene
        let selected = nodePicker.indexOfSelectedItem
        let previousRenderer = renderer
        scene = savedScene
        rebuild()
        guard renderer !== previousRenderer else {
            scene = previous
            updateInspector()
            nodePicker.selectItem(at: selected)
            selectNode()
            return false
        }
        self.savedScene = nil
        clearEditHistory()
        releaseImportedScopes()
        draft = false
        updateInspector()
        watchPackage()
        return true
    }
    func mayQuit() -> Bool {
        mayDiscard(resetting: false)
    }
    private func mayDiscard(resetting: Bool = true) -> Bool {
        guard !saving else {
            window.makeKeyAndOrderFront(nil)
            detailLabel.stringValue = "Please wait for the current import or save to finish."
            NSSound.beep()
            return false
        }
        commitFieldEdits()
        guard draft else { return true }
        window.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Discard unsaved scene changes?"
        alert.informativeText = "Save As first if you want to keep this scene."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        // Quitting does not need to decode the original scene again.
        return !resetting || restoreSavedScene()
    }
    var acceptsDocumentCommands: Bool { window.isVisible && !saving }
    private func commitFieldEdits() {
        if nameField.currentEditor() != nil { renameNode() }
        else if transformFields.contains(where: { $0.currentEditor() != nil }) { editTransform() }
        window.makeFirstResponder(nil)
    }
    @objc func saveDocument() {
        guard !saving else { return }
        commitFieldEdits()
        guard let url = selectedURL, url.pathExtension.lowercased() == "idlesse", let revision = document.revision else {
            saveCopy(); return
        }
        save(to: url, replacing: revision)
    }
    @objc func saveAsDocument() { saveCopy() }
    @objc func duplicateLayer() { editor.duplicate() }
    @objc private func saveCopy() {
        guard !saving else { return }
        commitFieldEdits()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(scene.title) Copy.idlesse"
        panel.allowedContentTypes = [UTType(exportedAs: "com.teamleaderleo.idlesse.scene", conformingTo: .package)]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.save(to: url, replacing: nil)
        }
    }
    private func save(to url: URL, replacing revision: ScenePackageWriter.Revision?) {
        saving = true
        cancelLoading()
        watcher = nil
        updateInspector()
        detailLabel.stringValue = "Saving scene…"
        let document = document
        Task { @MainActor [weak self] in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                try await document.save(to: url, replacing: revision)
                guard let self else { return }
                self.saving = false
                self.load(url)
            } catch {
                self?.saving = false
                self?.updateInspector()
                self?.detailLabel.stringValue = error.localizedDescription
                self?.watchPackage()
            }
        }
    }
    @objc private func changeFrameRate() {
        cancelMeasurement()
        SceneFrameRate.selected = SceneFrameRate.allCases[frameRate.indexOfSelectedItem]
    }
    private func updateFrameRate() {
        let maximum = window.screen?.maximumFramesPerSecond ?? 60
        frameRate.item(at: 1)?.title = "Match Display (\(maximum) Hz)"
        frameRate.selectItem(at: SceneFrameRate.allCases.firstIndex(of: SceneFrameRate.selected) ?? 0)
        renderer?.setPreferredFrameRate(SceneFrameRate.selected.requested(maximum: maximum))
    }
    func windowDidChangeScreen(_ notification: Notification) { cancelMeasurement(); updateFrameRate() }
    private func updatePlayback() {
        let stopped = paused || asleep || ProcessInfo.processInfo.isLowPowerModeEnabled || !window.isVisible || window.isMiniaturized || NSApp.isHidden
        if stopped { cancelMeasurement() }
        host.setPaused(stopped)
        pauseButton.title = paused ? "Resume" : "Pause"
        performanceTimer?.invalidate()
        performanceTimer = nil
        presentationSample = PresentationRateSample()
        updatePerformance()
        if !stopped && renderer?.diagnostics.animated == true && renderer?.presentedFrameCount != nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updatePerformance() }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            performanceTimer = timer
        }
    }
    private func cancelMeasurement() {
        measurement = nil
        measurementResult = nil
        measureButton.title = "Measure 10s"
    }
    @objc private func measure() {
        guard let renderer, renderer.diagnostics.state == .running,
              let count = renderer.presentedFrameCount, let gpu = renderer.gpuTotals else { return }
        measurementResult = nil
        measurement = (ProcessInfo.processInfo.systemUptime, count, gpu.seconds, gpu.frames)
        measureButton.isEnabled = false
        measureButton.title = "Measuring…"
    }
    private func updatePerformance() {
        performanceLabel.stringValue = host.performanceText()
        measureButton.isEnabled = measurement == nil && renderer?.diagnostics.state == .running && renderer?.diagnostics.animated == true && renderer?.gpuTotals != nil
        if measurementResult != nil { measureButton.title = "Measure Again" }
    }
    @objc private func togglePause() { paused.toggle(); updatePlayback() }
    @objc private func changeEngine() {
        let previous = renderer
        rebuild()
        if renderer === previous { engine.selectItem(at: engine.indexOfSelectedItem == 1 ? 0 : 1) }
    }
    @objc private func useOnDesktop() {
        guard !draft, !saving, let selectedURL else { return }
        window.close()
        apply(selectedURL)
    }
    @objc private func showSample() {
        guard mayDiscard() else { return }
        draft = false
        savedScene = nil
        clearEditHistory()
        releaseImportedScopes()
        cancelLoading()
        watcher = nil
        renderer?.releaseResources()
        renderer = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        selectedURL = nil
        document.revision = nil
        window.representedURL = nil
        applyButton.isEnabled = false
        scene = SceneDescriptor(title: "Aurora", nodes: [SceneNode(content: .gradient)])
        rebuild()
    }
    @objc private func choose() {
        guard mayDiscard() else { return }
        let panel = NSOpenPanel()
        panel.title = "Open in Studio"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.directory, .jpeg, .png, .heic, .mpeg4Movie, .quickTimeMovie,
            UTType(exportedAs: "com.teamleaderleo.idlesse.scene", conformingTo: .package)]
        panel.treatsFilePackagesAsDirectories = false
        panel.canChooseDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.load(url)
        }
    }
    private func cancelLoading() { generation += 1; loadTask?.cancel(); loadTask = nil }
    private func load(_ url: URL) {
        cancelLoading()
        let request = generation
        detailLabel.stringValue = "Opening \(url.lastPathComponent)…"
        loadTask = Task { @MainActor [weak self] in
            let accessed = url.startAccessingSecurityScopedResource()
            var adopted = false
            defer { if accessed && !adopted { url.stopAccessingSecurityScopedResource() } }
            do {
                let contents = try await SceneDocument.read(url)
                let next = contents.scene
                guard let self, request == self.generation else { return }
                let previous = self.scene
                let previousRenderer = self.renderer
                self.scene = next
                self.rebuild()
                guard self.renderer !== previousRenderer else { self.scene = previous; return }
                self.releaseImportedScopes()
                self.scopedURL?.stopAccessingSecurityScopedResource()
                self.scopedURL = accessed ? url : nil
                adopted = true
                self.draft = false
                self.clearEditHistory()
                self.savedScene = nil
                self.updateInspector()
                self.selectedURL = url
                self.document.revision = contents.revision
                self.updateInspector()
                self.window.representedURL = url.pathExtension.lowercased() == "idlesse" ? url : nil
                self.applyButton.isEnabled = true
                self.loadTask = nil
                self.watchPackage()
            } catch {
                guard let self, request == self.generation, !Task.isCancelled else { return }
                self.detailLabel.stringValue = error.localizedDescription
                self.loadTask = nil
            }
        }
    }
    private func watchPackage() {
        watcher = nil
        guard !draft, undoEdits.isEmpty, redoEdits.isEmpty, let url = selectedURL, url.pathExtension.lowercased() == "idlesse", window.isVisible else { return }
        watcher = SceneWatcher(package: url, assets: scene.allNodes.compactMap { $0.assetURL }) { [weak self] in
            self?.load(url)
        }
    }
    func windowDidEndLiveResize(_ notification: Notification) { fitCanvas() }
    func windowDidChangeBackingProperties(_ notification: Notification) { rebuild() }
    func windowDidMiniaturize(_ notification: Notification) { updatePlayback() }
    func windowDidDeminiaturize(_ notification: Notification) { updatePlayback() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { mayDiscard() }
    func windowWillClose(_ notification: Notification) {
        cancelLoading()
        cancelMeasurement()
        watcher = nil
        clock.setPaused(true)
        performanceTimer?.invalidate()
        performanceTimer = nil
        renderer?.releaseResources()
        renderer = nil
        onClose?()
    }
    func applicationVisibilityChanged() { updatePlayback() }
    deinit {
        document.clearHistory()
        releaseImportedScopes()
        performanceTimer?.invalidate()
        observers.forEach { $0.0.removeObserver($0.1) }
        loadTask?.cancel()
        renderer?.releaseResources()
    }
}
