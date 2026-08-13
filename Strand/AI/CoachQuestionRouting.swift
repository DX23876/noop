import Foundation
import NaturalLanguage

/// The four routing decisions the per-turn tool policy needs about a question, as a value.
///
/// `CoachLocalQueryRouter` answers them from an English/German word list. That list decides which tools
/// a question is even allowed to open — on EVERY provider, not just the tool-less local one its own doc
/// comment describes. So on a language the list doesn't speak, long-history, data-catalog and log tools
/// are never offered at all: the coach silently cannot answer "quanti allenamenti ho fatto negli ultimi
/// 90 giorni?", and nothing on screen says why.
///
/// Splitting the decisions out as a struct lets the same policy be fed either by the lexicon (fast,
/// offline, unit-tested) or by the cheap model, without the policy caring which produced them.
struct CoachQuestionRouting: Equatable {
    /// How many days of history the question explicitly asks for, or nil for "not a history question".
    var historyDays: Int?
    var wantsWorkoutHistory: Bool
    var wantsDataCatalog: Bool
    var wantsPersonalLogs: Bool

    static let none = CoachQuestionRouting(historyDays: nil, wantsWorkoutHistory: false,
                                           wantsDataCatalog: false, wantsPersonalLogs: false)

    /// The lexicon's verdict — the exact same four calls the policy used to make inline.
    static func lexicon(for question: String, knownJournalQuestions: [String]) -> CoachQuestionRouting {
        CoachQuestionRouting(
            historyDays: CoachLocalQueryRouter.explicitHistoryDays(for: question),
            wantsWorkoutHistory: CoachLocalQueryRouter.requestsWorkoutHistory(for: question),
            wantsDataCatalog: CoachLocalQueryRouter.requestsDataCatalog(for: question),
            wantsPersonalLogs: CoachLocalQueryRouter.requestsPersonalLogs(
                for: question, knownQuestions: knownJournalQuestions))
    }
}

/// Which language a question is in, and whether the routing lexicon actually speaks it.
///
/// On-device (Apple's `NaturalLanguage`), so this costs nothing, works offline and sends nothing
/// anywhere — the detection itself must not become a reason to make a network call.
enum CoachQuestionLanguage {
    /// The languages `CoachLocalQueryRouter`'s word lists are written in. Keep this in step with them:
    /// adding vocabulary for a language without adding it here just means the cheap model keeps doing
    /// work the lexicon could now do for free.
    static let lexiconLanguages: Set<String> = ["en", "de"]

    /// The dominant language code ("en", "de", "it", …), or nil when there isn't enough text to tell.
    ///
    /// Short questions are genuinely ambiguous ("ok?", "5k?"), and a wrong guess on a two-word question
    /// would route an English user through the model for nothing — so anything under `minimumCharacters`
    /// is reported as undetermined and treated as covered.
    static let minimumCharacters = 12

    static func dominantCode(of question: String) -> String? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage else { return nil }
        return language.rawValue
    }

    /// True when the lexicon can be trusted for this question: it is in a language the word lists cover,
    /// or too short to judge (in which case the lexicon's own miss is no worse than a coin flip).
    static func lexiconCovers(_ question: String) -> Bool {
        guard let code = dominantCode(of: question) else { return true }
        return lexiconLanguages.contains(code)
    }
}
