import AppKit
import UniformTypeIdentifiers

/// Turns a Spine lobby into an installed wallpaper through the export pipeline:
/// pick one already extracted, or point at a folder or ZIP, look at a free
/// preview, then import it.
///
/// The only paid step is texture upscaling, for a lobby never upscaled before.
/// The window shows its quote beside the preview and asks again, naming the
/// amount and the cap, before passing `--yes`; nothing is billed otherwise.
final class LobbyImportController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    struct Lobby {
        let asset: String
        var title: String?
        let installed: [String]
        let upscaled: Bool
        let quoteUSD: Double?
        let capUSD: Double?
    }

    private let pipeline: MediaPipeline
    private let onInstalled: (URL) -> Void
    private var lobbies: [Lobby] = []
    private var shown: [Lobby] = []
    private var run: PipelineRun?
    private var preview: [String: Any]?
    private var previewedAsset: String?

    private let search = NSSearchField()
    private let hideInstalled = NSButton(checkboxWithTitle: "Hide installed", target: nil, action: nil)
    private let table = NSTableView()
    private let image = NSImageView()
    private let heading = NSTextField(labelWithString: "Choose a lobby")
    private let info = NSTextField(wrappingLabelWithString: "")
    private let titleField = NSTextField()
    private let animationField = NSTextField(string: "Idle_01")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let previewButton = NSButton(title: "Preview", target: nil, action: nil)
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let fitButton = NSButton(title: "Fit Camera", target: nil, action: nil)
    private let chooseButton = NSButton(title: "Folder or ZIP…", target: nil, action: nil)

    init(pipeline: MediaPipeline, onInstalled: @escaping (URL) -> Void) {
        self.pipeline = pipeline
        self.onInstalled = onInstalled
        super.init(window: NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 660),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false))
        window?.title = "Import Lobby"
        window?.minSize = NSSize(width: 860, height: 520)
        window?.isReleasedWhenClosed = false
        window?.delegate = self
        window?.center()
        setup()
        reloadList()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var onClose: (() -> Void)?
    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setup() {
        guard let root = window?.contentView else { return }
        search.placeholderString = "Search lobbies"
        search.delegate = self
        hideInstalled.state = .on
        hideInstalled.target = self; hideInstalled.action = #selector(filter)
        chooseButton.target = self; chooseButton.action = #selector(chooseSource)
        let toolbar = NSStackView(views: [search, hideInstalled, NSView(), chooseButton])
        toolbar.spacing = 10

        for (id, title, width) in [("title", "Name", 150.0), ("asset", "Asset", 125.0), ("state", "Status", 175.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel("Lobbies")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.backgroundColor = NSColor.black.cgColor
        image.layer?.cornerRadius = 8
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        info.textColor = .secondaryLabelColor
        titleField.placeholderString = "Wallpaper name, e.g. Hoshino-Swimsuit"
        let nameLabel = NSTextField(labelWithString: "Name"), animationLabel = NSTextField(labelWithString: "Animation")
        for label in [nameLabel, animationLabel] { label.widthAnchor.constraint(equalToConstant: 72).isActive = true }
        let nameRow = NSStackView(views: [nameLabel, titleField]), animationRow = NSStackView(views: [animationLabel, animationField])
        let form = NSStackView(views: [nameRow, animationRow])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 6
        titleField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        animationField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        for (button, action) in [(previewButton, #selector(previewSelected)), (importButton, #selector(importSelected)), (stopButton, #selector(stop)), (fitButton, #selector(fitCamera))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        importButton.keyEquivalent = "\r"
        stopButton.isHidden = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        fitButton.toolTip = "Zoom and recentre until the art covers the frame for the whole loop (free, local)"
        let buttons = NSStackView(views: [previewButton, fitButton, importButton, stopButton, spinner])
        buttons.spacing = 10
        let right = NSStackView(views: [image, heading, info, form, buttons, status])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 12

        for view in [toolbar, scroll, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            search.widthAnchor.constraint(equalToConstant: 220),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalToConstant: 470),
            right.topAnchor.constraint(equalTo: scroll.topAnchor),
            right.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 18),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            right.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
            image.widthAnchor.constraint(equalTo: right.widthAnchor),
            image.heightAnchor.constraint(equalTo: image.widthAnchor, multiplier: 9.0 / 16.0),
            info.widthAnchor.constraint(equalTo: right.widthAnchor),
            status.widthAnchor.constraint(equalTo: right.widthAnchor)
        ])
        updateControls()
    }

    // MARK: List

    private func reloadList(selecting asset: String? = nil) {
        status.stringValue = "Reading the workspace…"
        start(["--list"], onEvent: nil) { [weak self] succeeded, output in
            guard let self else { return }
            guard succeeded, let start = output.firstIndex(of: "["),
                  let data = String(output[start...]).data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                self.status.stringValue = "Couldn’t list lobbies: " + (output.split(separator: "\n").last.map(String.init) ?? "")
                return
            }
            self.lobbies = rows.compactMap { row in
                guard let asset = row["asset"] as? String else { return nil }
                let quote = row["quote"] as? [String: Any]
                return Lobby(asset: asset, title: row["title"] as? String, installed: row["installed"] as? [String] ?? [],
                             upscaled: row["upscaled"] as? Bool ?? false,
                             quoteUSD: quote?["estimateUSD"] as? Double, capUSD: quote?["capUSD"] as? Double)
            }
            let pending = self.lobbies.filter { $0.installed.isEmpty }.count
            self.status.stringValue = "\(self.lobbies.count) lobbies extracted, \(pending) not installed yet."
            self.filter()
            if let asset, let row = self.shown.firstIndex(where: { $0.asset == asset }) {
                self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                self.table.scrollRowToVisible(row)
            }
        }
    }

    @objc private func filter() {
        let query = search.stringValue.lowercased()
        let selected = selectedLobby?.asset
        shown = lobbies.filter { lobby in
            (hideInstalled.state == .off || lobby.installed.isEmpty) &&
            (query.isEmpty || lobby.asset.lowercased().contains(query) || (lobby.title?.lowercased().contains(query) ?? false))
        }
        table.reloadData()
        if let selected, let row = shown.firstIndex(where: { $0.asset == selected }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateControls()
    }
    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSSearchField) === search { filter() }
    }

    private var selectedLobby: Lobby? { shown.indices.contains(table.selectedRow) ? shown[table.selectedRow] : nil }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let lobby = shown[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "title": text = lobby.title.map(SceneLibraryController.displayTitle) ?? "Unnamed"
        case "asset": text = lobby.asset
        default:
            if !lobby.installed.isEmpty { text = "Installed" }
            else if lobby.upscaled { text = "Ready · free" }
            else { text = lobby.quoteUSD.map { String(format: "Upscale · ~$%.2f", $0) } ?? "Needs upscale" }
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        if tableColumn?.identifier.rawValue != "title" { label.textColor = .secondaryLabelColor }
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let lobby = selectedLobby, lobby.asset != previewedAsset else { updateControls(); return }
        preview = nil
        previewedAsset = nil
        image.image = nil
        heading.stringValue = lobby.title.map(SceneLibraryController.displayTitle) ?? lobby.asset
        titleField.stringValue = lobby.title ?? ""
        info.stringValue = lobby.installed.isEmpty
            ? (lobby.upscaled ? "Upscaled textures are on disk, so importing is local and free."
               : String(format: "Importing upscales its textures once on Modal, about $%.2f.", lobby.quoteUSD ?? 0))
            : "Already installed: " + lobby.installed.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        updateControls()
        previewSelected()
    }

    // MARK: Actions

    @objc private func chooseSource() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a folder or ZIP holding a lobby's .skel, .atlas and .png files."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .folder]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.table.deselectAll(nil)
            self.heading.stringValue = url.deletingPathExtension().lastPathComponent
            self.info.stringValue = "Copying into the workspace and rendering a preview…"
            self.runPreview(source: url.path)
        }
    }

    @objc private func previewSelected() {
        guard let lobby = selectedLobby else { return }
        runPreview(source: lobby.asset)
    }

    @objc private func fitCamera() {
        guard let asset = previewedAsset ?? selectedLobby?.asset else { return }
        status.stringValue = "Fitting the camera…"
        runPreview(source: asset, fit: true)
    }

    private func runPreview(source: String, fit: Bool = false) {
        run?.stop()
        if !fit { image.image = nil }
        var arguments = [source, "--preview", "--json", "--animation", animationValue]
        if fit { arguments.append("--fit") }
        if !titleValue.isEmpty { arguments += ["--title", titleValue] }
        start(arguments, onEvent: { [weak self] event in
            guard let self, event["event"] as? String == "preview" else { return }
            self.show(preview: event)
        }) { [weak self] succeeded, output in
            guard let self, !succeeded, self.run == nil else { return }
            self.status.stringValue = Self.lastMessage(output)
        }
    }

    private func show(preview event: [String: Any]) {
        preview = event
        previewedAsset = event["asset"] as? String
        if let path = event["image"] as? String { image.image = NSImage(contentsOfFile: path) }
        let seconds = event["seconds"] as? Double ?? 0
        let clean = event["clean"] as? Bool ?? false
        let upscaled = event["upscaled"] as? Bool ?? false
        var lines = [String(format: "%.2f-second loop.", seconds)]
        lines.append(clean ? "Covers the frame for the whole loop."
                     : "Leaves part of the frame uncovered (\(event["matte"] ?? "?")px). Fit Camera zooms until it doesn’t.")
        if upscaled {
            lines.append("Textures already upscaled: importing is local and free.")
        } else if let quote = event["quote"] as? [String: Any], let usd = quote["estimateUSD"] as? Double, let cap = quote["capUSD"] as? Double {
            lines.append(String(format: "Importing upscales %@ texture(s) on Modal first: about $%.2f, at most $%.2f.",
                                "\(quote["textures"] ?? "?")", usd, cap))
        }
        if let replaces = event["replaces"] as? String {
            lines.append("Replaces \(URL(fileURLWithPath: replaces).lastPathComponent); the old file is archived.")
        }
        info.stringValue = lines.joined(separator: " ")
        if titleField.stringValue.isEmpty, let asset = previewedAsset, let lobby = lobbies.first(where: { $0.asset == asset }), let title = lobby.title {
            titleField.stringValue = title
        }
        updateControls()
    }

    @objc private func importSelected() {
        guard let preview, let asset = preview["asset"] as? String, let window else {
            status.stringValue = "Preview it first."
            return
        }
        guard !titleValue.isEmpty,
              titleValue.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            status.stringValue = "Name it with letters, digits, - and _, e.g. Hoshino-Swimsuit."
            window.makeFirstResponder(titleField)
            return
        }
        var arguments = [asset, "--json", "--title", titleValue, "--animation", animationValue]
        // Export exactly what the preview showed, including a fitted camera.
        if let camera = preview["camera"] as? [Double], camera.count == 3 {
            arguments += ["--camera"] + camera.map { String($0) }
        }
        if !(preview["clean"] as? Bool ?? false) { arguments.append("--allow-matte") }
        var questions: [String] = []
        if !(preview["upscaled"] as? Bool ?? false),
           let quote = preview["quote"] as? [String: Any], let usd = quote["estimateUSD"] as? Double, let cap = quote["capUSD"] as? Double {
            questions.append(String(format: "This upscales the lobby's textures on Modal first. That is billed to your Modal account: about $%.2f, and at most $%.2f because the job stops after 15 minutes with no retries.", usd, cap))
            arguments.append("--yes")
        }
        if (preview["replaces"] as? String).map({ URL(fileURLWithPath: $0).lastPathComponent == "\(titleValue)-Restored-4K60.mp4" }) == true {
            questions.append("A wallpaper named \(titleValue) already exists. It will be archived and replaced.")
            arguments.append("--replace")
        }
        let begin = { [weak self] in self?.startImport(arguments) }
        guard !questions.isEmpty else { begin(); return }
        let alert = NSAlert()
        alert.messageText = arguments.contains("--yes") ? "Upscale and import \(titleValue)?" : "Replace \(titleValue)?"
        alert.informativeText = questions.joined(separator: "\n\n")
        alert.addButton(withTitle: arguments.contains("--yes") ? "Upscale and Import" : "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { begin() }
        }
    }

    private func startImport(_ arguments: [String]) {
        let asset = arguments.first
        status.stringValue = arguments.contains("--yes") ? "Upscaling on Modal…" : "Exporting…"
        start(arguments, onEvent: { [weak self] event in
            guard let self, event["event"] as? String == "installed", let path = event["path"] as? String else { return }
            self.onInstalled(URL(fileURLWithPath: path))
        }) { [weak self] succeeded, output in
            guard let self else { return }
            if succeeded {
                self.status.stringValue = "Imported. " + Self.lastMessage(output)
                self.previewedAsset = nil
                self.reloadList(selecting: asset)
            } else if Self.lastMessage(output).contains("pass --replace"), !arguments.contains("--replace"), let window = self.window {
                // The name was changed after the preview and now matches an installed file.
                let alert = NSAlert()
                alert.messageText = "Replace \(self.titleValue)?"
                alert.informativeText = "A wallpaper with that name already exists. It will be archived and replaced."
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Cancel")
                alert.beginSheetModal(for: window) { response in
                    if response == .alertFirstButtonReturn { self.startImport(arguments + ["--replace"]) }
                }
            } else {
                self.status.stringValue = Self.lastMessage(output)
            }
        }
    }

    @objc private func stop() { run?.stop() }

    // MARK: Running

    private var titleValue: String { titleField.stringValue.trimmingCharacters(in: .whitespaces) }
    private var animationValue: String {
        let value = animationField.stringValue.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? "Idle_01" : value
    }

    private func start(_ arguments: [String], onEvent: (([String: Any]) -> Void)?, onExit: @escaping (Bool, String) -> Void) {
        let next = pipeline.run(arguments)
        next.onLine = { [weak self] line in self?.status.stringValue = line }
        next.onEvent = onEvent
        next.onExit = { [weak self, weak next] succeeded, output in
            guard let self else { return }
            if self.run === next { self.run = nil }
            self.updateControls()
            onExit(succeeded, output)
        }
        do {
            try next.start()
            run = next
        } catch {
            status.stringValue = "Couldn’t start the pipeline: " + error.localizedDescription
        }
        updateControls()
    }

    private func updateControls() {
        let busy = run != nil
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        stopButton.isHidden = !busy
        previewButton.isEnabled = !busy && selectedLobby != nil
        fitButton.isHidden = preview == nil || (preview?["clean"] as? Bool ?? true)
        fitButton.isEnabled = !busy
        importButton.isEnabled = !busy && preview != nil
        chooseButton.isEnabled = !busy
        importButton.title = (preview?["upscaled"] as? Bool ?? true) ? "Import" : "Upscale and Import…"
    }

    private static func lastMessage(_ output: String) -> String {
        output.split(separator: "\n").last(where: { !$0.hasPrefix("IDLESSE ") && !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? ""
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard run != nil else { return true }
        status.stringValue = "Stop the running step before closing."
        NSSound.beep()
        return false
    }
    func windowWillClose(_ notification: Notification) {
        run?.stop()
        onClose?()
    }

    /// Lists the workspace and previews one lobby that still needs upscaling,
    /// through the real script. Nothing is exported and nothing is billed.
    static func smokeTest(pipeline: MediaPipeline) {
        let controller = LobbyImportController(pipeline: pipeline) { _ in preconditionFailure("smoke test must not install") }
        func wait(_ what: String, seconds: Double = 120, until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !done() {
                precondition(Date() < deadline, "timed out waiting for \(what); status: \(controller.status.stringValue)")
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        wait("the lobby list") { controller.run == nil && !controller.lobbies.isEmpty }
        precondition(controller.shown.allSatisfy { $0.installed.isEmpty }, "installed lobbies are hidden by default")
        guard let row = controller.shown.firstIndex(where: { !$0.upscaled }) else {
            print("Lobby import smoke test passed (every lobby is already upscaled)")
            return
        }
        controller.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        wait("the preview") { controller.run == nil && controller.preview != nil }
        precondition(controller.image.image != nil, "the preview image loads")
        precondition(controller.preview?["upscaled"] as? Bool == false && controller.preview?["quote"] is [String: Any])
        precondition(controller.importButton.title == "Upscale and Import…" && controller.info.stringValue.contains("at most $"),
                     "the paid step is named, with its cap, before anything starts: \(controller.info.stringValue)")
        if controller.preview?["clean"] as? Bool == false {
            precondition(!controller.fitButton.isHidden, "matte offers Fit Camera")
            controller.fitCamera()
            wait("the fitted preview") { controller.run == nil }
            precondition(controller.preview?["clean"] as? Bool == true && controller.fitButton.isHidden,
                         "fitting clears the matte: \(controller.status.stringValue)")
        }
        if let hold = ProcessInfo.processInfo.environment["IDLESSE_SMOKE_HOLD"].flatMap(Double.init) {
            controller.show()
            RunLoop.main.run(until: Date().addingTimeInterval(hold))
        }
        controller.titleField.stringValue = "not a valid name!"
        controller.importSelected()
        precondition(controller.run == nil && controller.status.stringValue.contains("letters"), "a bad name stops before running")
        controller.close()
        print("Lobby import smoke test passed: \(controller.lobbies.count) lobbies; previewed \(controller.previewedAsset ?? "?")")
    }
}
