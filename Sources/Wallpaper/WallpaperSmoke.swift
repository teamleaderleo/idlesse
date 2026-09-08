import AppKit
import AVFoundation
import MetalKit

enum WallpaperSmoke {
    static func run(videoURL: URL) throws {
        let document = SceneDocument()
        var allowUndo = true
        document.prepareRestore = { _ in allowUndo }
        for index in 1...40 {
            let before = SceneDocument.Snapshot(scene: document.scene, selected: 0, draft: document.draft)
            document.scene = SceneDescriptor(title: "Edit \(index)", nodes: [SceneNode(content: .gradient)])
            document.draft = true
            document.record(before, name: "Move Layer")
        }
        precondition(document.undoTargets.count == 32 && document.undoManager.undoActionName == "Move Layer")
        allowUndo = false
        document.undoManager.undo()
        precondition(document.scene.title == "Edit 40" && document.undoTargets.count == 32 && !document.undoManager.canRedo)
        allowUndo = true
        for _ in 0..<32 { document.undoManager.undo() }
        precondition(document.scene.title == "Edit 8" && !document.undoManager.canUndo)
        for _ in 0..<32 { document.undoManager.redo() }
        precondition(document.scene.title == "Edit 40" && !document.undoManager.canRedo)
        document.undoManager.undo()
        let branch = SceneDocument.Snapshot(scene: document.scene, selected: 0, draft: true)
        document.scene = SceneDescriptor(title: "Branch", nodes: [SceneNode(content: .gradient)])
        document.record(branch, name: "Rename Layer")
        precondition(!document.undoManager.canRedo && document.redoTargets.isEmpty)
        StudioWindowController.smokeTestResetRecovery()
        let counter = PresentedFrameCounter()
        counter.record(presentedTime: 0)
        counter.record(presentedTime: .nan)
        precondition(counter.total == 0)
        counter.record(presentedTime: 1)
        precondition(counter.total == 1)
        counter.recordGPU(start: 0, end: 2)
        counter.recordGPU(start: 2, end: 1)
        precondition(counter.gpuTotals.frames == 0)
        counter.recordGPU(start: 1, end: 1.002)
        precondition(counter.gpuTotals.frames == 1)
        precondition(abs(counter.gpuTotals.seconds - 0.002) < 0.000001)
        var rateSample = PresentationRateSample()
        precondition(rateSample.sample(count: 0, time: 10) == nil)
        precondition(rateSample.sample(count: 160, time: 11) == 160)
        precondition(rateSample.sample(count: 160, time: 12) == 0)
        precondition(rateSample.sample(count: 0, time: 13) == nil)
        precondition(SceneFrameRate.matchDisplay.requested(maximum: 160) == 160)
        precondition(SceneFrameRate.matchDisplay.requested(maximum: 240) == 240)
        precondition(SceneFrameRate.fps160.requested(maximum: 60) == 60)
        precondition(SceneFrameRate.fps120.requested(maximum: 160) == 120)
        precondition(SceneFrameRate.automatic.requested(maximum: 160) == nil)
        guard !NSScreen.screens.isEmpty else { fatalError("Wallpaper tests need a logged-in display session") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-wallpaper-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageURL = folder.appendingPathComponent("test.png")
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<32 {
            for x in 0..<32 {
                let offset = y * image.bytesPerRow + x * 4
                image.bitmapData![offset] = 26
                image.bitmapData![offset + 1] = 179
                image.bitmapData![offset + 2] = 153
                image.bitmapData![offset + 3] = 255
            }
        }
        try image.representation(using: .png, properties: [:])!.write(to: imageURL)
        let controller = WallpaperController()
        controller.presentsWindows = false
        var errors: [String] = []
        controller.onError = { errors.append($0) }
        func wait(timeout: TimeInterval = 15, line: UInt = #line, until condition: () -> Bool) {
            let end = Date(timeIntervalSinceNow: timeout)
            while !condition() && Date() < end {
                autoreleasepool { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) }
            }
            precondition(condition(), "Timed out waiting for wallpaper state at line \(line); errors: \(errors)")
        }
        controller.select(imageURL)
        wait { controller.isRunning || !errors.isEmpty }
        precondition(errors.isEmpty)
        precondition(controller.surfaces.count == NSScreen.screens.count)
        for surface in controller.surfaces {
            precondition(!surface.window.canBecomeKey && !surface.window.canBecomeMain)
            precondition(surface.window.ignoresMouseEvents)
            precondition(surface.diagnostics.activeResources == 1 && !surface.diagnostics.animated)
            precondition(surface.window.level.rawValue < Int(CGWindowLevelForKey(.desktopIconWindow)))
        }
        controller.setAsleep(true)
        precondition(controller.surfaces.isEmpty && controller.isRunning)
        controller.setSystemAsleep(true)
        controller.setAsleep(false)
        precondition(controller.surfaces.isEmpty, "Display wake cannot override system sleep")
        controller.setSystemAsleep(false)
        precondition(controller.surfaces.count == NSScreen.screens.count)
        controller.setSessionInactive(true)
        precondition(controller.surfaces.isEmpty)
        controller.setSessionInactive(false)
        precondition(!controller.surfaces.isEmpty)

        let suite = "idlesse.async-saver-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = IdlessePreferences(defaults: defaults)
        try preferences.saveFolder(folder)
        let saver = IdlesseView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), preferences: preferences)
        saver.startAnimation()
        wait { saver.retainedImageCount == 1 }
        saver.stopAnimation()
        precondition(saver.retainedImageCount == 0)
        saver.startAnimation()
        saver.stopAnimation()
        let stoppedEnd = Date(timeIntervalSinceNow: 0.3)
        while Date() < stoppedEnd { _ = RunLoop.current.run(mode: .default, before: stoppedEnd) }
        precondition(saver.retainedImageCount == 0, "Cancelled preparation must not repopulate a stopped saver")

        let broken = folder.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: broken)
        controller.select(broken)
        wait { !errors.isEmpty }
        precondition(controller.selectedURL == imageURL && !controller.surfaces.isEmpty,
                     "A failed replacement must preserve the existing wallpaper")
        errors.removeAll()

        // Exercise the package path through the same production host.
        let package = folder.appendingPathComponent("Test.idlesse")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: videoURL, to: package.appendingPathComponent("assets/loop.mp4"))
        try Data(#"{"version":1,"title":"Test scene","capabilities":[]}"#.utf8)
            .write(to: package.appendingPathComponent("manifest.json"))
        try Data(#"{"layers":[{"type":"video","asset":"assets/loop.mp4"}]}"#.utf8)
            .write(to: package.appendingPathComponent("scene.json"))
        controller.select(package)
        wait { !controller.isLoading }
        precondition(errors.isEmpty && controller.selectedURL == package && controller.surfaces.first?.diagnostics.animated == true)
        controller.setAsleep(true)
        controller.setAsleep(false)
        precondition(controller.surfaces.first?.diagnostics.animated == true, "Package must survive display sleep")

        try FileManager.default.copyItem(at: imageURL, to: package.appendingPathComponent("assets/overlay.png"))
        try Data(#"{"layers":[{"type":"video","asset":"assets/loop.mp4"},{"type":"image","asset":"assets/overlay.png","opacity":0.25}]}"#.utf8)
            .write(to: package.appendingPathComponent("scene.json"))
        controller.select(package)
        wait { !controller.isLoading }
        precondition(errors.isEmpty)
        let composite = controller.surfaces[0].window.contentView!
        precondition(composite.subviews.count == 2 && composite.subviews[1].subviews[0].alphaValue == 0.25)
        controller.togglePause()
        precondition(controller.surfaces[0].diagnostics.state == .paused)
        controller.togglePause()

        // A real filesystem event must apply an atomic edit without resetting pause.
        controller.togglePause()
        let beforeRevision = controller.revision
        let beforeTime = controller.sceneTime
        try Data(#"{"layers":[{"type":"video","asset":"assets/loop.mp4"},{"type":"image","asset":"assets/overlay.png","opacity":0.6}]}"#.utf8)
            .write(to: package.appendingPathComponent("scene.json"), options: .atomic)
        wait { controller.revision > beforeRevision }
        precondition(controller.pausedByUser && controller.sceneTime == beforeTime)
        precondition(controller.surfaces[0].diagnostics.state == .paused)
        precondition(controller.surfaces[0].window.contentView!.subviews[1].subviews[0].alphaValue == 0.6)
        let goodRevision = controller.revision
        try Data("unfinished edit".utf8).write(to: package.appendingPathComponent("scene.json"), options: .atomic)
        wait { controller.lastReloadError != nil }
        precondition(controller.revision == goodRevision && !controller.surfaces.isEmpty)
        try Data(#"{"layers":[{"type":"video","asset":"assets/loop.mp4"}]}"#.utf8)
            .write(to: package.appendingPathComponent("scene.json"), options: .atomic)
        wait { controller.revision > goodRevision }
        precondition(controller.lastReloadError == nil && controller.pausedByUser)

        var instant = 0.0
        let sceneClock = SceneClock(now: { instant })
        sceneClock.setPaused(false)
        let gradient = try GradientRenderer(bounds: NSRect(x: 0, y: 0, width: 32, height: 32), clock: sceneClock) { errors.append($0) }
        gradient.setPreferredFrameRate(160)
        precondition((gradient.view as? MTKView)?.preferredFramesPerSecond == 160)
        gradient.setPreferredFrameRate(nil)
        precondition((gradient.view as? MTKView)?.preferredFramesPerSecond == 30)
        let frame = try gradient.renderProbe()
        precondition(Set(frame).count > 16 && stride(from: 3, to: frame.count, by: 4).allSatisfy { frame[$0] == 255 })
        instant = 10
        let laterFrame = try gradient.renderProbe()
        precondition(laterFrame != frame, "Scene time must animate actual GPU output")
        gradient.setPaused(true)
        precondition(gradient.diagnostics.state == .paused)
        gradient.releaseResources()
        precondition(gradient.diagnostics.activeResources == 0)

        // Exercise the experimental compositor through real GPU readback.
        let metalImage = try MetalSceneRenderer(playable: SceneDescriptor(title: "image", nodes: [
            SceneNode(content: .image(imageURL), opacity: 0.5,
                transform: .init(x: 0.25, y: 0, scale: 0.5, rotation: 0))]),
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: sceneClock) { errors.append($0) }
        let imageFrame = try metalImage.renderProbe()
        precondition(imageFrame[0] == 0 && imageFrame[1] == 0, "Translated image must leave backdrop visible")
        let center = (16 * 32 + 24) * 4
        precondition(abs(Int(imageFrame[center]) - 77) <= 3 && abs(Int(imageFrame[center+1]) - 90) <= 3,
            "Image upload, translation, scale and premultiplied opacity must compose correctly")
        metalImage.releaseResources()
        let metalScene = try MetalSceneRenderer(playable: SceneDescriptor(title: "mixed", nodes: [
            SceneNode(content: .gradient), SceneNode(content: .image(imageURL), opacity: 0.5)]),
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: sceneClock) { errors.append($0) }
        let mixedFrame = try metalScene.renderProbe()
        precondition(Set(mixedFrame).count > 16 && mixedFrame != imageFrame)
        instant = 20
        let changedMixedFrame = try metalScene.renderProbe()
        precondition(changedMixedFrame != mixedFrame)
        metalScene.releaseResources()
        let standardTransform = try LayeredSceneRenderer(playable: SceneDescriptor(title: "Centered", nodes: [
            SceneNode(content: .gradient, transform: .init(x: 0, y: 0, scale: 0.7, rotation: 0))]),
            bounds: NSRect(x: 0, y: 0, width: 100, height: 80), scale: 1, clock: sceneClock) { errors.append($0) }
        let transformHost = NSView(frame: standardTransform.view.frame)
        transformHost.addSubview(standardTransform.view)
        transformHost.layoutSubtreeIfNeeded()
        let layerTransform = standardTransform.view.subviews[0].layer!.sublayerTransform
        precondition(abs(layerTransform.m11 - 0.7) < 0.001)
        precondition(abs(layerTransform.m41 - 15) < 0.001 && abs(layerTransform.m42 - 12) < 0.001)
        standardTransform.releaseResources()
        let liveVideoScene = SceneDescriptor(title: "video", assetURL: videoURL, kind: .video)
        let standardLive = try LayeredSceneRenderer(playable: liveVideoScene,
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: sceneClock) { errors.append($0) }
        let originalVideoView = standardLive.view.subviews[0].subviews[0]
        var editedVideo = liveVideoScene.nodes
        editedVideo[0].opacity = 0.4
        editedVideo[0].transform = .init(x: 0.1, y: 0, scale: 0.8, rotation: 10)
        precondition(standardLive.updateScene(SceneDescriptor(title: "edit", nodes: editedVideo)))
        precondition(standardLive.view.subviews[0].subviews[0] === originalVideoView)
        precondition(abs(originalVideoView.alphaValue - 0.4) < 0.001)
        precondition(!standardLive.updateScene(SceneDescriptor(title: "replacement", nodes: [SceneNode(content: .gradient)])))
        standardLive.releaseResources()
        let metalVideo = try MetalSceneRenderer(playable: liveVideoScene,
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: sceneClock) { errors.append($0) }
        metalVideo.setPaused(false)
        var videoFrame: [UInt8] = []
        wait {
            videoFrame = (try? metalVideo.renderProbe()) ?? []
            return Set(videoFrame).count > 20
        }
        // A growing loop counter alone can hide a stale output on the next replica.
        // Require changing decoded pixels during three successive loop iterations.
        for iteration in 1...3 {
            wait { _ = try? metalVideo.renderProbe(); return metalVideo.diagnostics.loopCount >= iteration }
            let first = try metalVideo.renderProbe()
            wait {
                let next = (try? metalVideo.renderProbe()) ?? []
                return next != first && Set(next).count > 20
            }
        }
        let loopsBeforeEdit = metalVideo.diagnostics.loopCount
        precondition(metalVideo.updateScene(SceneDescriptor(title: "edit", nodes: editedVideo)))
        precondition(metalVideo.diagnostics.loopCount == loopsBeforeEdit)
        wait { _ = try? metalVideo.renderProbe(); return metalVideo.diagnostics.loopCount > loopsBeforeEdit }
        metalVideo.setPaused(true)
        precondition(metalVideo.diagnostics.state == .paused)
        let pausedLoops = metalVideo.diagnostics.loopCount
        metalVideo.setPaused(false)
        wait { _ = try? metalVideo.renderProbe(); return metalVideo.diagnostics.loopCount > pausedLoops }
        precondition(errors.isEmpty)
        metalVideo.releaseResources()
        precondition(metalVideo.diagnostics.activeResources == 0)

        try Data(#"{"version":99,"title":"Future scene","capabilities":[]}"#.utf8)
            .write(to: package.appendingPathComponent("manifest.json"))
        controller.select(package)
        wait { !controller.isLoading }
        precondition(!errors.isEmpty && controller.surfaces.first?.diagnostics.animated == true,
                     "Unsupported scene must preserve the current renderer")
        errors.removeAll()
        controller.stop()

        controller.select(videoURL)
        wait { controller.surfaces.first?.diagnostics.animated == true || !errors.isEmpty }
        precondition(errors.isEmpty)
        let surface = controller.surfaces[0]
        precondition(surface.diagnostics.audioMuted)
        precondition(surface.diagnostics.allowsDisplaySleep)
        surface.setPaused(false)
        wait(timeout: 60) { surface.diagnostics.loopCount >= 1 || !errors.isEmpty }
        precondition(errors.isEmpty)
        controller.togglePause()
        precondition(surface.diagnostics.state == .paused)
        controller.togglePause()
        controller.stop()
        precondition(controller.surfaces.isEmpty && !controller.isRunning)
        precondition(surface.diagnostics.activeResources == 0, "Stop must release the player, including externally retained surfaces")

        // A pending async selection cannot recreate windows after Stop.
        controller.select(videoURL)
        controller.stop()
        let end = Date(timeIntervalSinceNow: 0.5)
        while Date() < end { _ = RunLoop.current.run(mode: .default, before: end) }
        precondition(!controller.isRunning && controller.surfaces.isEmpty)
        precondition(errors.isEmpty)
        print("Wallpaper checks passed: async saver cancellation, image, two-layer scene package, hot reload, GPU gradient and mixed compositor, Metal video decode/loop, unsupported version, video loop, click-through, sleep/session overlap, pause, stop, cancellation")
    }
}
