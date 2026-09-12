import Foundation

@main struct VariantTests {
    static func reject(_ message: String, _ body: () throws -> Void) {
        do {
            try body()
            fatalError(message)
        } catch is SceneError {
        } catch {
        }
    }

    static func main() async throws {
        let gradient = SceneNode(content: .gradient)
        var type = SceneNode.Typography()
        type.text = "Default copy"
        type.fill = "#FFFFFF"
        let text = SceneNode(content: .text(type))

        var visible = SceneParameter(name: "Visible", type: .boolean, boolean: true)
        visible.targets = [.init(nodeID: text.id, property: .visible)]
        var accent = SceneParameter(name: "Accent", type: .color, text: "#FFFFFF")
        accent.targets = [.init(nodeID: text.id, property: .fill)]
        var blend = SceneParameter(name: "Blend", type: .choice, text: "normal",
            choices: ["normal", "add", "multiply", "screen"])
        blend.targets = [.init(nodeID: text.id, property: .blend)]
        var copy = SceneParameter(name: "Copy", type: .string, text: "Default copy")
        copy.targets = [.init(nodeID: text.id, property: .text)]

        let midnightID = UUID()
        let midnight = SceneVariant(id: midnightID, name: "Midnight", values: [
            "amount": .number(0.8),
            "visible": .boolean(false),
            "accent": .text("#112233"),
            "blend": .text("screen"),
            "copy": .text("Midnight copy")
        ])
        var authored = SceneDescriptor(title: "Variants", nodes: [gradient, text], parameters: [
            "amount": .init(name: "Amount", value: 0.3, min: 0, max: 1),
            "visible": visible,
            "accent": accent,
            "blend": blend,
            "copy": copy
        ], bindings: [
            .init(target: .init(nodeID: gradient.id, property: .opacity), parameter: "amount")
        ], variants: [midnight])

        _ = try authored.evaluated()
        precondition(SceneFormat.features(authored).contains("variants"))
        let applied = authored.applyingVariant(id: midnightID)
        precondition(applied.selectedVariantID == midnightID && applied.diagnostics.isEmpty)
        precondition(applied.scene.parameters["amount"]?.value == 0.8)
        precondition(applied.scene.parameters["visible"]?.boolean == false)
        precondition(applied.scene.parameters["accent"]?.text == "#112233")
        precondition(applied.scene.parameters["blend"]?.text == "screen")
        precondition(applied.scene.parameters["copy"]?.text == "Midnight copy")
        let effective = try applied.scene.evaluated()
        precondition(abs(effective.nodes[0].opacity - 0.8) < 0.00001)
        precondition(!effective.nodes[1].visible)
        precondition(effective.nodes[1].blend == .screen)
        precondition(effective.nodes[1].typography?.fill == "#112233")
        precondition(effective.nodes[1].typography?.text == "Midnight copy")

        // Sparse variants inherit future Default changes.
        let calmID = UUID()
        authored.variants.append(.init(id: calmID, name: "Calm", values: ["accent": .text("#334455")]))
        authored.parameters["amount"]?.value = 0.65
        let calm = authored.applyingVariant(id: calmID)
        precondition(calm.scene.parameters["amount"]?.value == 0.65)
        precondition(calm.scene.parameters["accent"]?.text == "#334455")

        // Stale controls degrade per override. The compatible portion still applies.
        let staleID = UUID()
        authored.variants.append(.init(id: staleID, name: "Old Look", values: [
            "amount": .number(0.7),
            "gone-control": .text("legacy"),
            "visible": .text("wrong type"),
            "blend": .text("overlay")
        ]))
        let stale = authored.applyingVariant(id: staleID)
        precondition(stale.selectedVariantID == staleID)
        precondition(stale.scene.parameters["amount"]?.value == 0.7)
        precondition(stale.scene.parameters["visible"]?.boolean == true)
        precondition(stale.scene.parameters["blend"]?.text == "normal")
        precondition(stale.diagnostics.count == 3)
        precondition(stale.diagnostics.contains { $0.controlID == "gone-control" && $0.reason == .missingControl })
        precondition(stale.diagnostics.contains { $0.controlID == "visible" && $0.reason == .incompatibleValue })
        precondition(stale.diagnostics.contains { $0.controlID == "blend" && $0.reason == .incompatibleValue })
        _ = try stale.scene.evaluated()

        let missingID = UUID()
        let missing = authored.applyingVariant(id: missingID)
        precondition(missing.selectedVariantID == nil)
        precondition(missing.diagnostics == [.init(variantID: missingID, controlID: nil, reason: .variantUnavailable)])
        precondition(authored.applyingVariant(id: nil).diagnostics.isEmpty)

        // Bounds are deliberate and independent from compatibility with current controls.
        let boundary = (0..<16).map { SceneVariant(id: UUID(), name: "Look \($0)", values: [:]) }
        try SceneVariant.validate(boundary)
        reject("Accepted seventeen variants") {
            try SceneVariant.validate(boundary + [.init(id: UUID(), name: "Look 16", values: [:])])
        }
        reject("Accepted duplicate variant identity") {
            try SceneVariant.validate([
                .init(id: midnightID, name: "A", values: [:]),
                .init(id: midnightID, name: "B", values: [:])
            ])
        }
        reject("Accepted duplicate case-insensitive variant name") {
            try SceneVariant.validate([
                .init(id: UUID(), name: "Night", values: [:]),
                .init(id: UUID(), name: "night", values: [:])
            ])
        }
        reject("Accepted seventeen overrides") {
            try SceneVariant.validate([.init(id: UUID(), name: "Too Many",
                values: Dictionary(uniqueKeysWithValues: (0..<17).map { ("k\($0)", .boolean(true)) }))])
        }
        reject("Accepted oversized variant payload") {
            try SceneVariant.validate((0..<5).map {
                .init(id: UUID(), name: "Large \($0)", values: ["legacy-\($0)": .text(String(repeating: "x", count: 3500))])
            })
        }
        reject("Accepted non-scalar variant value") {
            _ = try JSONDecoder().decode(SceneControlValue.self, from: Data(#"[1,2]"#.utf8))
        }

        // SceneDescriptor recovery/clipboard JSON from before variants remains decodable.
        let encodedDescriptor = try JSONEncoder().encode(authored)
        var oldObject = try JSONSerialization.jsonObject(with: encodedDescriptor) as! [String: Any]
        oldObject.removeValue(forKey: "variants")
        let oldData = try JSONSerialization.data(withJSONObject: oldObject)
        let migrated = try JSONDecoder().decode(SceneDescriptor.self, from: oldData)
        precondition(migrated.variants.isEmpty)

        // Rename preserves stable identity.
        var renamed = authored
        renamed.variants[0].name = "After Dark"
        precondition(renamed.variants[0].id == midnightID)

        let temp = FileManager.default.temporaryDirectory
        let package = temp.appendingPathComponent("variant-\(UUID().uuidString).idlesse")
        let defaultPackage = temp.appendingPathComponent("default-\(UUID().uuidString).idlesse")
        defer {
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: defaultPackage)
        }

        try ScenePackageWriter.write(authored, to: package)
        let loaded = try await LocalSceneSource().resolve(package)
        precondition(loaded.variants.count == authored.variants.count)
        precondition(loaded.variants[0].id == midnightID && loaded.variants[0].name == "Midnight")
        precondition(loaded.variants[0].values == midnight.values)
        let manifestData = try Data(contentsOf: package.appendingPathComponent("manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
        precondition((manifest["features"] as! [String]).contains("variants"))

        // The feature declaration is mandatory when a variant block is present.
        var missingFeature = manifest
        missingFeature["features"] = (manifest["features"] as! [String]).filter { $0 != "variants" }
        try JSONSerialization.data(withJSONObject: missingFeature).write(to: package.appendingPathComponent("manifest.json"))
        do {
            _ = try await LocalSceneSource().resolve(package)
            fatalError("Accepted variants without feature declaration")
        } catch is SceneError {}

        // Scenes with zero variants omit the block and feature.
        var defaultOnly = authored
        defaultOnly.variants = []
        try ScenePackageWriter.write(defaultOnly, to: defaultPackage)
        let defaultManifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: defaultPackage.appendingPathComponent("manifest.json"))) as! [String: Any]
        let defaultScene = try JSONSerialization.jsonObject(
            with: Data(contentsOf: defaultPackage.appendingPathComponent("scene.json"))) as! [String: Any]
        precondition(!(defaultManifest["features"] as! [String]).contains("variants"))
        precondition(defaultScene["variants"] == nil)

        print("variant tests passed")
    }
}
