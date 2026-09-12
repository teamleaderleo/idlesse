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

struct AmbientArrangementSnapshot: Codable, Equatable {
    static let maxBookmarkBytes = 16_384

    var wallpaperBookmark: Data?
    var filesVisible: Bool
    var widgetsVisible: Bool
    var dimming: AmbientDimmingState

    var isValid: Bool { (wallpaperBookmark?.count ?? 0) <= Self.maxBookmarkBytes }

    var resolvedState: ResolvedDesktopState {
        ResolvedDesktopState(wallpaper: AmbientSetActuationPolicy.arrangementDefaultTarget,
                             filesVisible: filesVisible,
                             widgetsVisible: widgetsVisible,
                             dimming: dimming)
    }
}
