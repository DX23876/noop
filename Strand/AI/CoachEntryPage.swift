import Foundation

/// The page the chat was last opened from through its header button (owner, 2026-11-21): which of the five main
/// pages and which day it showed. The coach is told this quietly with every question until the chat is opened
/// from another page, so "why was it so short?" on the Sleep page reads that night first. It sends nothing on
/// its own; the page's suggestions are offered as chips instead.
struct CoachEntryPage: Equatable {
    enum Kind: String, CaseIterable {
        case today, training, nutrition, sleep, health

        /// The page's name as the prompt states it, always in English like the rest of the prompt.
        var promptName: String {
            switch self {
            case .today: return "Today"
            case .training: return "Training"
            case .nutrition: return "Nutrition"
            case .sleep: return "Sleep"
            case .health: return "Health"
            }
        }

        /// What the page shows, so the model knows which data to read first.
        var promptContents: String {
            switch self {
            case .today: return "the day's Charge, Effort and Rest, the timeline and today's plan"
            case .training: return "workouts, training load and the week's sessions"
            case .nutrition: return "the food log, energy against the goal, macros and the nutrition quality note"
            case .sleep: return "one night's sleep: stages, timing, sleep need and Rest"
            case .health: return "last night's vitals (HRV, resting heart rate, oxygen, breathing, skin temperature) and long-term health"
            }
        }
    }

    let kind: Kind
    /// The day the page showed, `yyyy-MM-dd`; nil when the page has no single day.
    let day: String?
    /// The page's suggested questions, already in the app's language.
    let suggestions: [String]

    /// The line that rides the question as context. Names only the page and the day, never a value: the
    /// model reads the data itself through the same consented tools as for any other question.
    var promptNote: String {
        var note = "The person opened this chat from the \(kind.promptName) page, which shows \(kind.promptContents)"
        if let day { note += ", for \(day)" }
        note += ". When the question is about what that page shows, read that first. Do not mention this note."
        return note
    }
}
