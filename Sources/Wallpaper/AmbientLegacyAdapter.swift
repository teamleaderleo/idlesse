import Foundation

/// Explicit migration inputs. Callers translate existing persisted values to
/// stable Library IDs before asking for generated Ambient Sets. Legacy systems
/// keep running until the user commits the generated catalog.
struct AmbientLegacyCollectionSchedule: Equatable {
    var collectionID: String
    var collectionName: String
    var startMinute: Int
    var endMinute: Int
    var weekdays: Set<Int>?
}

struct AmbientLegacyDayNight: Equatable {
    var nightSceneID: String
    var followsSun: Bool
}

struct AmbientLegacyBedtime: Equatable {
    var enabled: Bool
    var startMinute: Int
    var endMinute: Int
    var dimLevel: Double
    var nightSceneID: String?
}

struct AmbientLegacyAdapter {
    private static func boundedName(_ name: String) -> String {
        String(name.prefix(AmbientSet.maxNameLength))
    }

    static func collectionSet(from schedule: AmbientLegacyCollectionSchedule) -> AmbientSet? {
        let range = AmbientTimeRange(startMinute: schedule.startMinute, endMinute: schedule.endMinute)
        let activation = AmbientActivation(timeRange: range, weekdays: schedule.weekdays)
        let setID = "legacy.collection.\(schedule.collectionID)"
        let target = AmbientWallpaperTarget.collection(schedule.collectionID)
        guard !schedule.collectionID.isEmpty, setID.count <= AmbientSet.maxIdentifierLength,
              target.isValid, activation.isValid else { return nil }
        return AmbientSet(id: setID,
                          name: boundedName("\(schedule.collectionName) Schedule"),
                          activation: activation,
                          overrides: AmbientDesktopOverrides(wallpaper: .collection(schedule.collectionID)))
    }

    static func dayNightSet(from settings: AmbientLegacyDayNight) -> AmbientSet? {
        let target = AmbientWallpaperTarget.scene(settings.nightSceneID)
        guard settings.followsSun, target.isValid else { return nil }
        return AmbientSet(id: "legacy.day-night.night",
                          name: "Night",
                          activation: AmbientActivation(solar: .night),
                          overrides: AmbientDesktopOverrides(wallpaper: .scene(settings.nightSceneID)))
    }

    static func bedtimeSet(from settings: AmbientLegacyBedtime) -> AmbientSet? {
        guard settings.enabled else { return nil }
        let range = AmbientTimeRange(startMinute: settings.startMinute, endMinute: settings.endMinute)
        let activation = AmbientActivation(timeRange: range)
        let scene = settings.nightSceneID.map(AmbientWallpaperTarget.scene)
        guard activation.isValid, scene?.isValid ?? true else { return nil }
        return AmbientSet(id: "legacy.bedtime",
                          name: "Bedtime",
                          activation: activation,
                          overrides: AmbientDesktopOverrides(
                            wallpaper: scene,
                            dimming: AmbientDimmingOverride(enabled: true, level: settings.dimLevel)))
    }
}
