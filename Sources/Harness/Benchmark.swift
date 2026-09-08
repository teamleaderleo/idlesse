import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// Runs the production saver and decoder with isolated preferences. No user photos,
/// settings changes, screenshot permissions, or persistent image cache are required.
enum PlaybackBenchmark {
    static func memory() -> [String: UInt64] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(status == KERN_SUCCESS)
        return ["footprint": info.phys_footprint, "resident": info.resident_size]
    }

    static func run(mode: String, folder: URL) throws {
        if mode == "fixture" {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<4 {
                try autoreleasepool {
                    let context = CGContext(data: nil, width: 6000, height: 4000,
                        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                    // Detailed, deterministic RGB patterns; avoids a trivial single-color input.
                    let pixels = context.data!.assumingMemoryBound(to: UInt32.self)
                    var state = UInt32(index + 1)
                    for p in 0..<(6000 * 4000) {
                        state = state &* 1664525 &+ 1013904223
                        pixels[p] = state | 0xFF000000
                    }
                    let destination = CGImageDestinationCreateWithURL(
                        folder.appendingPathComponent("\(index).jpg") as CFURL,
                        UTType.jpeg.identifier as CFString, 1, nil)!
                    CGImageDestinationAddImage(destination, context.makeImage()!,
                        [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                    guard CGImageDestinationFinalize(destination) else {
                        throw NSError(domain: "Benchmark", code: 1)
                    }
                }
            }
            return
        }

        let urls = try FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "jpg" }.sorted { $0.path < $1.path }
        precondition(urls.count >= 2)
        var samples: [[String: Any]] = []
        let start = ProcessInfo.processInfo.systemUptime
        func record(_ phase: String, _ retained: Int = 0) {
            var sample: [String: Any] = memory()
            sample["phase"] = phase
            sample["seconds"] = ProcessInfo.processInfo.systemUptime - start
            sample["retainedImages"] = retained
            samples.append(sample)
        }
        func pump(_ seconds: Double) {
            let end = Date(timeIntervalSinceNow: seconds)
            while Date() < end {
                autoreleasepool { _ = RunLoop.current.run(mode: .default, before: min(end, Date(timeIntervalSinceNow: 0.02))) }
            }
        }

        record("baseline")
        if mode == "lifecycle" {
            let suite = "com.teamleaderleo.idlesse.benchmark.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = IdlessePreferences(defaults: defaults)
            try preferences.saveFolder(folder)
            preferences.displayDuration = 1
            preferences.transitionDuration = 0.2
            preferences.scalingMode = .fill
            // No on-screen window: exercises production lifecycle, decoder and fade timers.
            let view = IdlesseView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), preferences: preferences)
            for cycle in 0..<8 {
                autoreleasepool { view.startAnimation() }
                for _ in 0..<3 {
                    pump(0.6)
                    record("playing-\(cycle)", view.retainedImageCount)
                }
                view.togglePlaybackPause()
                precondition(view.isPlaybackPaused)
                let pausedURL = view.displayedFileURL
                pump(1.1)
                precondition(view.displayedFileURL == pausedURL)
                view.showNextImage()
                pump(0.3)
                precondition(view.displayedFileURL != pausedURL)
                view.togglePlaybackPause()
                autoreleasepool { view.stopAnimation() }
                precondition(view.retainedImageCount == 0)
                pump(0.2)
                record("stopped-\(cycle)", view.retainedImageCount)
            }
        } else {
            precondition(["bounded", "full-resolution"].contains(mode))
            var current: NSImage?
            var next: NSImage?
            let target = NSSize(width: 3840, height: 2160)
            let canvas = ImageCanvasView(frame: NSRect(origin: .zero, size: target))
            let surface = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3840,
                pixelsHigh: 2160, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)!
            for index in 0..<24 {
                autoreleasepool {
                    let url = urls[index % urls.count]
                    if mode == "bounded" {
                        next = DisplayImageDecoder.load(url, target: target, mode: .fill)
                    } else {
                        // Generic eager full-resolution reference, NOT an Apple/competitor emulator.
                        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
                        let bitmap = CGImageSourceCreateImageAtIndex(source, 0,
                            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)!
                        next = NSImage(cgImage: bitmap, size: NSSize(width: 6000, height: 4000))
                        next?.cacheMode = .never
                    }
                    precondition(next != nil)
                    canvas.currentImage = current
                    canvas.nextImage = next
                    canvas.scalingMode = .fill
                    for frame in 1...6 {
                        canvas.transitionProgress = CGFloat(frame) / 6
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: surface)
                        canvas.draw(canvas.bounds)
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    record("transition-\(index)", current == nil ? 1 : 2)
                    current = next
                    next = nil
                    canvas.currentImage = current
                    canvas.nextImage = nil
                }
            }
            current = nil
            next = nil
            canvas.currentImage = nil
            canvas.nextImage = nil
            record("released")
        }
        let result: [String: Any] = [
            "mode": mode, "fixture": "4 synthetic 6000x4000 JPEGs", "target": "3840x2160",
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start,
            "samples": samples, "peakSampledFootprint": samples.compactMap { $0["footprint"] as? UInt64 }.max()!,
            "note": "Process footprint samples; not total system/GPU cost. Lifecycle does not render on screen."
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        print("")
    }
}
