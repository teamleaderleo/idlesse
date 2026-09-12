import Foundation

/// Shader-authored inputs stay inside the existing SceneParameter model. A control opts
/// into one of eight fixed GPU slots with a readable suffix on its persisted name:
/// `Gain [shader:0:gain]`. Studio hides the suffix in the ordinary Controls UI.
struct MetalShaderInput: Equatable, Sendable {
    static let maxInputs = 8
    static let maxDeclarationBytes = 8_192
    static let maxIdentifierBytes = 24

    struct Signature: Equatable, Sendable {
        let id: String
        let slot: Int
    }

    let id: String
    let slot: Int
    let parameter: SceneParameter

    private static let reservedIdentifiers: Set<String> = [
        "alignas", "bool", "break", "case", "char", "class", "constant", "constexpr", "continue",
        "default", "device", "do", "double", "else", "enum", "false", "float", "for", "fragment",
        "half", "if", "int", "long", "namespace", "nullptr", "private", "public", "return", "sampler",
        "short", "signed", "sizeof", "static", "struct", "switch", "template", "texture2d", "thread",
        "threadgroup", "true", "typedef", "uint", "uniform", "union", "unsigned", "using", "vertex",
        "void", "while"
    ]

    private static let markerPattern = #"^(.*?) \[shader:([0-7]):([A-Za-z_][A-Za-z0-9_]*)\]$"#

    static func declaredName(_ displayName: String, slot: Int, id: String) throws -> String {
        try validateIdentifier(id)
        guard (0..<maxInputs).contains(slot) else { throw SceneError.invalid("Shader input slots are 0–7.") }
        let label = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = "\(label) [shader:\(slot):\(id)]"
        guard !label.isEmpty, encoded.count <= 80 else {
            throw SceneError.invalid("Shader input labels plus their slot declaration may use at most 80 characters.")
        }
        return encoded
    }

    static func displayName(_ persistedName: String) -> String {
        declaration(in: persistedName)?.displayName ?? persistedName
    }

    private static func declaration(in persistedName: String) -> (displayName: String, slot: Int, id: String)? {
        guard let regex = try? NSRegularExpression(pattern: markerPattern),
              let match = regex.firstMatch(in: persistedName,
                  range: NSRange(persistedName.startIndex..<persistedName.endIndex, in: persistedName)),
              match.range.location != NSNotFound else { return nil }
        func capture(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: persistedName) else { return nil }
            return String(persistedName[range])
        }
        guard let name = capture(1), let slotText = capture(2), let slot = Int(slotText), let id = capture(3) else { return nil }
        return (name, slot, id)
    }

    static func keyPrefix(nodeID: UUID) -> String {
        "shader." + nodeID.uuidString.lowercased().replacingOccurrences(of: "-", with: "") + "."
    }

    static func parameterKey(nodeID: UUID, id: String) -> String { keyPrefix(nodeID: nodeID) + id }

    static func owns(_ key: String, nodeID: UUID) -> Bool { key.hasPrefix(keyPrefix(nodeID: nodeID)) }

    /// Returns the reserved node-scoped parameter key for a control carrying shader metadata.
    /// Ordinary scene controls return nil and keep their existing UUID key path.
    static func preferredParameterKey(_ parameter: SceneParameter, nodeID: UUID) -> String? {
        guard let value = declaration(in: parameter.name) else { return nil }
        return parameterKey(nodeID: nodeID, id: value.id)
    }

    static func inputs(nodeID: UUID, parameters: [String: SceneParameter]) throws -> [MetalShaderInput] {
        let prefix = keyPrefix(nodeID: nodeID)
        var result: [MetalShaderInput] = []
        var slots = Set<Int>()
        var ids = Set<String>()
        for (key, parameter) in parameters where key.hasPrefix(prefix) {
            let keyID = String(key.dropFirst(prefix.count))
            try validateIdentifier(keyID)
            guard let declaration = declaration(in: parameter.name), declaration.id == keyID else {
                throw SceneError.invalid("Shader input parameter keys must match their declared identifier.")
            }
            try validateIdentifier(declaration.id)
            guard parameter.targets.isEmpty, parameter.isValid,
                  [.number, .boolean, .color, .choice].contains(parameter.type) else {
                throw SceneError.invalid("Shader input ‘\(declaration.id)’ must be a valid number, color, toggle or choice without a layer-property target.")
            }
            guard slots.insert(declaration.slot).inserted else {
                throw SceneError.invalid("Shader input slot \(declaration.slot) is declared more than once on this shader layer.")
            }
            guard ids.insert(declaration.id).inserted else {
                throw SceneError.invalid("Shader input id ‘\(declaration.id)’ is declared more than once on this shader layer.")
            }
            result.append(.init(id: declaration.id, slot: declaration.slot, parameter: parameter))
        }
        guard result.count <= maxInputs else { throw SceneError.invalid("Use at most \(maxInputs) shader inputs per shader layer.") }
        return result.sorted { lhs, rhs in lhs.slot == rhs.slot ? lhs.id < rhs.id : lhs.slot < rhs.slot }
    }

    static func declarationSignature(nodeID: UUID, parameters: [String: SceneParameter]) throws -> [Signature] {
        try inputs(nodeID: nodeID, parameters: parameters).map { Signature(id: $0.id, slot: $0.slot) }
    }

    /// JSON-lines is the package/test declaration form. It immediately becomes ordinary
    /// SceneParameters; the declaration text itself is never a second persisted value store.
    static func replacingDeclarations(_ text: String, nodeID: UUID,
                                      parameters: [String: SceneParameter]) throws -> [String: SceneParameter] {
        guard text.utf8.count <= maxDeclarationBytes else {
            throw SceneError.invalid("Shader input declarations may use at most \(maxDeclarationBytes) UTF-8 bytes.")
        }
        let lines = text.split(whereSeparator: { $0.isNewline }).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard lines.count <= maxInputs else { throw SceneError.invalid("Use at most \(maxInputs) shader inputs per shader layer.") }

        var next = parameters.filter { !owns($0.key, nodeID: nodeID) }
        var seenSlots = Set<Int>()
        var seenIDs = Set<String>()
        for (index, line) in lines.enumerated() {
            let input = try parse(line, lineNumber: index + 1, fallbackSlot: index)
            guard seenSlots.insert(input.slot).inserted else {
                throw SceneError.invalid("Shader input declaration line \(index + 1) repeats slot \(input.slot).")
            }
            guard seenIDs.insert(input.id).inserted else {
                throw SceneError.invalid("Shader input declaration line \(index + 1) repeats id ‘\(input.id)’.")
            }
            next[parameterKey(nodeID: nodeID, id: input.id)] = input.parameter
        }
        guard next.count <= 16 else {
            throw SceneError.invalid("Shader inputs share the scene limit of 16 controls. Remove another control or input first.")
        }
        return next
    }

    static func declarationText(nodeID: UUID, parameters: [String: SceneParameter]) throws -> String {
        try inputs(nodeID: nodeID, parameters: parameters).map { input in
            var object: [String: Any] = [
                "id": input.id,
                "slot": input.slot,
                "name": displayName(input.parameter.name),
                "type": input.parameter.type.rawValue
            ]
            switch input.parameter.type {
            case .number:
                object["default"] = input.parameter.value
                object["min"] = input.parameter.min
                object["max"] = input.parameter.max
            case .boolean:
                object["default"] = input.parameter.boolean
            case .color:
                object["default"] = input.parameter.text
            case .choice:
                object["default"] = input.parameter.text
                object["choices"] = input.parameter.choices
            case .string:
                preconditionFailure("String parameters are not shader inputs")
            }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard let line = String(data: data, encoding: .utf8) else {
                throw SceneError.invalid("Could not serialize shader input declarations.")
            }
            return line
        }.joined(separator: "\n")
    }

    /// The Metal ABI is always the same fixed slot block. Human-authored identifiers are
    /// package/Studio metadata only and are never injected into user Metal source.
    static func metalDeclaration(_ inputs: [MetalShaderInput] = []) -> String {
        _ = inputs
        var lines = ["struct ShaderInputs {"]
        for index in 0..<maxInputs { lines.append("    float4 slot\(index);") }
        lines.append("};")
        return lines.joined(separator: "\n")
    }

    var vector: SIMD4<Float> {
        switch parameter.type {
        case .number:
            return SIMD4(Float(parameter.value), 0, 0, 0)
        case .boolean:
            return SIMD4(parameter.boolean ? 1 : 0, 0, 0, 0)
        case .choice:
            return SIMD4(Float(parameter.choices.firstIndex(of: parameter.text) ?? 0), 0, 0, 0)
        case .color:
            let digits = String(parameter.text.dropFirst())
            let raw = UInt64(digits, radix: 16) ?? 0
            let rgba: UInt64 = digits.count == 8 ? raw : (raw << 8) | 0xff
            return SIMD4(Float((rgba >> 24) & 0xff) / 255,
                         Float((rgba >> 16) & 0xff) / 255,
                         Float((rgba >> 8) & 0xff) / 255,
                         Float(rgba & 0xff) / 255)
        case .string:
            return .zero
        }
    }

    private static func validateIdentifier(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= maxIdentifierBytes,
              id.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
              !id.hasPrefix("idlesse"), !reservedIdentifiers.contains(id) else {
            throw SceneError.invalid("Shader input ids use 1–\(maxIdentifierBytes) ASCII letters, digits or underscores, begin with a letter/underscore, and cannot be Metal keywords or the reserved idlesse prefix.")
        }
    }

    private static func parse(_ line: String, lineNumber: Int, fallbackSlot: Int) throws -> MetalShaderInput {
        guard let data = line.data(using: .utf8) else {
            throw SceneError.invalid("Shader input declaration line \(lineNumber) is not UTF-8.")
        }
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: data) }
        catch { throw SceneError.invalid("Shader input declaration line \(lineNumber) is invalid JSON: \(error.localizedDescription)") }
        guard let object = raw as? [String: Any],
              let id = object["id"] as? String,
              let name = object["name"] as? String,
              let typeName = object["type"] as? String,
              let type = SceneParameter.ValueType(rawValue: typeName) else {
            throw SceneError.invalid("Shader input declaration line \(lineNumber) needs string id, name and type fields.")
        }
        try validateIdentifier(id)
        let slot = (object["slot"] as? NSNumber)?.intValue ?? fallbackSlot
        guard (0..<maxInputs).contains(slot) else { throw SceneError.invalid("Shader input declaration line \(lineNumber) needs slot 0–7.") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SceneError.invalid("Shader input declaration line \(lineNumber) needs a display name.")
        }

        func keys(_ allowed: Set<String>) throws {
            guard Set(object.keys).isSubset(of: allowed) else {
                throw SceneError.invalid("Shader input declaration line \(lineNumber) contains unsupported fields.")
            }
        }
        func number(_ key: String) throws -> Double {
            guard !(object[key] is Bool), let value = object[key] as? NSNumber,
                  value.doubleValue.isFinite else {
                throw SceneError.invalid("Shader input declaration line \(lineNumber) needs a finite numeric ‘\(key)’ value.")
            }
            return value.doubleValue
        }

        var parameter: SceneParameter
        switch type {
        case .number:
            try keys(["id", "slot", "name", "type", "default", "min", "max"])
            parameter = .init(name: name, value: try number("default"), min: try number("min"), max: try number("max"))
        case .boolean:
            try keys(["id", "slot", "name", "type", "default"])
            guard let value = object["default"] as? Bool else { throw SceneError.invalid("Shader input declaration line \(lineNumber) needs a boolean default.") }
            parameter = .init(name: name, type: .boolean, boolean: value)
        case .color:
            try keys(["id", "slot", "name", "type", "default"])
            guard let value = object["default"] as? String else { throw SceneError.invalid("Shader input declaration line \(lineNumber) needs a color default.") }
            parameter = .init(name: name, type: .color, text: value)
        case .choice:
            try keys(["id", "slot", "name", "type", "default", "choices"])
            guard let value = object["default"] as? String, let choices = object["choices"] as? [String] else {
                throw SceneError.invalid("Shader input declaration line \(lineNumber) needs string default and choices fields.")
            }
            parameter = .init(name: name, type: .choice, text: value, choices: choices)
        case .string:
            throw SceneError.invalid("Shader inputs support number, color, boolean and choice types.")
        }
        parameter.name = try declaredName(name, slot: slot, id: id)
        guard parameter.isValid else {
            throw SceneError.invalid("Shader input declaration line \(lineNumber) has an invalid default, range or choices list.")
        }
        return .init(id: id, slot: slot, parameter: parameter)
    }
}

/// Fixed 8 × float4 ABI for user shader inputs.
struct MetalShaderInputUniforms {
    var slot0 = SIMD4<Float>.zero
    var slot1 = SIMD4<Float>.zero
    var slot2 = SIMD4<Float>.zero
    var slot3 = SIMD4<Float>.zero
    var slot4 = SIMD4<Float>.zero
    var slot5 = SIMD4<Float>.zero
    var slot6 = SIMD4<Float>.zero
    var slot7 = SIMD4<Float>.zero

    init(_ inputs: [MetalShaderInput]) {
        for input in inputs {
            switch input.slot {
            case 0: slot0 = input.vector
            case 1: slot1 = input.vector
            case 2: slot2 = input.vector
            case 3: slot3 = input.vector
            case 4: slot4 = input.vector
            case 5: slot5 = input.vector
            case 6: slot6 = input.vector
            case 7: slot7 = input.vector
            default: break
            }
        }
    }
}
