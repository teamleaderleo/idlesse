import Foundation

struct AmbientWallpaperTarget: Codable, Equatable, Hashable {
    static let maxIdentifierLength = 256

    enum Kind: String, Codable { case scene, collection }
    var kind: Kind
    var id: String

    var isValid: Bool { !id.isEmpty && id.count <= Self.maxIdentifierLength }

    static func scene(_ id: String) -> Self { .init(kind: .scene, id: id) }
    static func collection(_ id: String) -> Self { .init(kind: .collection, id: id) }
}

struct AmbientDimmingState: Codable, Equatable {
    var enabled: Bool
    var level: Double

    init(enabled: Bool, level: Double) {
        self.enabled = enabled
        self.level = Self.clamp(level)
    }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0.9 }
        return min(0.98, max(0.2, value))
    }
}

struct AmbientDimmingOverride: Codable, Equatable {
    var enabled: Bool
    var level: Double?

    init(enabled: Bool, level: Double? = nil) {
        self.enabled = enabled
        self.level = level.map(AmbientDimmingState.clamp)
    }
}

struct AmbientDesktopOverrides: Codable, Equatable {
    var wallpaper: AmbientWallpaperTarget?
    var filesVisible: Bool?
    var widgetsVisible: Bool?
    var dimming: AmbientDimmingOverride?

    init(wallpaper: AmbientWallpaperTarget? = nil,
         filesVisible: Bool? = nil,
         widgetsVisible: Bool? = nil,
         dimming: AmbientDimmingOverride? = nil) {
        self.wallpaper = wallpaper
        self.filesVisible = filesVisible
        self.widgetsVisible = widgetsVisible
        self.dimming = dimming
    }

    var isValid: Bool { wallpaper?.isValid ?? true }
}

struct ResolvedDesktopState: Codable, Equatable {
    var wallpaper: AmbientWallpaperTarget?
    var filesVisible: Bool
    var widgetsVisible: Bool
    var dimming: AmbientDimmingState

    func applying(_ overrides: AmbientDesktopOverrides) -> ResolvedDesktopState {
        var result = self
        if let wallpaper = overrides.wallpaper { result.wallpaper = wallpaper }
        if let filesVisible = overrides.filesVisible { result.filesVisible = filesVisible }
        if let widgetsVisible = overrides.widgetsVisible { result.widgetsVisible = widgetsVisible }
        if let dimming = overrides.dimming {
            result.dimming.enabled = dimming.enabled
            if let level = dimming.level { result.dimming.level = AmbientDimmingState.clamp(level) }
        }
        return result
    }
}

struct AmbientTimeRange: Codable, Equatable, Hashable {
    var startMinute: Int
    var endMinute: Int

    var isValid: Bool {
        (0..<1440).contains(startMinute) && (0..<1440).contains(endMinute) && startMinute != endMinute
    }

    var crossesMidnight: Bool { startMinute > endMinute }

    func contains(minute: Int) -> Bool {
        guard isValid, (0..<1440).contains(minute) else { return false }
        return crossesMidnight ? (minute >= startMinute || minute < endMinute)
                               : (minute >= startMinute && minute < endMinute)
    }
}

enum AmbientSolarCondition: String, Codable, Equatable, Hashable {
    /// The interval beginning at local sunset and ending at the following sunrise.
    case night
}

struct AmbientActivation: Codable, Equatable, Hashable {
    var timeRange: AmbientTimeRange?
    /// Calendar weekday numbers (1 = Sunday ... 7 = Saturday). For an overnight
    /// range, the selected weekday is the day on which the range starts.
    var weekdays: Set<Int>?
    var solar: AmbientSolarCondition?

    init(timeRange: AmbientTimeRange? = nil,
         weekdays: Set<Int>? = nil,
         solar: AmbientSolarCondition? = nil) {
        self.timeRange = timeRange
        self.weekdays = weekdays
        self.solar = solar
    }

    var isValid: Bool {
        if let timeRange, !timeRange.isValid { return false }
        if let weekdays {
            if weekdays.isEmpty || weekdays.contains(where: { !(1...7).contains($0) }) { return false }
        }
        return true
    }
}

struct AmbientSet: Codable, Equatable, Identifiable {
    static let maxNameLength = 80
    static let maxIdentifierLength = 256

    var id: String
    var name: String
    var isEnabled: Bool
    /// nil means Manual Only. Automatic conditions are ANDed.
    var activation: AmbientActivation?
    var overrides: AmbientDesktopOverrides

    init(id: String = UUID().uuidString,
         name: String,
         isEnabled: Bool = true,
         activation: AmbientActivation? = nil,
         overrides: AmbientDesktopOverrides = .init()) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.activation = activation
        self.overrides = overrides
    }

    var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !id.isEmpty && id.count <= Self.maxIdentifierLength && !trimmed.isEmpty && trimmed.count <= Self.maxNameLength &&
            (activation?.isValid ?? true) && overrides.isValid
    }
}

struct AmbientSolarEvents: Equatable {
    var sunrise: Date
    var sunset: Date
}

enum AmbientManualIntent: Codable, Equatable {
    case set(id: String)
    case overrides(AmbientDesktopOverrides, label: String?)
}

enum AmbientManualHoldExpiry: Codable, Equatable {
    case at(Date)
    case untilResumed
}

struct AmbientManualHold: Codable, Equatable {
    static let maxLabelLength = AmbientSet.maxNameLength

    var intent: AmbientManualIntent
    var startedAt: Date
    var expiry: AmbientManualHoldExpiry

    func isActive(at date: Date) -> Bool {
        switch expiry {
        case .untilResumed: return true
        case .at(let boundary): return date < boundary
        }
    }

    var isValid: Bool {
        switch intent {
        case .set(let id):
            return !id.isEmpty && id.count <= AmbientSet.maxIdentifierLength
        case .overrides(let overrides, let label):
            return overrides.isValid && (label?.count ?? 0) <= Self.maxLabelLength
        }
    }
}

enum AmbientManualHoldPolicy {
    case untilNextAutomaticChange
    case untilResumed
}

enum AmbientDecisionSource: String, Codable, Equatable {
    case manualSet
    case manualOverrides
    case automatic
    case arrangementDefault
}

enum AmbientExplanationReason: Codable, Equatable {
    case manualHold
    case priority(Int)
    case timeRange(AmbientTimeRange)
    case weekday(Int)
    case solarNight(sunrise: Date, sunset: Date)
    case arrangementDefault
}

struct AmbientMatchedSet: Codable, Equatable {
    var id: String
    var name: String
    var priority: Int
}

struct AmbientNextChange: Codable, Equatable {
    var date: Date
    var fromSetID: String?
    var toSetID: String?
}

struct AmbientExplanation: Codable, Equatable {
    var source: AmbientDecisionSource
    var activeSetID: String?
    var activeSetName: String?
    var reasons: [AmbientExplanationReason]
    var alsoMatched: [AmbientMatchedSet]
    var nextChange: AmbientNextChange?
}

struct AmbientResolution: Codable, Equatable {
    var state: ResolvedDesktopState
    var explanation: AmbientExplanation
}

struct AmbientSetResolver {
    static let maxSets = 128
    static let boundaryLookaheadDays = 8
    static let maxBoundaryCandidates = 4096

    typealias SolarProvider = (_ date: Date, _ calendar: Calendar) -> AmbientSolarEvents?

    private struct Match {
        var set: AmbientSet
        var priority: Int
        var reasons: [AmbientExplanationReason]
    }

    func resolve(sets: [AmbientSet],
                 arrangementDefault: ResolvedDesktopState,
                 manualHold: AmbientManualHold? = nil,
                 now: Date = Date(),
                 calendar: Calendar = .current,
                 solarProvider: SolarProvider? = nil) -> AmbientResolution {
        let boundedSets = Array(sets.prefix(Self.maxSets))
        let matches = automaticMatches(sets: boundedSets, at: now, calendar: calendar, solarProvider: solarProvider)
        let automaticWinner = matches.first
        var automaticState = arrangementDefault
        if let automaticWinner { automaticState = arrangementDefault.applying(automaticWinner.set.overrides) }

        let otherMatches = matches.dropFirst().map { AmbientMatchedSet(id: $0.set.id, name: $0.set.name, priority: $0.priority) }
        let automaticNext = nextAutomaticChange(sets: boundedSets, now: now, calendar: calendar, solarProvider: solarProvider)

        if let manualHold, manualHold.isActive(at: now) {
            switch manualHold.intent {
            case .set(let id):
                if let manualSet = boundedSets.first(where: { $0.id == id && $0.isEnabled }) {
                    let next = manualNextChange(manualHold, automaticNext: automaticNext, currentAutomatic: automaticWinner?.set.id,
                                                sets: boundedSets, calendar: calendar, solarProvider: solarProvider)
                    return AmbientResolution(
                        state: arrangementDefault.applying(manualSet.overrides),
                        explanation: AmbientExplanation(source: .manualSet,
                                                        activeSetID: manualSet.id,
                                                        activeSetName: manualSet.name,
                                                        reasons: [.manualHold],
                                                        alsoMatched: matches.map { AmbientMatchedSet(id: $0.set.id, name: $0.set.name, priority: $0.priority) },
                                                        nextChange: next))
                }
            case .overrides(let overrides, let label):
                let next = manualNextChange(manualHold, automaticNext: automaticNext, currentAutomatic: automaticWinner?.set.id,
                                            sets: boundedSets, calendar: calendar, solarProvider: solarProvider)
                return AmbientResolution(
                    state: automaticState.applying(overrides),
                    explanation: AmbientExplanation(source: .manualOverrides,
                                                    activeSetID: automaticWinner?.set.id,
                                                    activeSetName: label ?? automaticWinner?.set.name,
                                                    reasons: [.manualHold],
                                                    alsoMatched: otherMatches,
                                                    nextChange: next))
            }
        }

        if let winner = automaticWinner {
            return AmbientResolution(
                state: automaticState,
                explanation: AmbientExplanation(source: .automatic,
                                                activeSetID: winner.set.id,
                                                activeSetName: winner.set.name,
                                                reasons: [.priority(winner.priority)] + winner.reasons,
                                                alsoMatched: otherMatches,
                                                nextChange: automaticNext))
        }

        return AmbientResolution(
            state: arrangementDefault,
            explanation: AmbientExplanation(source: .arrangementDefault,
                                            activeSetID: nil,
                                            activeSetName: nil,
                                            reasons: [.arrangementDefault],
                                            alsoMatched: [],
                                            nextChange: automaticNext))
    }

    func makeManualHold(intent: AmbientManualIntent,
                        policy: AmbientManualHoldPolicy,
                        sets: [AmbientSet],
                        now: Date = Date(),
                        calendar: Calendar = .current,
                        solarProvider: SolarProvider? = nil) -> AmbientManualHold {
        switch policy {
        case .untilResumed:
            return AmbientManualHold(intent: intent, startedAt: now, expiry: .untilResumed)
        case .untilNextAutomaticChange:
            if let boundary = nextAutomaticChange(sets: Array(sets.prefix(Self.maxSets)), now: now,
                                                  calendar: calendar, solarProvider: solarProvider)?.date {
                return AmbientManualHold(intent: intent, startedAt: now, expiry: .at(boundary))
            }
            return AmbientManualHold(intent: intent, startedAt: now, expiry: .untilResumed)
        }
    }

    func nextAutomaticChange(sets: [AmbientSet],
                             now: Date,
                             calendar: Calendar = .current,
                             solarProvider: SolarProvider? = nil) -> AmbientNextChange? {
        let boundedSets = Array(sets.prefix(Self.maxSets))
        let current = automaticMatches(sets: boundedSets, at: now, calendar: calendar, solarProvider: solarProvider).first?.set.id
        for candidate in boundaryCandidates(sets: boundedSets, after: now, calendar: calendar, solarProvider: solarProvider) {
            let next = automaticMatches(sets: boundedSets, at: candidate, calendar: calendar, solarProvider: solarProvider).first?.set.id
            if next != current {
                return AmbientNextChange(date: candidate, fromSetID: current, toSetID: next)
            }
        }
        return nil
    }

    private func manualNextChange(_ hold: AmbientManualHold,
                                  automaticNext: AmbientNextChange?,
                                  currentAutomatic: String?,
                                  sets: [AmbientSet],
                                  calendar: Calendar,
                                  solarProvider: SolarProvider?) -> AmbientNextChange? {
        switch hold.expiry {
        case .untilResumed:
            return nil
        case .at(let date):
            let nextWinner = automaticMatches(sets: sets, at: date, calendar: calendar, solarProvider: solarProvider).first?.set.id
            return AmbientNextChange(date: date, fromSetID: nil, toSetID: nextWinner ?? automaticNext?.toSetID ?? currentAutomatic)
        }
    }

    private func automaticMatches(sets: [AmbientSet],
                                  at date: Date,
                                  calendar: Calendar,
                                  solarProvider: SolarProvider?) -> [Match] {
        var output: [Match] = []
        for (index, set) in sets.enumerated() {
            guard set.isEnabled, set.isValid, let activation = set.activation else { continue }
            if let reasons = matchReasons(activation, at: date, calendar: calendar, solarProvider: solarProvider) {
                output.append(Match(set: set, priority: index + 1, reasons: reasons))
            }
        }
        return output
    }

    private func matchReasons(_ activation: AmbientActivation,
                              at date: Date,
                              calendar: Calendar,
                              solarProvider: SolarProvider?) -> [AmbientExplanationReason]? {
        guard activation.isValid else { return nil }
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let weekday = calendar.component(.weekday, from: date)
        var reasons: [AmbientExplanationReason] = []

        if let timeRange = activation.timeRange {
            guard timeRange.contains(minute: minute) else { return nil }
            reasons.append(.timeRange(timeRange))
            if let weekdays = activation.weekdays {
                let startWeekday: Int
                if timeRange.crossesMidnight && minute < timeRange.endMinute {
                    startWeekday = weekday == 1 ? 7 : weekday - 1
                } else {
                    startWeekday = weekday
                }
                guard weekdays.contains(startWeekday) else { return nil }
                reasons.append(.weekday(startWeekday))
            }
        } else if let weekdays = activation.weekdays {
            guard weekdays.contains(weekday) else { return nil }
            reasons.append(.weekday(weekday))
        }

        if let solar = activation.solar {
            guard solar == .night,
                  let events = solarProvider?(date, calendar),
                  date < events.sunrise || date >= events.sunset else { return nil }
            reasons.append(.solarNight(sunrise: events.sunrise, sunset: events.sunset))
        }
        return reasons
    }

    private func boundaryCandidates(sets: [AmbientSet],
                                    after now: Date,
                                    calendar: Calendar,
                                    solarProvider: SolarProvider?) -> [Date] {
        let automaticSets = sets.filter { $0.isEnabled && $0.isValid && $0.activation != nil }
        guard !automaticSets.isEmpty else { return [] }
        let needsSolar = automaticSets.contains { $0.activation?.solar != nil }
        let startDay = calendar.startOfDay(for: now)
        var candidates = Set<Date>()

        for offset in 0...Self.boundaryLookaheadDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else { continue }
            if day > now { candidates.insert(day) }
            for set in automaticSets {
                guard let range = set.activation?.timeRange else { continue }
                if let start = wallClockDate(minute: range.startMinute, on: day, calendar: calendar), start > now { candidates.insert(start) }
                if let end = wallClockDate(minute: range.endMinute, on: day, calendar: calendar), end > now { candidates.insert(end) }
            }
            if needsSolar, let events = solarProvider?(day, calendar) {
                if events.sunrise > now { candidates.insert(events.sunrise) }
                if events.sunset > now { candidates.insert(events.sunset) }
            }
            if candidates.count >= Self.maxBoundaryCandidates { break }
        }
        return Array(candidates).sorted().prefix(Self.maxBoundaryCandidates).map { $0 }
    }

    private func wallClockDate(minute: Int, on day: Date, calendar: Calendar) -> Date? {
        guard (0..<1440).contains(minute) else { return nil }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
    }
}
