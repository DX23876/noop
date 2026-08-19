import Foundation

/// The best any reranker could possibly do, and therefore the honest bound on what one is worth here.
///
/// A reranker only ever REORDERS the candidates the first stage returned; it cannot conjure a document the
/// retrieval missed. So if you hand the candidate set to a perfect oracle — one that knows the judgments and
/// sorts by them — you get the ceiling for every reranker that could ever be plugged in at that depth. The
/// gap between the shipped selection and that ceiling is the entire budget a cross-encoder is competing for,
/// before paying a second model's RAM, its cold load and its forward passes.
///
/// This costs no model and no inference, which is why it is the first thing to measure and not the last. If
/// the gap is small, the question is settled without downloading anything.
enum RerankOracle {
    /// The ≤`limit` source ids a perfect reranker would choose from `candidates`.
    ///
    /// Sources are deduplicated first — the context holds one line per source, so a reranker that reorders
    /// chunks of one source changes nothing — keeping each source's best grade, and ties break on cosine so
    /// the ordering is defined rather than arbitrary.
    static func rank(candidates: [SelectionCandidate],
                     judgments: Judgments,
                     limit: Int = contextSlots) -> [String] {
        var best: [String: (grade: Int, cosine: Double)] = [:]
        for candidate in candidates {
            let grade = judgments[candidate.sourceID] ?? 0
            if let existing = best[candidate.sourceID], existing.cosine >= candidate.cosine { continue }
            best[candidate.sourceID] = (grade, candidate.cosine)
        }
        return best
            .sorted {
                if $0.value.grade != $1.value.grade { return $0.value.grade > $1.value.grade }
                if $0.value.cosine != $1.value.cosine { return $0.value.cosine > $1.value.cosine }
                return $0.key < $1.key
            }
            .prefix(limit)
            .map(\.key)
    }

    /// The same ceiling, but with the floor's restraint kept: a perfect reranker still should not emit a line
    /// for a question nothing answers, so grade-0 sources are dropped rather than used as padding.
    ///
    /// Reported beside the padded ceiling because the two answer different questions. The padded one bounds
    /// nDCG@8; this one bounds what a reranker could do about the `irrelevant` category, which is a job a
    /// relevance model genuinely could take on — it does not need a threshold to know that nothing matches.
    static func rankWithoutPadding(candidates: [SelectionCandidate],
                                   judgments: Judgments,
                                   limit: Int = contextSlots) -> [String] {
        rank(candidates: candidates, judgments: judgments, limit: limit)
            .filter { (judgments[$0] ?? 0) > 0 }
    }
}
