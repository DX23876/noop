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
                let rank = (isNative ? 0 : 1,
                            target == nil ? 0 : (aliasOrder[key] ?? Int.max - 1),
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
            let candidate = target == nil ? 0 : (aliasOrder[key] ?? Int.max - 1)
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

    // MARK: - Finding duplicates worth offering

    /// Two questions to offer as one, with the similarity that suggested them.
    struct Candidate: Equatable, Identifiable {
        let questions: [String]
        /// The wording proposed as the survivor — the one with the most stored answers.
        let suggestedTarget: String
        let similarity: Double
        var id: String { questions.joined(separator: "\u{1F}") }
    }

    /// Jaccard at or above this, on the comparison tokens below, makes a pair a candidate.
    static let jaccardThreshold = 0.5
    /// …or the shorter question's tokens being this contained in the longer one's ("Magnesium?" inside
    /// "Did you take magnesium?"), which similarity alone would miss.
    static let containmentThreshold = 0.8

    /// Interrogative openers that carry no meaning for the comparison: WHOOP's re-wordings differ
    /// mostly in these ("Did you drink…" / "Have you had…"), which is exactly the noise to drop.
    private static let openers = ["did you", "have you", "do you", "any", "were you", "was your"]

    /// The tokens two questions are compared on: `CoachMemory.tokens` (lowercased, letters/digits,
    /// ≥ 3 characters, stopwords removed — the same tokeniser the coach's own duplicate check uses)
    /// over the question with its opener and question mark removed.
    static func comparisonTokens(_ question: String) -> Set<String> {
        var s = JournalCatalogStore.norm(question)
        s = s.replacingOccurrences(of: "?", with: " ")
        for opener in openers where s.hasPrefix(opener + " ") {
            s = String(s.dropFirst(opener.count + 1))
            break
        }
        return Set(CoachMemory.tokens(s).map(stem))
    }

    /// Crude, deliberate suffix trim so a re-worded question still matches: "Did you **use** a sauna?"
    /// against "Have you **used** a sauna?". WHOOP's re-wordings change the verb form as often as the
    /// opener, and without this such a pair scores far below any sane threshold.
    ///
    /// Not a real stemmer, and not trying to be: it only strips -ing / -ed and then a trailing -s, in
    /// that order, so that "stress" and "stressed" land on the same string. It never touches a word
    /// short enough for the trim to change its meaning, and false friends cost only a proposal the
    /// user declines.
    static func stem(_ token: String) -> String {
        var t = token
        if t.count > 4, t.hasSuffix("ing") { t = String(t.dropLast(3)) }
        else if t.count > 3, t.hasSuffix("ed") { t = String(t.dropLast(2)) }
        // The trailing -e matters: "used" trims to "us", and only dropping the e from "use" lands them
        // on the same string. The output is a bucket, never shown to anyone.
        if t.count > 2, t.hasSuffix("e") { t = String(t.dropLast()) }
        if t.count > 3, t.hasSuffix("s") { t = String(t.dropLast()) }
        return t
    }

    /// How alike two questions read, 0…1. Jaccard, lifted to the containment score when one question
    /// is a shortening of the other.
    static func similarity(_ a: String, _ b: String) -> Double {
        let ta = comparisonTokens(a), tb = comparisonTokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let shared = Double(ta.intersection(tb).count)
        let jaccard = shared / Double(ta.union(tb).count)
        let containment = shared / Double(min(ta.count, tb.count))
        return containment >= containmentThreshold ? max(jaccard, containment) : jaccard
    }

    /// Group the catalog's questions into merge candidates, most similar first.
    ///
    /// Only offers, never decides: the thresholds are deliberately generous because a proposal costs
    /// a glance, while a wrong automatic merge would quietly reshape the analysis. `dismissed` holds
    /// pairs the user has already waved away (`pairKey`), `counts` the stored answers per question —
    /// the wording with the most of them is proposed as the survivor, so the smaller history is the
    /// one that moves.
    static func candidates(questions: [String],
                           counts: [String: Int],
                           dismissed: Set<String> = []) -> [Candidate] {
        let cleaned = questions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var groups: [[String]] = []
        var placed = Set<String>()

        for (i, a) in cleaned.enumerated() {
            if placed.contains(JournalCatalogStore.norm(a)) { continue }
            var group = [a]
            for b in cleaned.dropFirst(i + 1) {
                let bKey = JournalCatalogStore.norm(b)
                guard !placed.contains(bKey), !dismissed.contains(pairKey(a, b)) else { continue }
                guard similarity(a, b) >= jaccardThreshold else { continue }
                group.append(b)
                placed.insert(bKey)
            }
            if group.count > 1 {
                placed.insert(JournalCatalogStore.norm(a))
                groups.append(group)
            }
        }

        return groups.map { group in
            let target = group.max { lhs, rhs in
                (counts[lhs] ?? 0, rhs) < (counts[rhs] ?? 0, lhs)
            } ?? group[0]
            let worst = group.dropFirst().map { similarity(group[0], $0) }.min() ?? 0
            return Candidate(questions: group, suggestedTarget: target, similarity: worst)
        }
        .sorted { ($0.similarity, $1.id) > ($1.similarity, $0.id) }
    }

    /// Order-independent key for "these two were offered together", so dismissing a pair sticks
    /// whichever way round it is proposed next time.
    static func pairKey(_ a: String, _ b: String) -> String {
        let x = JournalCatalogStore.norm(a), y = JournalCatalogStore.norm(b)
        return x < y ? x + "\u{1F}" + y : y + "\u{1F}" + x
    }
}
