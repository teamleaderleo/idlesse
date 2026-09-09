import AppKit

final class ConfigureSheetController: NSObject {
    let window: NSWindow

    private let preferences: IdlessePreferences
    private let onSave: () -> Void

    private let folderPathLabel = NSTextField(labelWithString: "No folder selected")
    private let durationField = NSTextField(string: "5")
    private let durationUnitPopup = NSPopUpButton()
    private let transitionField = NSTextField(string: "2")
    private let scalingPopup = NSPopUpButton()
    private let backgroundColorWell = NSColorWell()
    private let multiDisplayPopup = NSPopUpButton()
    private let orderingPopup = NSPopUpButton()
    private let subfoldersButton = NSButton(checkboxWithTitle: "Include subfolders", target: nil, action: nil)

    private var pendingFolderURL: URL?

    init(preferences: IdlessePreferences, onSave: @escaping () -> Void) {
        self.preferences = preferences
        self.onSave = onSave
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Idlesse Settings"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        buildInterface()
        reload()
    }

    func reload() {
        preferences.reloadFromDisk()
        pendingFolderURL = nil
        setFolderPath(preferences.folderDisplayPath)

        let seconds = preferences.displayDuration
        if seconds >= 3600 {
            durationField.doubleValue = seconds / 3600
            durationUnitPopup.selectItem(withTitle: "Hours")
        } else if seconds >= 60 {
            durationField.doubleValue = seconds / 60
            durationUnitPopup.selectItem(withTitle: "Minutes")
        } else {
            durationField.doubleValue = seconds
            durationUnitPopup.selectItem(withTitle: "Seconds")
        }

        transitionField.doubleValue = preferences.transitionDuration
        scalingPopup.selectItem(withTitle: preferences.scalingMode.title)
        backgroundColorWell.color = preferences.backgroundColor
        multiDisplayPopup.selectItem(withTitle: preferences.multiDisplayMode.title)
        orderingPopup.selectItem(withTitle: preferences.playbackOrder.title)
        subfoldersButton.state = preferences.includeSubfolders ? .on : .off
    }

    /// An opt-in render of our own content, not a capture of other applications.
    /// The marker is consumed, and each request replaces the previous artifact.
    func captureDiagnosticIfRequested() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        let marker = directory.appendingPathComponent("idlesse-capture-request")
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        try? FileManager.default.removeItem(at: marker)
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let imageURL = directory.appendingPathComponent("idlesse-settings.png")
        do {
            try png.write(to: imageURL, options: .atomic)
            let state: [String: Any] = [
                "pid": Int(getpid()), "capturedAt": ISO8601DateFormatter().string(from: Date()),
                "visible": window.isVisible, "key": window.isKeyWindow,
                "frame": NSStringFromRect(window.frame),
                "contentSize": NSStringFromSize(view.bounds.size),
                "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh,
                "kind": "own-view-render; does not prove on-screen visibility",
                "controls": diagnosticControls(in: view),
            ]
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("idlesse-settings.json"), options: .atomic)
        } catch {
            NSLog("Idlesse settings capture failed: %@", error.localizedDescription)
        }
    }

    private func diagnosticControls(in view: NSView) -> [[String: String]] {
        var result: [[String: String]] = []
        if let control = view as? NSControl {
            let text: String
            if let popup = control as? NSPopUpButton { text = popup.title }
            else if let button = control as? NSButton { text = button.title }
            else { text = control.stringValue }
            result.append(["type": String(describing: type(of: control)), "text": text,
                           "frame": NSStringFromRect(view.convert(view.bounds, to: window.contentView))])
        }
        return result + view.subviews.flatMap { diagnosticControls(in: $0) }
    }

    private func buildInterface() {
        guard let contentView = window.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        root.addArrangedSubview(sectionTitle("Pictures"))
        let folderControls = NSStackView()
        folderControls.orientation = .horizontal
        folderControls.spacing = 8
        folderPathLabel.lineBreakMode = .byTruncatingMiddle
        folderPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chooseButton = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        folderControls.addArrangedSubview(folderPathLabel)
        folderControls.addArrangedSubview(chooseButton)
        root.addArrangedSubview(makeRow(label: "Image folder", control: folderControls))

        root.addArrangedSubview(subfoldersButton)
        chooseButton.toolTip = "Choose a local or downloaded folder."
        root.addArrangedSubview(sectionTitle("Pace"))
        let presets = NSStackView()
        presets.spacing = 8
        for (index, title) in ["5 min", "30 sec", "5 sec"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(applyPreset(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            presets.addArrangedSubview(button)
        }
        root.addArrangedSubview(presets)

        durationUnitPopup.addItems(withTitles: ["Seconds", "Minutes", "Hours"])
        durationField.alignment = .right
        durationField.widthAnchor.constraint(equalToConstant: 86).isActive = true
        let durationControls = NSStackView(views: [durationField, durationUnitPopup])
        durationControls.orientation = .horizontal
        durationControls.spacing = 8
        root.addArrangedSubview(makeRow(label: "Show each image", control: durationControls))

        transitionField.alignment = .right
        transitionField.widthAnchor.constraint(equalToConstant: 86).isActive = true
        let secondsLabel = NSTextField(labelWithString: "seconds")
        let transitionControls = NSStackView(views: [transitionField, secondsLabel])
        transitionControls.orientation = .horizontal
        transitionControls.spacing = 8
        root.addArrangedSubview(makeRow(label: "Crossfade", control: transitionControls))

        root.addArrangedSubview(sectionTitle("Presentation"))
        scalingPopup.addItems(withTitles: IdlesseScalingMode.allCases.map(\.title))
        root.addArrangedSubview(makeRow(label: "Image size", control: scalingPopup))

        backgroundColorWell.supportsAlpha = false
        backgroundColorWell.widthAnchor.constraint(equalToConstant: 64).isActive = true
        root.addArrangedSubview(makeRow(label: "Background", control: backgroundColorWell))

        multiDisplayPopup.addItems(withTitles: IdlesseMultiDisplayMode.allCases.map(\.title))
        root.addArrangedSubview(makeRow(label: "Displays", control: multiDisplayPopup))

        orderingPopup.addItems(withTitles: IdlessePlaybackOrder.allCases.map(\.title))
        root.addArrangedSubview(makeRow(label: "Order", control: orderingPopup))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(spacer)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [buttonSpacer, cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        root.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        for item in root.arrangedSubviews {
            item.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -48).isActive = true
        }
    }

    private func makeRow(label: String, control: NSView) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let row = NSStackView(views: [labelView, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose the folder of pictures Idlesse should show."
        panel.prompt = "Choose"

        if let path = preferences.folderDisplayPath {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.pendingFolderURL = url
            self?.setFolderPath(url.path)
        }
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    @objc private func applyPreset(_ sender: NSButton) {
        let durations = [300.0, 30.0, 5.0]
        let seconds = durations[sender.tag]
        durationField.doubleValue = seconds >= 60 ? seconds / 60 : seconds
        durationUnitPopup.selectItem(withTitle: seconds >= 60 ? "Minutes" : "Seconds")
        transitionField.doubleValue = sender.tag == 2 ? 0.5 : 2
    }

    static func timingNumber(_ text: String) -> Double? {
        let scanner = Scanner(string: text)
        scanner.locale = Locale.current
        guard let value = scanner.scanDouble(), scanner.isAtEnd, value.isFinite else { return nil }
        return value
    }

    @objc private func save() {
        let durationText = durationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let fadeText = transitionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let duration = Self.timingNumber(durationText),
              let fade = Self.timingNumber(fadeText),
              duration.isFinite, duration > 0, fade.isFinite, (0...30).contains(fade) else {
            let alert = NSAlert()
            alert.messageText = "Check the timing"
            alert.informativeText = "Use a positive number for image duration and 0–30 seconds for crossfade."
            alert.beginSheetModal(for: window)
            return
        }
        if let pendingFolderURL {
            do {
                try preferences.saveFolder(pendingFolderURL)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t remember that folder"
                alert.informativeText = "Choose the folder again. macOS needs to grant Idlesse persistent read access."
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
        }

        let multiplier: Double
        switch durationUnitPopup.titleOfSelectedItem {
        case "Hours": multiplier = 3600
        case "Minutes": multiplier = 60
        default: multiplier = 1
        }

        preferences.displayDuration = max(1, duration * multiplier)
        preferences.transitionDuration = fade
        preferences.includeSubfolders = subfoldersButton.state == .on
        preferences.backgroundColor = backgroundColorWell.color

        if let title = scalingPopup.titleOfSelectedItem,
           let mode = IdlesseScalingMode.allCases.first(where: { $0.title == title }) {
            preferences.scalingMode = mode
        }

        if let title = multiDisplayPopup.titleOfSelectedItem,
           let mode = IdlesseMultiDisplayMode.allCases.first(where: { $0.title == title }) {
            preferences.multiDisplayMode = mode
        }

        if let title = orderingPopup.titleOfSelectedItem,
           let order = IdlessePlaybackOrder.allCases.first(where: { $0.title == title }) {
            preferences.playbackOrder = order
        }

        preferences.save()
        onSave()
        dismiss()
    }

    @objc private func cancel() {
        reload()
        dismiss()
    }

    private func dismiss() {
        // ScreenSaverView's configureSheet contract requires the controller to end
        // the document-modal session through NSApplication. Let AppKit perform the
        // native sheet dismissal animation; standalone development windows simply
        // order themselves out.
        if window.sheetParent != nil {
            NSApp.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }

    private func setFolderPath(_ path: String?) {
        let display = path ?? "No folder selected"
        folderPathLabel.stringValue = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? display
        folderPathLabel.toolTip = path
    }
}
