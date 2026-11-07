import Foundation

/// The causes a journal day can name that explain raised body signals: being unwell, alcohol, travel,
/// stress, a hard workout (2026-11-07).
///
/// A cause the app writes itself (the chips under a body-signal notice) carries a fixed key in the entry's
/// notes, so it reads the same in every language. Imported WHOOP questions have no key; they are read by
/// whole English words, as before, but no longer by fragments: "ill" used to match "still" or "Brille",
/// and the stress and travel answers never reached the warning at all.
///
/// Analysis migration required: no. The warning is worked out live from the journal each time and stored
/// nowhere.
enum JournalCause: String, CaseIterable {
    case sick, alcohol, travel, stress, hardWorkout

    /// The key written into the entry's notes.
    var key: String { "noop.cause.\(rawValue)" }

    /// The causes offered as chips under a notice. A hard workout is already known from the workouts.
    static let chips: [JournalCause] = [.sick, .alcohol, .travel, .stress]

    /// The question shown in the journal for an entry the chip writes, in the app's language.
    var question: String {
        switch self {
        case .sick: return String(localized: "Felt unwell")
        case .alcohol: return String(localized: "Drank alcohol")
        case .travel: return String(localized: "Travelled")
        case .stress: return String(localized: "Was under stress")
        case .hardWorkout: return String(localized: "Hard or late workout")
        }
    }

    /// The chip's title.
    var chipTitle: String {
        switch self {
        case .sick: return String(localized: "Unwell")
        case .alcohol: return String(localized: "Alcohol")
        case .travel: return String(localized: "Travel")
        case .stress: return String(localized: "Stress")
        case .hardWorkout: return String(localized: "Hard workout")
        }
    }

    /// Whole English words of imported questions, per cause.
    private var words: [String] {
        switch self {
        case .sick: return ["sick", "ill", "unwell", "illness"]
        case .alcohol: return ["alcohol", "alcoholic", "drink", "drinks", "drank"]
        case .travel: return ["travel", "travelled", "traveled", "travelling", "traveling", "jet lag", "jetlag"]
        case .stress: return ["stress", "stressed", "stressful"]
        case .hardWorkout: return ["workout", "training", "exercise", "exercised"]
        }
    }

    /// The causes named by these yes-answers.
    static func present(in answers: [(question: String, notes: String?)]) -> Set<JournalCause> {
        var found = Set<JournalCause>()
        for answer in answers {
            if let notes = answer.notes, let keyed = allCases.first(where: { notes.contains($0.key) }) {
                found.insert(keyed)
                continue
            }
            let q = answer.question.lowercased()
            for cause in allCases where cause.words.contains(where: { q.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }) {
                found.insert(cause)
            }
        }
        return found
    }
}
