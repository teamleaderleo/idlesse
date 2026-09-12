import AppKit

@main
enum CoverageTests {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() {
        let rect = NSRect(x: 0, y: 0, width: 120, height: 120)
        require(CoverageMonitor.coveredFraction(of: rect, by: []) == 0,
            "Empty coverage must be zero")
        require(CoverageMonitor.coveredFraction(of: rect, by: [rect]) == 1,
            "Full coverage must be one")
        let half = CoverageMonitor.coveredFraction(of: rect,
            by: [NSRect(x: 0, y: 0, width: 60, height: 120)])
        require(abs(half - 0.5) < 0.1, "Sampling must approximate half coverage")
        let union = CoverageMonitor.coveredFraction(of: rect, by: [
            NSRect(x: 0, y: 0, width: 72, height: 120),
            NSRect(x: 48, y: 0, width: 72, height: 120),
        ])
        require(union == 1, "Overlapping window bounds must be measured as a union")

        require(CoverageMonitor.countsAsOpaqueWindow(alpha: 1),
            "Opaque windows must count")
        require(!CoverageMonitor.countsAsOpaqueWindow(alpha: 0.8),
            "Whole-window translucency must remain render-visible")

        var policy = CoverageMonitor.RestPolicy()
        var decision = policy.update(fraction: 0.949, restThreshold: 0.95,
            resumeThreshold: 0.85, stableSamples: 2)
        require(!decision.resting && decision.pendingTarget == nil,
            "Coverage below the rest threshold must stay active")

        decision = policy.update(fraction: 0.97, restThreshold: 0.95,
            resumeThreshold: 0.85, stableSamples: 2)
        require(!decision.resting && decision.pendingTarget == true && decision.pendingSamples == 1,
            "One high sample must only arm rest")
        decision = policy.update(fraction: 0.96, restThreshold: 0.95,
            resumeThreshold: 0.85, stableSamples: 2)
        require(decision.resting && decision.changed,
            "Two stable high samples must enter rest")

        decision = policy.update(fraction: 0.90, restThreshold: 0.95,
            resumeThreshold: 0.85, stableSamples: 2)
        require(decision.resting && decision.pendingTarget == nil,
            "Hysteresis band must hold the resting state")
        decision = policy.update(fraction: 0.80, restThreshold: 0.95,
            resumeThreshold: 0.85, stableSamples: 2)
        require(decision.resting && decision.pendingTarget == false && decision.pendingSamples == 1,
            "One low sample must only arm resume")
        decision = policy.update(fraction: 0.90, restThreshold: 0.95,
            resumeThreshold: 0.85, stableSamples: 2)
        require(decision.resting && decision.pendingTarget == nil,
            "A bounce into the hysteresis band must cancel pending resume")
        _ = policy.update(fraction: 0.82, restThreshold: 0.95,
            resumeThreshold: 0.85, stableSamples: 2)
        decision = policy.update(fraction: 0.80, restThreshold: 0.95,
            resumeThreshold: 0.85, stableSamples: 2)
        require(!decision.resting && decision.changed,
            "Two stable low samples must resume")

        var otherDisplay = CoverageMonitor.RestPolicy()
        _ = otherDisplay.update(fraction: 0.98, restThreshold: 0.95,
            resumeThreshold: 0.85, stableSamples: 2)
        require(!otherDisplay.resting && !policy.resting,
            "Independent display policies must not share pending state")
        decision = otherDisplay.update(fraction: 0.98, restThreshold: 0.95,
            resumeThreshold: 0.85, stableSamples: 2)
        require(decision.resting && !policy.resting,
            "One display entering rest must leave the other display active")

        print("Coverage checks passed: union sampling, opacity filter, hysteresis, stability, per-display policy independence")
    }
}
