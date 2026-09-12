import Foundation

@main
private struct AmbientSetActuationTests {
    private enum InjectedFailure: Error { case write }

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

        // Arrangement Default keeps the complete display assignment intent and
        // rejects oversized/unbounded persisted values before they reach actuation.
        do {
            let plan = PersistedWallpaperAssignmentPlan(
                mode: .perDisplay,
                topologySignature: "desk+dock",
                baseBookmark: Data([1, 2, 3]),
                assignments: [
                    .init(persistentKey: "display-a", bookmark: Data([4]), explicit: true),
                    .init(persistentKey: "display-b", bookmark: Data([5]), explicit: true),
                ])
            expect(plan.isValid, "valid per-display Arrangement Default rejected")
            let snapshot = AmbientArrangementSnapshot(wallpaperPlan: plan,
                                                      filesVisible: false,
                                                      widgetsVisible: true,
                                                      dimming: .init(enabled: true, level: 0.72))
            expect(snapshot.resolvedState.filesVisible == false, "Files baseline changed")
            expect(snapshot.resolvedState.widgetsVisible == true, "Widgets baseline changed")
            expect(snapshot.resolvedState.dimming == .init(enabled: true, level: 0.72), "real dimming baseline changed")
            expect(snapshot.resolvedState.wallpaper == AmbientSetActuationPolicy.arrangementDefaultTarget,
                   "Arrangement Default sentinel changed")

            let tooMany = PersistedWallpaperAssignmentPlan(
                mode: .sameOnAll,
                topologySignature: "bad",
                baseBookmark: nil,
                assignments: (0...PersistedWallpaperAssignmentPlan.maxAssignments).map {
                    .init(persistentKey: "d\($0)", bookmark: Data([1]), explicit: true)
                })
            expect(!tooMany.isValid, "unbounded display assignment snapshot accepted")
        }

        // Legacy schedule handoff transforms every scheduled collection in one
        // catalog value. A writer failure occurs before any replacement is visible.
        do {
            var catalog = SceneLibraryStore.Catalog()
            catalog.collections = [
                .init(name: "Morning", playback: .init(minutes: 10, shuffle: false,
                                                       startMinute: 480, endMinute: 600, weekdays: [2, 3])),
                .init(name: "Evening", playback: .init(minutes: 20, shuffle: true,
                                                       startMinute: 1080, endMinute: 1320, weekdays: nil)),
                .init(name: "Manual", playback: .init(minutes: 30, shuffle: false,
                                                      startMinute: nil, endMinute: nil, weekdays: nil)),
            ]
            let backup = AmbientLegacyScheduleTransaction.backup(from: catalog)
            expect(backup.count == 2, "legacy schedule backup lost scheduled collections")
            let suspended = AmbientLegacyScheduleTransaction.suspending(catalog)
            expect(suspended.collections[0].playback?.startMinute == nil &&
                   suspended.collections[1].playback?.endMinute == nil,
                   "legacy schedules were only partially suspended")
            let restored = AmbientLegacyScheduleTransaction.restoring(suspended, backup: backup)
            expect(restored.collections[0].playback == catalog.collections[0].playback &&
                   restored.collections[1].playback == catalog.collections[1].playback,
                   "legacy schedule rollback did not restore the original playback values")

            let file = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-ambient-atomic-\(UUID()).json")
            let original = Data("sentinel".utf8)
            try original.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                try AmbientLegacyScheduleTransaction.write(suspended, to: file) { _, _ in
                    throw InjectedFailure.write
                }
                fail("injected schedule write failure was swallowed")
            } catch InjectedFailure.write { }
            expect((try? Data(contentsOf: file)) == original, "failed cutover modified the Library index")
        }

        print("AmbientSetActuationTests passed")
    }
}
