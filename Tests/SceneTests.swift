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
        print("Scene tests passed: metadata resolution, asset boundaries, bounded manifest")
    }
}
