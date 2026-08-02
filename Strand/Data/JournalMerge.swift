import Foundation
import WhoopStore

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
        // An untouched catalog must behave exactly as before, through the very same function every
        // other read has always used.
        guard !aliases.isEmpty else {
            return Repository.mergeJournal(imported: imported, native: native)
        }

        var best: [String: (entry: JournalEntry, rank: (Int, Int, Int))] = [:]
        for (isNative, list) in [(false, imported), (true, native)] {
            for (index, entry) in list.enumerated() {
                let key = JournalCatalogStore.norm(entry.question)
                let target = aliases[key]
                let question = target ?? entry.question
                // Bucketing on the VERBATIM resolved question, not its normalised form: a row that no
                // alias touches must land exactly where `mergeJournal` puts it today, so this only ever
                // merges what the user explicitly merged.
                let bucket = entry.day + "\u{1F}" + question
                // Negative index so that, all else equal, the LAST row wins — `mergeJournal`'s
                // last-write-wins within a list (two imported source ids can carry the same day and
                // question), preserved.
                let aliasRank = aliasOrder[key].map { $0 + 1 } ?? Int.max - 1
                let rank = (isNative ? 0 : 1,
                            target == nil ? 0 : aliasRank,
                            -index)
                if let existing = best[bucket], existing.rank <= rank { continue }
                let folded = target == nil ? entry : JournalEntry(day: entry.day,
                                                                  question: question,
                                                                  answeredYes: entry.answeredYes,
                                                                  notes: entry.notes,
                                                                  numericValue: entry.numericValue)
                best[bucket] = (folded, rank)
            }
        }
        return best.values.map(\.entry).sorted { ($0.day, $0.question) < ($1.day, $1.question) }
    }

    /// The same fold for a single day's `question → value` dictionaries the logging card reads. Same
    /// precedence, minus the native/imported step: those reads are native-only by construction.
    static func foldDay<V>(_ values: [String: V],
                           aliases: [String: String],
                           aliasOrder: [String: Int] = [:]) -> [String: V] {
        guard !aliases.isEmpty else { return values }
        var out: [String: V] = [:]
        var rank: [String: Int] = [:]
        for (question, value) in values.sorted(by: { $0.key < $1.key }) {
            let key = JournalCatalogStore.norm(question)
            let target = aliases[key]
            let resolved = target ?? question
            let candidate = target == nil ? 0 : aliasOrder[key].map { $0 + 1 } ?? Int.max - 1
            if let held = rank[resolved], held <= candidate { continue }
            out[resolved] = value
            rank[resolved] = candidate
        }
        return out
    }

    /// Where a write for `question` must land: the merge target if it has one. New answers belong to
    /// the question the user actually sees, not to the wording it was folded from.
    static func writeTarget(_ question: String, aliases: [String: String]) -> String {
        aliases[JournalCatalogStore.norm(question)] ?? question
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
