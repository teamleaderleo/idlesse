import AppKit

/// Renderer lifecycle and measurements, independent of document editing and AppKit controls.
final class ScenePreviewHost {
    var renderer: SceneRenderer?
    let clock = SceneClock()
    var performanceTimer: Timer?
    var presentationSample = PresentationRateSample()
    var measurement: (time: Double, count: Int, gpuSeconds: Double, gpuFrames: Int)?
    var measurementResult: String?
    func prepare(scene: SceneDescriptor, bounds: NSRect, scale: CGFloat, metal: Bool,
                 onError: @escaping (String) -> Void) throws -> SceneRenderer {
        if metal || scene.requiresMetal {
            return try MetalSceneRenderer(playable: scene, bounds: bounds, scale: scale, clock: clock, onError: onError)
        }
        return try LayeredSceneRenderer(playable: scene, bounds: bounds, scale: scale, clock: clock, onError: onError)
    }
    func setPaused(_ paused: Bool) {
        clock.setPaused(paused)
        renderer?.setPaused(paused)
    }
    func stop() {
        performanceTimer?.invalidate()
        performanceTimer = nil
        clock.setPaused(true)
        renderer?.releaseResources()
        renderer = nil
    }
    func performanceText() -> String {
        guard let renderer else { return "" }
        guard renderer.diagnostics.state == .running else { return "Paused · no continuous rendering" }
        guard renderer.diagnostics.animated else { return "Still image · redraws only when needed" }
        guard let count = renderer.presentedFrameCount else { return "Presentation rate unavailable for this renderer" }
        let now = ProcessInfo.processInfo.systemUptime
        if let measurement, let gpu = renderer.gpuTotals, now - measurement.time >= 10 {
            let frames = gpu.frames - measurement.gpuFrames
            let rate = Double(count - measurement.count) / (now - measurement.time)
            measurementResult = frames > 0
                ? String(format: "10s sample: %.1f fps · GPU %.2f ms/frame", rate, (gpu.seconds - measurement.gpuSeconds) * 1000 / Double(frames))
                : "10s sample: no completed GPU frames"
            self.measurement = nil
        }
        if let measurementResult { return measurementResult }
        if let rate = presentationSample.sample(count: count, time: now) { return String(format: "%.0f presented fps", rate) }
        return "Measuring presentation rate…"
    }
    deinit { stop() }
}
