import Foundation

/// Finding the journal questions that are one habit written twice, by asking the CHEAP model.
///
/// This replaced word-overlap scoring (removed from `JournalMerge`), which could not do the job in
/// principle: "Ein Magnesiumpräparat eingenommen?" and "Ein Zinkpräparat eingenommen?" share every
/// word but the one that matters, while "Alkohol konsumiert?" and "Did you drink any alcohol?" share
/// none at all. Separating the first pair and joining the second needs to know what magnesium and zinc
/// ARE — a question for a model, not for a tokeniser.
///
/// Built like `MemoryMaintainer`: everything except the single `cheapComplete` call is a pure static
/// function, so the prompt, the parse and the validation are pinned by tests that never touch the
/// network. Only offers, never decides — the user picks the survivor and confirms every merge.
///
/// Cost and privacy: one request, only on an explicit tap, only with the Coach on and configured, and
/// cached against a fingerprint of the catalog so an unchanged list is never paid for twice. What
/// leaves the device is the question WORDINGS only — no answers, no values, no dates.
extension AICoachEngine {

    // MARK: - The request

    /// Ask the cheap model which of `list` are the same habit, and hand back its RAW reply.
    ///
    /// Raw rather than parsed, so the caller can cache the one thing that was paid for and re-derive
    /// candidates from it for free — which matters because the derivation also applies the user's
    /// dismissals, and those change without the catalog changing.
    ///
    /// `nil` means no answer at all: Coach off, no key, or the request failed. The model never sees the
    /// user's answers, only the wordings it is asked to compare.
    ///
    /// `list` must come from `journalQuestionList` — every index in the reply is resolved against it.
    func journalDuplicateReply(for list: [String]) async -> String? {
        guard CoachFeaturePrefs.isEnabled, isConfigured, list.count > 1 else { return nil }
        return await cheapComplete(system: Self.journalDuplicateSystem,
                                   user: Self.journalDuplicatePrompt(list),
                                   role: .summary)
    }

    /// The questions actually sent, in the order the indices refer to: trimmed, blanks dropped,
    /// deduped on `JournalCatalogStore.norm`, and sorted by that same stable identity key.
    ///
    /// Sorting here rather than only in the fingerprint is the safety boundary for the cached raw
    /// reply: regrouping or reordering the visible catalog must not make index 3 name a different
    /// question while the cache still looks current.
    nonisolated static func journalQuestionList(_ questions: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for q in questions.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !q.isEmpty {
            if seen.insert(JournalCatalogStore.norm(q)).inserted { out.append(q) }
        }
        return out.sorted { JournalCatalogStore.norm($0) < JournalCatalogStore.norm($1) }
    }

    /// Instruction for the cheap model. Strict line format rather than JSON, for the same reason
    /// `MemoryMaintainer` uses one: small models emit malformed JSON often enough to matter, but keep
    /// a two-keyword line shape reliably.
    ///
    /// The negative examples are not decoration — they are the exact failures the old word-overlap
    /// scoring produced on this user's imported German catalog, and a model asked only for "duplicates"
    /// will happily reproduce them.
    nonisolated static let journalDuplicateSystem = """
    You are given a numbered list of journal questions from one person's habit tracker. Some of them \
    are the SAME habit entered twice — a re-wording, or the same question in another language. Find \
    only those.

    Output EXACTLY this format and nothing else:
    GROUP <comma-separated numbers from the list>
    KEEP <one number from that same group>
    (repeat the pair of lines for each group)

    Output nothing at all when no two questions are the same habit. Never write prose, never invent a \
    number that is not in the list, never put one number in two groups.

    Two questions belong in a group ONLY if answering one would always answer the other. Questions \
    that merely look alike must stay apart — in particular:
    - different supplements or nutrients are different questions (magnesium / zinc / melatonin / \
    multivitamin; fat / carbohydrates / protein);
    - opposite or merely different feelings are different questions (irritable / motivated; \
    recovered / sick; anxious / calm);
    - different substances, foods or activities are different questions (meat / caffeine / alcohol; \
    reading in bed / screen in bed).
    A shared sentence frame ("Did you take …?", "Hast du dich … gefühlt?") is NOT a reason to group.

    KEEP names the clearest and most complete wording in the group.
    """

    /// The user message: the questions, numbered from 1, one per line.
    nonisolated static func journalDuplicatePrompt(_ list: [String]) -> String {
        let lines = list.enumerated().map { "\($0.offset + 1). \($0.element)" }
        return "Journal questions:\n" + lines.joined(separator: "\n")
    }

    // MARK: - Reading the reply

    /// A successful comparison is not the same thing as an empty candidate list: an empty model reply
    /// is the specified "nothing duplicated" answer, while prose or unusable indices mean the reply
    /// could not be trusted. The view uses this distinction for both its status and its cache.
    enum JournalDuplicateReviewResult: Equatable {
        case candidates([JournalMerge.Candidate])
        case noDuplicates
        case invalid
    }

    /// Validate and resolve one raw reply. Valid groups may all disappear through the user's durable
    /// dismissals; that remains a successful `candidates([])` result rather than turning a good cached
    /// reply into an error.
    nonisolated static func journalDuplicateReview(from raw: String,
                                                   questions: [String],
                                                   counts: [String: Int],
                                                   dismissed: Set<String> = []) -> JournalDuplicateReviewResult {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noDuplicates
        }

        var claimed = Set<Int>()
        var out: [JournalMerge.Candidate] = []
        var foundValidGroup = false

        for group in parseJournalDuplicateGroups(raw) {
            var indices: [Int] = []
            for index in group.indices where (1...questions.count).contains(index) {
                // A question in two groups is a contradiction the model has no way to resolve; the
                // first group wins and the later claim is simply not made.
                if claimed.contains(index) || indices.contains(index) { continue }
                indices.append(index)
            }
            guard indices.count > 1 else { continue }
            foundValidGroup = true
            indices.forEach { claimed.insert($0) }

            let members = indices.map { questions[$0 - 1] }
            guard !JournalMerge.isDismissed(members, dismissed: dismissed) else { continue }
            // An out-of-range or missing KEEP falls back to the wording with the most answers, so a
            // sloppy target costs a default rather than the otherwise valid group.
            let keep = group.keep.flatMap { indices.contains($0) ? questions[$0 - 1] : nil }
            out.append(JournalMerge.Candidate(
                questions: members,
                suggestedTarget: keep ?? JournalMerge.suggestedTarget(for: members, counts: counts)))
        }

        guard foundValidGroup else { return .invalid }
        // Biggest histories first: those are the groups where staying split actually distorts the
        // analysis, and the ones worth the user's attention before the tail of one-answer wordings.
        return .candidates(out.sorted { lhs, rhs in
            let l = lhs.questions.reduce(0) { $0 + (counts[$1] ?? 0) }
            let r = rhs.questions.reduce(0) { $0 + (counts[$1] ?? 0) }
            return (l, rhs.id) > (r, lhs.id)
        })
    }

    /// Turn a reply into merge candidates, discarding anything that does not check out.
    ///
    /// The reply is INDICES, never text, and this is the containment that matters: the questions come
    /// from a WHOOP CSV the app did not write, and resolving numbers against our own array means no
    /// string the model emits can become a question, a merge target, or anything else the app acts on.
    /// A number outside the list, a group left with fewer than two questions, or a question already
    /// claimed by an earlier group is dropped — the rest of the reply still stands.
    nonisolated static func journalDuplicateCandidates(from raw: String,
                                                       questions: [String],
                                                       counts: [String: Int],
                                                       dismissed: Set<String> = []) -> [JournalMerge.Candidate] {
        guard case let .candidates(candidates) = journalDuplicateReview(
            from: raw, questions: questions, counts: counts, dismissed: dismissed
        ) else { return [] }
        return candidates
    }

    /// Pull `GROUP …` / `KEEP …` line pairs out of the reply. Lenient about spacing, casing, a colon
    /// after the keyword, and separators, because that is where small models drift; strict about the
    /// keywords themselves, so prose is ignored rather than half-parsed.
    ///
    /// A `KEEP` binds to the `GROUP` above it. A `GROUP` with no `KEEP` is kept (the target falls back
    /// to the answer count); a `KEEP` with no `GROUP` is dropped.
    nonisolated static func parseJournalDuplicateGroups(_ raw: String) -> [(indices: [Int], keep: Int?)] {
        var out: [(indices: [Int], keep: Int?)] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: "GROUP", options: .caseInsensitive), r.lowerBound == t.startIndex {
                let numbers = integers(in: t[r.upperBound...])
                if !numbers.isEmpty { out.append((indices: numbers, keep: nil)) }
            } else if let r = t.range(of: "KEEP", options: .caseInsensitive), r.lowerBound == t.startIndex {
                guard !out.isEmpty, let keep = integers(in: t[r.upperBound...]).first else { continue }
                out[out.count - 1].keep = keep
            }
        }
        return out
    }

    /// Every run of digits in a fragment, in order. Deliberately separator-blind: "1,2", "1, 2",
    /// "1 and 2" and "#1 #2" all mean the same thing, and the validation above is what makes being
    /// generous here safe.
    private nonisolated static func integers(in fragment: Substring) -> [Int] {
        fragment.split { !$0.isNumber }.compactMap { Int($0) }
    }

    // MARK: - Paying for it once

    /// A fingerprint of the catalog, so an unchanged question list is never sent twice.
    ///
    /// FNV-1a over UTF-16 code units rather than `hashValue`, per the cross-platform rule in
    /// `CLAUDE.md`: Swift randomises `hashValue` per process, which would silently defeat the cache on
    /// every launch. `journalQuestionList` owns the canonical order used by BOTH this hash and the
    /// prompt, so a cached index can never be resolved against a differently ordered list.
    nonisolated static func journalCatalogFingerprint(_ questions: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for question in journalQuestionList(questions).map({ JournalCatalogStore.norm($0) }) {
            for unit in question.utf16 {
                hash ^= UInt64(unit)
                hash = hash &* 0x100_0000_01b3
            }
            // A separator between questions, so ["ab", "c"] and ["a", "bc"] cannot collide.
            hash ^= 0x1F
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
