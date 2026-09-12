import AppKit
import UniformTypeIdentifiers

private final class StudioInspectorView: NSView {
    override var isFlipped: Bool { true }
}

final class StudioPerformanceHUDView: NSVisualEffectView {
    private let label = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor

        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .labelColor
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func update(text: String) {
        label.stringValue = text
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

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
        precondition(!editor.layerInspector.transformFields[0].isEnabled)
        let lockedTransform = editor.scene.nodes[1].transform.x
        editor.editor.selection = 1
        editor.editor.nudge(x: 0.1, y: 0)
        precondition(editor.scene.nodes[1].transform.x == lockedTransform)
        editor.document.undoManager.undo()
        precondition(!editor.scene.nodes[1].locked)
        precondition(editor.layerInspector.transformFields[0].isEnabled)
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
        var controlled = editor.scene
        controlled.parameters = ["amount": .init(name: "Amount", value: 0.5, min: 0, max: 1)]
        controlled.bindings = [.init(target: .init(nodeID: childID, property: .opacity), parameter: "amount")]
        precondition(editor.applyEdit(controlled.nodes, selected: 1, name: "Bind", controls: controlled))
        precondition(editor.renderer === styledRenderer && editor.scene.bindings.count == 1)
        let opacityTarget = ScenePropertyAddress(nodeID: childID, property: .opacity)
        precondition(StudioInspectorState.numeric(opacityTarget, in: editor.scene) == .controlled)
        var signalControlled = editor.scene
        signalControlled.bindings = [.init(target: opacityTarget, signal: .sine)]
        precondition(editor.applyEdit(signalControlled.nodes, selected: 1, name: "Drive", controls: signalControlled))
        precondition(StudioInspectorState.numeric(opacityTarget, in: editor.scene) == .driven)
        precondition(editor.renderer === styledRenderer)
        editor.document.undoManager.undo()
        precondition(StudioInspectorState.numeric(opacityTarget, in: editor.scene) == .controlled)
        editor.document.undoManager.undo()
        precondition(editor.scene.bindings.isEmpty)
        precondition(StudioInspectorState.numeric(opacityTarget, in: editor.scene) == .staticValue)
        editor.document.undoManager.redo()
        precondition(editor.scene.parameters["amount"]?.value == 0.5 && editor.scene.bindings.count == 1)
        precondition(StudioInspectorState.numeric(opacityTarget, in: editor.scene) == .controlled)
        editor.editor.rename("Bound child")
        precondition(editor.scene.bindings.count == 1 && editor.scene.parameters["amount"]?.value == 0.5)
        var keyed = editor.scene
        let target = ScenePropertyAddress(nodeID: keyed.allNodes[1].id, property: .opacity)
        keyed.bindings = [.init(target: target, keyframes: .init(keys: [.init(time: 0, value: 0), .init(time: 4, value: 1)]))]
        precondition(editor.applyEdit(keyed.nodes, selected: 1, name: "Keyframes", controls: keyed))
        precondition(StudioInspectorState.numeric(target, in: editor.scene) == .keyframed)
        let keyRenderer = editor.renderer
        editor.timeline.onMoveKey?(target, 1, 3)
        precondition(editor.scene.bindings[0].keyframes?.keys[1].time == 3 && editor.renderer === keyRenderer)
        editor.document.undoManager.undo()
        precondition(editor.scene.bindings[0].keyframes?.keys[1].time == 4 && editor.renderer === keyRenderer)
        editor.document.undoManager.redo()
        precondition(editor.scene.bindings[0].keyframes?.keys[1].time == 3)
        var editedTrack = editor.scene.bindings[0].keyframes!
        editedTrack.keys[1].value = 0.6
        editor.timeline.onEditTrack?(target, editedTrack, "Move Keyframe")
        precondition(editor.scene.bindings[0].keyframes?.keys[1].value == 0.6 && editor.renderer === keyRenderer)
        editor.document.undoManager.undo()
        precondition(editor.scene.bindings[0].keyframes?.keys[1].value == 1 && editor.renderer === keyRenderer)
        var timed = editor.scene
        timed.timeline = .init(duration: 6, mode: .pingPong, rate: 0.5)
        precondition(editor.applyEdit(timed.nodes, selected: 1, name: "Change Playback", controls: timed))
        precondition(editor.clock.playbackRate == 0.5 && editor.renderer === keyRenderer)
        editor.document.undoManager.undo()
        precondition(editor.scene.timeline == nil && editor.clock.playbackRate == 1)
        editor.document.undoManager.redo()
        precondition(editor.scene.timeline == timed.timeline && editor.clock.playbackRate == 0.5)
        editor.renderer?.releaseResources()
    }
}

/// A small scene workbench. Previewing never changes the running desktop scene.
final class StudioWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let canvas = NSView()
    private let viewport = NSScrollView()
    private let hudOverlay = StudioPerformanceHUDView()
    private let hudButton = NSButton(title: "HUD", target: nil, action: nil)
    private let dragOverlay = SceneDragOverlay()
    private let addMediaButton = NSButton(title: "+ Image / Video…", target: nil, action: nil)
    private let addParticlesButton = NSButton(title: "+ Particles", target: nil, action: nil)
    private let emitterButton = NSButton(title: "Emitter…", target: nil, action: nil)
    private let addGradientButton = NSButton(title: "+ Create…", target: nil, action: nil)
    private let removeNodeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let reorderButton = NSButton(title: "Bring Forward", target: nil, action: nil)
    private let document = SceneDocument()
    private let fieldEditor = StudioFieldEditor()
    private weak var editingClient: NSTextField?
    private lazy var editor = SceneEditorController(document: document)
    private let layerInspector = StudioLayerInspector(frame: .zero)
    private var nameField: NSTextField { layerInspector.nameField }
    private var audioSession: SceneAudioSession?
    private let audioStatus = NSTextField(wrappingLabelWithString: "Audio response off")
    private let audioToggle = NSButton(checkboxWithTitle: "Enable Audio Response", target: nil, action: nil)
    private let pointerToggle = NSButton(checkboxWithTitle: "Enable Pointer Response", target: nil, action: nil)
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
    private let timeline = SceneTimelineView(frame: .zero)
    private var transformFields: [NSTextField] { layerInspector.transformFields }
    private var exportTask: Task<Void, Never>?
    private let exportButton = NSButton(title: "Export Video…", target: nil, action: nil)
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
    private var sessionInactive = false
    private var displayAsleep = false
    private var selectedMotionTarget: ScenePropertyAddress?
    private var canvasMotionBase: SceneDescriptor?
    private var canvasMotionPreview: SceneDescriptor?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var clock: SceneClock { host.clock }
    private let apply: (URL) -> Void
    var onClose: (() -> Void)?

    init(apply: @escaping (URL) -> Void) {
        self.apply = apply
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        audioSession = SceneAudioSession(clock: clock) { [weak self] message in
            self?.audioToggle.state = .off
            self?.detailLabel.stringValue = message
        }
        window.title = "Idlesse Studio"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1180, height: 820)
        window.delegate = self
        fieldEditor.isFieldEditor = true
        fieldEditor.allowsUndo = true
        editor.onError = { [weak self] message in self?.detailLabel.stringValue = message }
        editor.duplicateCommit = { [weak self] source, copy, nodes, selected in
            guard let self else { return false }
            if let id = source.componentID {
                do {
                    let captured = try SceneComponent.capture(source, from: self.scene)
                    var next = try captured.inserting(into: self.scene, id: id)
                    var roots = next.nodes
                    let instance = roots.removeLast()
                    _ = SceneTree.edit(source.id, in: &roots) { siblings, index in siblings.insert(instance, at: index + 1) }
                    next = next.replacingNodes(roots)
                    return self.applyEdit(roots, selected: next.allNodes.firstIndex { $0.id == instance.id } ?? 0, name: "Duplicate Instance", controls: next)
                } catch { self.detailLabel.stringValue = error.localizedDescription; return false }
            }
            let next = self.scene.duplicatingBindings(from: source, to: copy)
            guard (try? next.replacingNodes(nodes).evaluated()) != nil else {
                self.detailLabel.stringValue = "Duplicating this layer would exceed the scene binding budget."; return false
            }
            return self.applyEdit(nodes, selected: selected, name: "Duplicate Layer", controls: next)
        }
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
            if (updated || self.renderer !== renderer), previous.timeline != target.scene.timeline {
                try? self.clock.configure(timeline: target.scene.timeline)
                self.renderer?.refreshSceneTime()
            }
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
            self.detailLabel.stringValue = target.draft ? "Unsaved scene" : "Original scene"
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, inactive) in [(NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sessionInactive = inactive; self?.updatePlayback()
            }
            observers.append((workspace, token))
        }
        for (name, sleeping) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.displayAsleep = sleeping; self?.updatePlayback()
            }
            observers.append((workspace, token))
        }
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
        let sample = NSPopUpButton(frame: .zero, pullsDown: true)
        sample.addItems(withTitles: ["Samples", "Aurora", "Audio Aurora", "Fireflies", "Ripple"])
        sample.item(at: 1)?.target = self; sample.item(at: 1)?.action = #selector(showSample)
        sample.item(at: 4)?.target = self; sample.item(at: 4)?.action = #selector(showRippleSample)
        sample.item(at: 3)?.target = self; sample.item(at: 3)?.action = #selector(showParticleSample)
        sample.item(at: 2)?.target = self; sample.item(at: 2)?.action = #selector(showAudioSample)
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
        let transport = NSButton(title: "Time…", target: self, action: #selector(editTransport))
        transport.toolTip = "Seek, change motion speed, or loop scene animation in Metal"
        let playback = NSButton(title: "Playback…", target: self, action: #selector(editAuthoredPlayback))
        playback.toolTip = "Save scene duration, looping, and speed in the document"
        hudButton.target = self
        hudButton.action = #selector(toggleHUD)
        hudButton.setButtonType(.pushOnPushOff)
        hudButton.toolTip = "Toggle real-time performance HUD overlay"
        let showHUD = UserDefaults.standard.bool(forKey: "Idlesse.studio.showHUD")
        hudButton.state = showHUD ? .on : .off
        hudOverlay.isHidden = !showHUD
        let controls = NSStackView(views: [open, sample, pauseButton, transport, playback, engine, zoomOut, fit, zoomIn, measureButton, hudButton, applyButton])
        controls.spacing = 10
        nodePicker.onVisibility = { [weak self] in self?.editor.toggleVisibility($0) }
        nodePicker.onLock = { [weak self] in self?.editor.toggleLock($0) }
        nodePicker.target = self
        nodePicker.action = #selector(selectNode)
        nodePicker.onReorder = { [weak self] source, destination in
            guard let self, !self.saving else { return }
            self.editor.reorder(source, destination)
        }
        nodePicker.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(nodePicker)

        undoButton.target = self; undoButton.action = #selector(undoEdit)
        redoButton.target = self; redoButton.action = #selector(redoEdit)
        for (button, action) in [(addMediaButton, #selector(addMedia)), (addGradientButton, #selector(createMenu)),
                                 (addParticlesButton, #selector(addParticles)), (reorderButton, #selector(reorderNode)),
                                 (removeNodeButton, #selector(removeNode))] {
            button.target = self
            button.action = action
        }
        duplicateButton.target = self; duplicateButton.action = #selector(duplicateNode)
        groupButton.target = self; groupButton.action = #selector(groupNodes)
        groupButton.toolTip = "Combine this layer and the next layer in drawing order. Undo restores the individual layers."
        ungroupButton.target = self; ungroupButton.action = #selector(ungroupNodes)
        ungroupButton.toolTip = "Restore the child layers. Reset group transform, opacity and appearance first."

        dragOverlay.onSelect = { [weak self] index in
            guard let self, self.scene.allNodes.indices.contains(index) else { return }
            self.nodePicker.selectItem(at: index); self.selectNode()
        }
        dragOverlay.onBeginTransform = { [weak self] gesture in self?.beginCanvasMotion(gesture) ?? false }
        dragOverlay.onPreviewTransform = { [weak self] transform, gesture in
            self?.previewCanvasMotion(transform, gesture: gesture)
        }
        dragOverlay.onTransform = { [weak self] transform, name, gesture in
            self?.commitCanvasMotion(transform, name: name, gesture: gesture)
        }
        dragOverlay.onCancelTransform = { [weak self] in self?.cancelCanvasMotion() }
        dragOverlay.onNudge = { [weak self] x, y in self?.nudgeCanvasMotion(x: x, y: y) }
        dragOverlay.onDelete = { [weak self] in self?.editor.remove() }

        pointerToggle.target = self; pointerToggle.action = #selector(togglePointer)
        pointerToggle.font = .systemFont(ofSize: 10)
        audioToggle.target = self; audioToggle.action = #selector(toggleAudio)
        audioToggle.font = .systemFont(ofSize: 10)
        audioToggle.toolTip = "Use system audio levels for this session. No audio is saved."
        audioStatus.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        audioStatus.setAccessibilityLabel("Audio input levels")
        audioStatus.widthAnchor.constraint(equalToConstant: 270).isActive = true

        saveCopyButton.target = self; saveCopyButton.action = #selector(saveCopy)
        saveButton.target = self; saveButton.action = #selector(saveDocument)
        exportButton.target = self; exportButton.action = #selector(exportVideo)
        let resetButton = NSButton(title: "Reset Changes", target: self, action: #selector(resetChanges))
        let sceneDetails = NSButton(title: "Scene Details…", target: self, action: #selector(editMetadata))
        let scenePlayback = NSButton(title: "Playback…", target: self, action: #selector(editAuthoredPlayback))

        layerInspector.onRename = { [weak self] in self?.renameNode() }
        layerInspector.onTransform = { [weak self] in self?.editTransform() }
        layerInspector.onNumericProperty = { [weak self] target, value in self?.editMotionProperty(target, value: value) }
        layerInspector.onSelectMotionTarget = { [weak self] target in
            guard let self else { return }
            self.selectedMotionTarget = target
            self.updateTimeline()
        }
        layerInspector.onMotionCommand = { [weak self] target, command in self?.handleMotionCommand(target, command: command) }
        layerInspector.onTypedMotionCommand = { [weak self] target, command in self?.handleTypedMotionCommand(target, command: command) }
        layerInspector.onVisibility = { [weak self] in
            guard let self else { return }
            self.editor.toggleVisibility(self.nodePicker.indexOfSelectedItem)
        }
        layerInspector.onLock = { [weak self] in
            guard let self else { return }
            self.editor.toggleLock(self.nodePicker.indexOfSelectedItem)
        }
        layerInspector.onCommitNode = { [weak self] node, name in self?.commitInspectorNode(node, name: name) }
        layerInspector.onChooseMaskImage = { [weak self] node in self?.chooseLayerImage(node, sprite: false) }
        layerInspector.onChooseSpriteImage = { [weak self] node in self?.chooseLayerImage(node, sprite: true) }
        layerInspector.onEditControls = { [weak self] in self?.editControls() }
        layerInspector.onEditBinding = { [weak self] in self?.editBinding() }
        layerInspector.onEditKeyframes = { [weak self] in self?.editKeyframes() }
        layerInspector.onError = { [weak self] message in self?.detailLabel.stringValue = message }
        layerInspector.install(layerActions: [
            NSStackView(views: [undoButton, redoButton]),
            NSStackView(views: [addMediaButton, addGradientButton]),
            NSStackView(views: [addParticlesButton, duplicateButton]),
            groupButton, ungroupButton,
            NSStackView(views: [reorderButton, removeNodeButton])
        ], motionSession: [pointerToggle, audioToggle, audioStatus], sceneActions: [
            scenePlayback, sceneDetails, NSStackView(views: [saveButton, saveCopyButton]), exportButton, resetButton
        ])
        layerInspector.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(layerInspector)
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
        timeline.onSeek = { [weak self] time in
            guard let self, self.renderer is MetalSceneRenderer else { return }
            self.paused = true; self.updatePlayback()
            do { try self.clock.seek(to: time); self.renderer?.refreshSceneTime(); self.updateTimeline() }
            catch { self.detailLabel.stringValue = error.localizedDescription }
        }
        timeline.onAutoKey = { [weak self] _ in
            self?.selectNode()
            self?.updateTimeline()
        }
        timeline.onSelectTarget = { [weak self] target in
            guard let self else { return }
            self.selectedMotionTarget = target
            self.layerInspector.revealMotionTarget(target)
        }
        timeline.onMoveKey = { [weak self] target, index, time in
            guard let self, !self.saving, self.editor.selectedNode?.id == target.nodeID,
                  self.editor.selectedNode?.locked == false else { return }
            var next = self.scene
            guard let bindingIndex = next.bindings.firstIndex(where: { $0.target == target }),
                  let track = next.bindings[bindingIndex].keyframes else { return }
            do {
                let moved = try track.movingKey(at: index, to: time)
                guard moved != track else { return }
                next.bindings[bindingIndex].keyframes = moved
                _ = self.applyEdit(next.nodes, selected: self.editor.selection, name: "Move Keyframe", controls: next)
            } catch { self.detailLabel.stringValue = error.localizedDescription }
        }
        timeline.onEditTrack = { [weak self] target, track, name in
            guard let self, !self.saving, self.editor.selectedNode?.id == target.nodeID,
                  self.editor.selectedNode?.locked == false else { return }
            var next = self.scene
            guard let index = next.bindings.firstIndex(where: { $0.target == target && $0.keyframes != nil }) else { return }
            do {
                _ = try track.sample(at: 0)
                next.bindings[index].keyframes = track
                _ = self.applyEdit(next.nodes, selected: self.nodePicker.indexOfSelectedItem, name: name, controls: next)
            } catch { self.detailLabel.stringValue = error.localizedDescription }
        }
        timeline.onLoop = { [weak self] end in
            guard let self, self.renderer is MetalSceneRenderer else { return }
            do {
                try self.clock.configure(time: 0, rate: self.clock.playbackRate, loop: 0..<end)
                self.renderer?.refreshSceneTime(); self.updateTimeline()
                self.detailLabel.stringValue = "Loop set to 0–\(end) seconds. Resume to play; Time… changes or disables it."
            } catch { self.detailLabel.stringValue = error.localizedDescription }
        }
        for child in [heading, viewport, controls, frameRate, timeline, hudOverlay] {
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
            viewport.trailingAnchor.constraint(equalTo: layerInspector.leadingAnchor, constant: -16),
            layerInspector.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            layerInspector.topAnchor.constraint(equalTo: viewport.topAnchor),
            layerInspector.bottomAnchor.constraint(equalTo: viewport.bottomAnchor),
            layerInspector.widthAnchor.constraint(equalToConstant: 304),
            viewport.bottomAnchor.constraint(equalTo: timeline.topAnchor, constant: -12),
            timeline.leadingAnchor.constraint(equalTo: viewport.leadingAnchor),
            timeline.trailingAnchor.constraint(equalTo: viewport.trailingAnchor),
            timeline.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12),
            controls.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            hudOverlay.topAnchor.constraint(equalTo: viewport.topAnchor, constant: 12),
            hudOverlay.trailingAnchor.constraint(equalTo: viewport.trailingAnchor, constant: -12),
            hudOverlay.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
    }
    private var checkedRecovery = false
    func show() {
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        if renderer == nil { fitCanvas() }
        watchPackage()
        updatePlayback()
        NSApp.activate(ignoringOtherApps: true)
        guard !checkedRecovery else { return }
        checkedRecovery = true
        document.recoveryEnabled = true
        document.recoveryError = { [weak self] in self?.detailLabel.stringValue = $0 }
        do {
            guard let recovery = try document.readRecovery() else { return }
            let alert = NSAlert()
            alert.messageText = "Recover unsaved Studio work?"
            alert.informativeText = "\(recovery.scene.title) · \(recovery.edited.formatted())\nMedia stays in its existing location."
            alert.addButton(withTitle: "Recover")
            alert.addButton(withTitle: "Keep for Later")
            alert.addButton(withTitle: "Discard Draft")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if applyEdit(recovery.scene.nodes, selected: 0, name: "Recover Draft", controls: recovery.scene) {
                    document.adoptRecovery()
                    document.scheduleRecovery()
                    document.sourceURL = nil
                    document.revision = nil
                    detailLabel.stringValue = "Recovered draft · Save As to keep it"
                }
            case .alertThirdButtonReturn: document.discardPendingRecovery()
            default: break
            }
        } catch { detailLabel.stringValue = "Recovery draft preserved: \(error.localizedDescription)" }
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
        detailLabel.stringValue = "\(scene.nodes.count) layer\(scene.nodes.count == 1 ? "" : "s") · \(engine.indexOfSelectedItem == 1 ? "Metal preview" : "Standard preview")"
        updateInspector()
        updatePlayback()
    }
    private func updateInspector() {
        if !scene.usesAudio { clock.audioEnabled = false }
        audioToggle.isEnabled = scene.usesAudio && !saving
        audioToggle.state = clock.audioEnabled ? .on : .off
        updateTimeline()
        let selected = max(0, nodePicker.indexOfSelectedItem)
        nodePicker.removeAllItems()
        nodePicker.setNodes(scene.nodes)
        nodePicker.selectItem(at: min(selected, scene.allNodes.count - 1))
        selectNode()
        applyButton.isEnabled = selectedURL != nil && !draft && !saving
        saveCopyButton.isEnabled = !saving
        exportButton.isEnabled = !saving
        saveButton.isEnabled = !saving
        nameField.isEditable = !saving && editor.selectedNode?.locked == false
        duplicateButton.isEnabled = !saving && scene.allNodes.count < SceneBudget.maxNodes
        addMediaButton.isEnabled = !saving && scene.allNodes.count < SceneBudget.maxNodes
        addGradientButton.isEnabled = !saving
        addParticlesButton.isEnabled = addMediaButton.isEnabled && scene.allNodes.filter { $0.kind == .particles }.count < 4
        emitterButton.isEnabled = !saving && editor.selectedNode?.emitter != nil && editor.selectedNode?.locked == false
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
        if selectedMotionTarget?.nodeID != node.id { selectedMotionTarget = nil }
        let signals = motionSignals()
        let previewNodes = (try? scene.evaluated(signals: signals).nodes) ?? scene.nodes
        dragOverlay.roots = previewNodes
        dragOverlay.isEnabled = !saving
        dragOverlay.selected = editor.selection
        dragOverlay.transform = previewNodes.flatMap { $0.descendants }.first { $0.id == node.id }?.transform ?? node.transform
        reorderButton.title = offset == 0 ? "Bring Forward" : "Send Backward"
        layerInspector.update(scene: scene, node: node, saving: saving, time: clock.time,
                              signals: signals, autoKey: timeline.autoKeyEnabled)
        updateTimeline()
    }
    private func motionSignals() -> SceneSignals { SceneSignals(time: clock.time) }

    private func commitMotionScene(_ next: SceneDescriptor, name: String) {
        _ = applyEdit(next.nodes, selected: editor.selection, name: name, controls: next)
    }

    private func editMotionProperty(_ target: ScenePropertyAddress, value: Double) {
        guard !saving, editor.selectedNode?.id == target.nodeID, editor.selectedNode?.locked == false else { return }
        do {
            let next = try StudioMotionAuthoring.edit(value, target: target, time: clock.time,
                                                      autoKey: timeline.autoKeyEnabled, in: scene)
            selectedMotionTarget = target
            commitMotionScene(next, name: timeline.autoKeyEnabled ? "Auto-Key \(target.label(in: scene.nodes))" : "Change \(target.label(in: scene.nodes))")
        } catch { detailLabel.stringValue = error.localizedDescription; selectNode() }
    }

    private func handleMotionCommand(_ target: ScenePropertyAddress, command: StudioMotionCommand) {
        guard !saving, editor.selectedNode?.id == target.nodeID, editor.selectedNode?.locked == false else { return }
        selectedMotionTarget = target
        if case .select = command { layerInspector.revealMotionTarget(target); updateTimeline(); return }
        if case .revealTimeline = command { updateTimeline(); return }
        if case .advancedBinding = command { editBinding(); return }
        if case .advancedKeyframes = command { editKeyframes(); return }
        do {
            let next: SceneDescriptor
            switch command {
            case .select, .revealTimeline, .advancedBinding, .advancedKeyframes:
                return
            case .makeStatic:
                next = try StudioMotionAuthoring.makeStatic(target, signals: motionSignals(), in: scene)
            case .addKey:
                next = try StudioMotionAuthoring.promoteToKeyframes(target, time: clock.time,
                                                                    signals: motionSignals(), in: scene)
            case .removeKey:
                next = try StudioMotionAuthoring.removeKey(target, time: clock.time,
                                                           signals: motionSignals(), in: scene)
            case .bindSignal(let signal):
                next = try StudioMotionAuthoring.bind(target, to: signal, in: scene)
            case .bindControl(let key):
                next = try StudioMotionAuthoring.bind(target, toParameter: key, in: scene)
            case .createControl:
                let range = try target.range(in: scene.nodes)
                let value = try StudioMotionAuthoring.visibleValue(of: target, in: scene, signals: motionSignals())
                var controlled = scene
                let key = UUID().uuidString
                controlled.parameters[key] = SceneParameter(name: target.label(in: scene.nodes), value: value,
                                                             min: range.lowerBound, max: range.upperBound)
                next = try StudioMotionAuthoring.bind(target, toParameter: key, in: controlled)
            case .updateMapping(let scale, let offset, let period, let smoothing):
                next = try StudioMotionAuthoring.updateMapping(target, scale: scale, offset: offset,
                                                               period: period, smoothing: smoothing, in: scene)
            case .interpolation(let interpolation):
                next = try StudioMotionAuthoring.setInterpolation(interpolation, target: target, in: scene)
            }
            commitMotionScene(next, name: "Change \(target.label(in: scene.nodes)) Motion")
        } catch { detailLabel.stringValue = error.localizedDescription }
    }

    private func handleTypedMotionCommand(_ target: SceneControlTarget, command: StudioTypedMotionCommand) {
        guard !saving, editor.selectedNode?.id == target.nodeID, editor.selectedNode?.locked == false else { return }
        if case .select = command { return }
        do {
            let next: SceneDescriptor
            switch command {
            case .select: return
            case .makeStatic:
                next = try StudioMotionAuthoring.makeStatic(target, in: scene)
            case .bindControl(let key):
                next = try StudioMotionAuthoring.bind(target, toParameter: key, in: scene)
            case .createControl:
                let nodeName = editor.selectedNode?.displayName ?? "Layer"
                let propertyName: String
                switch target.property {
                case .visible: propertyName = "Visibility"
                case .blend: propertyName = "Blend"
                case .text: propertyName = "Text"
                case .fill: propertyName = "Fill"
                }
                var controlled = scene
                let key = UUID().uuidString
                controlled.parameters[key] = try StudioMotionAuthoring.newControl(for: target,
                    name: "\(nodeName) \(propertyName)", in: scene)
                next = try StudioMotionAuthoring.bind(target, toParameter: key, in: controlled)
            }
            commitMotionScene(next, name: "Change Property Motion")
        } catch { detailLabel.stringValue = error.localizedDescription }
    }

    private func canvasTargets(for gesture: SceneTransformGesture, nodeID: UUID) -> [ScenePropertyAddress] {
        switch gesture {
        case .move: return [.init(nodeID: nodeID, property: .x), .init(nodeID: nodeID, property: .y)]
        case .scale: return [.init(nodeID: nodeID, property: .scale)]
        case .rotate: return [.init(nodeID: nodeID, property: .rotation)]
        }
    }

    private func beginCanvasMotion(_ gesture: SceneTransformGesture) -> Bool {
        guard !saving, let node = editor.selectedNode, !node.locked else { return false }
        let targets = canvasTargets(for: gesture, nodeID: node.id)
        let blocked = targets.first { !StudioMotionAuthoring.writeDisposition(for: $0, in: scene,
            time: clock.time, autoKey: timeline.autoKeyEnabled).writable }
        guard blocked == nil else {
            detailLabel.stringValue = "\(blocked!.label(in: scene.nodes)) has another Motion owner, or needs Auto-Key at this playhead."
            return false
        }
        paused = true
        updatePlayback()
        canvasMotionBase = scene
        canvasMotionPreview = nil
        selectedMotionTarget = targets.first
        return true
    }

    private func canvasMotionScene(_ transform: SceneNode.Transform, gesture: SceneTransformGesture,
                                   base: SceneDescriptor) throws -> SceneDescriptor {
        guard let node = editor.selectedNode else { return base }
        let values: [(ScenePropertyAddress.Property, Double)]
        switch gesture {
        case .move:
            values = [(.x, transform.x ?? 0), (.y, transform.y ?? 0)]
        case .scale:
            values = [(.scale, transform.scale ?? 1)]
        case .rotate:
            values = [(.rotation, transform.rotation ?? 0)]
        }
        let signals = motionSignals()
        var next = base
        for (property, value) in values {
            let target = ScenePropertyAddress(nodeID: node.id, property: property)
            let current = try StudioMotionAuthoring.visibleValue(of: target, in: base, signals: signals)
            guard abs(current - value) > 0.0000001 else { continue }
            next = try StudioMotionAuthoring.edit(value, target: target, time: clock.time,
                                                  autoKey: timeline.autoKeyEnabled, in: next)
        }
        return next
    }

    private func previewCanvasMotion(_ transform: SceneNode.Transform, gesture: SceneTransformGesture) {
        guard let base = canvasMotionBase else { return }
        do {
            let next = try canvasMotionScene(transform, gesture: gesture, base: base)
            guard renderer?.updateScene(next) == true else { throw SceneError.invalid("Could not preview this motion edit.") }
            canvasMotionPreview = next
        } catch {
            if let valid = canvasMotionPreview ?? canvasMotionBase { _ = renderer?.updateScene(valid) }
            detailLabel.stringValue = error.localizedDescription
        }
    }

    private func commitCanvasMotion(_ transform: SceneNode.Transform, name: String, gesture: SceneTransformGesture) {
        guard let base = canvasMotionBase else { return }
        do {
            let next = try (canvasMotionPreview ?? canvasMotionScene(transform, gesture: gesture, base: base))
            canvasMotionBase = nil
            canvasMotionPreview = nil
            commitMotionScene(next, name: timeline.autoKeyEnabled ? "Auto-Key \(name)" : name)
        } catch {
            canvasMotionBase = nil
            canvasMotionPreview = nil
            _ = renderer?.updateScene(base)
            detailLabel.stringValue = error.localizedDescription
            selectNode()
        }
    }

    private func cancelCanvasMotion() {
        if let base = canvasMotionBase { _ = renderer?.updateScene(base) }
        canvasMotionBase = nil
        canvasMotionPreview = nil
        selectNode()
    }

    private func nudgeCanvasMotion(x: Double, y: Double) {
        guard !saving, let node = editor.selectedNode, !node.locked else { return }
        paused = true
        updatePlayback()
        do {
            let signals = motionSignals()
            var next = scene
            for (property, delta) in [(ScenePropertyAddress.Property.x, x), (.y, y)] where abs(delta) > 0 {
                let target = ScenePropertyAddress(nodeID: node.id, property: property)
                guard StudioMotionAuthoring.writeDisposition(for: target, in: next, time: clock.time,
                    autoKey: timeline.autoKeyEnabled).writable else {
                    throw SceneError.invalid("\(target.label(in: scene.nodes)) cannot be edited at this playhead with its current Motion owner.")
                }
                let current = try StudioMotionAuthoring.visibleValue(of: target, in: next, signals: signals)
                next = try StudioMotionAuthoring.edit(current + delta, target: target, time: clock.time,
                                                      autoKey: timeline.autoKeyEnabled, in: next)
            }
            commitMotionScene(next, name: timeline.autoKeyEnabled ? "Auto-Key Nudge Layer" : "Nudge Layer")
        } catch { detailLabel.stringValue = error.localizedDescription; selectNode() }
    }

    @objc private func editTransform() {
        guard !saving, let current = editor.selectedNode, !current.locked else { return }
        let values = transformFields.compactMap { Double($0.stringValue) }
        let ranges = [-2.0...2.0, -2.0...2.0, 0.05...4.0, -360.0...360.0, 0.0...1.0]
        guard values.count == 5, zip(values, ranges).allSatisfy({ $0.isFinite && $1.contains($0) }) else {
            detailLabel.stringValue = "Use X/Y −2…2, scale 0.05…4, rotation −360…360, opacity 0…1."
            selectNode()
            return
        }
        let existing: [Double] = [current.transform.x ?? 0, current.transform.y ?? 0, current.transform.scale ?? 1,
                                  current.transform.rotation ?? 0, current.opacity]
        // Display rounds to three decimals; unchanged fields must not create edits.
        guard zip(values, existing).contains(where: { abs($0 - $1) > 0.0005 }) else { return }
        var node = current
        node.transform = .init(x: values[0], y: values[1], scale: values[2], rotation: values[3])
        node.opacity = values[4]
        editor.replaceSelected(node, name: "Change Layer")
    }
    @discardableResult private func applyEdit(_ nodes: [SceneNode], selected: Int, name: String = "Change Layer", controls: SceneDescriptor? = nil) -> Bool {
        guard !saving, (1...SceneBudget.maxNodes).contains(nodes.count) else { return false }
        do { try SceneBudget.validate(nodes) } catch { detailLabel.stringValue = error.localizedDescription; return false }
        let previous = scene
        let snapshot = EditSnapshot(scene: previous, selected: nodePicker.indexOfSelectedItem, draft: draft)
        let previousRenderer = renderer
        scene = (controls ?? scene).replacingNodes(nodes)
        let updated = renderer?.updateScene(scene) ?? false
        if !updated { rebuild() }
        guard updated || renderer !== previousRenderer else { scene = previous; updateInspector(); return false }
        if previous.timeline != scene.timeline {
            try? clock.configure(timeline: scene.timeline)
            renderer?.refreshSceneTime()
        }
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
    @objc private func renameNode() {
        guard !saving, editor.selectedNode?.locked == false else { selectNode(); return }
        editor.rename(nameField.stringValue)
    }
    private func commitInspectorNode(_ node: SceneNode, name: String) {
        guard !saving, let current = editor.selectedNode, current.id == node.id, !current.locked else {
            selectNode(); return
        }
        editor.replaceSelected(node, name: name)
    }
    @objc private func editControls() {
        guard !saving else { return }
        let original = scene.parameters
        SceneParameterControls.present(scene: scene, window: window) { [weak self] values in
            guard let self, self.scene.parameters == original, values != original else { return }
            var next = self.scene
            next.parameters = values
            _ = self.applyEdit(next.nodes, selected: self.editor.selection, name: "Change Controls", controls: next)
        }
    }
    @objc private func toggleAudio() {
        guard scene.usesAudio, !saving else { return }
        clock.audioEnabled = audioToggle.state == .on
        if renderer?.updateScene(scene) != true { rebuild() }
        updatePlayback()
    }
    @objc private func togglePointer() {
        clock.pointerEnabled = pointerToggle.state == .on
        if renderer?.updateScene(scene) != true { rebuild() }
        updatePlayback()
    }
    @objc private func editKeyframes() {
        guard !saving, let node = editor.selectedNode, !node.locked else { return }
        let dialog = NSAlert()
        dialog.messageText = "Keyframes — " + node.displayName
        dialog.informativeText = "Enter time:value pairs separated by commas (seconds). Replaces the selected property's binding. Use Time… to seek or loop; Playback… controls video following."
        dialog.addButton(withTitle: "Apply"); dialog.addButton(withTitle: "Remove Track"); dialog.addButton(withTitle: "Cancel")
        let properties = ScenePropertyAddress.targets(for: node)
        let property = NSPopUpButton(frame: .zero, pullsDown: false)
        property.addItems(withTitles: properties.map { $0.label(in: scene.nodes) })
        property.setAccessibilityLabel("Keyframe property")
        let interpolation = NSPopUpButton(frame: .zero, pullsDown: false)
        interpolation.addItems(withTitles: ["Linear", "Hold", "Ease In Out"])
        interpolation.setAccessibilityLabel("Keyframe interpolation")
        let values = NSTextField(string: "0:-0.3, 3:0.3, 6:-0.3")
        values.setAccessibilityLabel("Keyframe time and value pairs")
        values.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let stack = NSStackView(views: [property, interpolation, values])
        stack.orientation = .vertical; stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 100)
        let selectionAction = StudioControlAction()
        selectionAction.perform = { [weak self] in
            guard let self else { return }
            let target = properties[property.indexOfSelectedItem]
            if let track = self.scene.bindings.first(where: { $0.target == target })?.keyframes {
                values.stringValue = track.keys.map { "\($0.time):\($0.value)" }.joined(separator: ", ")
                interpolation.selectItem(at: track.interpolation == .linear ? 0 : track.interpolation == .hold ? 1 : 2)
            } else {
                let value = (try? target.value(in: self.scene.nodes)) ?? 0
                values.stringValue = "0:\(value), 3:\(value)"
                interpolation.selectItem(at: 0)
            }
        }
        property.target = selectionAction; property.action = #selector(StudioControlAction.changed)
        if let existing = scene.bindings.first(where: { $0.target.nodeID == node.id && $0.keyframes != nil }),
           let index = properties.firstIndex(of: existing.target) { property.selectItem(at: index) }
        selectionAction.perform()
        dialog.accessoryView = stack
        dialog.beginSheetModal(for: window) { [weak self] response in
            _ = selectionAction // Retain the popup target through the sheet lifetime.
            guard let self, response != .alertThirdButtonReturn, !self.saving,
                  self.scene.allNodes.contains(where: { $0.id == node.id && !$0.locked }) else { return }
            do {
                let target = properties[property.indexOfSelectedItem]
                if response == .alertSecondButtonReturn {
                    var next = self.scene
                    next.bindings.removeAll { $0.target == target && $0.keyframes != nil }
                    _ = self.applyEdit(next.nodes, selected: self.editor.selection, name: "Remove Keyframes", controls: next)
                    return
                }
                let entries = values.stringValue.split(separator: ",", omittingEmptySubsequences: false)
                guard entries.count <= 128 else { throw SceneError.invalid("Use at most 128 keys.") }
                let keys = try entries.map { entry -> SceneKeyframeTrack.Key in
                    let pair = entry.split(separator: ":", omittingEmptySubsequences: false)
                    guard pair.count == 2,
                          let time = Double(pair[0].trimmingCharacters(in: .whitespaces)),
                          let value = Double(pair[1].trimmingCharacters(in: .whitespaces)) else {
                        throw SceneError.invalid("Use comma-separated time:value pairs, such as 0:0, 3:1.")
                    }
                    return .init(time: time, value: value)
                }
                let modes: [SceneKeyframeTrack.Interpolation] = [.linear, .hold, .easeInOut]
                let track = SceneKeyframeTrack(interpolation: modes[interpolation.indexOfSelectedItem], keys: keys)
                var next = self.scene
                let existing = next.bindings.first { $0.target == target && $0.keyframes != nil }
                next.bindings.removeAll { $0.target == target }
                var binding = existing ?? SceneParameterBinding(target: target)
                binding.keyframes = track
                next.bindings.append(binding)
                _ = try next.evaluated()
                _ = self.applyEdit(next.nodes, selected: self.editor.selection, name: "Set Keyframes", controls: next)
            } catch { self.detailLabel.stringValue = error.localizedDescription }
        }
    }

    @objc private func editBinding() {
        guard !saving, let node = editor.selectedNode, !node.locked else { return }
        let dialog = NSAlert()
        dialog.messageText = "Bind — " + node.displayName
        dialog.informativeText = ""
        dialog.addButton(withTitle: "Bind"); dialog.addButton(withTitle: "Remove Binding"); dialog.addButton(withTitle: "Cancel")
        let property = NSPopUpButton(frame: .zero, pullsDown: false)
        let properties = ScenePropertyAddress.targets(for: node)
        property.addItems(withTitles: properties.map { $0.label(in: scene.nodes) })
        property.selectItem(at: properties.firstIndex(where: { $0.property == .opacity })!)
        property.setAccessibilityLabel("Target property")
        let parameter = NSPopUpButton(frame: .zero, pullsDown: false)
        let keys = scene.parameters.keys.filter { scene.parameters[$0]?.type == .number }.sorted()
        let signals: [SceneParameterBinding.Signal] = [.time, .sine, .pointerX, .pointerY, .audioLevel, .audioBass, .audioMid, .audioTreble]
        parameter.addItems(withTitles: ["New control"] + keys.map { scene.parameters[$0]!.name } + ["Elapsed Time", "Sine Wave", "Pointer X", "Pointer Y", "Audio Level", "Audio Bass", "Audio Mid", "Audio Treble", "Existing Keyframes"])
        parameter.setAccessibilityLabel("Control")
        let name = NSTextField(string: node.displayName + " Control")
        name.setAccessibilityLabel("New control name")
        let scale = NSTextField(string: "1")
        let offset = NSTextField(string: "0")
        let period = NSTextField(string: "8")
        let smoothing = NSTextField(string: "0")
        smoothing.setAccessibilityLabel("Binding smoothing in seconds")
        let multiplier = NSPopUpButton(frame: .zero, pullsDown: false)
        multiplier.addItems(withTitles: ["Keep existing modifiers", "None"] + keys.map { scene.parameters[$0]!.name })
        multiplier.setAccessibilityLabel("Multiply by control")
        scale.setAccessibilityLabel("Binding scale"); offset.setAccessibilityLabel("Binding offset"); period.setAccessibilityLabel("Sine period in seconds")
        let fields = NSStackView(views: [property, parameter, name,
            NSTextField(labelWithString: "Scale"), scale, NSTextField(labelWithString: "Offset"), offset,
            NSTextField(labelWithString: "Sine period (seconds)"), period,
            NSTextField(labelWithString: "Multiply result by control"), multiplier,
            NSTextField(labelWithString: "Smoothing (0–5 seconds, signals/keyframes)"), smoothing])
        fields.orientation = .vertical; fields.alignment = .leading
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 365)
        name.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let selectionAction = StudioControlAction()
        selectionAction.perform = { [weak self] in
            guard let self else { return }
            let target = properties[property.indexOfSelectedItem]
            let binding = self.scene.bindings.first { $0.target == target }
            scale.stringValue = String(binding?.scale ?? 1)
            offset.stringValue = String(binding?.offset ?? 0)
            period.stringValue = String(binding?.period ?? 8)
            smoothing.stringValue = String(binding?.smoothing ?? 0)
            multiplier.selectItem(at: 0)
            parameter.lastItem?.isEnabled = binding?.keyframes != nil
            if binding?.keyframes != nil { parameter.selectItem(at: keys.count + signals.count + 1) }
            else if let signal = binding?.signal, let index = signals.firstIndex(of: signal) { parameter.selectItem(at: keys.count + 1 + index) }
            else if let key = binding?.parameter, let index = keys.firstIndex(of: key) { parameter.selectItem(at: index + 1) }
            else { parameter.selectItem(at: 0) }
        }
        property.target = selectionAction; property.action = #selector(StudioControlAction.changed)
        if let existing = scene.bindings.first(where: { $0.target.nodeID == node.id }),
           let index = properties.firstIndex(of: existing.target) { property.selectItem(at: index) }
        selectionAction.perform()
        dialog.accessoryView = fields
        dialog.beginSheetModal(for: window) { [weak self] response in
            _ = selectionAction
            guard let self, !self.saving, response != .alertThirdButtonReturn,
                  self.scene.allNodes.contains(where: { $0.id == node.id && !$0.locked }) else { return }
            var next = self.scene
            let target = properties[property.indexOfSelectedItem]
            let previous = next.bindings.first { $0.target == target }
            let previousKeys = next.bindings.filter { $0.target == target }.flatMap(\.referencedParameters)
            next.bindings.removeAll { $0.target == target }
            if response == .alertFirstButtonReturn {
                let index = parameter.indexOfSelectedItem
                guard let amount = Double(scale.stringValue), let base = Double(offset.stringValue), let seconds = Double(period.stringValue), let damping = Double(smoothing.stringValue) else {
                    self.detailLabel.stringValue = "Use numeric scale, offset, period and smoothing values."; return
                }
                let usesTrack = index == keys.count + signals.count + 1
                if usesTrack && previous?.keyframes == nil { self.detailLabel.stringValue = "Add keyframes with Keys… first."; return }
                let signal = index > keys.count && !usesTrack ? signals[index - keys.count - 1] : nil
                let key = signal != nil || usesTrack ? "" : index == 0 ? UUID().uuidString : keys[index - 1]
                if index == 0 {
                    let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty, title.count <= 80 else { self.detailLabel.stringValue = "Use a control name of 1–80 characters."; return }
                    guard let range = try? target.range(in: self.scene.nodes) else {
                        self.detailLabel.stringValue = "The target effect no longer exists."; return
                    }
                    let value = (try? target.value(in: self.scene.nodes)) ?? range.lowerBound
                    next.parameters[key] = SceneParameter(name: title, value: value,
                                                          min: range.lowerBound, max: range.upperBound)
                }
                let modifiers: [SceneParameterBinding.Modifier] = multiplier.indexOfSelectedItem == 0 ? previous?.modifiers ?? []
                    : multiplier.indexOfSelectedItem > 1 ? [.init(operation: .multiply, parameter: keys[multiplier.indexOfSelectedItem - 2])] : []
                next.bindings.append(SceneParameterBinding(target: target, parameter: key, scale: amount, offset: base, signal: signal, period: seconds, modifiers: modifiers, keyframes: usesTrack ? previous?.keyframes : nil, smoothing: damping))
            }
            for key in previousKeys where !next.bindings.contains(where: { $0.referencedParameters.contains(key) }) {
                next.parameters.removeValue(forKey: key)
            }
            do { _ = try next.evaluated() } catch { self.detailLabel.stringValue = error.localizedDescription; return }
            _ = self.applyEdit(next.nodes, selected: self.editor.selection, name: "Change Binding", controls: next)
        }
    }
    @objc private func editCompositing() {
        guard !saving, var node = editor.selectedNode, !node.locked else { return }
        let dialog = NSAlert()
        dialog.messageText = "Mask & Blend — " + node.displayName
        dialog.informativeText = "Masks cover the scene canvas after this layer's transform. Node masks include that layer's effects and transform; hidden layers can still supply a mask. Image masks stretch to the canvas. Use an image layer as the mask to position it."
        dialog.addButton(withTitle: "Apply"); dialog.addButton(withTitle: "Cancel")
        let blend = NSPopUpButton()
        let blends: [SceneNode.Blend] = [.normal, .add, .multiply, .screen]
        blend.addItems(withTitles: ["Normal", "Add", "Multiply", "Screen"])
        blend.selectItem(at: blends.firstIndex(of: node.blend ?? .normal) ?? 0)
        let masks = scene.allNodes.filter { $0.id != node.id }
        let mask = NSPopUpButton()
        mask.addItems(withTitles: ["No asset/node mask", "Choose Image…", "Keep Current Image"] + masks.map { $0.displayName })
        mask.item(at: 2)?.isEnabled = node.maskAsset != nil
        mask.selectItem(at: node.maskAsset != nil ? 2 : node.maskNodeID.flatMap { id in masks.firstIndex { $0.id == id }.map { $0 + 3 } } ?? 0)
        let channel = NSPopUpButton()
        channel.addItems(withTitles: ["Alpha", "Luminance"])
        channel.selectItem(at: node.maskChannel == .luma ? 1 : 0)
        let fields = NSStackView(views: [NSTextField(labelWithString: "Blend"), blend,
            NSTextField(labelWithString: "Mask source"), mask, NSTextField(labelWithString: "Mask channel"), channel])
        fields.orientation = .vertical; fields.alignment = .leading
        fields.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        dialog.accessoryView = fields
        dialog.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, self.editor.selectedNode?.id == node.id, !self.saving else { return }
            node.blend = blends[blend.indexOfSelectedItem] == .normal ? nil : blends[blend.indexOfSelectedItem]
            node.maskChannel = channel.indexOfSelectedItem == 1 ? .luma : nil
            let choice = mask.indexOfSelectedItem
            if choice != 2 { node.maskAsset = nil }
            node.maskNodeID = choice >= 3 ? masks[choice - 3].id : nil
            if choice == 1 { self.chooseLayerImage(node, sprite: false) }
            else { self.editor.replaceSelected(node, name: "Change Mask and Blend") }
        }
    }

    private func chooseLayerImage(_ proposed: SceneNode, sprite: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.prompt = sprite ? "Use Sprite" : "Use Mask"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, !self.saving,
                  self.editor.selectedNode?.id == proposed.id, self.editor.selectedNode?.locked == false else { return }
            let access = url.startAccessingSecurityScopedResource()
            var adopted = false
            defer { if access && !adopted { url.stopAccessingSecurityScopedResource() } }
            var node = proposed
            if sprite { node.sprite = url } else { node.maskAsset = url; node.maskNodeID = nil }
            var roots = self.scene.nodes
            _ = SceneTree.edit(node.id, in: &roots) { siblings, index in siblings[index] = node }
            if self.applyEdit(roots, selected: self.editor.selection, name: sprite ? "Change Particle Sprite" : "Change Image Mask"),
               access && !self.importedScopes.contains(url) {
                self.importedScopes.append(url); adopted = true
            }
        }
    }

    @objc private func editAppearance() {
        guard !saving, var node = editor.selectedNode else { return }
        let dialog = NSAlert()
        dialog.messageText = "Appearance — " + node.displayName
        dialog.informativeText = ""
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
        let effectEditor = SceneEffectsEditor(effects: node.style.effects)
        let fields = NSStackView(views: [mask, NSTextField(labelWithString: "Exposure"), exposure,
                                        NSTextField(labelWithString: "Saturation"), saturation,
                                        NSTextField(labelWithString: "Vignette"), vignette])
        fields.orientation = .vertical; fields.alignment = .leading
        fields.addArrangedSubview(NSTextField(labelWithString: "Effects • drag to reorder"))
        fields.addArrangedSubview(effectEditor)
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 490)
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
            let effects: [SceneNode.Style.Effect]
            do { effects = try effectEditor.validatedEffects() }
            catch { self.detailLabel.stringValue = error.localizedDescription; return }
            node.style = .init(mask: mask.indexOfSelectedItem == 1 ? .ellipse : nil, exposure: ev, saturation: sat, vignette: vignette.doubleValue)
            node.style.effects = effects
            self.editor.replaceSelected(node, name: "Change Appearance")
        }
    }
    @objc private func ungroupNodes() { editor.ungroup() }
    @objc private func groupNodes() { editor.groupWithNext() }
    @objc private func duplicateNode() { editor.duplicate() }
    @objc private func addParticles() {
        guard !saving else { return }
        _ = editor.add(SceneNode(name: "Fireflies", content: .particles(.init())))
    }
    @objc private func editEmitter() {
        guard !saving, var node = editor.selectedNode, !node.locked, let current = node.emitter else { return }
        let dialog = NSAlert()
        dialog.messageText = "Emitter — " + node.displayName
        dialog.informativeText = ""
        dialog.addButton(withTitle: "Apply"); dialog.addButton(withTitle: "Cancel")
        let names = ["Count (1–512)", "Lifetime (0.1–60 s)", "Speed (−1…1)", "Wind (−1…1)", "Gravity (−1…1)", "Size (0.001–0.05)", "Seed (0–65535)"]
        let values = [String(current.count), String(current.lifetime), String(current.speed), String(current.wind), String(current.gravity), String(current.size), String(current.seed)]
        let fields = values.map { NSTextField(string: $0) }
        let sprite = NSPopUpButton()
        sprite.addItems(withTitles: ["Procedural Discs", "Choose Sprite Image…", "Keep Current Sprite"])
        sprite.item(at: 2)?.isEnabled = node.sprite != nil
        sprite.selectItem(at: node.sprite != nil ? 2 : 0)
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading
        for (index, name) in names.enumerated() {
            fields[index].setAccessibilityLabel(name)
            fields[index].widthAnchor.constraint(equalToConstant: 250).isActive = true
            stack.addArrangedSubview(NSTextField(labelWithString: name)); stack.addArrangedSubview(fields[index])
        }
        stack.addArrangedSubview(sprite)
        stack.frame = NSRect(x: 0, y: 0, width: 270, height: 385)
        dialog.accessoryView = stack
        dialog.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, self.editor.selectedNode?.id == node.id,
                  !self.saving, self.editor.selectedNode?.locked == false else { return }
            guard let count = Int(fields[0].stringValue), let lifetime = Double(fields[1].stringValue),
                  let speed = Double(fields[2].stringValue), let wind = Double(fields[3].stringValue),
                  let gravity = Double(fields[4].stringValue), let size = Double(fields[5].stringValue),
                  let seed = Int(fields[6].stringValue) else {
                self.detailLabel.stringValue = "Enter numeric emitter values; count and seed must be integers."; return
            }
            let emitter = SceneNode.Emitter(count: count, lifetime: lifetime, speed: speed, wind: wind, gravity: gravity, size: size, seed: seed)
            do { try emitter.validate() } catch { self.detailLabel.stringValue = error.localizedDescription; return }
            node.content = .particles(emitter)
            if sprite.indexOfSelectedItem == 1 { self.chooseLayerImage(node, sprite: true) }
            else {
                if sprite.indexOfSelectedItem == 0 { node.sprite = nil }
                self.editor.replaceSelected(node, name: "Change Emitter")
            }
        }
    }
    @objc private func showRippleSample() {
        guard mayDiscard() else { return }
        showSample()
        var node = SceneNode(name: "Ripple", content: .gradient)
        node.style.effects = [.init(type: .displacement, amount: 0.04)]
        let target = ScenePropertyAddress(nodeID: node.id, property: .effectAmount, effectID: node.style.effects[0].id)
        let sample = SceneDescriptor(title: "Ripple", nodes: [node], parameters: [
            "strength": .init(name: "Ripple Strength", value: 0.04, min: 0, max: 0.1)
        ], bindings: [.init(target: target, parameter: "strength")])
        _ = applyEdit(sample.nodes, selected: 0, name: "Create Ripple", controls: sample)
    }
    @objc private func showParticleSample() {
        guard mayDiscard() else { return }
        showSample()
        let particles = SceneNode(name: "Fireflies", content: .particles(.init()))
        let background = SceneNode(name: "Night", content: .gradient, opacity: 0.25)
        let sample = SceneDescriptor(title: "Fireflies", nodes: [background, particles], timeline: .init(duration: 6, mode: .loop))
        _ = applyEdit(sample.nodes, selected: 1, name: "Create Fireflies", controls: sample)
    }
    @objc private func createMenu() {
        let menu = NSMenu()
        for (title, action) in [("Gradient", #selector(addGradient)), ("Text", #selector(addText)),
            ("Shape", #selector(addShape)), ("Shader", #selector(addShader)),
            ("New Control…", #selector(addControl)), ("Local Presets…", #selector(presetBrowser)), ("My Presets…", #selector(globalPresets)), ("Scene Details…", #selector(editMetadata))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: addGradientButton.bounds.height), in: addGradientButton)
    }
    @objc private func globalPresets() {
        guard !saving else { return }
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("Idlesse/Studio Presets", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]).filter { $0.pathExtension == "idlesse" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let dialog = NSAlert(); dialog.messageText = "My Presets"
            dialog.addButton(withTitle: "Insert"); dialog.addButton(withTitle: "Cancel")
            dialog.addButton(withTitle: "Save Selection…"); dialog.addButton(withTitle: "Show in Finder")
            let picker = NSPopUpButton()
            picker.addItems(withTitles: entries.map { $0.deletingPathExtension().lastPathComponent })
            picker.frame.size = NSSize(width: 360, height: 28); dialog.accessoryView = picker
            dialog.buttons[0].isEnabled = !entries.isEmpty && (scene.components?.count ?? 0) < 8
            dialog.buttons[2].isEnabled = editor.selectedNode != nil
            dialog.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3 {
                    NSWorkspace.shared.open(root); return
                }
                if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 2 {
                    guard let node = self.editor.selectedNode else { return }
                    let panel = NSSavePanel(); panel.directoryURL = root
                    panel.allowedContentTypes = [.init(filenameExtension: "idlesse")!]
                    panel.nameFieldStringValue = node.displayName + ".idlesse"
                    panel.beginSheetModal(for: self.window) { [weak self] answer in
                        guard let self, answer == .OK, let destination = panel.url else { return }
                        do {
                            let captured = try SceneComponent.capture(node, from: self.scene).scene
                            self.saving = true; self.updateInspector()
                            Task { @MainActor [weak self] in
                                let scoped = destination.startAccessingSecurityScopedResource()
                                defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
                                do {
                                    try await Task.detached { try ScenePackageWriter.write(captured, to: destination) }.value
                                    self?.detailLabel.stringValue = "Preset saved"
                                } catch { self?.detailLabel.stringValue = error.localizedDescription }
                                self?.saving = false; self?.updateInspector()
                            }
                        } catch { self.detailLabel.stringValue = error.localizedDescription }
                    }
                    return
                }
                guard response == .alertFirstButtonReturn, entries.indices.contains(picker.indexOfSelectedItem) else { return }
                let url = entries[picker.indexOfSelectedItem]
                self.saving = true; self.updateInspector()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.saving = false; self.updateInspector() }
                    do {
                        let loaded = try await SceneDocument.read(url).scene
                        guard loaded.nodes.count == 1 else { throw SceneError.invalid("A preset needs one root layer or group.") }
                        let component = try SceneComponent.capture(loaded.nodes[0], from: loaded)
                        let id = UUID().uuidString
                        var next = self.scene
                        if next.components == nil { next.components = [:] }
                        next.components?[id] = component
                        next = try component.inserting(into: next, id: id)
                        let selected = next.allNodes.firstIndex { $0.id == next.nodes.last!.id } ?? 0
                        self.saving = false
                        _ = self.applyEdit(next.nodes, selected: selected, name: "Insert Shared Preset", controls: next)
                    } catch { self.detailLabel.stringValue = error.localizedDescription }
                }
            }
        } catch { detailLabel.stringValue = error.localizedDescription }
    }

    @objc private func presetBrowser() {
        guard !saving else { return }
        let dialog = NSAlert(); dialog.messageText = "Local Presets"
        dialog.informativeText = "Presets insert as independent copies."
        dialog.addButton(withTitle: "Insert"); dialog.addButton(withTitle: "Cancel")
        dialog.addButton(withTitle: "Capture Selection"); dialog.addButton(withTitle: "Detach Selection")
        let entries = (scene.components ?? [:]).sorted { $0.value.name.localizedStandardCompare($1.value.name) == .orderedAscending }
        let picker = NSPopUpButton()
        picker.addItems(withTitles: entries.map { "\($0.value.name) · \($0.value.node.descendants.count) layers · \($0.value.parameters.count) controls" })
        picker.frame.size = NSSize(width: 380, height: 28)
        dialog.accessoryView = picker
        dialog.buttons[0].isEnabled = !entries.isEmpty
        dialog.buttons[2].isEnabled = editor.selectedNode != nil && entries.count < 8
        dialog.buttons[3].isEnabled = editor.selectedNode?.componentID != nil
        dialog.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            do {
                var next = self.scene
                var selection = self.editor.selection
                let action: String
                if response == .alertFirstButtonReturn, entries.indices.contains(picker.indexOfSelectedItem) {
                    let entry = entries[picker.indexOfSelectedItem]
                    next = try entry.value.inserting(into: next, id: entry.key)
                    selection = next.allNodes.firstIndex { $0.id == next.nodes.last!.id } ?? 0
                    action = "Insert Preset"
                } else if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 2, let node = self.editor.selectedNode {
                    let component = try SceneComponent.capture(node, from: next)
                    let id = UUID().uuidString
                    if next.components == nil { next.components = [:] }
                    next.components?[id] = component
                    var nodes = next.nodes
                    _ = SceneTree.edit(node.id, in: &nodes) { siblings, index in siblings[index].componentID = id }
                    next = next.replacingNodes(nodes); action = "Capture Preset"
                } else if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3, let node = self.editor.selectedNode {
                    var nodes = next.nodes
                    _ = SceneTree.edit(node.id, in: &nodes) { siblings, index in siblings[index].componentID = nil }
                    next = next.replacingNodes(nodes); action = "Detach Preset"
                } else { return }
                _ = try next.evaluated()
                _ = self.applyEdit(next.nodes, selected: selection, name: action, controls: next)
            } catch { self.detailLabel.stringValue = error.localizedDescription }
        }
    }
    @objc private func addText() {
        guard !saving else { return }
        if editor.add(SceneNode(content: .text(.init()), transform: .init(x: 0, y: 0, scale: 0.6, rotation: 0))) { layerInspector.revealContent() }
    }
    @objc private func addShape() {
        guard !saving else { return }
        if editor.add(SceneNode(content: .shape(.init()), transform: .init(x: 0, y: 0, scale: 0.4, rotation: 0))) { layerInspector.revealContent() }
    }
    @objc private func editGraphic() {
        guard !saving, let original = editor.selectedNode, !original.locked,
              original.typography != nil || original.shape != nil else { return }
        let dialog = NSAlert()
        dialog.messageText = original.typography != nil ? "Text Layer" : "Shape Layer"
        dialog.informativeText = "Dimensions describe the layer’s own canvas. Use the canvas handles to place it in the scene."
        dialog.addButton(withTitle: "Apply"); dialog.addButton(withTitle: "Cancel")
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        let names: [String], values: [String]
        let picker = NSPopUpButton()
        let sourcePicker = NSPopUpButton()
        sourcePicker.addItems(withTitles: ["Static Text"] + SceneNode.Typography.LiveSource.allCases.map(\.title))
        if let source = original.typography?.liveSource,
           let index = SceneNode.Typography.LiveSource.allCases.firstIndex(of: source) { sourcePicker.selectItem(at: index + 1) }
        if original.typography != nil {
            stack.addArrangedSubview(NSTextField(labelWithString: "Content"))
            stack.addArrangedSubview(sourcePicker)
        }
        if let text = original.typography {
            names = ["Text", "Font name", "Font size", "Fill (#RRGGBB or #RRGGBBAA)", "Line spacing", "Width", "Height"]
            values = [text.text, text.font, String(text.size), text.fill, String(text.lineSpacing), String(text.width), String(text.height)]
            picker.addItems(withTitles: ["Left", "Center", "Right"])
            picker.selectItem(at: text.alignment == .left ? 0 : text.alignment == .center ? 1 : 2)
        } else {
            let shape = original.shape!
            names = ["Fill (#RRGGBB or #RRGGBBAA)", "Width", "Height", "Corner radius", "Line width"]
            values = [shape.fill, String(shape.width), String(shape.height), String(shape.cornerRadius), String(shape.lineWidth)]
            picker.addItems(withTitles: ["Rectangle", "Ellipse", "Line", "Rounded Rectangle"])
            picker.selectItem(at: [SceneNode.Shape.Primitive.rectangle, .ellipse, .line, .roundedRectangle].firstIndex(of: shape.primitive)!)
        }
        let fields = values.map { NSTextField(string: $0) }
        let textEditor = NSTextView()
        textEditor.isRichText = false
        textEditor.isAutomaticQuoteSubstitutionEnabled = false
        textEditor.isAutomaticDashSubstitutionEnabled = false
        textEditor.font = .systemFont(ofSize: 14)
        textEditor.textContainerInset = NSSize(width: 6, height: 6)
        textEditor.string = original.typography?.text ?? ""
        let fillIndex = original.typography != nil ? 3 : 0
        let fill = NSColorWell()
        let hex = String(values[fillIndex].dropFirst())
        let rgba = UInt64(hex, radix: 16) ?? 0
        let rgb = hex.count == 8 ? rgba >> 8 : rgba
        fill.color = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255,
            alpha: hex.count == 8 ? CGFloat(rgba & 255) / 255 : 1)
        for (index, pair) in zip(names, fields).enumerated() {
            let (name, field) = pair
            stack.addArrangedSubview(NSTextField(labelWithString: index == fillIndex ? "Fill color" : name))
            if original.typography != nil && index == 0 {
                let scroll = NSScrollView()
                scroll.borderType = .bezelBorder
                scroll.hasVerticalScroller = true
                scroll.documentView = textEditor
                textEditor.isVerticallyResizable = true
                textEditor.isHorizontallyResizable = false
                textEditor.autoresizingMask = [.width]
                textEditor.textContainer?.widthTracksTextView = true
                textEditor.frame = NSRect(x: 0, y: 0, width: 340, height: 90)
                stack.addArrangedSubview(scroll)
                scroll.widthAnchor.constraint(equalToConstant: 340).isActive = true
                scroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
            } else if index == fillIndex {
                stack.addArrangedSubview(fill)
            } else {
                stack.addArrangedSubview(field)
                field.widthAnchor.constraint(equalToConstant: 340).isActive = true
            }
        }
        stack.addArrangedSubview(NSTextField(labelWithString: original.typography != nil ? "Alignment" : "Shape"))
        stack.addArrangedSubview(picker)
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: original.typography != nil ? 490 : 350)
        dialog.accessoryView = stack
        dialog.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, self.editor.selectedNode?.id == original.id else { return }
            var node = original
            guard let color = fill.color.usingColorSpace(.sRGB) else { return }
            func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
            fields[fillIndex].stringValue = String(format: "#%02X%02X%02X%02X",
                byte(color.redComponent), byte(color.greenComponent), byte(color.blueComponent), byte(color.alphaComponent))
            if var text = node.typography {
                fields[0].stringValue = textEditor.string
                text.liveSource = sourcePicker.indexOfSelectedItem == 0 ? nil : SceneNode.Typography.LiveSource.allCases[sourcePicker.indexOfSelectedItem - 1]
                text.text = fields[0].stringValue; text.font = fields[1].stringValue
                text.size = Double(fields[2].stringValue) ?? .nan; text.fill = fields[3].stringValue
                text.lineSpacing = Double(fields[4].stringValue) ?? .nan
                text.width = Int(fields[5].stringValue) ?? 0; text.height = Int(fields[6].stringValue) ?? 0
                text.alignment = [SceneNode.Typography.Alignment.left, .center, .right][picker.indexOfSelectedItem]
                node.content = .text(text)
            } else {
                var shape = node.shape!
                shape.fill = fields[0].stringValue; shape.width = Int(fields[1].stringValue) ?? 0; shape.height = Int(fields[2].stringValue) ?? 0
                shape.cornerRadius = Double(fields[3].stringValue) ?? .nan; shape.lineWidth = Double(fields[4].stringValue) ?? .nan
                shape.primitive = [SceneNode.Shape.Primitive.rectangle, .ellipse, .line, .roundedRectangle][picker.indexOfSelectedItem]
                node.content = .shape(shape)
            }
            do { try SceneBudget.validate([node]); self.editor.replaceSelected(node, name: "Edit Content") }
            catch { self.detailLabel.stringValue = error.localizedDescription }
        }
    }
    @objc private func addControl() {
        guard !saving, scene.parameters.count < 16 else { return }
        SceneParameterControls.create(window: window, node: editor.selectedNode) { [weak self] parameter in
            guard let self else { return }
            var next = self.scene
            next.parameters[UUID().uuidString] = parameter
            _ = self.applyEdit(next.nodes, selected: self.nodePicker.indexOfSelectedItem, name: "Add Control", controls: next)
        }
    }
    @objc private func editMetadata() {
        guard !saving else { return }
        let current = scene.metadata ?? SceneMetadata()
        let dialog = NSAlert(); dialog.messageText = "Scene Details"
        dialog.addButton(withTitle: "Apply"); dialog.addButton(withTitle: "Cancel")
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        let fields = [current.author ?? "", current.description ?? "", (current.tags ?? []).joined(separator: ", "),
            current.license ?? "", String(current.previewTime ?? 2)].map { NSTextField(string: $0) }
        for (name, field) in zip(["Author", "Description", "Tags (comma separated)", "License / attribution", "Poster time (seconds)"], fields) {
            stack.addArrangedSubview(NSTextField(labelWithString: name)); stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        }
        dialog.accessoryView = stack
        dialog.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let metadata = SceneMetadata(author: fields[0].stringValue, description: fields[1].stringValue,
                tags: fields[2].stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                license: fields[3].stringValue, createdWith: "Idlesse", previewTime: Double(fields[4].stringValue) ?? .nan)
            do {
                try metadata.validate()
                var next = self.scene; next.metadata = metadata
                _ = self.applyEdit(next.nodes, selected: self.nodePicker.indexOfSelectedItem, name: "Edit Scene Details", controls: next)
            } catch { self.detailLabel.stringValue = error.localizedDescription }
        }
    }
    @objc private func addGradient() {
        guard scene.allNodes.count < SceneBudget.maxNodes else { return }
        _ = editor.add(SceneNode(name: "Gradient \(scene.allNodes.count + 1)", content: .gradient, transform: .init(x: 0, y: 0, scale: 0.6, rotation: 0)))
    }
    @objc private func addShader() {
        guard scene.allNodes.count < SceneBudget.maxNodes,
              scene.allNodes.filter({ $0.kind == .shader }).count < SceneBudget.maxShaders else { return }
        if editor.add(SceneNode(name: "Waves", content: .shader(.init()), transform: .init(x: 0, y: 0, scale: 1, rotation: 0))) {
            layerInspector.revealContent()
        }
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
        try? clock.configure(timeline: scene.timeline)
        renderer?.refreshSceneTime()
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
        let discarded = !resetting || restoreSavedScene()
        if discarded { document.clearRecovery() }
        return discarded
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
    @objc private func exportVideo() {
        guard !saving else { return }
        commitFieldEdits()
        let options = NSAlert()
        options.messageText = "Export Video"
        options.informativeText = "Silent HEVC movie of the whole scene. Pointer and live audio responses are off. Authored looping is preserved; exporting does not make non-looping source media seamless."
        options.addButton(withTitle: "Continue…"); options.addButton(withTitle: "Cancel")
        let resolution = NSPopUpButton()
        resolution.addItems(withTitles: ["1080p · 1920 × 1080", "4K · 3840 × 2160"])
        let rate = NSPopUpButton(); rate.addItems(withTitles: ["30 fps", "60 fps"])
        let duration = NSTextField(string: String(min(60, scene.timeline?.duration ?? 8)))
        duration.setAccessibilityLabel("Export duration in seconds")
        let fields = NSStackView(views: [resolution, rate, NSTextField(labelWithString: "Duration (0.1–60 seconds)"), duration])
        fields.orientation = .vertical; fields.alignment = .leading
        fields.frame = CGRect(x: 0, y: 0, width: 310, height: 120)
        options.accessoryView = fields
        options.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard let seconds = Double(duration.stringValue), seconds.isFinite, (0.1...60).contains(seconds) else {
                self.detailLabel.stringValue = "Use a duration of 0.1–60 seconds."; return
            }
            let width = resolution.indexOfSelectedItem == 1 ? 3840 : 1920
            let fps = rate.indexOfSelectedItem == 1 ? 60 : 30
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = self.scene.title + ".mp4"
            panel.beginSheetModal(for: self.window) { [weak self] response in
                guard let self, response == .OK, let url = panel.url else { return }
                self.beginExport(to: url, width: width, fps: fps, duration: seconds)
            }
        }
    }

    private func beginExport(to url: URL, width: Int, fps: Int, duration: Double) {
        let snapshot = scene
        saving = true; watcher = nil
        let wasPaused = paused
        paused = true; updatePlayback(); updateInspector()
        let progress = NSProgressIndicator()
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        progress.frame = CGRect(x: 0, y: 0, width: 320, height: 16)
        let sheet = NSAlert()
        sheet.messageText = "Exporting Video"
        sheet.informativeText = "Rendering frames…"
        sheet.accessoryView = progress
        sheet.addButton(withTitle: "Cancel")
        sheet.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.exportTask?.cancel() }
        }
        exportTask = Task { @MainActor [self] in
            let access = url.startAccessingSecurityScopedResource()
            defer {
                if access { url.stopAccessingSecurityScopedResource() }
                if sheet.window.sheetParent != nil { window.endSheet(sheet.window, returnCode: .abort) }
                saving = false; paused = wasPaused; exportTask = nil
                updatePlayback(); updateInspector(); watchPackage()
            }
            do {
                try await SceneVideoExporter.export(snapshot, to: url, width: width, height: width * 9 / 16,
                    fps: fps, duration: duration) { value in progress.doubleValue = value }
                detailLabel.stringValue = "Exported " + url.lastPathComponent
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch is CancellationError {
                detailLabel.stringValue = "Video export cancelled."
            } catch { detailLabel.stringValue = error.localizedDescription }
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
        let stopped = paused || asleep || displayAsleep || sessionInactive || ProcessInfo.processInfo.isLowPowerModeEnabled || !window.isVisible || window.isMiniaturized || NSApp.isHidden
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
    private func updateTimeline() {
        timeline.update(scene: scene, selectedID: editor.selectedNode?.id, selectedTarget: selectedMotionTarget,
                        time: clock.time, enabled: renderer is MetalSceneRenderer)
    }
    private func updatePerformance() {
        let levels = clock.audioLevels()
        audioStatus.stringValue = !clock.audioEnabled ? "Audio response off" : clock.isPaused ? "Audio capture paused" :
            String(format: "Level %.1f%% · Bass %.1f%%\nMid %.1f%% · Treble %.1f%%", levels.level * 100, levels.bass * 100, levels.mid * 100, levels.treble * 100)
        updateTimeline()
        performanceLabel.stringValue = host.performanceText()
        measureButton.isEnabled = measurement == nil && renderer?.diagnostics.state == .running && renderer?.diagnostics.animated == true && renderer?.gpuTotals != nil
        if measurementResult != nil { measureButton.title = "Measure Again" }
        if !hudOverlay.isHidden {
            var lines: [String] = []
            lines.append("Renderer: \(renderer is MetalSceneRenderer ? "Metal (GPU)" : "Native / AVPlayer")")
            lines.append("Status: \(renderer?.diagnostics.state == .running ? "Running" : "Paused")")
            lines.append("Rate: \(host.performanceText())")
            if let gpu = renderer?.gpuTotals, gpu.frames > 0 {
                let msPerFrame = (gpu.seconds * 1000.0) / Double(gpu.frames)
                lines.append(String(format: "GPU: %.2f ms/frame (%d frames)", msPerFrame, gpu.frames))
            }
            lines.append("Nodes: \(scene.nodes.count)")
            lines.append("Canvas: \(Int(canvas.bounds.width)) × \(Int(canvas.bounds.height))")
            hudOverlay.update(text: lines.joined(separator: "\n"))
        }
    }
    @objc private func toggleHUD() {
        let visible = hudButton.state == .on
        hudOverlay.isHidden = !visible
        UserDefaults.standard.set(visible, forKey: "Idlesse.studio.showHUD")
        if visible {
            updatePerformance()
        }
    }
    @objc private func togglePause() { paused.toggle(); updatePlayback() }
    @objc private func editAuthoredPlayback() {
        guard !saving else { return }
        let dialog = NSAlert()
        dialog.messageText = "Scene Playback"
        dialog.informativeText = "Saved with the scene and used on the desktop. Video following supports Once and Loop with approximate synchronization. Time… temporarily overrides playback in Studio."
        dialog.addButton(withTitle: "Apply")
        dialog.addButton(withTitle: "Cancel")
        dialog.addButton(withTitle: "Remove")
        let follow = NSButton(checkboxWithTitle: "Videos follow scene time (experimental)", target: nil, action: nil)
        follow.state = scene.timeline?.videosFollowScene == true ? .on : .off
        let duration = NSTextField(string: String(scene.timeline?.duration ?? 8))
        let rate = NSTextField(string: String(scene.timeline?.rate ?? 1))
        let canvasMode = NSPopUpButton()
        canvasMode.addItems(withTitles: ["Per Display", "Span Desktop"])
        canvasMode.selectItem(at: scene.canvas == .desktopSpan ? 1 : 0)
        canvasMode.setAccessibilityLabel("Scene canvas")
        let mode = NSPopUpButton()
        mode.addItems(withTitles: ["Once", "Loop", "Ping-pong"])
        let modes: [SceneTimeline.Mode] = [.once, .loop, .pingPong]
        mode.selectItem(at: modes.firstIndex(of: scene.timeline?.mode ?? .loop) ?? 1)
        duration.setAccessibilityLabel("Scene duration in seconds")
        rate.setAccessibilityLabel("Authored playback speed")
        mode.setAccessibilityLabel("Authored playback mode")
        let fields = NSStackView(views: [NSTextField(labelWithString: "Duration (seconds)"), duration,
            NSTextField(labelWithString: "Speed (0.1–4×)"), rate, mode, follow, canvasMode])
        fields.orientation = .vertical; fields.alignment = .leading
        fields.frame = NSRect(x: 0, y: 0, width: 340, height: 225)
        dialog.accessoryView = fields
        dialog.beginSheetModal(for: window) { [weak self] response in
            guard let self, response != .alertSecondButtonReturn else { return }
            do {
                var next = self.scene
                if response == .alertThirdButtonReturn { next.timeline = nil }
                else {
                    guard let seconds = Double(duration.stringValue), let speed = Double(rate.stringValue) else {
                        throw SceneError.invalid("Enter numeric duration and speed values.")
                    }
                    next.timeline = SceneTimeline(duration: seconds, mode: modes[mode.indexOfSelectedItem], rate: speed, videosFollowScene: follow.state == .on)
                    try next.timeline?.validate()
                }
                next.canvas = canvasMode.indexOfSelectedItem == 1 ? .desktopSpan : nil
                guard next.timeline != self.scene.timeline || next.canvas != self.scene.canvas else { return }
                _ = self.applyEdit(next.nodes, selected: self.nodePicker.indexOfSelectedItem, name: "Change Playback", controls: next)
            } catch { self.detailLabel.stringValue = error.localizedDescription }
        }
    }
    @objc private func editTransport() {
        guard renderer is MetalSceneRenderer else {
            detailLabel.stringValue = "Select Metal to use scene transport."; return
        }
        let dialog = NSAlert()
        dialog.messageText = "Scene Time"
        dialog.informativeText = "Controls scene motion and videos opted into scene playback. Other videos stay independent. These preview overrides are not saved. Apply also redraws a paused scene."
        dialog.addButton(withTitle: "Apply"); dialog.addButton(withTitle: "Cancel")
        let position = NSTextField(string: String(format: "%.3f", clock.time))
        let rate = NSTextField(string: String(format: "%.2f", clock.playbackRate))
        let loop = NSButton(checkboxWithTitle: "Loop scene time", target: nil, action: nil)
        loop.state = clock.loopRange == nil ? .off : .on
        let start = NSTextField(string: String(clock.loopRange?.lowerBound ?? 0))
        let end = NSTextField(string: String(clock.loopRange?.upperBound ?? 8))
        position.setAccessibilityLabel("Scene time in seconds")
        rate.setAccessibilityLabel("Scene playback rate")
        start.setAccessibilityLabel("Loop start"); end.setAccessibilityLabel("Loop end")
        let fields = NSStackView(views: [NSTextField(labelWithString: "Time (seconds)"), position,
            NSTextField(labelWithString: "Speed (0.1–4×)"), rate, loop,
            NSTextField(labelWithString: "Loop start / end (seconds)"), start, end])
        fields.orientation = .vertical; fields.alignment = .leading
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 250)
        position.widthAnchor.constraint(equalToConstant: 280).isActive = true
        dialog.accessoryView = fields
        dialog.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                guard let time = Double(position.stringValue), let speed = Double(rate.stringValue) else {
                    throw SceneError.invalid("Enter numeric time and speed values.")
                }
                var range: Range<Double>?
                if loop.state == .on {
                    guard let lower = Double(start.stringValue), let upper = Double(end.stringValue),
                          lower.isFinite, upper.isFinite, lower < upper else {
                        throw SceneError.invalid("Loop end must be greater than loop start.")
                    }
                    range = lower..<upper
                }
                try self.clock.configure(time: time, rate: speed, loop: range)
                self.renderer?.refreshSceneTime()
                self.updateTimeline()
                self.detailLabel.stringValue = "Scene transport updated. Video following is configured in Playback…."
            } catch { self.detailLabel.stringValue = error.localizedDescription }
        }
    }
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
    @objc private func showAudioSample() {
        guard mayDiscard() else { return }
        showSample()
        var node = SceneNode(name: "Audio Glow", content: .gradient)
        node.style.effects = [.init(type: .exposure, amount: 0.8), .init(type: .bloom, amount: 0.9)]
        let audio = SceneDescriptor(title: "Audio Aurora", nodes: [node], parameters: ["gain": .init(name: "Audio Sensitivity", value: 1, min: 0.1, max: 4)], bindings: [
            .init(target: .init(nodeID: node.id, property: .effectAmount, effectID: node.style.effects[1].id), scale: 20, signal: .audioBass,
                  modifiers: [.init(operation: .multiply, parameter: "gain"), .init(operation: .add, value: 0.3)], smoothing: 0.08),
            .init(target: .init(nodeID: node.id, property: .vignette), scale: -2, signal: .audioLevel,
                  modifiers: [.init(operation: .multiply, parameter: "gain"), .init(operation: .add, value: 0.7)], smoothing: 0.08)
        ])
        _ = applyEdit(audio.nodes, selected: 0, name: "Create Audio Scene", controls: audio)
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
        try? clock.configure(timeline: nil)
        rebuild()
    }
    @objc private func choose() {
        guard mayDiscard() else { return }
        let panel = NSOpenPanel()
        panel.title = "Open in Studio"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.directory, .jpeg, .png, .heic, .mpeg4Movie, .quickTimeMovie,
            UTType(exportedAs: "com.teamleaderleo.idlesse.scene", conformingTo: .package)]
        panel.treatsFilePackagesAsDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.load(url)
        }
    }
    private func cancelLoading() { generation += 1; loadTask?.cancel(); loadTask = nil }
    func openLibraryScene(_ url: URL, asCopy: Bool) {
        show()
        guard mayDiscard() else { return }
        load(url, asCopy: asCopy)
    }
    private func load(_ url: URL, asCopy: Bool = false) {
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
                let previousPointer = self.clock.pointerEnabled
                let previousAudio = self.clock.audioEnabled
                if self.selectedURL != url { self.clock.pointerEnabled = false; self.clock.audioEnabled = false }
                self.scene = next
                self.rebuild()
                guard self.renderer !== previousRenderer else { self.scene = previous; self.clock.pointerEnabled = previousPointer; self.clock.audioEnabled = previousAudio; return }
                if self.selectedURL != url || previous.timeline != next.timeline {
                    try self.clock.configure(timeline: next.timeline)
                    self.renderer?.refreshSceneTime()
                }
                self.pointerToggle.state = self.clock.pointerEnabled ? .on : .off
                self.releaseImportedScopes()
                self.scopedURL?.stopAccessingSecurityScopedResource()
                self.scopedURL = accessed ? url : nil
                adopted = true
                self.draft = asCopy
                self.clearEditHistory()
                self.savedScene = nil
                self.updateInspector()
                self.selectedURL = asCopy ? nil : url
                self.document.revision = asCopy ? nil : contents.revision
                self.updateInspector()
                self.window.representedURL = !asCopy && url.pathExtension.lowercased() == "idlesse" ? url : nil
                self.applyButton.isEnabled = !asCopy
                if asCopy { self.document.scheduleRecovery() }
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
        watcher = SceneWatcher(package: url, assets: scene.assetNodes.flatMap { $0.assets }) { [weak self] in
            self?.load(url)
        }
    }
    func windowDidEndLiveResize(_ notification: Notification) { fitCanvas() }
    func windowDidChangeBackingProperties(_ notification: Notification) { rebuild() }
    func windowDidMiniaturize(_ notification: Notification) { updatePlayback() }
    func windowDidDeminiaturize(_ notification: Notification) { updatePlayback() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { mayDiscard() }
    func windowWillClose(_ notification: Notification) {
        exportTask?.cancel()
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
