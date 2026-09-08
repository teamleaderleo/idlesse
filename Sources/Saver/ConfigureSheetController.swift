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
    private let shuffleButton = NSButton(checkboxWithTitle: "Random order", target: nil, action: nil)
    private let subfoldersButton = NSButton(checkboxWithTitle: "Include subfolders", target: nil, action: nil)

    private var pendingFolderURL: URL?

    init(preferences: IdlessePreferences, onSave: @escaping () -> Void) {
        self.preferences = preferences
        self.onSave = onSave
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 370),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Idlesse Options"
        window.isReleasedWhenClosed = false
        buildInterface()
        reload()
    }

    func reload() {
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
        shuffleButton.state = preferences.shuffle ? .on : .off
        subfoldersButton.state = preferences.includeSubfolders ? .on : .off
    }

    private func buildInterface() {
        guard let contentView = window.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        let title = NSTextField(labelWithString: "Idlesse")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        root.addArrangedSubview(title)

        let subtitle = NSTextField(labelWithString: "Give the picture enough time to exist.")
        subtitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(subtitle)

        let folderControls = NSStackView()
        folderControls.orientation = .horizontal
        folderControls.spacing = 8
        folderPathLabel.lineBreakMode = .byTruncatingMiddle
        folderPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chooseButton = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        folderControls.addArrangedSubview(folderPathLabel)
        folderControls.addArrangedSubview(chooseButton)
        root.addArrangedSubview(makeRow(label: "Image folder", control: folderControls))

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

        scalingPopup.addItems(withTitles: IdlesseScalingMode.allCases.map(\.title))
        root.addArrangedSubview(makeRow(label: "Image size", control: scalingPopup))

        root.addArrangedSubview(shuffleButton)
        root.addArrangedSubview(subfoldersButton)

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
        buttons.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        root.addArrangedSubview(buttons)
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

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.pendingFolderURL = url
            self?.setFolderPath(url.path)
        }
    }

    @objc private func save() {
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

        preferences.displayDuration = max(1, durationField.doubleValue * multiplier)
        preferences.transitionDuration = max(0, transitionField.doubleValue)
        preferences.shuffle = shuffleButton.state == .on
        preferences.includeSubfolders = subfoldersButton.state == .on

        if let title = scalingPopup.titleOfSelectedItem,
           let mode = IdlesseScalingMode.allCases.first(where: { $0.title == title }) {
            preferences.scalingMode = mode
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
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            NSApp.endSheet(window)
        }
    }

    private func setFolderPath(_ path: String?) {
        let display = path ?? "No folder selected"
        folderPathLabel.stringValue = display
        folderPathLabel.toolTip = path
    }
}
