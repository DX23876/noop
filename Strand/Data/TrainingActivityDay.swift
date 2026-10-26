import Foundation
import StrandTraining

/// One day of the Consistency heatmap. Computed once per history load (`TrainingActivityDay.pastYear`),
/// because the heatmap body is re-evaluated whenever its parent redraws and a year of date formatting per
/// redraw is measurable while a workout is being logged.
struct TrainingActivityDay: Hashable, Sendable {
    let day: String
    let minutes: Double

    static func pastYear(sessions: [ResolvedStrengthSession], weekStart: TrainingWeekStart,
                         now: Date = Date()) -> [TrainingActivityDay] {
        var calendar = Calendar.current
        calendar.firstWeekday = weekStart == .sunday ? 1 : 2
        let today = calendar.startOfDay(for: now)
        let earliest = calendar.date(byAdding: .day, value: -363, to: today) ?? today
        let start = calendar.dateInterval(of: .weekOfYear, for: earliest)?.start ?? earliest
        let count = (calendar.dateComponents([.day], from: start, to: today).day ?? 363) + 1
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        var byDay: [String: Double] = [:]
        for session in sessions {
            let day = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(session.startTs)))
            byDay[day, default: 0] += Double(max(0, session.endTs - session.startTs)) / 60
        }
        return (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let day = formatter.string(from: date)
            return TrainingActivityDay(day: day, minutes: byDay[day] ?? 0)
        }
    }
}
