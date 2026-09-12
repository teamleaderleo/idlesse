import Foundation

/// Internal wallpaper sentinels used by the actuation bridge. User-authored
/// Ambient Sets still target only Library scenes or collections.
enum AmbientSetActuationPolicy {
    static let reservedPrefix = "__idlesse.ambient.internal."
    static let currentSelectionID = reservedPrefix + "current-selection"
    static let arrangementDefaultID = reservedPrefix + "arrangement-default"

    static var currentSelectionTarget: AmbientWallpaperTarget { .scene(currentSelectionID) }
    static var arrangementDefaultTarget: AmbientWallpaperTarget { .scene(arrangementDefaultID) }

    static func isCurrentSelection(_ target: AmbientWallpaperTarget?) -> Bool {
        target?.kind == .scene && target?.id == currentSelectionID
    }

    static func isArrangementDefault(_ target: AmbientWallpaperTarget?) -> Bool {
        target?.kind == .scene && target?.id == arrangementDefaultID
    }

    static func validateUserSets(_ sets: [AmbientSet]) throws {
        try AmbientSetStore.validate(sets)
        for set in sets {
            if let target = set.overrides.wallpaper, target.id.hasPrefix(reservedPrefix) {
                throw AmbientSetActuationError.reservedWallpaperTarget
            }
        }
    }

    static func mergedManualOverrides(existing hold: AmbientManualHold?,
                                      changes: AmbientDesktopOverrides,
                                      at now: Date) -> AmbientDesktopOverrides {
        var result = AmbientDesktopOverrides()
        if let hold, hold.isActive(at: now), case .overrides(let overrides, _) = hold.intent {
            result = overrides
        }
        if let wallpaper = changes.wallpaper { result.wallpaper = wallpaper }
        if let filesVisible = changes.filesVisible { result.filesVisible = filesVisible }
        if let widgetsVisible = changes.widgetsVisible { result.widgetsVisible = widgetsVisible }
        if let dimming = changes.dimming { result.dimming = dimming }
        return result
    }
}

enum AmbientSetActuationError: Error, Equatable {
    case reservedWallpaperTarget
    case unavailableStore
    case onlineConditionStillConfigured
    case unsafeLegacyBedtimeOverlap
    case invalidLegacySchedule
    case missingAmbientSet(String)
    case missingWallpaperTarget(String)
    case invalidArrangementSnapshot
}

extension AmbientSetActuationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .reservedWallpaperTarget:
            return "That wallpaper target is reserved for Ambient Sets runtime state."
        case .unavailableStore:
            return "Ambient Sets storage is unavailable."
        case .onlineConditionStillConfigured:
            return "Legacy online condition scenes are still configured. Keep legacy modes active until online Ambient conditions are available."
        case .unsafeLegacyBedtimeOverlap:
            return "Bedtime overlaps a collection schedule without a night scene. Create an explicit priority choice before converting."
        case .invalidLegacySchedule:
            return "A legacy collection schedule could not be represented safely as an Ambient Set."
        case .missingAmbientSet(let id):
            return "Ambient Set “\(id)” is unavailable."
        case .missingWallpaperTarget(let id):
            return "Wallpaper target “\(id)” is unavailable."
        case .invalidArrangementSnapshot:
            return "The Arrangement Default snapshot is invalid."
        }
    }
}

/// Complete user-controlled baseline beneath Ambient Set automation. The
/// wallpaper portion keeps #31's Same / Per Display / Desktop Span intent and
/// durable display identities instead of flattening the baseline to one URL.
struct AmbientArrangementSnapshot: Codable, Equatable {
    var wallpaperPlan: PersistedWallpaperAssignmentPlan
    var filesVisible: Bool
    var widgetsVisible: Bool
    var dimming: AmbientDimmingState

    private enum CodingKeys: String, CodingKey {
        case wallpaperPlan, wallpaperBookmark, filesVisible, widgetsVisible, dimming
    }

    init(wallpaperPlan: PersistedWallpaperAssignmentPlan,
         filesVisible: Bool,
         widgetsVisible: Bool,
         dimming: AmbientDimmingState) {
        self.wallpaperPlan = wallpaperPlan
        self.filesVisible = filesVisible
        self.widgetsVisible = widgetsVisible
        self.dimming = dimming
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        filesVisible = try values.decode(Bool.self, forKey: .filesVisible)
        widgetsVisible = try values.decode(Bool.self, forKey: .widgetsVisible)
        dimming = try values.decode(AmbientDimmingState.self, forKey: .dimming)
        if let plan = try values.decodeIfPresent(PersistedWallpaperAssignmentPlan.self, forKey: .wallpaperPlan) {
            wallpaperPlan = plan
        } else {
            // One-time compatibility for pre-integration #73 snapshots.
            let bookmark = try values.decodeIfPresent(Data.self, forKey: .wallpaperBookmark)
            wallpaperPlan = PersistedWallpaperAssignmentPlan(
                mode: .sameOnAll,
                topologySignature: "legacy",
                baseBookmark: bookmark,
                assignments: [])
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(wallpaperPlan, forKey: .wallpaperPlan)
        try values.encode(filesVisible, forKey: .filesVisible)
        try values.encode(widgetsVisible, forKey: .widgetsVisible)
        try values.encode(dimming, forKey: .dimming)
    }

    var isValid: Bool { wallpaperPlan.isValid }

    var resolvedState: ResolvedDesktopState {
        ResolvedDesktopState(wallpaper: AmbientSetActuationPolicy.arrangementDefaultTarget,
                             filesVisible: filesVisible,
                             widgetsVisible: widgetsVisible,
                             dimming: dimming)
    }
}
