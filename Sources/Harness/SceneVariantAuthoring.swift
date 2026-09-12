import Foundation

/// Draft state for Studio's Scene Controls sheet. The canonical scene stays separate
/// from the selected effective variant so switching looks never compounds deltas.
struct SceneVariantAuthoringState {
    enum Origin: Equatable { case defaultValue, inherited, overridden }

    private(set) var scene: SceneDescriptor
    private(set) var selectedID: UUID?

    init(scene: SceneDescriptor, selectedID: UUID? = nil) {
        self.scene = scene
        self.selectedID = selectedID.flatMap { id in scene.variants.contains(where: { $0.id == id }) ? id : nil }
    }

    var selectedVariant: SceneVariant? {
        guard let selectedID else { return nil }
        return scene.variants.first { $0.id == selectedID }
    }

    var application: SceneVariantApplication { scene.applyingVariant(id: selectedID) }
    var visibleParameters: [String: SceneParameter] { application.scene.parameters }
    var unavailableCount: Int { application.diagnostics.filter { $0.controlID != nil }.count }

    func origin(for controlID: String) -> Origin {
        guard let selectedVariant else { return .defaultValue }
        return selectedVariant.values[controlID] == nil ? .inherited : .overridden
    }

    mutating func select(_ id: UUID?) {
        selectedID = id.flatMap { candidate in scene.variants.contains(where: { $0.id == candidate }) ? candidate : nil }
    }

    mutating func updateVisibleParameters(_ values: [String: SceneParameter]) throws {
        guard Set(values.keys) == Set(scene.parameters.keys), values.values.allSatisfy(\.isValid) else {
            throw SceneError.invalid("Scene control values changed while the variant editor was open.")
        }
        guard let selectedID, let index = scene.variants.firstIndex(where: { $0.id == selectedID }) else {
            scene.parameters = values
            return
        }
        var overrides = scene.variants[index].values
        for key in scene.parameters.keys {
            guard let value = values[key], let authored = scene.parameters[key], value.type == authored.type else {
                throw SceneError.invalid("A scene control changed type while the variant editor was open.")
            }
            let current = SceneControlValue(value)
            let fallback = SceneControlValue(authored)
            if current == fallback { overrides.removeValue(forKey: key) }
            else { overrides[key] = current }
        }
        scene.variants[index].values = overrides
        try SceneVariant.validate(scene.variants)
    }

    mutating func useDefault(_ controlID: String) {
        guard let selectedID, let index = scene.variants.firstIndex(where: { $0.id == selectedID }) else { return }
        scene.variants[index].values.removeValue(forKey: controlID)
    }

    @discardableResult mutating func create(name: String) throws -> UUID {
        guard scene.variants.count < SceneVariant.maximumCount else { throw SceneError.invalid("Use at most 16 scene variants.") }
        let clean = try validatedName(name, excluding: nil)
        let effective = visibleParameters
        var values: [String: SceneControlValue] = [:]
        for key in scene.parameters.keys {
            guard let current = effective[key], let fallback = scene.parameters[key] else { continue }
            let value = SceneControlValue(current)
            if value != SceneControlValue(fallback) { values[key] = value }
        }
        let id = UUID()
        scene.variants.append(.init(id: id, name: clean, values: values))
        try SceneVariant.validate(scene.variants)
        selectedID = id
        return id
    }

    mutating func renameSelected(_ name: String) throws {
        guard let selectedID, let index = scene.variants.firstIndex(where: { $0.id == selectedID }) else { return }
        scene.variants[index].name = try validatedName(name, excluding: selectedID)
        try SceneVariant.validate(scene.variants)
    }

    @discardableResult mutating func duplicateSelected() throws -> UUID {
        guard scene.variants.count < SceneVariant.maximumCount else { throw SceneError.invalid("Use at most 16 scene variants.") }
        let source = selectedVariant
        let base = source?.name ?? "Default"
        let id = UUID()
        scene.variants.append(.init(id: id, name: uniqueCopyName(base), values: source?.values ?? [:]))
        try SceneVariant.validate(scene.variants)
        selectedID = id
        return id
    }

    mutating func deleteSelected() {
        guard let selectedID else { return }
        scene.variants.removeAll { $0.id == selectedID }
        self.selectedID = nil
    }

    /// Saving from Studio repairs stale variant entries while retaining every
    /// compatible override. Runtime application itself remains degradation-only.
    @discardableResult mutating func normalizeStaleOverrides() -> [SceneVariantDiagnostic] {
        var removed: [SceneVariantDiagnostic] = []
        for index in scene.variants.indices {
            let id = scene.variants[index].id
            for key in Array(scene.variants[index].values.keys) {
                guard let value = scene.variants[index].values[key] else { continue }
                guard let parameter = scene.parameters[key] else {
                    scene.variants[index].values.removeValue(forKey: key)
                    removed.append(.init(variantID: id, controlID: key, reason: .missingControl))
                    continue
                }
                guard value.applying(to: parameter) != nil else {
                    scene.variants[index].values.removeValue(forKey: key)
                    removed.append(.init(variantID: id, controlID: key, reason: .incompatibleValue))
                    continue
                }
                if value == SceneControlValue(parameter) { scene.variants[index].values.removeValue(forKey: key) }
            }
        }
        return removed
    }

    mutating func pruneRemovedControls() {
        let keys = Set(scene.parameters.keys)
        for index in scene.variants.indices {
            scene.variants[index].values = scene.variants[index].values.filter { keys.contains($0.key) }
        }
    }

    private func validatedName(_ name: String, excluding id: UUID?) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 80,
              !scene.variants.contains(where: { $0.id != id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(clean) == .orderedSame }) else {
            throw SceneError.invalid("Use a unique variant name of 1–80 characters.")
        }
        return clean
    }

    private func uniqueCopyName(_ base: String) -> String {
        let existing = Set(scene.variants.map { $0.name.lowercased() })
        var suffix = 1
        while true {
            let label = suffix == 1 ? "\(base) Copy" : "\(base) Copy \(suffix)"
            if label.count <= 80, !existing.contains(label.lowercased()) { return label }
            suffix += 1
        }
    }
}
