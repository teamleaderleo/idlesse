import AppKit

@main struct ComfortTests {
    static func main() {
        let night = DimSchedule(start: 1320, end: 420)
        for minute in 0..<1440 {
            precondition(night.contains(minute: minute) == (minute >= 1320 || minute < 420))
        }
        let day = DimSchedule(start: 540, end: 1020)
        for minute in 0..<1440 {
            precondition(day.contains(minute: minute) == (minute >= 540 && minute < 1020))
        }
        precondition(!night.contains(minute: -1) && !night.contains(minute: 1440))
        precondition(!DimSchedule(start: 1, end: 1).contains(minute: 1))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        // Civil times must survive both DST transition days, not drift by an hour.
        for (month, day) in [(3, 8), (11, 1)] {
            let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
            for minute in [0, 420, 1320, 1439] {
                let result = DimSchedule.pickerDate(minute: minute, on: date, calendar: calendar)
                let parts = calendar.dateComponents([.hour, .minute], from: result)
                precondition(parts.hour == minute / 60 && parts.minute == minute % 60)
            }
        }
        print("Comfort checks passed: complete daily intervals, invalid minutes, and DST picker times")
    }
}
