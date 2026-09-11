import AppKit

/// Three-step first launch: pick a wallpaper (applied live), optional
/// screensaver mirror, done. Only shown for genuinely fresh profiles —
/// anyone with a saved wallpaper never sees it.
final class OnboardingController: NSWindowController {
    private static let doneKey = "Idlesse.onboarded"
    static var needed: Bool {
        !UserDefaults.standard.bool(forKey: doneKey)
            && UserDefaults.standard.data(forKey: "wallpaperResumeBookmark") == nil
    }
    static func markDone() { UserDefaults.standard.set(true, forKey: doneKey) }

    private let builtins: [(title: String, url: URL)]
    private let onPick: (URL) -> Void
    private let onMirror: () -> String
    private let onOpenSaver: () -> Void
    private let onDone: () -> Void

    private let stepLabel = NSTextField(labelWithString: "")
    private let body = NSStackView()
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let nextButton = NSButton(title: "Continue", target: nil, action: nil)
    private var step = 0
    private var pickedID: URL?
    private var mirrorStatus = NSTextField(labelWithString: "")

    init(builtins: [(title: String, url: URL)], onPick: @escaping (URL) -> Void,
         onMirror: @escaping () -> String, onOpenSaver: @escaping () -> Void,
         onDone: @escaping () -> Void) {
        self.builtins = builtins
        self.onPick = onPick
        self.onMirror = onMirror
        self.onOpenSaver = onOpenSaver
        self.onDone = onDone
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Idlesse"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()

        guard let root = window.contentView else { return }
        let heading = NSTextField(labelWithString: "")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        heading.tag = 100
        stepLabel.textColor = .secondaryLabelColor
        body.orientation = .vertical
        body.spacing = 10
        backButton.target = self; backButton.action = #selector(goBack)
        backButton.bezelStyle = .rounded
        nextButton.target = self; nextButton.action = #selector(goNext)
        nextButton.bezelStyle = .rounded
        nextButton.bezelColor = .controlAccentColor
        nextButton.contentTintColor = .white
        nextButton.keyEquivalent = "\r"
        let nav = NSStackView(views: [stepLabel, NSView(), backButton, nextButton])
        nav.spacing = 10
        for view in [heading, body, nav] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            body.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 16),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            nav.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            nav.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            nav.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            body.bottomAnchor.constraint(lessThanOrEqualTo: nav.topAnchor, constant: -16),
        ])
        render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func heading() -> NSTextField? { window?.contentView?.viewWithTag(100) as? NSTextField }

    private func render() {
        for view in body.views { body.removeView(view); view.removeFromSuperview() }
        stepLabel.stringValue = "Step \(step + 1) of 3"
        backButton.isHidden = step == 0
        switch step {
        case 0: renderPick()
        case 1: renderSaver()
        default: renderDone()
        }
    }

    private func explain(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        body.addView(label, in: .leading)
    }

    private func renderPick() {
        heading()?.stringValue = "Pick your first wallpaper"
        explain("It applies to your desktop the moment you click — what you see is what you get.")
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.spacing = 8
        var row: NSStackView?
        for (index, scene) in builtins.enumerated() {
            if index % 2 == 0 { row = NSStackView(); row?.spacing = 8; row?.distribution = .fillEqually; grid.addView(row!, in: .leading) }
            let button = NSButton(title: scene.title, target: self, action: #selector(pick(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            if pickedID == scene.url {
                button.bezelColor = .controlAccentColor
                button.contentTintColor = .controlAccentColor
            }
            row?.addView(button, in: .leading)
        }
        body.addView(grid, in: .leading)
        nextButton.title = pickedID == nil ? "Pick one above to continue" : "Continue"
        nextButton.isEnabled = pickedID != nil
    }

    private func renderSaver() {
        heading()?.stringValue = "Screensaver (optional)"
        explain("Your wallpaper can double as the screensaver, or skip this and decide later in Settings.")
        let mirror = NSButton(title: "Mirror wallpaper to screensaver", target: self, action: #selector(mirror))
        mirror.bezelStyle = .rounded
        let options = NSButton(title: "Screen Saver Options…", target: self, action: #selector(openSaver))
        options.bezelStyle = .rounded
        mirrorStatus.textColor = .secondaryLabelColor
        body.addView(mirror, in: .leading)
        body.addView(options, in: .leading)
        body.addView(mirrorStatus, in: .leading)
        nextButton.title = "Continue"
        nextButton.isEnabled = true
    }

    private func renderDone() {
        heading()?.stringValue = "You're set"
        explain("Right-click the desktop for wallpaper controls. Pause anytime from the menu bar. Everything else lives in the Library (Cmd-L): imports, collections, schedules, and Studio.")
        nextButton.title = "Start using Idlesse"
        nextButton.isEnabled = true
    }

    @objc private func pick(_ sender: NSButton) {
        let scene = builtins[sender.tag]
        pickedID = scene.url
        onPick(scene.url)
        render()
    }
    @objc private func mirror() { mirrorStatus.stringValue = onMirror() }
    @objc private func openSaver() { onOpenSaver() }
    @objc private func goBack() { step = max(0, step - 1); render() }
    @objc private func goNext() {
        if step == 0, pickedID == nil { return }
        if step == 2 {
            Self.markDone()
            window?.orderOut(nil)
            onDone()
            return
        }
        step += 1
        render()
    }

    /// Exercises all three steps without showing anything on screen.
    static func smokeTest(builtins: [(title: String, url: URL)]) throws {
        precondition(!builtins.isEmpty)
        var picked: URL?
        var mirrored = false
        var finished = false
        let controller = OnboardingController(builtins: builtins,
            onPick: { picked = $0 }, onMirror: { mirrored = true; return "ok" },
            onOpenSaver: {}, onDone: { finished = true })
        precondition(!controller.nextButton.isEnabled, "Step 1 must wait for an explicit pick")
        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) }
        }
        guard let first = buttons(in: controller.body).first(where: { $0.action == #selector(pick(_:)) }) else {
            preconditionFailure("Step 1 must offer scene picks")
        }
        controller.pick(first)
        precondition(picked == builtins[0].url && controller.nextButton.isEnabled)
        controller.goNext()
        controller.mirror()
        precondition(mirrored)
        controller.goNext()
        controller.goNext()
        precondition(finished, "Step 3 must finish onboarding")
        UserDefaults.standard.removeObject(forKey: doneKey)
        print("Onboarding checks passed: pick, mirror, finish")
    }
}
