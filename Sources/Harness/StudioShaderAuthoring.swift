import AppKit
import Metal

struct StudioShaderTemplate: Equatable {
    let name: String
    let source: String
    let speed: Double
    var shader: SceneNode.Shader { .init(source: source, speed: speed) }
}

enum StudioShaderTemplates {
    static let all: [StudioShaderTemplate] = [
        .init(name: "Plasma", source: SceneNode.Shader.plasma, speed: 1),
        .init(name: "Noise / Grain", source: """
        float studioHash21(float2 p) {
            p = fract(p * float2(123.34, 456.21));
            p += dot(p, p + 45.32);
            return fract(p.x * p.y);
        }
        fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]) {
            float2 px = floor(in.uv * u.resolution);
            float grain = studioHash21(px + floor(u.time * 24.0));
            float vignette = 1.0 - 0.28 * smoothstep(0.2, 1.35, length(in.uv * 2.0 - 1.0));
            float value = (0.10 + grain * 0.18) * vignette;
            return float4(float3(value) * u.opacity, u.opacity);
        }
        """, speed: 1),
        .init(name: "Star Field", source: """
        float2 studioHash22(float2 p) {
            float3 q = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
            q += dot(q, q.yzx + 33.33);
            return fract((q.xx + q.yz) * q.zy);
        }
        fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]) {
            float2 uv = (in.uv - 0.5) * float2(u.resolution.x / max(u.resolution.y, 1.0), 1.0);
            uv *= 9.0;
            float2 cell = floor(uv);
            float2 local = fract(uv) - 0.5;
            float3 color = float3(0.008, 0.012, 0.026);
            for (int y = -1; y <= 1; ++y) {
                for (int x = -1; x <= 1; ++x) {
                    float2 offset = float2(x, y);
                    float2 h = studioHash22(cell + offset);
                    float2 point = offset + h - 0.5;
                    float d = length(local - point);
                    float twinkle = 0.65 + 0.35 * sin(u.time * (0.8 + h.x) + h.y * 18.0);
                    float star = smoothstep(0.075, 0.0, d) * twinkle;
                    color += star * mix(float3(0.55, 0.68, 1.0), float3(1.0, 0.82, 0.58), h.x);
                }
            }
            return float4(min(color, 1.0) * u.opacity, u.opacity);
        }
        """, speed: 0.45),
        .init(name: "Water / Ripple", source: """
        fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]) {
            float2 aspect = float2(u.resolution.x / max(u.resolution.y, 1.0), 1.0);
            float2 p = (in.uv - 0.5) * aspect;
            float2 pointer = u.pointer * 0.18 * aspect;
            float d = length(p - pointer);
            float wave = sin(d * 46.0 - u.time * 2.4) * exp(-d * 2.1);
            wave += 0.35 * sin((p.x + p.y) * 19.0 + u.time * 0.8);
            float3 deep = float3(0.015, 0.08, 0.13);
            float3 light = float3(0.10, 0.42, 0.48);
            float3 color = mix(deep, light, 0.46 + 0.20 * wave);
            return float4(color * u.opacity, u.opacity);
        }
        """, speed: 0.8),
        .init(name: "CRT", source: """
        fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]) {
            float2 uv = in.uv;
            float2 p = uv * 2.0 - 1.0;
            float scan = 0.92 + 0.08 * sin(uv.y * u.resolution.y * 3.14159);
            float grille = 0.96 + 0.04 * sin(uv.x * u.resolution.x * 2.0944);
            float glow = 0.55 + 0.12 * sin(uv.y * 8.0 + u.time * 0.7);
            float vignette = 1.0 - 0.38 * smoothstep(0.25, 1.35, dot(p, p));
            float3 phosphor = float3(0.20, 0.78, 0.58) * glow * scan * grille * vignette;
            return float4(phosphor * u.opacity, u.opacity);
        }
        """, speed: 0.35),
        .init(name: "Voronoi", source: """
        float2 studioVoronoiHash(float2 p) {
            float2 q = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
            return fract(sin(q) * 43758.5453);
        }
        fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]) {
            float2 p = in.uv * 6.0;
            float2 cell = floor(p);
            float2 local = fract(p);
            float nearest = 10.0;
            float pulse = 0.0;
            for (int y = -1; y <= 1; ++y) {
                for (int x = -1; x <= 1; ++x) {
                    float2 neighbor = float2(x, y);
                    float2 h = studioVoronoiHash(cell + neighbor);
                    float2 point = neighbor + 0.5 + 0.24 * sin(u.time * 0.45 + 6.28318 * h);
                    float d = length(point - local);
                    if (d < nearest) { nearest = d; pulse = h.x; }
                }
            }
            float edge = smoothstep(0.08, 0.72, nearest);
            float3 a = float3(0.035, 0.055, 0.09);
            float3 b = float3(0.26, 0.38, 0.44);
            float3 color = mix(b, a, edge) * (0.86 + 0.14 * pulse);
            return float4(color * u.opacity, u.opacity);
        }
        """, speed: 0.55)
    ]
}

struct StudioShaderDiagnostic: Equatable {
    let line: Int?
    let column: Int?
    let message: String

    var displayText: String {
        if let line, let column { return "Line \(line):\(column) — \(message)" }
        if let line { return "Line \(line) — \(message)" }
        return message
    }
}

struct StudioShaderCompileFailure: LocalizedError {
    let diagnostics: [StudioShaderDiagnostic]
    var errorDescription: String? { diagnostics.map(\.displayText).joined(separator: "\n") }
}

enum StudioShaderCompiler {
    private static let prelude = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position [[position]]; float2 uv; float fade; float2 canvasUV; };
    struct ShaderU { float time; float2 resolution; float2 pointer; float audio; float opacity; };
    vertex V studioShaderVertex(uint id [[vertex_id]]) {
        float2 p = float2(id & 1, id >> 1) * 2.0 - 1.0;
        float2 uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
        return {float4(p, 0, 1), uv, 1.0, uv};
    }
    """

    private static var physicalSourceOffset: Int {
        prelude.components(separatedBy: "\n").count + 1
    }

    static func validate(_ shader: SceneNode.Shader) throws {
        try shader.validate()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw StudioShaderCompileFailure(diagnostics: [.init(line: nil, column: nil,
                message: "Metal is unavailable on this Mac.")])
        }
        let source = prelude + "\n#line 1 \"StudioShader\"\n" + shader.source
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw StudioShaderCompileFailure(diagnostics: diagnostics(from: error))
        }
        guard let fragment = library.makeFunction(name: "shaderMain") else {
            throw StudioShaderCompileFailure(diagnostics: [.init(line: nil, column: nil,
                message: "Define fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]).")])
        }
        guard let vertex = library.makeFunction(name: "studioShaderVertex") else {
            throw StudioShaderCompileFailure(diagnostics: [.init(line: nil, column: nil,
                message: "Could not prepare the Studio shader compiler.")])
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            _ = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw StudioShaderCompileFailure(diagnostics: diagnostics(from: error))
        }
    }

    static func diagnostics(from error: Error) -> [StudioShaderDiagnostic] {
        let description = (error as NSError).localizedDescription
        let parsed = parseDiagnostics(description)
        if !parsed.isEmpty { return parsed }
        let clean = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return [.init(line: nil, column: nil, message: clean.isEmpty ? "Metal could not compile this shader." : clean)]
    }

    static func parseDiagnostics(_ text: String) -> [StudioShaderDiagnostic] {
        let pattern = #"(StudioShader|program_source|<program source>|source):(\d+):(\d+):\s*(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [StudioShaderDiagnostic] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let range = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            guard let match = regex.firstMatch(in: rawLine, range: range), match.numberOfRanges == 5,
                  let sourceRange = Range(match.range(at: 1), in: rawLine),
                  let lineRange = Range(match.range(at: 2), in: rawLine),
                  let columnRange = Range(match.range(at: 3), in: rawLine),
                  let messageRange = Range(match.range(at: 4), in: rawLine),
                  let rawNumber = Int(rawLine[lineRange]), let column = Int(rawLine[columnRange]) else { continue }
            let sourceName = String(rawLine[sourceRange])
            let line = sourceName == "StudioShader" ? rawNumber : max(1, rawNumber - physicalSourceOffset)
            var message = String(rawLine[messageRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["fatal error:", "error:", "warning:", "note:"] where message.lowercased().hasPrefix(prefix) {
                message = String(message.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            guard !message.isEmpty else { continue }
            let diagnostic = StudioShaderDiagnostic(line: line, column: column, message: message)
            if result.last != diagnostic { result.append(diagnostic) }
            if result.count == 20 { break }
        }
        return result
    }
}

final class StudioShaderEditor: NSObject, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    private static var openEditors: [UUID: StudioShaderEditor] = [:]

    private let identity = UUID()
    private let window: NSWindow
    private let sourceView = NSTextView()
    private let speedField = NSTextField(string: "1")
    private let preset = NSPopUpButton()
    private let compileButton = NSButton(title: "Compile", target: nil, action: nil)
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let diagnosticsView = NSTextView()
    private let onApply: (SceneNode.Shader) -> String?
    private var compiledShader: SceneNode.Shader?

    static func present(shader: SceneNode.Shader, title: String,
                        onApply: @escaping (SceneNode.Shader) -> String?) {
        let editor = StudioShaderEditor(shader: shader, title: title, onApply: onApply)
        openEditors[editor.identity] = editor
        editor.window.center()
        editor.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(shader: SceneNode.Shader, title: String,
                 onApply: @escaping (SceneNode.Shader) -> String?) {
        self.onApply = onApply
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Metal Shader — " + title
        window.minSize = NSSize(width: 680, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self

        sourceView.isRichText = false
        sourceView.allowsUndo = true
        sourceView.isAutomaticQuoteSubstitutionEnabled = false
        sourceView.isAutomaticDashSubstitutionEnabled = false
        sourceView.isAutomaticSpellingCorrectionEnabled = false
        sourceView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        sourceView.textContainerInset = NSSize(width: 8, height: 8)
        sourceView.string = shader.source
        sourceView.delegate = self
        sourceView.setAccessibilityLabel("Metal shader source")

        diagnosticsView.isEditable = false
        diagnosticsView.isSelectable = true
        diagnosticsView.drawsBackground = false
        diagnosticsView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnosticsView.textColor = .secondaryLabelColor
        diagnosticsView.textContainerInset = NSSize(width: 6, height: 6)
        diagnosticsView.string = "Compile to validate this shader."
        diagnosticsView.setAccessibilityLabel("Shader compiler diagnostics")

        speedField.stringValue = String(format: "%.3g", shader.speed)
        speedField.widthAnchor.constraint(equalToConstant: 76).isActive = true
        speedField.delegate = self
        speedField.setAccessibilityLabel("Shader speed")

        preset.addItems(withTitles: ["Template…"] + StudioShaderTemplates.all.map(\.name))
        preset.target = self
        preset.action = #selector(loadTemplate)
        preset.setAccessibilityLabel("Shader template")

        compileButton.target = self
        compileButton.action = #selector(compileDraft)
        applyButton.target = self
        applyButton.action = #selector(applyDraft)
        applyButton.isEnabled = false
        let close = NSButton(title: "Close", target: self, action: #selector(closeEditor))

        let titleLabel = NSTextField(labelWithString: "Metal fragment source")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        let contract = NSTextField(wrappingLabelWithString:
            "Define shaderMain(V, ShaderU). V exposes uv, canvasUV and fade; ShaderU exposes time, resolution, pointer, audio and opacity. Custom uniforms remain a typed scene-control follow-up.")
        contract.textColor = .secondaryLabelColor
        contract.maximumNumberOfLines = 3

        let speedLabel = NSTextField(labelWithString: "Speed")
        let topControls = NSStackView(views: [preset, speedLabel, speedField, compileButton, applyButton, close])
        topControls.spacing = 8

        let sourceScroll = Self.scrollView(for: sourceView)
        let diagnosticsScroll = Self.scrollView(for: diagnosticsView)
        diagnosticsScroll.heightAnchor.constraint(equalToConstant: 118).isActive = true
        let diagnosticsLabel = NSTextField(labelWithString: "COMPILER DIAGNOSTICS")
        diagnosticsLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        diagnosticsLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleLabel, contract, topControls, sourceScroll, diagnosticsLabel, diagnosticsScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let root = window.contentView else { return }
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contract.widthAnchor.constraint(equalTo: stack.widthAnchor),
            topControls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sourceScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sourceScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            diagnosticsLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            diagnosticsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private static func scrollView(for textView: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        return scroll
    }

    private func draft() throws -> SceneNode.Shader {
        guard let speed = Double(speedField.stringValue) else {
            throw SceneError.invalid("Shader speed must be a number from 0.01 to 10.")
        }
        let shader = SceneNode.Shader(source: sourceView.string, speed: speed)
        try shader.validate()
        return shader
    }

    @discardableResult private func compileCurrent(showSuccess: Bool = true) -> SceneNode.Shader? {
        do {
            let shader = try draft()
            try StudioShaderCompiler.validate(shader)
            compiledShader = shader
            applyButton.isEnabled = true
            if showSuccess {
                showDiagnostics([.init(line: nil, column: nil, message: "Compiled successfully. Apply will create one Studio document edit.")], error: false)
            }
            return shader
        } catch let failure as StudioShaderCompileFailure {
            compiledShader = nil
            applyButton.isEnabled = false
            showDiagnostics(failure.diagnostics, error: true)
            if let first = failure.diagnostics.first(where: { $0.line != nil }) { reveal(first) }
            return nil
        } catch {
            compiledShader = nil
            applyButton.isEnabled = false
            showDiagnostics([.init(line: nil, column: nil, message: error.localizedDescription)], error: true)
            return nil
        }
    }

    private func invalidateCompilation(message: String = "Edited since the last compile. Compile again before applying.") {
        compiledShader = nil
        applyButton.isEnabled = false
        showDiagnostics([.init(line: nil, column: nil, message: message)], error: false)
    }

    private func showDiagnostics(_ diagnostics: [StudioShaderDiagnostic], error: Bool) {
        diagnosticsView.string = diagnostics.map(\.displayText).joined(separator: "\n")
        diagnosticsView.textColor = error ? .systemRed : .secondaryLabelColor
    }

    private func reveal(_ diagnostic: StudioShaderDiagnostic) {
        guard let line = diagnostic.line, line > 0 else { return }
        let text = sourceView.string as NSString
        var location = 0
        if line > 1 {
            for _ in 1..<line {
                let remaining = NSRange(location: location, length: max(0, text.length - location))
                let newline = text.range(of: "\n", options: [], range: remaining)
                if newline.location == NSNotFound { return }
                location = NSMaxRange(newline)
            }
        }
        let lineRange = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        let columnOffset = max(0, (diagnostic.column ?? 1) - 1)
        let caret = min(NSMaxRange(lineRange), lineRange.location + columnOffset)
        sourceView.setSelectedRange(NSRange(location: caret, length: 0))
        sourceView.scrollRangeToVisible(lineRange)
        window.makeFirstResponder(sourceView)
    }

    @objc private func compileDraft() { _ = compileCurrent() }

    @objc private func applyDraft() {
        guard let current = try? draft(), current == compiledShader else {
            _ = compileCurrent()
            return
        }
        if let message = onApply(current) {
            showDiagnostics([.init(line: nil, column: nil, message: message)], error: true)
            return
        }
        applyButton.isEnabled = false
        showDiagnostics([.init(line: nil, column: nil,
            message: "Applied to Studio. Undo/Redo and recovery now treat this as one document edit.")], error: false)
    }

    @objc private func loadTemplate() {
        guard preset.indexOfSelectedItem > 0 else { return }
        let template = StudioShaderTemplates.all[preset.indexOfSelectedItem - 1]
        sourceView.string = template.source
        speedField.stringValue = String(format: "%.3g", template.speed)
        preset.selectItem(at: 0)
        invalidateCompilation(message: "Loaded \(template.name). Compile it before applying.")
        window.makeFirstResponder(sourceView)
    }

    @objc private func closeEditor() { window.close() }

    func textDidChange(_ notification: Notification) { invalidateCompilation() }
    func controlTextDidChange(_ notification: Notification) { invalidateCompilation() }

    func windowWillClose(_ notification: Notification) {
        Self.openEditors.removeValue(forKey: identity)
    }
}
