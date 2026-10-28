import Foundation

extension GoalAction.Requirement {
    /// `label` in the reader's language. The English `label` stays for anything that is not UI; a
    /// composed English string cannot be looked up in the catalog afterwards, so each part is
    /// localized here with its own key.
    var displayLabel: String {
        switch self {
        case .steps(let minimum): return String(localized: "\(minimum.formatted()) steps")
        case .workout(let sports, let minutes):
            let activity = sports.isEmpty ? String(localized: "Any workout") : sports.joined(separator: ", ")
            return minutes.map { String(localized: "\(activity) · \($0) min") } ?? activity
        case .sleep(let hours):
            return String(localized: "\(hours.formatted(.number.precision(.fractionLength(0...1)))) h sleep")
        case .activeCalories(let minimum):
            return String(localized: "\(minimum.formatted()) kcal active (estimate)")
        // Nothing to say: ticking a box by hand is what a goal without a measure is.
        case .manual: return ""
        case .journal(let question, let wantsYes):
            let habit = JournalLabel.display(question)
            return wantsYes ? String(localized: "Ticks when you log yes: \(habit)")
                            : String(localized: "Ticks when you log no: \(habit)")
        }
    }
}
