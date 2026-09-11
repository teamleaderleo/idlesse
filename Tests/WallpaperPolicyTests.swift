import Foundation

@main
enum WallpaperPolicyTests {
    static func main() {
        let policy = CoverageRestPolicy()
        precondition(policy.restThreshold > policy.resumeThreshold)
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
                     "Hysteresis deadband should keep the current resting state")
        precondition(left.sample(0.70, policy: policy).isResting)
        let leftResume = left.sample(0.60, policy: policy)
        precondition(!leftResume.isResting && leftResume.changed,
                     "Two low samples should resume a rested display")
        var noisy = CoverageRestPolicy.Tracker()
        _ = noisy.sample(0.99, policy: policy)
        precondition(!noisy.sample(0.90, policy: policy).isResting,
                     "A deadband sample must cancel an incomplete rest transition")

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

        print("Wallpaper policy checks passed: per-display coverage stability and reconnect-safe assignment keys")
    }
}
