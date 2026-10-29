import Foundation

extension CoachGoal {
    /// Calendar-day overdue count shared by goal monitoring and proactive review. A target passed
    /// less than a calendar day ago must not become one full day overdue through duration rounding.
    func daysPastTarget(now: Date = Date()) -> Int? {
        guard let target = targetDate else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: target),
                                        to: calendar.startOfDay(for: now)).day
    }
}
