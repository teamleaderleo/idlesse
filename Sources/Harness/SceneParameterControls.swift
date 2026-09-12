import AppKit

/// Generated controls shared by Studio and the desktop host. No media is copied.
final class SceneParameterControls: NSView, NSTextFieldDelegate {
    enum Origin { case defaultValue, inherited, overridden }

    private var sliders: [String: NSSlider] = [:]
    private var labels: [Int: NSTextField] = [:]
    private var typedControls: [String: NSControl] = [:]
    private let sourceParameters: [String: SceneParameter]
    var onChange: (([String: SceneParameter]) -> Void)?
    var onUseDefault: ((String) -> Void)?

    init(parameters: [String: SceneParameter], origins: [String: Origin]? = nil) {
        sourceParameters = parameters
        let keys = parameters.keys.sorted()
        let originHeight = origins == nil ? 0 : 24
        // Keep the pre-super layout calculation explicit: Swift's optimized
        // ownership pass crashes on the map/reduce expression in this initializer.
        var heights: [Int] = []
        var totalHeight = 0
        for key in keys {
            let height = (parameters[key]?.type == .string ? 112 : 64) + originHeight
            heights.append(height)
            totalHeight += height
        }
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: max(50, totalHeight)))
        var y = bounds.height
        for (index, key) in keys.enumerated() {
            let parameter = parameters[key]!
            y -= CGFloat(heights[index])
            let baseY = y + CGFloat(originHeight)
            let baseHeight = CGFloat(heights[index] - originHeight)
            let title = NSTextField(labelWithString: parameter.name)
            title.frame = NSRect(x: 0, y: baseY + baseHeight - 30, width: 250, height: 20)
            addSubview(title)
            if parameter.type != .number {
                let control: NSControl
                switch parameter.type {
                case .boolean:
                    let toggle = NSButton(checkboxWithTitle: parameter.name, target: nil, action: nil)
                    toggle.state = parameter.boolean ? .on : .off
                    control = toggle; title.isHidden = true
                case .choice:
                    let menu = NSPopUpButton()
                    menu.addItems(withTitles: parameter.choices); menu.selectItem(withTitle: parameter.text)
                    control = menu
                case .color:
                    let well = NSColorWell()
                    let hex = parameter.text.dropFirst()
                    let rgba = UInt64(hex, radix: 16) ?? 0
                    let alpha = hex.count == 8 ? CGFloat(rgba & 255) / 255 : 1
                    let rgb = hex.count == 8 ? rgba >> 8 : rgba
                    well.color = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                        green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: alpha)
                    control = well
                case .string:
                    let field = NSTextField(string: parameter.text)
                    field.usesSingleLineMode = false
                    field.cell?.wraps = true; field.cell?.isScrollable = false
                    field.delegate = self
                    control = field
                case .number: preconditionFailure()
                }
                control.frame = NSRect(x: 0, y: baseY + 4, width: 330, height: parameter.type == .string ? 72 : 26)
                control.setAccessibilityLabel(parameter.name)
                control.target = self
                control.action = #selector(typedChanged)
                addSubview(control); typedControls[key] = control
            } else {
                let value = NSTextField(labelWithString: String(format: "%.3f", parameter.value))
                value.frame = NSRect(x: 255, y: baseY + 34, width: 80, height: 20)
                addSubview(value); labels[index] = value
                let slider = NSSlider(value: parameter.value, minValue: parameter.min, maxValue: parameter.max,
                                      target: self, action: #selector(changed))
                slider.frame = NSRect(x: 0, y: baseY + 4, width: 330, height: 24)
                slider.tag = index; slider.isContinuous = true
                slider.setAccessibilityLabel(parameter.name)
                addSubview(slider); sliders[key] = slider
            }
            if let origin = origins?[key] {
                let status = NSTextField(labelWithString: origin == .defaultValue ? "Default" : origin == .inherited ? "Inherited" : "Override")
                status.textColor = origin == .overridden ? .controlAccentColor : .secondaryLabelColor
                status.font = .systemFont(ofSize: 11)
                status.frame = NSRect(x: 0, y: y + 2, width: 100, height: 18)
                addSubview(status)
                if origin == .overridden {
                    let useDefault = NSButton(title: "Use Default", target: self, action: #selector(useDefault(_:)))
                    useDefault.bezelStyle = .inline
                    useDefault.controlSize = .small
                    useDefault.identifier = NSUserInterfaceItemIdentifier(key)
                    useDefault.frame = NSRect(x: 235, y: y, width: 95, height: 22)
                    useDefault.setAccessibilityLabel("Use Default for \(parameter.name)")
                    addSubview(useDefault)
                }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func changed(_ sender: NSSlider) {
        labels[sender.tag]?.stringValue = String(format: "%.3f", sender.doubleValue)
        emitChange()
    }
    @objc private func typedChanged(_ sender: NSControl) { emitChange() }
    @objc private func useDefault(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        onUseDefault?(key)
    }
    func controlTextDidChange(_ obj: Notification) { emitChange() }

    /// Returns a validated snapshot of the values currently visible in the
    /// generated controls. Studio dialogs and Library inline controls share it.
    func currentValues() -> [String: SceneParameter]? {
        var values = sourceParameters
        for (id, slider) in sliders { values[id]?.value = slider.doubleValue }
        for (id, control) in typedControls {
            if let toggle = control as? NSButton { values[id]?.boolean = toggle.state == .on }
            if let menu = control as? NSPopUpButton { values[id]?.text = menu.titleOfSelectedItem ?? "" }
            if let field = control as? NSTextField { values[id]?.text = field.stringValue }
            if let well = control as? NSColorWell, let color = well.color.usingColorSpace(.sRGB) {
                values[id]?.text = String(format: "#%02X%02X%02X%02X", Int((color.redComponent * 255).rounded()),
                    Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()), Int((color.alphaComponent * 255).rounded()))
            }
        }
        return values.values.allSatisfy(\.isValid) ? values : nil
    }

    private func emitChange() {
        guard let values = currentValues() else { return }
        onChange?(values)
    }

    static func create(window: NSWindow, node: SceneNode?, completion: @escaping (SceneParameter) -> Void) {
        let dialog = NSAlert(); dialog.messageText = "New Scene Control"
        dialog.informativeText = "Numbers connect through Bind…. Other types can control the selected layer’s visibility, blend mode, text or fill."
        dialog.addButton(withTitle: "Create"); dialog.addButton(withTitle: "Cancel")
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        let type = NSPopUpButton(); type.addItems(withTitles: ["Number", "Toggle", "Color", "Choice", "Text"])
        stack.addArrangedSubview(type)
        let target = NSPopUpButton(); target.addItems(withTitles: ["Unconnected", "Selected layer: Visibility (toggle)", "Selected layer: Blend (choice)", "Selected layer: Text (text)", "Selected layer: Fill (color)"])
        target.isEnabled = node != nil; stack.addArrangedSubview(target)
        let fields = ["Control", "0.5", "0", "1", ""].map { NSTextField(string: $0) }
        for (name, field) in zip(["Name", "Default (toggle: true/false; color: #RRGGBB)", "Number minimum", "Number maximum", "Choice options (one per comma)"], fields) {
            stack.addArrangedSubview(NSTextField(labelWithString: name)); stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        }
        dialog.accessoryView = stack
        dialog.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = fields[0].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = fields[1].stringValue
            var parameter: SceneParameter
            switch type.indexOfSelectedItem {
            case 0: parameter = .init(name: name, value: Double(value) ?? .nan, min: Double(fields[2].stringValue) ?? .nan, max: Double(fields[3].stringValue) ?? .nan)
            case 1:
                guard ["true", "false"].contains(value.lowercased()) else { NSSound.beep(); return }
                parameter = .init(name: name, type: .boolean, boolean: value.lowercased() == "true")
            case 2: parameter = .init(name: name, type: .color, text: value)
            case 3: parameter = .init(name: name, type: .choice, text: value,
                choices: fields[4].stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            default: parameter = .init(name: name, type: .string, text: value)
            }
            guard !name.isEmpty, name.count <= 80, parameter.isValid else {
                let error = NSAlert(); error.messageText = "Invalid control"
                error.informativeText = "Check the default, limits and choice options. Nothing was added."
                error.beginSheetModal(for: window); return
            }
            if target.indexOfSelectedItem > 0, let node {
                let property = [SceneControlTarget.Property.visible, .blend, .text, .fill][target.indexOfSelectedItem - 1]
                parameter.targets = [.init(nodeID: node.id, property: property)]
                do { var nodes = [node]; try parameter.targets[0].apply(parameter, to: &nodes) }
                catch {
                    let alert = NSAlert(); alert.messageText = "Cannot connect this control"
                    alert.informativeText = error.localizedDescription; alert.beginSheetModal(for: window); return
                }
            }
            completion(parameter)
        }
    }
    static func present(scene: SceneDescriptor, window: NSWindow?, completion: @escaping ([String: SceneParameter]) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Scene Controls"
        alert.informativeText = scene.parameters.isEmpty ? "This scene has no controls yet. Select a layer and use Bind… to create one." : "Adjust the controls, then Apply. Studio saves these values as scene defaults; desktop changes last until the scene is reloaded."
        alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
        alert.buttons[0].isEnabled = !scene.parameters.isEmpty
        let controls = SceneParameterControls(parameters: scene.parameters)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: min(320, controls.bounds.height)))
        scroll.hasVerticalScroller = true; scroll.documentView = controls
        alert.accessoryView = scroll
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            guard let values = controls.currentValues() else {
                let error = NSAlert(); error.messageText = "Invalid control value"
                error.informativeText = "Text controls allow up to 4,096 UTF-8 bytes. Your scene has not changed."
                error.runModal(); return
            }
            completion(values)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { NSApp.activate(ignoringOtherApps: true); finish(alert.runModal()) }
    }
}