import AppKit
import Darwin

/// A separate test process: no scene/library settings or input grants are persisted.
enum DesktopQualification {
    static func run(source: URL, output: URL, seconds: Double, cycles: Int) throws {
        guard !FileManager.default.fileExists(atPath: output.path), !NSScreen.screens.isEmpty else {
            throw SceneError.invalid("Choose a new report path and attach a display.")
        }
        let controller = WallpaperController()
        var errors: [String] = []
        controller.onError = { errors.append($0) }
        defer { controller.stop() }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SceneError.invalid(message) }
        }
        func pump(_ duration: Double) {
            let end = Date(timeIntervalSinceNow: duration)
            while Date() < end {
                autoreleasepool { _ = RunLoop.current.run(mode: .default, before: min(end, Date(timeIntervalSinceNow: 0.02))) }
            }
        }
        func loaded() throws {
            let end = Date(timeIntervalSinceNow: 30)
            while controller.isLoading && Date() < end { pump(0.02) }
            try require(!controller.isLoading && errors.isEmpty, "Scene load failed or timed out: \(errors)")
            try require(controller.surfaces.count == NSScreen.screens.count, "Missing desktop surface")
        }
        var samples: [[String: Any]] = []
        let began = ProcessInfo.processInfo.systemUptime
        func record(_ phase: String, _ cycle: Int) {
            let memory = PlaybackBenchmark.memory()
            var row: [String: Any] = ["phase": phase, "cycle": cycle,
                "seconds": ProcessInfo.processInfo.systemUptime - began,
                "processCPUSeconds": Double(Darwin.clock()) / Double(CLOCKS_PER_SEC),
                "footprintBytes": memory["footprint"]!, "residentBytes": memory["resident"]!,
                "surfaceCount": controller.surfaces.count]
            row["displays"] = controller.surfaces.map { surface -> [String: Any] in
                var display: [String: Any] = ["submittedFrames": surface.diagnostics.frameCount,
                    "loops": surface.diagnostics.loopCount]
                if let presented = surface.presentedFrameCount { display["presentedFrames"] = presented }
                if let gpu = surface.gpuTotals { display["gpuSeconds"] = gpu.seconds; display["gpuFrames"] = gpu.frames }
                return display
            }
            samples.append(row)
        }
        record("baseline", 0)
        for cycle in 1...cycles {
            // Synchronous CLI-driven lifecycle calls need the event-level pool
            // AppKit normally supplies. Drain before measuring post-stop memory.
            try autoreleasepool {
                controller.select(source)
                try loaded()
                record("loaded", cycle)
                let end = Date(timeIntervalSinceNow: seconds)
                while Date() < end { pump(min(1, end.timeIntervalSinceNow)); record("playing", cycle) }
                try require(errors.isEmpty, "Playback error: \(errors)")
                controller.togglePause()
                try require(controller.surfaces.allSatisfy { $0.diagnostics.state == .paused }, "Pause failed")
                controller.setSystemAsleep(true)
                controller.setAsleep(true)
                controller.setSessionInactive(true)
                try require(controller.surfaces.isEmpty, "Suspension retained surfaces")
                controller.setSystemAsleep(false)
                controller.setAsleep(false)
                try require(controller.surfaces.isEmpty, "Resumed while session inactive")
                // A schedule may select a replacement while the session is suspended.
                controller.select(source, automatic: true)
                let deadline = Date(timeIntervalSinceNow: 30)
                while controller.isLoading && Date() < deadline { pump(0.02) }
                try require(!controller.isLoading && errors.isEmpty && controller.surfaces.isEmpty, "Suspended selection failed")
                controller.setSessionInactive(false)
                try loaded()
                record("resumed", cycle)
                let revision = controller.revision
                controller.select(source.appendingPathComponent("missing-qualification-asset"), automatic: true)
                let failedDeadline = Date(timeIntervalSinceNow: 30)
                while controller.isLoading && Date() < failedDeadline { pump(0.02) }
                try require(!controller.isLoading && !errors.isEmpty && controller.revision == revision &&
                    !controller.surfaces.isEmpty, "Failed replacement discarded the working scene")
                errors.removeAll()
                controller.stop()
            }
            pump(0.25)
            try require(controller.surfaces.isEmpty && !controller.isRunning, "Teardown failed")
            record("stopped", cycle)
            print("Desktop qualification cycle \(cycle)/\(cycles) passed")
        }
        let report: [String: Any] = ["source": source.path, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "requestedSecondsPerCycle": seconds, "cycles": cycles,
            "metalRequested": ProcessInfo.processInfo.environment["IDLESSE_METAL_COMPOSITOR"] == "1",
            "frameRatePreference": SceneFrameRate.selected.title,
            "screens": NSScreen.screens.map { ["frame": NSStringFromRect($0.frame),
                "scale": $0.backingScaleFactor, "maximumFramesPerSecond": $0.maximumFramesPerSecond] as [String: Any] },
            "samples": samples,
            "limitations": ["Synthetic lifecycle calls, not physical sleep or hotplug", "No energy or decoder-specific memory counter", "No HDR qualification", "Presented frame counts can be zero when the desktop is occluded or locked"]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .withoutOverwriting)
    }
}
