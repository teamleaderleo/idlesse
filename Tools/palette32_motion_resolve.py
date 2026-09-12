from pathlib import Path


def replace(path, old, new, count=1):
    p = Path(path)
    s = p.read_text()
    n = s.count(old)
    if n < count:
        raise SystemExit(f"{path}: expected {count}, found {n}: {old[:140]!r}")
    p.write_text(s.replace(old, new, count))


studio = "Sources/Harness/StudioWindowController.swift"

replace(studio, '''    private var renderer: SceneRenderer? { get { host.renderer } set { host.renderer = newValue } }
    private var scene: SceneDescriptor { get { document.scene } set { document.scene = newValue } }
    private var selectedURL: URL? { get { document.sourceURL } set { document.sourceURL = newValue } }
''', '''    private var renderer: SceneRenderer? { get { host.renderer } set { host.renderer = newValue } }
    private var scene: SceneDescriptor { get { document.scene } set { document.scene = newValue } }
    private var selectedVariantID: UUID?
    private var selectedURL: URL? { get { document.sourceURL } set { document.sourceURL = newValue } }
''')
replace(studio, '''    private let apply: (URL) -> Void
    var onClose: (() -> Void)?
''', '''    private let apply: (URL) -> Void
    var onApplyVariant: ((URL, UUID?) -> Void)?
    var onClose: (() -> Void)?
''')

replace(studio, '''            self.scene = target.scene
            let updated = self.renderer?.updateScene(target.scene) ?? false
            if !updated { self.rebuild() }
''', '''            self.scene = target.scene
            let restoreID = self.selectedVariantID.flatMap { id in target.scene.variants.contains(where: { $0.id == id }) ? id : nil }
            let effective = target.scene.applyingVariant(id: restoreID).scene
            let updated = self.renderer?.updateScene(effective) ?? false
            if !updated { self.rebuild() }
''')
replace(studio, '''            self.cancelLoading()
            self.watcher = nil
            self.updateInspector()
''', '''            self.cancelLoading()
            self.watcher = nil
            if let id = self.selectedVariantID, !target.scene.variants.contains(where: { $0.id == id }) { self.selectedVariantID = nil }
            self.updateInspector()
''', 1)

replace(studio, '''            next = try host.prepare(scene: scene, bounds: bounds, scale: window.backingScaleFactor,
                                    metal: engine.indexOfSelectedItem == 1, onError: onError)
''', '''            let effective = scene.applyingVariant(id: selectedVariantID).scene
            next = try host.prepare(scene: effective, bounds: bounds, scale: window.backingScaleFactor,
                                    metal: engine.indexOfSelectedItem == 1, onError: onError)
''')
replace(studio, '''    private func updateInspector() {
        if !scene.usesAudio { clock.audioEnabled = false }
''', '''    private func updateInspector() {
        if let id = selectedVariantID, !scene.variants.contains(where: { $0.id == id }) { selectedVariantID = nil }
        if !scene.usesAudio { clock.audioEnabled = false }
''')
replace(studio, '''        let signals = motionSignals()
        let previewNodes = (try? scene.evaluated(signals: signals).nodes) ?? scene.nodes
''', '''        let signals = motionSignals()
        let effectiveScene = scene.applyingVariant(id: selectedVariantID).scene
        let previewNodes = (try? effectiveScene.evaluated(signals: signals).nodes) ?? effectiveScene.nodes
''')
replace(studio, '''        layerInspector.update(scene: scene, node: node, saving: saving, time: clock.time,
                              signals: signals, autoKey: timeline.autoKeyEnabled)
''', '''        layerInspector.update(scene: effectiveScene, node: node, saving: saving, time: clock.time,
                              signals: signals, autoKey: timeline.autoKeyEnabled)
''')

replace(studio, '''            let next = try canvasMotionScene(transform, gesture: gesture, base: base)
            guard renderer?.updateScene(next) == true else { throw SceneError.invalid("Could not preview this motion edit.") }
            canvasMotionPreview = next
        } catch {
            if let valid = canvasMotionPreview ?? canvasMotionBase { _ = renderer?.updateScene(valid) }
''', '''            let next = try canvasMotionScene(transform, gesture: gesture, base: base)
            let effective = next.applyingVariant(id: selectedVariantID).scene
            guard renderer?.updateScene(effective) == true else { throw SceneError.invalid("Could not preview this motion edit.") }
            canvasMotionPreview = next
        } catch {
            if let valid = canvasMotionPreview ?? canvasMotionBase {
                _ = renderer?.updateScene(valid.applyingVariant(id: selectedVariantID).scene)
            }
''')
replace(studio, '''            _ = renderer?.updateScene(base)
            detailLabel.stringValue = error.localizedDescription
''', '''            _ = renderer?.updateScene(base.applyingVariant(id: selectedVariantID).scene)
            detailLabel.stringValue = error.localizedDescription
''', 1)
replace(studio, '''    private func cancelCanvasMotion() {
        if let base = canvasMotionBase { _ = renderer?.updateScene(base) }
''', '''    private func cancelCanvasMotion() {
        if let base = canvasMotionBase { _ = renderer?.updateScene(base.applyingVariant(id: selectedVariantID).scene) }
''')

replace(studio, '''        let previousRenderer = renderer
        scene = (controls ?? scene).replacingNodes(nodes)
        let updated = renderer?.updateScene(scene) ?? false
''', '''        let previousRenderer = renderer
        var authoring = SceneVariantAuthoringState(scene: (controls ?? scene).replacingNodes(nodes), selectedID: selectedVariantID)
        authoring.pruneRemovedControls()
        scene = authoring.scene
        let effective = scene.applyingVariant(id: selectedVariantID).scene
        let updated = renderer?.updateScene(effective) ?? false
''')

replace(studio, '''    @objc private func editControls() {
        guard !saving else { return }
        let original = scene.parameters
        SceneParameterControls.present(scene: scene, window: window) { [weak self] values in
            guard let self, self.scene.parameters == original, values != original else { return }
            var next = self.scene
            next.parameters = values
            _ = self.applyEdit(next.nodes, selected: self.editor.selection, name: "Change Controls", controls: next)
        }
    }
''', '''    @objc private func editControls() {
        guard !saving else { return }
        let originalVariantID = selectedVariantID
        let sheet = SceneVariantControlsSheet(scene: scene, selectedID: selectedVariantID, window: window,
            preview: { [weak self] draft, variantID in
                guard let self else { return false }
                return self.renderer?.updateScene(draft.applyingVariant(id: variantID).scene) ?? false
            }, completion: { [weak self] next, variantID in
                guard let self else { return }
                let changed = next.parameters != self.scene.parameters || next.variants != self.scene.variants
                let previousID = self.selectedVariantID
                self.selectedVariantID = variantID
                if changed {
                    if !self.applyEdit(next.nodes, selected: self.editor.selection, name: "Change Scene Variants", controls: next) {
                        self.selectedVariantID = previousID
                        _ = self.renderer?.updateScene(self.scene.applyingVariant(id: previousID).scene)
                    }
                } else {
                    _ = self.renderer?.updateScene(self.scene.applyingVariant(id: variantID).scene)
                    self.selectNode()
                }
            }, cancel: { [weak self] in
                guard let self else { return }
                _ = self.renderer?.updateScene(self.scene.applyingVariant(id: originalVariantID).scene)
                self.selectNode()
            })
        sheet.present()
    }
''')
replace(studio, '''        if renderer?.updateScene(scene) != true { rebuild() }
        updatePlayback()
    }
    @objc private func togglePointer() {
        clock.pointerEnabled = pointerToggle.state == .on
        if renderer?.updateScene(scene) != true { rebuild() }
''', '''        let effective = scene.applyingVariant(id: selectedVariantID).scene
        if renderer?.updateScene(effective) != true { rebuild() }
        updatePlayback()
    }
    @objc private func togglePointer() {
        clock.pointerEnabled = pointerToggle.state == .on
        let effective = scene.applyingVariant(id: selectedVariantID).scene
        if renderer?.updateScene(effective) != true { rebuild() }
''')

replace(studio, '''    @objc private func useOnDesktop() {
        guard !draft, !saving, let selectedURL else { return }
        window.close()
        apply(selectedURL)
    }
''', '''    @objc private func useOnDesktop() {
        guard !draft, !saving, let selectedURL else { return }
        window.close()
        if let onApplyVariant { onApplyVariant(selectedURL, selectedVariantID) }
        else { apply(selectedURL) }
    }
''')
replace(studio, '''        applyButton.isEnabled = false
        scene = SceneDescriptor(title: "Aurora", nodes: [SceneNode(content: .gradient)])
''', '''        applyButton.isEnabled = false
        selectedVariantID = nil
        scene = SceneDescriptor(title: "Aurora", nodes: [SceneNode(content: .gradient)])
''', 1)
replace(studio, '''    func openLibraryScene(_ url: URL, asCopy: Bool) {
        show()
        guard mayDiscard() else { return }
        load(url, asCopy: asCopy)
    }
    private func load(_ url: URL, asCopy: Bool = false) {
''', '''    func openLibraryScene(_ url: URL, asCopy: Bool, variantID: UUID? = nil) {
        show()
        guard mayDiscard() else { return }
        load(url, asCopy: asCopy, variantID: variantID)
    }
    private func load(_ url: URL, asCopy: Bool = false, variantID: UUID? = nil) {
''')
replace(studio, '''                let previous = self.scene
                let previousRenderer = self.renderer
''', '''                let previous = self.scene
                let previousVariantID = self.selectedVariantID
                let previousRenderer = self.renderer
''', 1)
replace(studio, '''                self.scene = next
                self.rebuild()
                guard self.renderer !== previousRenderer else { self.scene = previous; self.clock.pointerEnabled = previousPointer; self.clock.audioEnabled = previousAudio; return }
''', '''                self.scene = next
                let application = next.applyingVariant(id: variantID)
                self.selectedVariantID = application.selectedVariantID
                self.rebuild()
                guard self.renderer !== previousRenderer else {
                    self.scene = previous
                    self.selectedVariantID = previousVariantID
                    self.clock.pointerEnabled = previousPointer
                    self.clock.audioEnabled = previousAudio
                    return
                }
                if variantID != nil && application.selectedVariantID == nil {
                    self.detailLabel.stringValue = "Requested variant is unavailable - editing Default"
                }
''')
replace(studio, '''            self?.load(url)
''', '''            self?.load(url, variantID: self?.selectedVariantID)
''', 1)
replace(studio, '''        scene = savedScene
        rebuild()
''', '''        scene = savedScene
        if let id = selectedVariantID, !scene.variants.contains(where: { $0.id == id }) { selectedVariantID = nil }
        rebuild()
''', 1)
replace(studio, '''                self.saving = false
                self.load(url)
''', '''                self.saving = false
                self.load(url, variantID: self.selectedVariantID)
''', 1)
replace(studio, '''        let snapshot = scene
''', '''        let snapshot = scene.applyingVariant(id: selectedVariantID).scene
''', 1)

# Resolve test runner in favor of motion, then add Studio variant authoring coverage.
test = "test.sh"
p = Path(test)
s = p.read_text()
marker = '''# Await any parallel background compilations
'''
block = '''# 11. Studio variant authoring state. Foundation-only coverage keeps sparse-delta
# semantics independent from the AppKit sheet.
STUDIO_VARIANT_SRCS=(
  Sources/Runtime/Scene.swift
  Sources/Harness/SceneVariantAuthoring.swift
  Tests/StudioVariantTests.swift
)
if needs_build "build/tests/studio-variants" "${STUDIO_VARIANT_SRCS[@]}"; then
  xcrun swiftc "$OPT_FLAG" "${STUDIO_VARIANT_SRCS[@]}" -o build/tests/studio-variants &
  pids+=($!)
fi

'''
if "STUDIO_VARIANT_SRCS" not in s:
    if marker not in s: raise SystemExit("test.sh await marker missing")
    s = s.replace(marker, block + marker, 1)
    s = s.replace('''build/tests/studio-motion
''', '''build/tests/studio-motion
build/tests/studio-variants
''', 1)
p.write_text(s)
