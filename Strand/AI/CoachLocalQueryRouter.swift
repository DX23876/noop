import Foundation

/// A transparent local routing rule for providers that cannot call tools (most importantly a local
/// OpenAI-compatible server). It recognises only an explicit long-history request and selects one known
/// metric; ordinary coaching questions still use the compact recent-data context. This is deliberately
/// not a hidden model: its small vocabulary is inspectable and unit-tested.
struct CoachLocalQueryRouter {
    struct MetricHistoryRequest: Equatable {
        let metric: String
        let days: Int
    }

    static func metricHistoryRequest(for question: String) -> MetricHistoryRequest? {
        let folded = folded(question)
        let words = words(in: folded)
        guard let days = explicitHistoryDays(words: words, text: folded), let metric = metric(in: words) else { return nil }
        return MetricHistoryRequest(metric: metric, days: days)
    }

    /// The second stage is deliberately separate from the known aliases above. It lets the caller match
    /// a literal, locally present key (for example a user-imported `vitamin_d`) without expanding this
    /// routing vocabulary into a second medical catalogue.
    static func explicitHistoryDays(for question: String) -> Int? {
        let text = folded(question)
        return explicitHistoryDays(words: words(in: text), text: text)
    }

    /// A long-range workout question needs the workout store, not the numeric metric catalog and never
    /// the Lab Book merely because a custom journal field happens to share one of its words.
    static func requestsWorkoutHistory(for question: String) -> Bool {
        let text = folded(question)
        let questionWords = words(in: text)
        guard explicitHistoryDays(words: questionWords, text: text) != nil else { return false }
        let workoutWords: Set<String> = [
            "workout", "workouts", "training", "trainings", "session", "sessions",
            "exercise", "sport", "activity", "activities", "einheit", "einheiten",
            "aktivitat", "aktivitaten"
        ]
        return !questionWords.isDisjoint(with: workoutWords)
    }

    /// A broad local-data inventory is itself an explicit request. It may expose only metadata, but it
    /// can still reveal which health domains exist on the device, so the tool policy must not offer it on
    /// every ordinary coaching turn. A genuine long-history question also qualifies because the catalog
    /// can be the safe first step when the requested imported metric is not one of the built-in aliases.
    static func requestsDataCatalog(for question: String) -> Bool {
        let text = folded(question)
        let questionWords = words(in: text)
        if explicitHistoryDays(words: questionWords, text: text) != nil { return true }
        if questionWords.contains("datenkatalog") || (questionWords.contains("data") && questionWords.contains("catalog")) {
            return true
        }
        let phrases = [
            "what data", "which data", "what metrics", "which metrics", "available data", "available metrics",
            "welche daten", "welche werte", "welche metriken", "verfugbare daten", "vorhandene daten"
        ]
        return phrases.contains { text.contains($0) }
    }

    /// Structured diary values can be sensitive even though they are not free-form prose. A direct log
    /// read is therefore exposed only when the question itself names a log topic; ordinary coaching uses
    /// the separate, aggregate-only personal-pattern path instead. `knownQuestions` comes from the local
    /// catalog, so a user-added "Fish oil" or "CBD" field works without hard-coding a private vocabulary
    /// or sending the catalog to the provider.
    static func requestsPersonalLogs(for question: String, knownQuestions: [String] = []) -> Bool {
        let text = folded(question)
        let questionWords = words(in: text)
        let logWords: Set<String> = [
            "journal", "diary", "tagebuch", "log", "logs", "caffeine", "coffee", "kaffee",
            "hydration", "water", "wasser", "mood", "stimmung", "lab", "labor", "marker"
        ]
        if !questionWords.isDisjoint(with: logWords) { return true }

        // "Did I take fish oil last week?" is an explicit retrospective question, unlike "Is fish oil
        // useful?". Require that recall wording AND an overlap with a configured field, so a generic
        // coaching question about stress never opens the direct-entry reader merely because a stress
        // checkbox exists in the catalog.
        let recallWords: Set<String> = [
            "did", "have", "was", "were", "when", "last", "history", "remember",
            "habe", "hatte", "wann", "letzte", "letzten", "verlauf", "erinner"
        ]
        guard !questionWords.isDisjoint(with: recallWords) else { return false }
        // Starter labels are phrased as English questions ("Did you …?"). Those grammatical words
        // cannot count as a field match, or "Did I run last week?" would accidentally open the journal.
        let grammarWords: Set<String> = [
            "did", "does", "do", "you", "your", "i", "my", "have", "has", "had", "was", "were",
            "take", "taken", "feel", "felt", "any", "the", "and", "or", "in", "on", "at", "of",
            "habe", "hast", "hatte", "ich", "mein", "meine", "genommen", "gefuhlt", "und", "oder"
        ]
        let queryTopics = questionWords.subtracting(recallWords).subtracting(grammarWords)
        guard !queryTopics.isEmpty else { return false }
        return knownQuestions.contains { known in
            let knownTopics = words(in: folded(known))
                .filter { $0.count >= 3 && !grammarWords.contains($0) }
            return !queryTopics.isDisjoint(with: Set(knownTopics))
        }
    }

    private static func explicitHistoryDays(words: Set<String>, text: String) -> Int? {
        guard requestsLongHistory(words: words, text: text) else { return nil }
        return requestedDays(in: text)
    }

    private static func folded(_ question: String) -> String {
        question
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    private static func words(in text: String) -> Set<String> {
        Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private static func requestsLongHistory(words: Set<String>, text: String) -> Bool {
        let direct = ["history", "historical", "trend", "trajectory", "development", "developed",
                      "verlauf", "entwicklung", "entwickelt", "langzeit"]
        if direct.contains(where: words.contains) { return true }
        if (words.contains("over") && words.contains("time")) || (words.contains("uber") && words.contains("zeit")) {
            return true
        }
        if text.contains("last year") || text.contains("letztes jahr") { return true }
        let historyWords: Set<String> = [
            "last", "past", "over", "previous", "uber", "letzte", "letzten", "letztes",
            "vergangene", "vergangenen"
        ]
        return !words.isDisjoint(with: historyWords) && requestedYearCount(in: text) != nil
    }

    private static func metric(in words: Set<String>) -> String? {
        if intersects(words, ["weight", "gewicht", "bodyweight", "body", "mass", "kg"]) { return "weight" }
        if intersects(words, ["hrv", "variability", "variabilitat", "herzfrequenzvariabilitat"]) { return "hrv" }
        if intersects(words, ["resting", "rhr", "ruhepuls", "restinghr"]) { return "resting_hr" }
        if intersects(words, ["sleep", "schlaf", "asleep"]) { return "sleep_total_min" }
        if intersects(words, ["steps", "schritte", "walking"]) { return "steps" }
        if intersects(words, ["ferritin", "eisen", "iron"]) { return "ferritin" }
        return nil
    }

    private static func requestedDays(in text: String) -> Int {
        if let years = requestedYearCount(in: text) {
            return max(7, min(years * 365, 3_650))
        }
        return 365
    }

    private static func requestedYearCount(in text: String) -> Int? {
        let pattern = "\\b(\\d{1,2})\\s*(?:years?|jahre[n]?)\\b"
        if let range = text.range(of: pattern, options: .regularExpression) {
            let match = String(text[range])
            return match.split { !$0.isNumber }.first.flatMap { Int($0) }
        }
        if text.contains("last year") || text.contains("letztes jahr") { return 1 }
        let words: [String: Int] = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
            "ein": 1, "einem": 1, "einen": 1, "einer": 1,
            "zwei": 2, "drei": 3, "vier": 4, "funf": 5,
            "sechs": 6, "sieben": 7, "acht": 8, "neun": 9, "zehn": 10
        ]
        for (word, count) in words {
            let wordPattern = "\\b\(word)\\s+(?:years?|jahre[n]?)\\b"
            if text.range(of: wordPattern, options: .regularExpression) != nil { return count }
        }
        return nil
    }

    private static func intersects(_ lhs: Set<String>, _ rhs: [String]) -> Bool {
        !lhs.isDisjoint(with: Set(rhs))
    }
}

/// A narrow, local-only classification for journal labels that can reveal sexual, relationship, illness
/// or cannabis information. It never diagnoses or interprets a value; it only keeps these labels behind
/// the additional sensitive-logs consent. The ordinary journal remains available under its existing grant.
enum CoachSensitiveJournalPolicy {
    private static let terms: Set<String> = [
        "sex", "sexual", "masturbat", "orgasm", "intim", "beziehung", "relationship", "partner",
        "single", "alleinsteh", "cbd", "cannabis", "marijuana", "cannabidiol", "illness", "sick",
        "ill", "krank"
    ]

    static func isSensitive(label: String) -> Bool {
        let words = Set(label.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return words.contains { word in terms.contains { word.hasPrefix($0) } }
    }

    static func questionNamesSensitiveTopic(_ question: String) -> Bool { isSensitive(label: question) }
}
