import Foundation

@main
private struct AmbientSetActuationTests {
    private static func fail(_ message: String) -> Never {
        fputs("AmbientSetActuationTests: \(message)\n", stderr)
        exit(1)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    static func main() throws {
        do {
            let reserved = AmbientSet(name: "Bad", activation: AmbientActivation(),
                                      overrides: .init(wallpaper: AmbientSetActuationPolicy.currentSelectionTarget))
            do {
                try AmbientSetActuationPolicy.validateUserSets([reserved])
                fail("reserved target accepted as user-authored state")
            } catch AmbientSetActuationError.reservedWallpaperTarget { }
        }

        do {
            let now = Date(timeIntervalSince1970: 100)
            let existing = AmbientManualHold(
                intent: .overrides(.init(wallpaper: AmbientSetActuationPolicy.currentSelectionTarget,
                                         filesVisible: false), label: "Manual"),
                startedAt: now,
                expiry: .untilResumed)
            let merged = AmbientSetActuationPolicy.mergedManualOverrides(
                existing: existing,
                changes: .init(widgetsVisible: false, dimming: .init(enabled: true, level: 0.7)),
                at: now.addingTimeInterval(1))
            expect(merged.wallpaper == AmbientSetActuationPolicy.currentSelectionTarget, "wallpaper manual hold was dropped")
            expect(merged.filesVisible == false, "Files manual override was dropped")
            expect(merged.widgetsVisible == false, "Widgets manual override was not merged")
            expect(merged.dimming == .init(enabled: true, level: 0.7), "dimming manual override was not merged")
        }

        do {
            let expired = AmbientManualHold(
                intent: .overrides(.init(filesVisible: false), label: "Old"),
                startedAt: Date(timeIntervalSince1970: 0),
                expiry: .at(Date(timeIntervalSince1970: 10)))
            let merged = AmbientSetActuationPolicy.mergedManualOverrides(
                existing: expired, changes: .init(widgetsVisible: false), at: Date(timeIntervalSince1970: 20))
            expect(merged.filesVisible == nil && merged.widgetsVisible == false, "expired manual state leaked into a new hold")
        }

        do {
            let collection = AmbientLegacyCollectionSchedule(collectionID: "c1", collectionName: "Evening",
                                                              startMinute: 19 * 60, endMinute: 23 * 60,
                                                              weekdays: [2, 3, 4, 5, 6])
            let bedtime = AmbientLegacyBedtime(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60,
                                                dimLevel: 0.9, nightSceneID: "night")
            let sets = try AmbientLegacyMigrationPlan.make(collections: [collection], followsSun: true,
                                                           nightSceneID: "night", bedtime: bedtime)
            expect(sets.map(\.id) == ["legacy.bedtime", "legacy.day-night.night", "legacy.collection.c1"],
                   "legacy migration priority order changed")
            expect(sets[0].overrides.dimming?.enabled == true, "Bedtime dimming disappeared")
            expect(sets[0].overrides.wallpaper == .scene("night"), "Bedtime lost the legacy night scene")
        }

        do {
            let collection = AmbientLegacyCollectionSchedule(collectionID: "c1", collectionName: "Evening",
                                                              startMinute: 19 * 60, endMinute: 23 * 60,
                                                              weekdays: nil)
            let bedtime = AmbientLegacyBedtime(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60,
                                                dimLevel: 0.9, nightSceneID: nil)
            do {
                _ = try AmbientLegacyMigrationPlan.make(collections: [collection], followsSun: false,
                                                        nightSceneID: nil, bedtime: bedtime)
                fail("unsafe Bedtime/collection overlap converted silently")
            } catch AmbientSetActuationError.unsafeLegacyBedtimeOverlap { }

            let safe = try AmbientLegacyMigrationPlan.make(collections: [], followsSun: false,
                                                            nightSceneID: nil, bedtime: bedtime)
            expect(safe.count == 1 && safe[0].id == "legacy.bedtime", "dim-only Bedtime migration should work without collection schedules")
        }

        print("AmbientSetActuationTests passed")
    }
}
