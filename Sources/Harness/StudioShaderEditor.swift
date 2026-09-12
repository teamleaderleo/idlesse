import AppKit
import Metal

/// Studio-only compiler that mirrors the runtime shader interface while mapping
/// diagnostics back to the author's snippet line numbers.
enum StudioShaderCompiler {
    struct Template {
        let name: String
        let source: String
    }

    static let templates: [Template] = [
        .init(name: "Plasma", source: SceneNode.Shader.plasma),
        .init(name: "Soft Rings", source: """
        fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]) {
            float2 p = (in.uv - 0.5) * u.resolution / min(u.resolution.x, u.resolution.y);
            float d = length(p);
            float wave = 0.5 + 0.5 * cos(d * 30.0 - u.time * 3.0);
            float glow = smoothstep(0.18, 1.0, wave) * exp(-d * 0.9);
            float3 color = mix(float3(0.015, 0.025, 0.07), float3(0.12, 0.72, 1.0), glow);
            return float4(color * u.opacity, u.opacity);
        }
        """),
        .init(name: "Pointer Glow", source: """
        fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]) {
            float2 pointer = float2(u.pointer.x, -u.pointer.y) * 0.5 + 0.5;
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 delta = in.uv - pointer;
            delta.x *= aspect;
            float glow = exp(-12.0 * length(delta));
            float3 base = 0.12 + 0.08 * cos(u.time * 0.7 + float3(0.0, 2.1, 4.2));
            float3 color = base + glow * float3(0.9, 0.45, 0.18);
            return float4(clamp(color, 0.0, 1.0) * u.opacity, u.opacity);
        }
        """),
        .init(name: "Drifting Grid", source: """
        fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]) {
            float2 uv = in.uv;
            uv.x += u.time * 0.035;
            uv.y -= u.time * 0.02;
            float2 cell = abs(fract(uv * 10.0) - 0.5);
            float lines = 1.0 - smoothstep(0.43, 0.49, max(cell.x, cell.y));
            float pulse = 0.55 + 0.45 * sin(u.time + in.uv.y * 6.0);
            float3 color = mix(float3(0.025, 0.03, 0.07), float3(0.28, 0.78, 0.66), lines * pulse);
            return float4(color * u.opacity, u.opacity);
        }
        """)
    ]

    private static let prelude = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position [[position]]; float2 uv; float fade; float2 canvasUV; };
    struct ShaderU { float time; float2 resolution; float2 pointer; float audio; float opacity; };
    """

    private static let probeVertex = """
    vertex V __idlesseStudioVertex(uint id [[vertex_id]]) {
        float2 p = float2(id & 1, id >> 1) * 2.0 - 1.0;
        return {float4(p, 0, 1), float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5), 1.0, float2(0.0)};
    }
    """

    static func compile(_ shader: SceneNode.Shader) throws {
        try shader.validate()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SceneError.invalid("Metal is unavailable on this Mac.")
        }
        let source = prelude + "\n#line 1 \"Shader\"\n" + shader.source + "\n#line 1 \"StudioProbe\"\n" + probeVertex
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw SceneError.invalid(normalizedDiagnostic(error.localizedDescription))
        }
        guard let fragment = library.makeFunction(name: "shaderMain") else {
            throw SceneError.invalid("Shader must define fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]).")
        }
        guard let vertex = library.makeFunction(name: "__idlesseStudioVertex") else {
            throw SceneError.invalid("Studio could not prepare the shader compile probe.")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0]!.pixelFormat = .bgra8Unorm
        do {
            _ = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw SceneError.invalid(normalizedDiagnostic(error.localizedDescription))
        }
    }

    static func normalizedDiagnostic(_ message: String) -> String {
        let lines = message.split(whereSeparator: \.isNewline).map(String.init)
        let useful = lines.filter { line in
            line.localizedCaseInsensitiveContains("error:") || line.localizedCaseInsensitiveContains("warning:") || line.hasPrefix("Shader:")
        }
        let selected = useful.isEmpty ? lines : useful
        let cleaned = selected.map { line -> String in
            if line.hasPrefix("Shader:") { return "Line " + String(line.dropFirst("Shader:".count)) }
            return line.replacingOccurrences(of: "program_source:", with: "Source ")
        }
        return cleaned.joined(separator: "\n")
    }
}

/// Native source editor kept inside the persistent inspector. Drafts remain local
/// until Apply so a compiler failure cannot replace the current rendered shader.
final class StudioShaderEditorView: NSStackView {
    private let sourceEditor = NSTextView()
    private let speedField = NSTextField(string: "")
    private let speedStepper = NSStepper()
    private let templates = NSPopUpButton()
    private let diagnostic = NSTextField(wrappingLabelWithString: "")
    private let compileButton = NSButton(title: "Compile", target: nil, action: nil)
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let onApply: (SceneNode.Shader) -> Void

    init(shader: SceneNode.Shader, editable: Bool, onApply: @escaping (SceneNode.Shader) -> Void) {
        self.onApply = onApply
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 7
        widthAnchor.constraint(equalToConstant: 270).isActive = true

        let hint = NSTextField(wrappingLabelWithString: "Metal fragment snippet · V + ShaderU: time, resolution, pointer, audio, opacity")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 270
        addArrangedSubview(hint)

        templates.addItem(withTitle: "Templates…")
        templates.addItems(withTitles: StudioShaderCompiler.templates.map(\.name))
        templates.target = self
        templates.action = #selector(loadTemplate)
        templates.isEnabled = editable
        templates.setAccessibilityLabel("Shader template")
        templates.widthAnchor.constraint(equalToConstant: 180).isActive = true
        addArrangedSubview(templates)

        sourceEditor.isRichText = false
        sourceEditor.isAutomaticQuoteSubstitutionEnabled = false
        sourceEditor.isAutomaticDashSubstitutionEnabled = false
        sourceEditor.isContinuousSpellCheckingEnabled = false
        sourceEditor.allowsUndo = true
        sourceEditor.usesFindPanel = true
        sourceEditor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        sourceEditor.textContainerInset = NSSize(width: 6, height: 6)
        sourceEditor.string = shader.source
        sourceEditor.isEditable = editable
        sourceEditor.setAccessibilityLabel("Shader source")
        sourceEditor.isVerticallyResizable = true
        sourceEditor.isHorizontallyResizable = true
        sourceEditor.autoresizingMask = [.width]
        sourceEditor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        sourceEditor.textContainer?.widthTracksTextView = false
        sourceEditor.frame = NSRect(x: 0, y: 0, width: 520, height: 220)

        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = sourceEditor
        scroll.widthAnchor.constraint(equalToConstant: 270).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        addArrangedSubview(scroll)

        speedField.stringValue = Self.speedString(shader.speed)
        speedField.setAccessibilityLabel("Shader speed")
        speedField.isEnabled = editable
        speedField.target = self
        speedField.action = #selector(speedFieldChanged)
        speedField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        speedStepper.minValue = 0.01
        speedStepper.maxValue = 10
        speedStepper.increment = 0.1
        speedStepper.doubleValue = shader.speed
        speedStepper.isEnabled = editable
        speedStepper.target = self
        speedStepper.action = #selector(speedStepChanged)
        speedStepper.setAccessibilityLabel("Shader speed stepper")
        let speedRow = NSStackView(views: [NSTextField(labelWithString: "Speed"), speedField, speedStepper])
        speedRow.spacing = 6
        addArrangedSubview(speedRow)

        compileButton.target = self
        compileButton.action = #selector(compileDraft)
        compileButton.isEnabled = editable
        applyButton.target = self
        applyButton.action = #selector(applyDraft)
        applyButton.isEnabled = editable
        let buttons = NSStackView(views: [compileButton, applyButton])
        buttons.spacing = 6
        addArrangedSubview(buttons)

        diagnostic.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        diagnostic.textColor = .secondaryLabelColor
        diagnostic.isSelectable = true
        diagnostic.preferredMaxLayoutWidth = 270
        diagnostic.widthAnchor.constraint(equalToConstant: 270).isActive = true
        diagnostic.setAccessibilityLabel("Shader compiler result")
        addArrangedSubview(diagnostic)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func speedString(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    @objc private func speedStepChanged() {
        speedField.stringValue = Self.speedString(speedStepper.doubleValue)
        clearDiagnostic()
    }

    @objc private func speedFieldChanged() {
        if let value = Double(speedField.stringValue), value.isFinite, (0.01...10).contains(value) {
            speedStepper.doubleValue = value
            speedField.stringValue = Self.speedString(value)
            clearDiagnostic()
        }
    }

    @objc private func loadTemplate() {
        let index = templates.indexOfSelectedItem - 1
        guard StudioShaderCompiler.templates.indices.contains(index) else { return }
        sourceEditor.string = StudioShaderCompiler.templates[index].source
        templates.selectItem(at: 0)
        diagnostic.stringValue = "Template loaded · Compile or Apply"
        diagnostic.textColor = .secondaryLabelColor
    }

    private func draft() throws -> SceneNode.Shader {
        guard let speed = Double(speedField.stringValue), speed.isFinite else {
            throw SceneError.invalid("Speed must be a number from 0.01 to 10.")
        }
        let shader = SceneNode.Shader(source: sourceEditor.string, speed: speed)
        try shader.validate()
        return shader
    }

    private func compiledDraft() throws -> SceneNode.Shader {
        let shader = try draft()
        try StudioShaderCompiler.compile(shader)
        return shader
    }

    @objc private func compileDraft() {
        do {
            _ = try compiledDraft()
            diagnostic.stringValue = "Compiled successfully."
            diagnostic.textColor = .systemGreen
        } catch {
            diagnostic.stringValue = error.localizedDescription
            diagnostic.textColor = .systemRed
        }
    }

    @objc private func applyDraft() {
        do {
            let shader = try compiledDraft()
            diagnostic.stringValue = "Compiled successfully. Applying…"
            diagnostic.textColor = .systemGreen
            onApply(shader)
        } catch {
            diagnostic.stringValue = error.localizedDescription
            diagnostic.textColor = .systemRed
        }
    }

    private func clearDiagnostic() {
        if !diagnostic.stringValue.isEmpty {
            diagnostic.stringValue = "Draft changed · Compile or Apply"
            diagnostic.textColor = .secondaryLabelColor
        }
    }
}
