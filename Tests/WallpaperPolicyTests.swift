import AppKit

@main
enum WallpaperPolicyTests {
    static func main() {
        let policy = CoverageRestPolicy()
        precondition(policy.restThreshold == 0.95)
        precondition(policy.resumeThreshold == 0.85)
        precondition(policy.stableSamples == 2)

        var left = CoverageRestPolicy.Tracker()
        var right = CoverageRestPolicy.Tracker()
        precondition(!left.sample(0.98, policy: policy).isResting)
        let leftRest = left.sample(0.99, policy: policy)
        precondition(leftRest.isResting && leftRest.changed,
                     "Two high samples should rest only the covered display")
        precondition(!right.sample(0.15, policy: policy).isResting)
        precondition(!right.sample(0.20, policy: policy).isResting,
                     "A visible display must continue while another rests")
        precondition(!CoverageRestPolicy.shouldRestSharedPlayback(
            globalPause: false, displayResting: [left.isResting, right.isResting]),
            "Shared playback must continue while any display is visible")
        precondition(CoverageRestPolicy.shouldRestSharedPlayback(
            globalPause: false, displayResting: [true, true]),
            "Shared playback can rest once every display rests")
        precondition(CoverageRestPolicy.shouldRestSharedPlayback(
            globalPause: true, displayResting: [false, false]),
            "Global pause must always pause shared playback")

        precondition(left.sample(0.90, policy: policy).isResting,
                     "Hysteresis band should hold the resting state")
        precondition(left.sample(0.80, policy: policy).isResting,
                     "One low sample should only arm resume")
        precondition(left.sample(0.90, policy: policy).isResting,
                     "A return to the hysteresis band must cancel pending resume")
        _ = left.sample(0.82, policy: policy)
        let leftResume = left.sample(0.80, policy: policy)
        precondition(!leftResume.isResting && leftResume.changed,
                     "Two stable low samples should resume a rested display")

        var noisy = CoverageRestPolicy.Tracker()
        _ = noisy.sample(0.99, policy: policy)
        precondition(!noisy.sample(0.90, policy: policy).isResting,
                     "A hysteresis-band sample must cancel an incomplete rest transition")

        var instant = 0.0
        let monitor = CoverageMonitor(staleAfter: 8, now: { instant })
        var stale = monitor.evaluate(displayKey: "DISPLAY-A", fraction: 0.99, currentResting: false)
        precondition(!stale.isResting && stale.candidate == true)
        instant = 1
        stale = monitor.evaluate(displayKey: "DISPLAY-A", fraction: 0.99, currentResting: false)
        precondition(stale.isResting && stale.changed)
        instant = 10
        stale = monitor.evaluate(displayKey: "DISPLAY-A", fraction: 0.99, currentResting: true)
        precondition(!stale.isResting && stale.changed,
                     "A stale sampling gap must wake a rested display before reconfirming coverage")
        instant = 11
        stale = monitor.evaluate(displayKey: "DISPLAY-A", fraction: 0.99, currentResting: false)
        precondition(!stale.isResting && stale.candidate == true)
        instant = 12
        stale = monitor.evaluate(displayKey: "DISPLAY-A", fraction: 0.99, currentResting: false)
        precondition(stale.isResting && stale.changed,
                     "Coverage must reconfirm after a stale reset")

        precondition(CoverageMonitor.countsAsOpaqueWindow(alpha: 1))
        precondition(!CoverageMonitor.countsAsOpaqueWindow(alpha: 0.97),
                     "Translucent whole-window alpha must keep rendering active")
        let rect = NSRect(x: 0, y: 0, width: 120, height: 120)
        precondition(CoverageMonitor.coveredFraction(of: rect, by: []) == 0)
        precondition(CoverageMonitor.coveredFraction(of: rect, by: [rect]) == 1)
        let half = CoverageMonitor.coveredFraction(of: rect,
            by: [NSRect(x: 0, y: 0, width: 60, height: 120)])
        precondition(abs(half - 0.5) < 0.1)
        let union = CoverageMonitor.coveredFraction(of: rect, by: [
            NSRect(x: 0, y: 0, width: 72, height: 120),
            NSRect(x: 48, y: 0, width: 72, height: 120),
        ])
        precondition(union == 1, "Overlapping window bounds must be measured as a union")

        let suite = "Idlesse.DisplayAssignmentStoreTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DisplayAssignmentStore(defaults: defaults, prefix: "wallpaperResumeBookmark")
        let saved = Data([1, 2, 3, 4])
        store.setBookmarkData(saved, persistentID: "DISPLAY-A")
        precondition(store.bookmarkData(persistentID: "DISPLAY-A", legacyDisplayID: 999) == saved,
                     "Stable display identity must survive a changed transient display ID")
        let legacy = Data([9, 8, 7])
        defaults.set(legacy, forKey: store.legacyKey(42))
        precondition(store.bookmarkData(persistentID: "DISPLAY-B", legacyDisplayID: 42) == legacy)
        precondition(defaults.data(forKey: store.stableKey("DISPLAY-B")) == legacy,
                     "Legacy NSScreenNumber bookmarks should migrate on first read")
        precondition(defaults.data(forKey: store.legacyKey(42)) == nil,
                     "Migration should retire the transient numeric key")
        store.clear(persistentID: "DISPLAY-B", legacyDisplayID: 42)
        precondition(defaults.data(forKey: store.stableKey("DISPLAY-B")) == nil)
        precondition(defaults.data(forKey: store.legacyKey(42)) == nil)

        print("Wallpaper policy checks passed: assignment identity, shared playback, coverage hysteresis, stale reset, opacity and union sampling")
    }
}
