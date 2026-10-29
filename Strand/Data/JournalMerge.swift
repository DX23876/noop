import Foundation
import WhoopStore
import StrandCore

/// Reading a journal whose questions the user has merged, and finding the merges worth offering.
///
/// Both halves are pure and live here rather than in `JournalCatalogStore` (which owns the persisted
/// catalog) or in a view, so the rules that decide what a merged day *says* are testable without a
/// store, a screen or a WHOOP export.
enum JournalMerge {

    // MARK: - Reading a merged journal

    /// Rewrite every entry's question to its merge target and keep exactly ONE row per (day, target).
    ///
    /// No row is changed on disk — this is what the app *reads*. That matters for the conflict below:
    /// once two wordings become one question, a day that carries an answer under each has to resolve
    /// to a single answer, and the rule has to be one a person can predict.
    ///
    /// The order, highest first:
    /// 1. **native beats imported** — the same precedence `Repository.mergeJournal` already applies,
    ///    because an answer the user typed here is their own most recent statement,
    /// 2. **the target's own wording beats any alias**,
    /// 3. **earlier alias beats later** — the order the user merged them in.
    ///
    /// Deliberately NOT done: OR-ing yes/no together, or summing numbers. "It said yes somewhere"
    /// would invent a day that never happened; the winner is always one real stored row. (`journal`
    /// has no modified-at column, so "the newest wins" is not available and is not pretended.)
    static func fold(imported: [JournalEntry],
                     native: [JournalEntry],
                     aliases: [String: String],
                     aliasOrder: [String: Int] = [:]) -> [JournalEntry] {
        JournalRead.fold(imported: imported, native: native, aliases: aliases, aliasOrder: aliasOrder)
    }

    /// The same fold for a single day's `question → value` dictionaries the logging card reads. Same
    /// precedence, minus the native/imported step: those reads are native-only by construction.
    static func foldDay<V>(_ values: [String: V],
                           aliases: [String: String],
                           aliasOrder: [String: Int] = [:]) -> [String: V] {
        JournalRead.foldDay(values, aliases: aliases, aliasOrder: aliasOrder)
    }

    /// Where a write for `question` must land: the merge target if it has one. New answers belong to
    /// the question the user actually sees, not to the wording it was folded from.
    static func writeTarget(_ question: String, aliases: [String: String]) -> String {
        JournalRead.writeTarget(question, aliases: aliases)
    }

    // MARK: - The merges offered for review

    /// Two or more wordings to offer as one question.
    ///
    /// Finding them is NOT done here. Word-overlap scoring used to live in this file and was removed:
    /// it failed at both ends of the same limit. "Ein Magnesiumpräparat eingenommen?" and "Ein
    /// Zinkpräparat eingenommen?" share only their German frame, and a tokeniser with an English-only
    /// stopword list counted `ein`/`eingenommen` as agreement — two different supplements scored as a
    /// duplicate. Meanwhile "Alkohol konsumiert?" and "Did you drink any alcohol?" share not one
    /// token, so the real duplicate scored zero. No weighting fixes both: telling magnesium from zinc
    /// takes knowing what they are, which is what `AICoachEngine.journalDuplicateCandidates`
    /// (`Strand/AI/JournalDuplicateReviewer.swift`) asks a model for.
    struct Candidate: Equatable, Identifiable {
        let questions: [String]
        /// The wording proposed as the survivor. The user can pick a different one before merging.
        let suggestedTarget: String
        var id: String { questions.joined(separator: "\u{1F}") }
    }

    /// The wording proposed as the survivor of a group: the one carrying the most stored answers, so
    /// the smaller history is the one that moves. Ties break on the wording itself, so the suggestion
    /// is stable across runs rather than dependent on dictionary order.
    static func suggestedTarget(for group: [String], counts: [String: Int]) -> String {
        // `max` only returns nil on an empty group, which no caller produces — but a helper reached
        // from a model reply is the wrong place to trap on it.
        group.max { lhs, rhs in (counts[lhs] ?? 0, rhs) < (counts[rhs] ?? 0, lhs) } ?? group.first ?? ""
    }

    /// Order-independent key for "these two were offered together", so dismissing a pair sticks
    /// whichever way round it is proposed next time.
    static func pairKey(_ a: String, _ b: String) -> String {
        let x = JournalCatalogStore.norm(a), y = JournalCatalogStore.norm(b)
        return x < y ? x + "\u{1F}" + y : y + "\u{1F}" + x
    }

    /// Whether the user has already waved away any pair inside this group. One dismissed pair kills the
    /// whole group rather than shrinking it: the group is a claim that all of these are one habit, and
    /// re-offering it minus the pair would put the same rejected question back in front of the user
    /// under a slightly different heading.
    static func isDismissed(_ group: [String], dismissed: Set<String>) -> Bool {
        guard !dismissed.isEmpty else { return false }
        for (i, a) in group.enumerated() {
            for b in group.dropFirst(i + 1) where dismissed.contains(pairKey(a, b)) { return true }
        }
        return false
    }
}
