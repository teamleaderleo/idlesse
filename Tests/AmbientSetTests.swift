import Foundation

@main
private struct AmbientSetTests {

    private static func fail(_ message: String) -> Never {
        fputs("AmbientSetTests: \(message)\n", stderr)
        exit(1)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    private static var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static let base = ResolvedDesktopState(wallpaper: .scene("default"), filesVisible: true, widgetsVisible: true,
                                            dimming: AmbientDimmingState(enabled: false, level: 0.9))
    private static let resolver = AmbientSetResolver()


    static func main() throws {
        // Ordered priority: first matching automatic set wins and lower matches remain explainable.
        do {
            let first = AmbientSet(id: "first", name: "First", activation: AmbientActivation(timeRange: .init(startMinute: 18 * 60, endMinute: 23 * 60)),
                                   overrides: .init(wallpaper: .scene("one")))
            let second = AmbientSet(id: "second", name: "Second", activation: AmbientActivation(timeRange: .init(startMinute: 19 * 60, endMinute: 22 * 60)),
                                    overrides: .init(wallpaper: .scene("two")))
            let resolution = resolver.resolve(sets: [first, second], arrangementDefault: base, now: date(2026, 9, 11, 20), calendar: calendar)
            expect(resolution.explanation.activeSetID == "first", "priority winner changed")
            expect(resolution.explanation.alsoMatched.map(\.id) == ["second"], "overlap explanation missing")
            expect(resolution.state.wallpaper == .scene("one"), "winner override not applied")
        }

        // Scene targets persist an explicit variant reference; legacy targets decode as Default.
        do {
            let midnight = UUID()
            let target = AmbientWallpaperTarget.scene("undertow", variantID: midnight)
            let decoded = try JSONDecoder().decode(AmbientWallpaperTarget.self, from: JSONEncoder().encode(target))
            expect(decoded == target, "scene variant reference did not round-trip")
            let legacy = Data(#"{"kind":"scene","id":"undertow"}"#.utf8)
            let legacyTarget = try JSONDecoder().decode(AmbientWallpaperTarget.self, from: legacy)
            expect(legacyTarget == .scene("undertow"), "legacy Ambient scene target did not decode as Default")
            expect(!AmbientWallpaperTarget(kind: .collection, id: "c1", variantID: midnight).isValid,
                   "collection target accepted a direct variant instead of its per-item selections")
        }

        // Sparse overrides inherit the arrangement default.
        do {
            let set = AmbientSet(id: "reading", name: "Reading", activation: AmbientActivation(),
                                 overrides: .init(filesVisible: false, dimming: .init(enabled: true, level: 0.7)))
            let resolution = resolver.resolve(sets: [set], arrangementDefault: base, now: date(2026, 9, 11, 12), calendar: calendar)
            expect(resolution.state.wallpaper == .scene("default"), "sparse wallpaper inheritance failed")
            expect(resolution.state.filesVisible == false && resolution.state.widgetsVisible == true, "visibility inheritance failed")
            expect(resolution.state.dimming == AmbientDimmingState(enabled: true, level: 0.7), "dimming override failed")
        }

        // Overnight weekdays use the day the interval starts, preserving collection schedule semantics.
        do {
            let friday = AmbientSet(id: "fri", name: "Friday Night",
                                    activation: AmbientActivation(timeRange: .init(startMinute: 22 * 60, endMinute: 7 * 60), weekdays: [6]),
                                    overrides: .init(wallpaper: .scene("night")))
            let fridayLate = resolver.resolve(sets: [friday], arrangementDefault: base, now: date(2026, 9, 11, 23), calendar: calendar)
            let saturdayEarly = resolver.resolve(sets: [friday], arrangementDefault: base, now: date(2026, 9, 12, 2), calendar: calendar)
            let saturdayLate = resolver.resolve(sets: [friday], arrangementDefault: base, now: date(2026, 9, 12, 23), calendar: calendar)
            expect(fridayLate.explanation.activeSetID == "fri", "Friday start did not match")
            expect(saturdayEarly.explanation.activeSetID == "fri", "overnight spill lost start weekday")
            expect(saturdayLate.explanation.source == .arrangementDefault, "Saturday incorrectly reused Friday rule")
        }

        // Solar night activates at sunset and releases at sunrise; the next boundary is deterministic.
        do {
            let night = AmbientSet(id: "night", name: "Night", activation: AmbientActivation(solar: .night),
                                   overrides: .init(wallpaper: .scene("moon")))
            let solar: AmbientSetResolver.SolarProvider = { value, cal in
                let day = cal.startOfDay(for: value)
                return AmbientSolarEvents(sunrise: cal.date(bySettingHour: 6, minute: 30, second: 0, of: day)!,
                                          sunset: cal.date(bySettingHour: 19, minute: 30, second: 0, of: day)!)
            }
            let evening = resolver.resolve(sets: [night], arrangementDefault: base, now: date(2026, 9, 11, 20), calendar: calendar, solarProvider: solar)
            expect(evening.explanation.activeSetID == "night", "solar night did not activate")
            expect(evening.explanation.nextChange?.date == date(2026, 9, 12, 6, 30), "solar next boundary is wrong")
        }

        // Manual hold captures the next winner change once. Re-resolving before it never moves the expiry.
        do {
            let work = AmbientSet(id: "work", name: "Work", activation: AmbientActivation(timeRange: .init(startMinute: 9 * 60, endMinute: 17 * 60)),
                                  overrides: .init(wallpaper: .scene("work")))
            let reading = AmbientSet(id: "reading", name: "Reading", overrides: .init(wallpaper: .scene("read")))
            let start = date(2026, 9, 11, 10)
            let hold = resolver.makeManualHold(intent: .set(id: "reading"), policy: .untilNextAutomaticChange,
                                               sets: [work, reading], now: start, calendar: calendar)
            guard case .at(let expiry) = hold.expiry else { fail("manual hold lacked automatic boundary") }
            expect(expiry == date(2026, 9, 11, 17), "manual hold expiry should be 17:00")
            let later = resolver.resolve(sets: [work, reading], arrangementDefault: base, manualHold: hold,
                                         now: date(2026, 9, 11, 16, 30), calendar: calendar)
            expect(later.explanation.source == .manualSet && later.state.wallpaper == .scene("read"), "manual hold lost before boundary")
            expect(later.explanation.nextChange?.date == expiry, "manual expiry drifted on refresh")
            let after = resolver.resolve(sets: [work, reading], arrangementDefault: base, manualHold: hold,
                                         now: date(2026, 9, 11, 17), calendar: calendar)
            expect(after.explanation.source == .arrangementDefault, "manual hold survived its explicit boundary")
        }

        // Next-boundary search skips a lower-priority rule's edges when the winner stays unchanged.
        do {
            let allDay = AmbientSet(id: "top", name: "Top", activation: AmbientActivation(), overrides: .init(wallpaper: .scene("top")))
            let lower = AmbientSet(id: "lower", name: "Lower", activation: AmbientActivation(timeRange: .init(startMinute: 13 * 60, endMinute: 14 * 60)),
                                   overrides: .init(wallpaper: .scene("lower")))
            let next = resolver.nextAutomaticChange(sets: [allDay, lower], now: date(2026, 9, 11, 12), calendar: calendar)
            expect(next == nil, "lower-priority edge incorrectly counted as a winner change")
        }

        // Legacy adapters create explicit, sparse sets without silently mutating legacy settings.
        do {
            let collection = AmbientLegacyAdapter.collectionSet(from: .init(collectionID: "c1", collectionName: "Psychedelic",
                                                                              startMinute: 19 * 60, endMinute: 23 * 60, weekdays: [2,3,4,5,6]))
            expect(collection?.overrides.wallpaper == .collection("c1"), "collection migration target wrong")
            expect(collection?.activation?.weekdays == [2,3,4,5,6], "collection weekdays lost")

            let bedtime = AmbientLegacyAdapter.bedtimeSet(from: .init(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60,
                                                                       dimLevel: 0.98, nightSceneID: "night-scene"))
            expect(bedtime?.overrides.wallpaper == .scene("night-scene"), "bedtime scene lost")
            expect(bedtime?.overrides.dimming == .init(enabled: true, level: 0.98), "bedtime dimming lost")

            let night = AmbientLegacyAdapter.dayNightSet(from: .init(nightSceneID: "night-scene", followsSun: true))
            expect(night?.activation?.solar == .night, "day/night migration lost solar activation")
        }

        // Catalog persistence keeps ordering, rejects stale holds and bounds growth.
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-ambient-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("ambient-sets.json")
            let store = try AmbientSetStore(fileURL: file)
            let a = AmbientSet(id: "a", name: "A")
            let b = AmbientSet(id: "b", name: "B")
            try store.replaceAll([a, b])
            try store.move(id: "b", to: 0)
            let reloaded = try AmbientSetStore(fileURL: file)
            expect(reloaded.catalog.sets.map(\.id) == ["b", "a"], "priority order did not persist")
            let hold = AmbientManualHold(intent: .set(id: "a"), startedAt: date(2026, 9, 11, 10),
                                         expiry: .at(date(2026, 9, 11, 17)))
            try reloaded.setManualHold(hold)
            let withHold = try AmbientSetStore(fileURL: file)
            expect(withHold.catalog.manualHold == hold, "manual hold did not persist")
            try withHold.remove(id: "a")
            expect(withHold.catalog.manualHold == nil, "deleting a held set left a stale hold")
            do {
                try withHold.setManualHold(.init(intent: .set(id: "missing"), startedAt: date(2026, 9, 11, 10), expiry: .untilResumed))
                fail("manual hold accepted a missing Set")
            } catch AmbientSetStoreError.invalidManualHold { }
            expect(withHold.catalog.manualHold == nil, "rejected manual hold changed catalog state")
            do {
                try withHold.replaceAll([b, b])
                fail("duplicate IDs accepted")
            } catch AmbientSetStoreError.duplicateID { }
            do {
                let tooMany = (0...AmbientSetResolver.maxSets).map { AmbientSet(id: "set-\($0)", name: "Set \($0)") }
                try withHold.replaceAll(tooMany)
                fail("unbounded set count accepted")
            } catch AmbientSetStoreError.tooManySets { }

            let blocker = folder.appendingPathComponent("blocked-parent")
            try Data([1]).write(to: blocker)
            let unwritable = try AmbientSetStore(fileURL: blocker.appendingPathComponent("ambient-sets.json"))
            do {
                try unwritable.replaceAll([a])
                fail("write through a non-directory parent unexpectedly succeeded")
            } catch { }
            expect(unwritable.catalog.sets.isEmpty, "failed persistence mutated the in-memory catalog")
        }

        print("AmbientSetTests passed")
    }
}
