from pathlib import Path


def replace(path, old, new, count=1):
    p = Path(path)
    s = p.read_text()
    n = s.count(old)
    if n < count:
        raise SystemExit(f"{path}: expected {count}, found {n}: {old[:120]!r}")
    p.write_text(s.replace(old, new, count))


studio = "Sources/Harness/StudioWindowController.swift"

replace(studio, '''        dragOverlay.onPreviewTransform = { [weak self] transform in
            guard let self, !self.saving else { return }
            var nodes = self.scene.nodes
            guard let id = self.editor.selectedNode?.id else { return }
            _ = SceneTree.edit(id, in: &nodes) { siblings, index in siblings[index].transform = transform }
            _ = self.renderer?.updateScene(self.scene.replacingNodes(nodes))
        }
''', '''        dragOverlay.onPreviewTransform = { [weak self] transform in
            guard let self, !self.saving else { return }
            var nodes = self.scene.nodes
            guard let id = self.editor.selectedNode?.id else { return }
            _ = SceneTree.edit(id, in: &nodes) { siblings, index in siblings[index].transform = transform }
            let preview = self.scene.replacingNodes(nodes).applyingVariant(id: self.selectedVariantID).scene
            _ = self.renderer?.updateScene(preview)
        }
''')

replace(studio, '''    private let apply: (URL) -> Void
    var onClose: (() -> Void)?
''', '''    private let apply: (URL) -> Void
    var onApplyVariant: ((URL, UUID?) -> Void)?
    var onClose: (() -> Void)?
''')

replace(studio, '''        var previewNodes = (try? scene.evaluated().nodes) ?? scene.nodes
''', '''        let effectiveScene = scene.applyingVariant(id: selectedVariantID).scene
        var previewNodes = (try? effectiveScene.evaluated().nodes) ?? effectiveScene.nodes
''', 1)

replace(studio, '''    @objc private func toggleAudio() {
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
''', '''    @objc private func toggleAudio() {
        guard scene.usesAudio, !saving else { return }
        clock.audioEnabled = audioToggle.state == .on
        let effective = scene.applyingVariant(id: selectedVariantID).scene
        if renderer?.updateScene(effective) != true { rebuild() }
        updatePlayback()
    }
    @objc private func togglePointer() {
        clock.pointerEnabled = pointerToggle.state == .on
        let effective = scene.applyingVariant(id: selectedVariantID).scene
        if renderer?.updateScene(effective) != true { rebuild() }
        updatePlayback()
    }
''')

replace(studio, '''                self.saving = false
                self.load(url)
''', '''                self.saving = false
                self.load(url, variantID: self.selectedVariantID)
''', 1)

replace(studio, '''        let snapshot = scene
''', '''        let snapshot = scene.applyingVariant(id: selectedVariantID).scene
''', 1)

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
                let previousPointer = self.clock.pointerEnabled
                let previousAudio = self.clock.audioEnabled
                if self.selectedURL != url { self.clock.pointerEnabled = false; self.clock.audioEnabled = false }
                self.scene = next
                self.rebuild()
                guard self.renderer !== previousRenderer else { self.scene = previous; self.clock.pointerEnabled = previousPointer; self.clock.audioEnabled = previousAudio; return }
''', '''                let previous = self.scene
                let previousVariantID = self.selectedVariantID
                let previousRenderer = self.renderer
                let previousPointer = self.clock.pointerEnabled
                let previousAudio = self.clock.audioEnabled
                if self.selectedURL != url { self.clock.pointerEnabled = false; self.clock.audioEnabled = false }
                self.scene = next
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

main = "Sources/Harness/main.swift"
replace(main, '''        library?.onUseVariant = { [weak self] url, variantID in
            self?.wallpaper.select(url, variantID: variantID, automatic: true)
        }
        library?.onPeek = { [weak self] url in self?.wallpaper.peek(url) }
''', '''        library?.onUseVariant = { [weak self] url, variantID in
            self?.wallpaper.select(url, variantID: variantID, automatic: true)
        }
        library?.onEditVariant = { [weak self] url, asCopy, variantID in
            guard let self else { return }
            self.scenePreview.onClose = { [weak self] in
                self?.library?.releaseActiveEditAccess()
                self?.showLibrary()
            }
            self.scenePreview.openLibraryScene(url, asCopy: asCopy, variantID: variantID)
        }
        library?.onPeek = { [weak self] url in self?.wallpaper.peek(url) }
''')

replace(main, '''    private lazy var scenePreview = StudioWindowController { [weak self] url in self?.wallpaper.select(url) }
''', '''    private lazy var scenePreview: StudioWindowController = {
        let controller = StudioWindowController { [weak self] url in self?.wallpaper.select(url) }
        controller.onApplyVariant = { [weak self] url, variantID in
            self?.wallpaper.select(url, variantID: variantID)
        }
        return controller
    }()
''')

tests = "Tests/StudioVariantTests.swift"
replace(tests, '''        // The 16-variant limit is enforced by the authoring layer as well as package validation.
''', '''        // A named look authored in Studio survives serialization/reopen with sparse values.
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
''')

docs = Path("docs/scene-variants.md")
text = docs.read_text()
if "## Studio authoring" not in text:
    docs.write_text(text + '''

## Studio authoring

Scene Controls contains a synthetic **Default** entry plus authored named variants. Creating, renaming, duplicating and deleting variants is staged inside the sheet; Apply records one document Undo step and Cancel restores the original in-place preview. Each control shows Default, Inherited or Override, and overridden controls expose **Use Default**. Named variants persist only values that differ from Default.

Studio keeps the selected variant as editor session state. Switching variants updates the current renderer in place, so scene time and playing media keep their phase. Library Edit carries the selected variant into Studio, and **Use on Desktop** carries it back to wallpaper selection.
''')
