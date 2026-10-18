import Foundation

/// Pure precedence for the global wallpaper transport decision. Per-display
/// coverage rest remains a separate policy because one visible display keeps a
/// shared decoder alive for the whole group.
struct WallpaperPresentationDecision: Equatable {
    enum State: String, Equatable {
        case playing
        case paused
        case suspended
    }

    enum Reason: String, Equatable {
        case none
        case userPause
        case bedtime
        case lowPower
        case displaySleep
        case sessionInactive
    }

    let state: State
    let reason: Reason

    var pausesPlayback: Bool { state == .paused }
    var suspendsDisplay: Bool { state == .suspended }

    static func resolve(userPaused: Bool, bedtime: Bool, lowPower: Bool,
                        displayAsleep: Bool, sessionInactive: Bool) -> Self {
        if sessionInactive { return .init(state: .suspended, reason: .sessionInactive) }
        if displayAsleep { return .init(state: .suspended, reason: .displaySleep) }
        if userPaused { return .init(state: .paused, reason: .userPause) }
        if bedtime { return .init(state: .paused, reason: .bedtime) }
        if lowPower { return .init(state: .paused, reason: .lowPower) }
        return .init(state: .playing, reason: .none)
    }
}
