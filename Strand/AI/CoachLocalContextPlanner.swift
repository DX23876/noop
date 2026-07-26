import Foundation

/// A small, inspectable on-device router for providers that cannot call coach tools. It chooses context
/// *categories*, never values, from the user's own wording. The engine applies consent separately, so a
/// match can request less context but can never grant a purpose the person has not enabled.
struct CoachLocalContextPlanner {
    enum Section: Hashable {
        case compactBiometrics
        case detailedBiometrics
        case readiness
        case workouts
        case planning
        case trainingPreferences
        case stress
        case patterns
        case conversationMemory
    }

    static func sections(for question: String) -> Set<Section> {
        let text = question
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let words = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))

        // A long-history question receives its evidence through the separate aggregate-only router. Do
        // not add a 14-day table simply because its wording happens to include "trend" or "last".
        if CoachLocalQueryRouter.explicitHistoryDays(for: question) != nil {
            return [.compactBiometrics]
        }

        var result: Set<Section> = [.compactBiometrics]
        if intersects(words, ["train", "training", "run", "running", "jog", "jogging", "workout", "gym", "lift", "lifting", "ride", "cycling", "cycle", "zone", "effort", "session", "exercise", "sport", "lauf", "laufen", "joggen", "training", "rad", "kraft", "einheit"]) {
            result.formUnion([.readiness, .workouts, .planning, .trainingPreferences])
        }
        if intersects(words, ["today", "today's", "recovery", "readiness", "charge", "recover", "heute", "erholung", "bereit"]) {
            result.insert(.readiness)
        }
        if intersects(words, ["sleep", "asleep", "bed", "wake", "schlaf", "schlafen", "bett", "wach"]) {
            result.formUnion([.detailedBiometrics, .readiness])
        }
        if intersects(words, ["trend", "change", "changed", "week", "weeks", "month", "months", "why", "hrv", "rhr", "weight", "steps", "oxygen", "spo2", "verlauf", "anderung", "woche", "monat", "warum", "gewicht", "schritte", "sauerstoff"]) {
            result.insert(.detailedBiometrics)
        }
        if intersects(words, ["plan", "schedule", "tomorrow", "week", "goal", "swap", "skip", "decline", "planned", "morgen", "woche", "ziel", "tauschen", "auslassen", "ablehnen", "geplant"]) {
            result.insert(.planning)
        }
        if intersects(words, ["stress", "stressed", "anxious", "pressure", "gestresst", "stressig", "anspannung"]) {
            result.insert(.stress)
        }
        if intersects(words, ["pattern", "patterns", "caffeine", "coffee", "alcohol", "habit", "behavior", "muster", "kaffee", "alkohol", "gewohnheit", "verhalten"]) {
            result.insert(.patterns)
        }
        if intersects(words, ["remember", "remembered", "previous", "before", "earlier", "yesterday", "conversation", "chat", "erinner", "vorher", "gestern", "unterhaltung"]) {
            result.insert(.conversationMemory)
        }
        return result
    }

    private static func intersects(_ lhs: Set<String>, _ rhs: [String]) -> Bool {
        !lhs.isDisjoint(with: Set(rhs))
    }
}
