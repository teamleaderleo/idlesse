import AppKit

/// Focused editor for one-input custom Metal effects. The parent Effects editor owns
/// ordering and amount; this sheet owns only source/speed and returns a validated draft.
final class StudioShaderEffectEditorController: NSObject, NSWindowDelegate {
    let window: NSWindow
    var onApply: ((SceneNode.Shader) -> Void)?
    var onClose: (() -> Void)?

    private let sourceView = NSTextView()
    private let speedField = NSTextField(string: "")
    private let diagnostics = NSTextField(wrappingLabelWithString: "Ready to compile Metal effect source.")
    private weak var parentWindow: NSWindow?
    private var closed = false

    init(shader: SceneNode.Shader) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 590),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Custom Metal Effect"
        window.delegate = self
        window.minSize = NSSize(width: 620, height: 460)

        speedField.stringValue = String(shader.speed)
        speedField.setAccessibilityLabel("Shader effect speed multiplier")
        speedField.widthAnchor.constraint(equalToConstant: 90).isActive = true

        sourceView.isRichText = false
        sourceView.isAutomaticQuoteSubstitutionEnabled = false
        sourceView.isAutomaticDashSubstitutionEnabled = false
        sourceView.isAutomaticTextReplacementEnabled = false
        sourceView.isAutomaticSpellingCorrectionEnabled = false
        sourceView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        sourceView.textContainerInset = NSSize(width: 8, height: 8)
        sourceView.string = shader.source
        sourceView.allowsUndo = true
        sourceView.setAccessibilityLabel("Custom Metal effect source")
        sourceView.isVerticallyResizable = true
        sourceView.isHorizontallyResizable = true
        sourceView.autoresizingMask = [.width]
        sourceView.textContainer?.widthTracksTextView = false
        sourceView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                         height: CGFloat.greatestFiniteMagnitude)

        let sourceScroll = NSScrollView()
        sourceScroll.borderType = .bezelBorder
        sourceScroll.hasVerticalScroller = true
        sourceScroll.hasHorizontalScroller = true
        sourceScroll.documentView = sourceView
        sourceScroll.translatesAutoresizingMaskIntoConstraints = false

        diagnostics.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnostics.textColor = .secondaryLabelColor
        diagnostics.maximumNumberOfLines = 5
        diagnostics.lineBreakMode = .byWordWrapping
        diagnostics.isSelectable = true
        diagnostics.setAccessibilityLabel("Shader effect compiler diagnostics")

        let compile = NSButton(title: "Compile", target: self, action: #selector(compileSource))
        let apply = NSButton(title: "Apply", target: self, action: #selector(applySource))
        apply.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"

        let speedLabel = NSTextField(labelWithString: "Speed")
        let range = NSTextField(labelWithString: "0.01–10×")
        range.textColor = .secondaryLabelColor
        let top = NSStackView(views: [speedLabel, speedField, range])
        top.spacing = 8
        top.alignment = .centerY

        let hint = NSTextField(wrappingLabelWithString:
            "Entry: fragment float4 effectMain(V, EffectU, ShaderInputs, texture2d<float> source). " +
            "Sample only source at texture(0). EffectU.viewport = time, width, height, amount; " +
            "EffectU.signals = pointer x/y and audio. ShaderInputs exposes the ordinary scene-control slots.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)

        let buttons = NSStackView(views: [compile, apply, cancel])
        buttons.spacing = 8
        let spacer = NSView()
        let bottom = NSStackView(views: [diagnostics, spacer, buttons])
        bottom.spacing = 10
        bottom.alignment = .centerY
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        diagnostics.setContentHuggingPriority(.defaultLow, for: .horizontal)
        diagnostics.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let content = window.contentView!
        for view in [top, hint, sourceScroll, bottom] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            sourceScroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            sourceScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            sourceScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            sourceScroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            diagnostics.widthAnchor.constraint(greaterThanOrEqualToConstant: 300)
        ])
    }

    func present(on parent: NSWindow) {
        parentWindow = parent
        parent.beginSheet(window)
        window.makeFirstResponder(sourceView)
    }

    @objc private func compileSource() { _ = compileDraft(selectFirstError: true) }

    @objc private func applySource() {
        guard let shader = compileDraft(selectFirstError: true) else { return }
        onApply?(shader)
        closeSheet()
    }

    @objc private func cancel() { closeSheet() }

    private func draft() throws -> SceneNode.Shader {
        guard let speed = Double(speedField.stringValue), speed.isFinite else {
            throw SceneError.invalid("Speed must be a finite number from 0.01 through 10.")
        }
        let shader = SceneNode.Shader(source: sourceView.string, speed: speed)
        try shader.validate()
        return shader
    }

    private func compileDraft(selectFirstError: Bool) -> SceneNode.Shader? {
        do {
            let shader = try draft()
            try MetalShaderEffectCompiler.validate(shader)
            diagnostics.stringValue = "Compiled successfully · \(shader.source.utf8.count) bytes · \(shader.speed)×"
            diagnostics.textColor = .systemGreen
            return shader
        } catch let error as MetalShaderCompilationError {
            diagnostics.stringValue = error.errorDescription ?? error.fallback
            diagnostics.textColor = .systemRed
            if selectFirstError, let line = error.diagnostics.compactMap(\.line).first { select(line: line) }
        } catch {
            diagnostics.stringValue = error.localizedDescription
            diagnostics.textColor = .systemRed
        }
        return nil
    }

    private func select(line: Int) {
        guard line > 0 else { return }
        let ns = sourceView.string as NSString
        var current = 1
        var location = 0
        while current < line && location < ns.length {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            current += 1
        }
        guard current == line, location <= ns.length else { return }
        let range = ns.lineRange(for: NSRange(location: location, length: 0))
        sourceView.setSelectedRange(range)
        sourceView.scrollRangeToVisible(range)
        window.makeFirstResponder(sourceView)
    }

    private func closeSheet() {
        guard !closed else { return }
        closed = true
        if let parentWindow { parentWindow.endSheet(window) }
        else { window.close() }
        onClose?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeSheet()
        return false
    }
}
