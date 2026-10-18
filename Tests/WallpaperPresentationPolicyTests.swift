import Foundation

@main
enum WallpaperPresentationPolicyTests {
    static func main() {
        let playing = WallpaperPresentationDecision.resolve(userPaused: false, bedtime: false, lowPower: false,
                                                             displayAsleep: false, sessionInactive: false)
        precondition(playing == .init(state: .playing, reason: .none))

        let user = WallpaperPresentationDecision.resolve(userPaused: true, bedtime: true, lowPower: true,
                                                         displayAsleep: false, sessionInactive: false)
        precondition(user.state == .paused && user.reason == .userPause,
                     "Explicit user pause must win over automatic pause causes")

        let sleep = WallpaperPresentationDecision.resolve(userPaused: true, bedtime: true, lowPower: true,
                                                          displayAsleep: true, sessionInactive: false)
        precondition(sleep.state == .suspended && sleep.reason == .displaySleep)
        precondition(!sleep.pausesPlayback && sleep.suspendsDisplay)

        let inactive = WallpaperPresentationDecision.resolve(userPaused: false, bedtime: false, lowPower: true,
                                                             displayAsleep: true, sessionInactive: true)
        precondition(inactive.reason == .sessionInactive,
                     "Session inactivity must remain the strongest suspension cause")

        let bedtime = WallpaperPresentationDecision.resolve(userPaused: false, bedtime: true, lowPower: true,
                                                            displayAsleep: false, sessionInactive: false)
        precondition(bedtime == .init(state: .paused, reason: .bedtime))
        print("Wallpaper presentation policy checks passed")
    }
}
