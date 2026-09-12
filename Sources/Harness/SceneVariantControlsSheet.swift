import AppKit

/// Variant authoring stays inside the existing Scene Controls experience. All edits
/// are staged until Apply, while renderer previews are delivered continuously.
final class SceneVariantControlsSheet: NSObject {
    typealias Preview = (SceneDescriptor, UUID?) -> Bool
    typealias Completion = (SceneDescriptor, UUID?) -> Void

    private var state: SceneVariantAuthoringState
    private let window: NSWindow
    private let preview: Preview
    private let completion: Completion
    private let cancel: () -> Void

    private let alert = NSAlert()
    private let selector = NSPopUpButton()
    private let nameField = NSTextField()
    private let addButton = NSButton(title: "+", target: nil, action: nil)
    private let duplicateButton = NSButton(title: "Duplicate", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private var controls: SceneParameterControls?

    init(scene: SceneDescriptor, selectedID: UUID?, window: NSWindow, preview: @escaping Preview,
         completion: @escaping Completion, cancel: @escaping () -> Void) {
        state = SceneVariantAuthoringState(scene: scene, selectedID: selectedID)
        self.window = window
        self.preview = preview
        self.completion = completion
        self.cancel = cancel
        super.init()
    }

    func present() {
        alert.messageText = "Scene Controls"
        alert.informativeText = "Default edits the scene defaults. Named variants store only the control values that differ."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].isEnabled = !state.scene.parameters.isEmpty || !state.scene.variants.isEmpty

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 410))
        let variantLabel = NSTextField(labelWithString: "Variant")
        variantLabel.frame = NSRect(x: 0, y: 376, width: 52, height: 20)
        root.addSubview(variantLabel)
        selector.frame = NSRect(x: 58, y: 372, width: 180, height: 26)
        selector.target = self; selector.action = #selector(selectVariant)
        root.addSubview(selector)
        addButton.frame = NSRect(x: 246, y: 372, width: 34, height: 26)
        addButton.target = self; addButton.action = #selector(addVariant)
        addButton.toolTip = "New Variant from Current Values"
        root.addSubview(addButton)
        duplicateButton.frame = NSRect(x: 284, y: 372, width: 96, height: 26)
        duplicateButton.target = self; duplicateButton.action = #selector(duplicateVariant)
        root.addSubview(duplicateButton)

        let nameLabel = NSTextField(labelWithString: "Name")
        nameLabel.frame = NSRect(x: 0, y: 340, width: 52, height: 20)
        root.addSubview(nameLabel)
        nameField.frame = NSRect(x: 58, y: 336, width: 218, height: 24)
        nameField.target = self; nameField.action = #selector(renameVariant)
        nameField.setAccessibilityLabel("Variant name")
        root.addSubview(nameField)
        deleteButton.frame = NSRect(x: 284, y: 336, width: 96, height: 26)
        deleteButton.target = self; deleteButton.action = #selector(deleteVariant)
        root.addSubview(deleteButton)

        scroll.frame = NSRect(x: 0, y: 30, width: 380, height: 298)
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        root.addSubview(scroll)
        status.frame = NSRect(x: 0, y: 2, width: 380, height: 20)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        root.addSubview(status)
        alert.accessoryView = root

        rebuildSelector()
        rebuildControls()
        _ = showPreview()

        // The completion block retains this controller for the sheet lifetime.
        alert.beginSheetModal(for: window) { [self] response in
            if response == .alertFirstButtonReturn {
                guard let values = controls?.currentValues() else {
                    cancel(); return
                }
                do {
                    try state.updateVisibleParameters(values)
                    let removed = state.normalizeStaleOverrides()
                    try SceneVariant.validate(state.scene.variants)
                    if !removed.isEmpty {
                        status.stringValue = "Removed \(removed.count) unavailable variant setting\(removed.count == 1 ? "" : "s")."
                    }
                    completion(state.scene, state.selectedID)
                } catch {
                    cancel()
                }
            } else {
                cancel()
            }
        }
    }

    private func rebuildSelector() {
        selector.removeAllItems()
        selector.addItem(withTitle: "Default")
        for variant in state.scene.variants { selector.addItem(withTitle: variant.name) }
        if let id = state.selectedID, let index = state.scene.variants.firstIndex(where: { $0.id == id }) {
            selector.selectItem(at: index + 1)
        } else {
            selector.selectItem(at: 0)
        }
        let selected = state.selectedVariant
        nameField.stringValue = selected?.name ?? "Default"
        nameField.isEnabled = selected != nil
        duplicateButton.isEnabled = state.scene.variants.count < SceneVariant.maximumCount
        addButton.isEnabled = !state.scene.parameters.isEmpty && state.scene.variants.count < SceneVariant.maximumCount
        deleteButton.isEnabled = selected != nil
    }

    private func rebuildControls() {
        let values = state.visibleParameters
        let origins: [String: SceneParameterControls.Origin] = Dictionary(uniqueKeysWithValues: values.keys.map { key in
            let origin = state.origin(for: key)
            switch origin {
            case .defaultValue: return (key, .defaultValue)
            case .inherited: return (key, .inherited)
            case .overridden: return (key, .overridden)
            }
        })
        let next = SceneParameterControls(parameters: values, origins: origins)
        next.onChange = { [weak self] values in
            guard let self else { return }
            do {
                try self.state.updateVisibleParameters(values)
                self.updateStatus()
                _ = self.showPreview()
            } catch { self.status.stringValue = error.localizedDescription }
        }
        next.onUseDefault = { [weak self] key in
            guard let self else { return }
            self.state.useDefault(key)
            self.rebuildControls()
            _ = self.showPreview()
        }
        controls = next
        scroll.documentView = next
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        updateStatus()
    }

    private func updateStatus(_ message: String? = nil) {
        if let message { status.stringValue = message; return }
        let unavailable = state.unavailableCount
        if unavailable > 0 {
            status.stringValue = "\(unavailable) setting\(unavailable == 1 ? "" : "s") unavailable · Apply repairs stale values"
        } else if let variant = state.selectedVariant {
            status.stringValue = "\(variant.values.count) override\(variant.values.count == 1 ? "" : "s") · inherited values follow Default"
        } else {
            status.stringValue = "Default · inherited by every named variant"
        }
    }

    @discardableResult private func showPreview() -> Bool {
        let ok = preview(state.scene, state.selectedID)
        if !ok { updateStatus("This preview could not update in place. Current playback was preserved.") }
        return ok
    }

    @objc private func selectVariant() {
        if selector.indexOfSelectedItem <= 0 { state.select(nil) }
        else { state.select(state.scene.variants[selector.indexOfSelectedItem - 1].id) }
        rebuildSelector()
        rebuildControls()
        _ = showPreview()
    }

    @objc private func addVariant() {
        do {
            _ = try state.create(name: nextVariantName())
            rebuildSelector(); rebuildControls(); _ = showPreview()
            window.makeFirstResponder(nameField)
            nameField.selectText(nil)
        } catch { updateStatus(error.localizedDescription) }
    }

    @objc private func renameVariant() {
        do {
            try state.renameSelected(nameField.stringValue)
            rebuildSelector(); updateStatus()
        } catch {
            nameField.stringValue = state.selectedVariant?.name ?? "Default"
            updateStatus(error.localizedDescription)
        }
    }

    @objc private func duplicateVariant() {
        do {
            _ = try state.duplicateSelected()
            rebuildSelector(); rebuildControls(); _ = showPreview()
        } catch { updateStatus(error.localizedDescription) }
    }

    @objc private func deleteVariant() {
        state.deleteSelected()
        rebuildSelector(); rebuildControls(); _ = showPreview()
    }

    private func nextVariantName() -> String {
        let existing = Set(state.scene.variants.map { $0.name.lowercased() })
        if !existing.contains("variant") { return "Variant" }
        for number in 2...SceneVariant.maximumCount where !existing.contains("variant \(number)") {
            return "Variant \(number)"
        }
        return "Variant \(state.scene.variants.count + 1)"
    }
}