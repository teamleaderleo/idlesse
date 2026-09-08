import Foundation

@main struct SceneTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".idlesse")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("manifest.json")
        let scene = root.appendingPathComponent("scene.json")
        try Data(#"{"version":1,"title":"Example","capabilities":[]}"#.utf8).write(to: manifest)
        try Data().write(to: root.appendingPathComponent("picture.png"))
        func setScene(_ asset: String) throws {
            let object: [String: Any] = ["layers": [["type": "image", "asset": asset]]]
            try JSONSerialization.data(withJSONObject: object).write(to: scene)
        }
        let source = LocalSceneSource()
        try setScene("picture.png")
        let result = try await source.resolve(root)
        precondition(result.kind == .image && result.title == "Example")
        try Data(#"{"layers":[{"type":"image","asset":"picture.png"},{"type":"image","asset":"picture.png","opacity":0.3}]}"#.utf8).write(to: scene)
        let layered = try await source.resolve(root)
        precondition(layered.nodes.count == 2 && layered.nodes[1].opacity == 0.3)
        try Data(#"{"layers":[{"type":"image","asset":"picture.png","opacity":2}]}"#.utf8).write(to: scene)
        do { _ = try await source.resolve(root); fatalError("Accepted invalid opacity") }
        catch is SceneError {}
        try Data(#"{"version":2,"title":"Aurora","capabilities":[]}"#.utf8).write(to: manifest)
        try Data(#"{"nodes":[{"type":"gradient","transform":{"x":0.1,"scale":0.8,"rotation":15}}]}"#.utf8).write(to: scene)
        let gradient = try await source.resolve(root)
        precondition(gradient.nodes[0].kind == .gradient && gradient.nodes[0].assetURL == nil)
        precondition(gradient.nodes[0].transform.scale == 0.8)
        try Data(#"{"nodes":[{"type":"gradient","transform":{"scale":0}}]}"#.utf8).write(to: scene)
        do { _ = try await source.resolve(root); fatalError("Accepted zero scale") }
        catch is SceneError {}
        var instant = 10.0
        let clock = SceneClock(now: { instant })
        precondition(clock.time == 0)
        clock.setPaused(false)
        instant = 12
        precondition(clock.time == 2)
        clock.setPaused(true)
        instant = 100
        precondition(clock.time == 2)
        clock.setPaused(false)
        instant = 101
        precondition(clock.time == 3)
        try Data(#"{"version":1,"title":"Example","capabilities":[]}"#.utf8).write(to: manifest)
        // Resolution is metadata-only; decoding this empty fixture belongs to the renderer.
        for path in ["../outside.png", "/tmp/outside.png", "https://example.com/picture.png"] {
            try setScene(path)
            do { _ = try await source.resolve(root); fatalError("Accepted invalid asset path") }
            catch is SceneError {}
        }
        try setScene("picture.png")
        try Data(repeating: 32, count: 65_537).write(to: manifest)
        do { _ = try await source.resolve(root); fatalError("Accepted oversized manifest") }
        catch is SceneError {}
        let exported = root.deletingLastPathComponent().appendingPathComponent("copy-\(UUID().uuidString).idlesse")
        defer { try? FileManager.default.removeItem(at: exported) }
        try ScenePackageWriter.write(gradient, to: exported)
        let roundTrip = try await source.resolve(exported)
        precondition(roundTrip.nodes[0].transform.scale == 0.8 && roundTrip.nodes[0].kind == .gradient)
        do { try ScenePackageWriter.write(gradient, to: exported); fatalError("Replaced existing package") }
        catch is SceneError {}
        let mediaExport = root.deletingLastPathComponent().appendingPathComponent("media-\(UUID().uuidString).idlesse")
        defer { try? FileManager.default.removeItem(at: mediaExport) }
        var foreground = result.nodes[0]
        foreground.opacity = 0.4
        foreground.transform = .init(x: 0.2, y: -0.1, scale: 0.6, rotation: 15)
        let composition = SceneDescriptor(title: "Layers", nodes: [gradient.nodes[0], foreground])
        try ScenePackageWriter.write(composition, to: mediaExport)
        let mediaRoundTrip = try await source.resolve(mediaExport)
        precondition(mediaRoundTrip.nodes[1].assetURL!.path.hasPrefix(mediaExport.path + "/assets/"))
        precondition(mediaRoundTrip.nodes.count == 2 && mediaRoundTrip.nodes[0].kind == .gradient)
        precondition(mediaRoundTrip.nodes[1].opacity == 0.4 && mediaRoundTrip.nodes[1].transform.x == 0.2)
        let copiedBytes = try Data(contentsOf: mediaRoundTrip.nodes[1].assetURL!)
        precondition(copiedBytes == Data())
        // Save-in-place validates before replacement and detects outside edits.
        let revision = try ScenePackageWriter.revision(of: mediaExport)
        var renamed = mediaRoundTrip.nodes[1]
        renamed.name = "Foreground"
        let edited = SceneDescriptor(title: "Edited", nodes: [mediaRoundTrip.nodes[0], renamed])
        try ScenePackageWriter.write(edited, to: mediaExport, replacing: revision)
        let saved = try await source.resolve(mediaExport)
        precondition(saved.title == "Edited" && saved.nodes[1].name == "Foreground")
        precondition(saved.nodes[1].assetURL == mediaRoundTrip.nodes[1].assetURL)
        let savedRevision = try ScenePackageWriter.revision(of: mediaExport)
        do {
            try ScenePackageWriter.write(SceneDescriptor(title: "Invalid", nodes: []), to: mediaExport, replacing: savedRevision)
            fatalError("Invalid replacement succeeded")
        } catch is SceneError {}
        let afterInvalid = try ScenePackageWriter.revision(of: mediaExport)
        precondition(afterInvalid == savedRevision)
        let metadata = mediaExport.appendingPathComponent("scene.json")
        var changed = try Data(contentsOf: metadata)
        changed.append(10)
        try changed.write(to: metadata)
        do {
            try ScenePackageWriter.write(edited, to: mediaExport, replacing: savedRevision)
            fatalError("Overwrote an outside edit")
        } catch is SceneError {}
        let afterConflict = try Data(contentsOf: metadata)
        precondition(afterConflict == changed)
        let currentRevision = try ScenePackageWriter.revision(of: mediaExport)
        try ScenePackageWriter.write(gradient, to: mediaExport, replacing: currentRevision)
        precondition(!FileManager.default.fileExists(atPath: renamed.assetURL!.path))
        let linked = root.deletingLastPathComponent().appendingPathComponent("linked-\(UUID().uuidString).idlesse")
        defer { try? FileManager.default.removeItem(at: linked) }
        try ScenePackageWriter.write(gradient, to: linked)
        let linkedAssets = linked.appendingPathComponent("assets")
        try FileManager.default.removeItem(at: linkedAssets)
        try FileManager.default.createSymbolicLink(at: linkedAssets, withDestinationURL: root)
        let linkedRevision = try ScenePackageWriter.revision(of: linked)
        do {
            try ScenePackageWriter.write(composition, to: linked, replacing: linkedRevision)
            fatalError("Saved through a symlinked assets folder")
        } catch is SceneError {}
        let afterLinked = try ScenePackageWriter.revision(of: linked)
        precondition(afterLinked == linkedRevision)
        let invalidExport = root.deletingLastPathComponent().appendingPathComponent("invalid-\(UUID().uuidString).idlesse")
        do {
            try ScenePackageWriter.write(SceneDescriptor(title: "Empty", nodes: []), to: invalidExport)
            fatalError("Exported invalid scene")
        } catch is SceneError {}
        precondition(!FileManager.default.fileExists(atPath: invalidExport.path))
        var hidden = SceneNode(content: .gradient)
        hidden.visible = false
        hidden.locked = true
        let hiddenPackage = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".idlesse")
        defer { try? FileManager.default.removeItem(at: hiddenPackage) }
        try ScenePackageWriter.write(SceneDescriptor(title: "Hidden", nodes: [hidden]), to: hiddenPackage)
        let hiddenLoaded = try await source.resolve(hiddenPackage)
        precondition(!hiddenLoaded.nodes[0].visible && hiddenLoaded.nodes[0].locked)
        let sixteen = (0..<16).map { _ in SceneNode(content: .image(root.appendingPathComponent("picture.png"))) }
        try SceneBudget.validate(sixteen)
        precondition(SceneBudget.imagePixels(sixteen) == 2_000_000)
        for invalid in [sixteen + [hidden], (0..<3).map { _ in SceneNode(content: .video(root.appendingPathComponent("video.mp4"))) },
                        (0..<5).map { _ in SceneNode(content: .gradient) }] {
            do { try SceneBudget.validate(invalid); fatalError("Accepted over-budget scene") } catch is SceneError {}
        }
        let firstNode = SceneNode(content: .gradient)
        let secondNode = SceneNode(content: .gradient)
        precondition(sceneResourceOrder(from: [firstNode, secondNode], to: [secondNode, firstNode]) == [1, 0])
        precondition(sceneResourceOrder(from: [firstNode, secondNode], to: [firstNode, firstNode]) == nil)
        precondition(sceneResourceOrder(from: [firstNode], to: [secondNode]) == nil)
        let group = SceneNode(name: "Environment", content: .group([firstNode, secondNode]), opacity: 0.5)
        let groupedPackage = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".idlesse")
        defer { try? FileManager.default.removeItem(at: groupedPackage) }
        try ScenePackageWriter.write(SceneDescriptor(title: "Grouped", nodes: [group]), to: groupedPackage)
        let grouped = try await source.resolve(groupedPackage)
        var controlled = SceneDescriptor(title: "Controls", nodes: [group],
            parameters: ["amount": .init(name: "Amount", value: 0.4, min: 0, max: 1)],
            bindings: [.init(target: .init(nodeID: firstNode.id, property: .opacity), parameter: "amount", scale: 2, offset: 0.1)])
        let evaluated = try controlled.evaluated()
        precondition(evaluated.allNodes[1].opacity == 0.9 && controlled.allNodes[1].opacity == firstNode.opacity)
        controlled.parameters["amount"]?.value = 1
        let clamped = try controlled.evaluated()
        precondition(clamped.allNodes[1].opacity == 1)
        try ScenePackageWriter.write(controlled, to: groupedPackage, replacing: ScenePackageWriter.revision(of: groupedPackage))
        let controlsLoaded = try await source.resolve(groupedPackage)
        precondition(controlsLoaded.parameters == controlled.parameters && controlsLoaded.bindings[0].target == controlled.bindings[0].target)
        let retained = controlled.replacingNodes([group])
        precondition(retained.bindings.count == 1 && retained.parameters == controlled.parameters)
        precondition(controlled.replacingNodes([SceneNode(content: .gradient)]).bindings.isEmpty)
        for invalid in 0..<9 {
            var bad = controlled
            switch invalid {
            case 0: bad.parameters["amount"]?.value = .nan
            case 1: bad.parameters["amount"]?.min = 1
            case 2: bad.bindings.append(bad.bindings[0])
            case 3: bad.parameters = [:]
            case 4: bad.bindings[0] = .init(target: .init(nodeID: UUID(), property: .opacity), parameter: "amount")
            case 5: bad.bindings[0].scale = .infinity
            case 6: bad.parameters = Dictionary(uniqueKeysWithValues: (0..<17).map { ("p\($0)", SceneParameter(name: "Control", value: 0, min: 0, max: 1)) })
            case 7: bad.parameters["amount"]?.name = " "
            default: bad.parameters["amount"]?.min = -Double.greatestFiniteMagnitude; bad.parameters["amount"]?.max = Double.greatestFiniteMagnitude
            }
            do { _ = try bad.evaluated(); fatalError("Accepted invalid controls") } catch is SceneError {}
        }
        try Data(#"{"version":6,"title":"Old","capabilities":[]}"#.utf8).write(to: groupedPackage.appendingPathComponent("manifest.json"))
        do { _ = try await source.resolve(groupedPackage); fatalError("Accepted controls in v6") } catch is SceneError {}
        try Data(#"{"version":7,"title":"Controls","capabilities":[]}"#.utf8).write(to: groupedPackage.appendingPathComponent("manifest.json"))
        try ScenePackageWriter.write(SceneDescriptor(title: "Grouped", nodes: [group]), to: groupedPackage,
                                    replacing: ScenePackageWriter.revision(of: groupedPackage))
        precondition(grouped.allNodes.map(\.id) == group.descendants.map(\.id))
        let reloaded = try await source.resolve(groupedPackage)
        precondition(reloaded.allNodes.map(\.id) == grouped.allNodes.map(\.id))
        var addressed = reloaded.nodes
        for property in ScenePropertyAddress.Property.allCases {
            let address = ScenePropertyAddress(nodeID: firstNode.id, property: property)
            let decoded = try JSONDecoder().decode(ScenePropertyAddress.self, from: JSONEncoder().encode(address))
            precondition(decoded == address)
            let value = (property.range.lowerBound + property.range.upperBound) / 2
            try address.set(value, in: &addressed)
            let actual = try address.value(in: addressed)
            precondition(actual == value)
            for invalid in [Double.nan, Double.infinity, property.range.upperBound + 1] {
                do { try address.set(invalid, in: &addressed); fatalError("Accepted invalid property") } catch is SceneError {}
            }
            let unchanged = try address.value(in: addressed)
            precondition(unchanged == value)
        }
        do {
            try ScenePropertyAddress(nodeID: UUID(), property: .opacity).set(0.5, in: &addressed)
            fatalError("Accepted missing target")
        } catch is SceneError {}
        let nodeFile = groupedPackage.appendingPathComponent("scene.json")
        let originalNodes = try Data(contentsOf: nodeFile)
        for invalidNodes in [
            #"{"nodes":[{"type":"gradient"}]}"#,
            #"{"nodes":[{"type":"gradient","id":"bad"}]}"#,
            "{\"nodes\":[{\"type\":\"gradient\",\"id\":\"\(group.id)\"},{\"type\":\"gradient\",\"id\":\"\(group.id)\"}]}"
        ] {
            try Data(invalidNodes.utf8).write(to: nodeFile)
            do { _ = try await source.resolve(groupedPackage); fatalError("Accepted invalid v6 identity") } catch {}
        }
        try originalNodes.write(to: nodeFile)
        precondition(grouped.nodes[0].kind == .group && grouped.nodes[0].children.count == 2 && grouped.nodes[0].opacity == 0.5)
        let duplicate = group.duplicated()
        precondition(Set((group.descendants + duplicate.descendants).map { $0.id }).count == 6)
        var renamedGroup = group
        renamedGroup.name = "Changed"
        precondition(sceneResourceOrder(from: [group], to: [renamedGroup]) == [0])
        renamedGroup.content = .group([SceneNode(content: .gradient)])
        precondition(sceneResourceOrder(from: [group], to: [renamedGroup]) == nil)
        let nested = SceneNode(content: .group([group]))
        try SceneBudget.validate([nested])
        for invalid in [[SceneNode(content: .group([]))], [SceneNode(content: .group([nested]))],
                        [SceneNode(content: .group(sixteen))]] {
            do { try SceneBudget.validate(invalid); fatalError("Accepted invalid group budget") } catch is SceneError {}
        }
        let groupedImages = [SceneNode(content: .group(Array(sixteen.prefix(7)))), SceneNode(content: .group(Array(sixteen.suffix(7))))]
        try SceneBudget.validate(groupedImages)
        precondition(SceneBudget.imagePixels(groupedImages) == 32_000_000 / 14)
        let mediaGroup = SceneDescriptor(title: "Media", nodes: [SceneNode(content: .group([sixteen[0]]))])
        let mediaPackage = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".idlesse")
        defer { try? FileManager.default.removeItem(at: mediaPackage) }
        try ScenePackageWriter.write(mediaGroup, to: mediaPackage)
        let loadedMedia = try await source.resolve(mediaPackage)
        precondition(loadedMedia.allNodes.count == 2 && loadedMedia.allNodes.compactMap { $0.assetURL }.count == 1)
        let savedAsset = loadedMedia.allNodes.compactMap { $0.assetURL }[0]
        let mediaRevision = try ScenePackageWriter.revision(of: mediaPackage)
        try ScenePackageWriter.write(loadedMedia, to: mediaPackage, replacing: mediaRevision)
        precondition(FileManager.default.fileExists(atPath: savedAsset.path))
        let secondRevision = try ScenePackageWriter.revision(of: mediaPackage)
        try ScenePackageWriter.write(SceneDescriptor(title: "Replacement", nodes: [SceneNode(content: .gradient)]), to: mediaPackage, replacing: secondRevision)
        precondition(!FileManager.default.fileExists(atPath: savedAsset.path), "Removed nested assets must be pruned")
        let size = SceneBudget.groupTargetSize(width: 7680, height: 4320, count: 4)!
        precondition(size.width * size.height * 4 * 4 * 2 <= SceneBudget.intermediateTextureBytes)
        precondition(size.width < 7680 && abs(Double(size.width) / Double(size.height) - 16.0 / 9) < 0.01)
        precondition(SceneBudget.groupTargetSize(width: .infinity, height: 1, count: 1) == nil)
        try Data(#"{"version":2,"title":"Old format","capabilities":[]}"#.utf8).write(to: groupedPackage.appendingPathComponent("manifest.json"))
        do { _ = try await source.resolve(groupedPackage); fatalError("Accepted groups in v2") } catch is SceneError {}
        var styledNode = SceneNode(style: .init(mask: .ellipse, exposure: -1, saturation: 0, vignette: 0.7), content: .gradient)
        let styledScene = SceneDescriptor(title: "Styled", nodes: [styledNode])
        precondition(styledScene.requiresMetal)
        let styledPackage = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".idlesse")
        defer { try? FileManager.default.removeItem(at: styledPackage) }
        try ScenePackageWriter.write(styledScene, to: styledPackage)
        let styledLoaded = try await source.resolve(styledPackage)
        precondition(styledLoaded.nodes[0].style == styledNode.style)
        try Data(#"{"version":4,"title":"Old","capabilities":[]}"#.utf8).write(to: styledPackage.appendingPathComponent("manifest.json"))
        do { _ = try await source.resolve(styledPackage); fatalError("Accepted vignette in v4") } catch is SceneError {}
        var invalidVignette = styledNode
        for value in [-0.1, 1.1, Double.infinity, Double.nan] {
            invalidVignette.style.vignette = value
            do { try SceneBudget.validate([invalidVignette]); fatalError("Accepted invalid vignette") } catch is SceneError {}
        }
        try Data(#"{"version":3,"title":"Old","capabilities":[]}"#.utf8).write(to: styledPackage.appendingPathComponent("manifest.json"))
        do { _ = try await source.resolve(styledPackage); fatalError("Accepted style in v3") } catch is SceneError {}
        styledNode.style.exposure = .infinity
        do { try SceneBudget.validate([styledNode]); fatalError("Accepted infinite exposure") } catch is SceneError {}
        var tree = [group]
        precondition(SceneTree.edit(firstNode.id, in: &tree) { nodes, index in nodes[index].name = "Edited child" })
        precondition(tree[0].id == group.id && tree[0].children[0].name == "Edited child")
        precondition(SceneTree.siblings(of: firstNode.id, in: tree)?.count == 2)
        print("Scene tests passed: metadata resolution, asset boundaries, bounded manifest")
    }
}
