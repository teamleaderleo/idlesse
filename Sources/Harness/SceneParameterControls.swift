import AppKit

/// Generated controls shared by Studio and the desktop host. No media is copied.
final class SceneParameterControls: NSView {
    private var sliders: [String: NSSlider] = [:]
    private var labels: [Int: NSTextField] = [:]
    init(parameters: [String: SceneParameter]) {
        let keys = parameters.keys.sorted()
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: max(50, keys.count * 64)))
        for (index, key) in keys.enumerated() {
            let parameter = parameters[key]!
            let y = bounds.height - CGFloat(index + 1) * 64
            let title = NSTextField(labelWithString: parameter.name)
            title.frame = NSRect(x: 0, y: y + 34, width: 250, height: 20)
            addSubview(title)
            let value = NSTextField(labelWithString: String(format: "%.3f", parameter.value))
            value.frame = NSRect(x: 255, y: y + 34, width: 80, height: 20)
            addSubview(value); labels[index] = value
            let slider = NSSlider(value: parameter.value, minValue: parameter.min, maxValue: parameter.max,
                                  target: self, action: #selector(changed))
            slider.frame = NSRect(x: 0, y: y + 4, width: 330, height: 24)
            slider.tag = index; slider.isContinuous = true
            slider.setAccessibilityLabel(parameter.name)
            addSubview(slider); sliders[key] = slider
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed(_ sender: NSSlider) { labels[sender.tag]?.stringValue = String(format: "%.3f", sender.doubleValue) }
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
            var values = scene.parameters
            for (id, slider) in controls.sliders { values[id]?.value = slider.doubleValue }
            completion(values)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { NSApp.activate(ignoringOtherApps: true); finish(alert.runModal()) }
    }
}
