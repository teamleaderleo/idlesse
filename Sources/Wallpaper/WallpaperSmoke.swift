import AppKit
import AVFoundation

enum WallpaperSmoke {
    static func run(videoURL: URL) throws {
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
        func wait(timeout: TimeInterval = 15, until condition: () -> Bool) {
            let end = Date(timeIntervalSinceNow: timeout)
            while !condition() && Date() < end {
                autoreleasepool { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) }
            }
            precondition(condition(), "Timed out waiting for wallpaper state")
        }
        controller.select(imageURL)
        wait { controller.isRunning || !errors.isEmpty }
        precondition(errors.isEmpty)
        precondition(controller.surfaces.count == NSScreen.screens.count)
        for surface in controller.surfaces {
            precondition(!surface.window.canBecomeKey && !surface.window.canBecomeMain)
            precondition(surface.window.ignoresMouseEvents)
            precondition(surface.player == nil)
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
        precondition(errors.isEmpty && controller.selectedURL == package && controller.surfaces.first?.player != nil)
        controller.setAsleep(true)
        controller.setAsleep(false)
        precondition(controller.surfaces.first?.player != nil, "Package must survive display sleep")

        try Data(#"{"version":99,"title":"Future scene","capabilities":[]}"#.utf8)
            .write(to: package.appendingPathComponent("manifest.json"))
        controller.select(package)
        wait { !controller.isLoading }
        precondition(!errors.isEmpty && controller.surfaces.first?.player != nil,
                     "Unsupported scene must preserve the current renderer")
        errors.removeAll()
        controller.stop()

        controller.select(videoURL)
        wait { controller.surfaces.first?.player != nil || !errors.isEmpty }
        precondition(errors.isEmpty)
        let surface = controller.surfaces[0]
        precondition(surface.player?.isMuted == true)
        precondition(surface.player?.preventsDisplaySleepDuringVideoPlayback == false)
        surface.player?.play()
        wait(timeout: 60) { surface.completedLoops >= 1 || !errors.isEmpty }
        precondition(errors.isEmpty)
        controller.togglePause()
        precondition(surface.player?.rate == 0)
        controller.togglePause()
        controller.stop()
        precondition(controller.surfaces.isEmpty && !controller.isRunning)
        precondition(surface.player == nil, "Stop must release the player, including externally retained surfaces")

        // A pending async selection cannot recreate windows after Stop.
        controller.select(videoURL)
        controller.stop()
        let end = Date(timeIntervalSinceNow: 0.5)
        while Date() < end { _ = RunLoop.current.run(mode: .default, before: end) }
        precondition(!controller.isRunning && controller.surfaces.isEmpty)
        precondition(errors.isEmpty)
        print("Wallpaper checks passed: image, scene package, unsupported version, video loop, click-through, sleep/session overlap, pause, stop, cancellation")
    }
}
