import Foundation
import SemanticMemory

/// The keyword arm, in both the shipped shape and the proposed one.
///
/// Shipped (`CoachSemanticMemory.lexicalHits`): score is the raw COUNT of shared tokens, the bar is
/// `overlap > 0`, ties break on document id, and the list is cut at 16. That means a single shared everyday
/// word — "sleep", "training" — scores the same as a shared "ferritin", and is enough to claim one of the
/// two rescue slots. Combined with a tokeniser that discards runs under three characters, the arm kept
/// specifically to catch an exact name, date or number cannot see numbers or dates and cannot tell a rare
/// term from a common one.
///
/// Proposed: the same candidates, weighted by inverse document frequency, and a `lexicalMass` — the share
/// of the query's total IDF the source actually matched — that the scorer can use as a bounded additive
/// bonus instead of as a guaranteed slot.
struct LexicalIndex {
    /// chunk document id → its tokens
    let tokensByDocument: [String: Set<String>]
    /// token → IDF over the chunk collection
    let idf: [String: Double]
    /// chunk document id → the candidate skeleton to return on a hit
    let candidates: [String: SelectionCandidate]

    /// How much of the ranking is worth carrying. Mirrors `lexicalCandidateLimit`.
    static let candidateLimit = 16

    init(documents: [(candidate: SelectionCandidate, text: String)], numericTokens: Bool) {
        var tokensByDocument: [String: Set<String>] = [:]
        var candidates: [String: SelectionCandidate] = [:]
        var documentFrequency: [String: Int] = [:]
        for entry in documents {
            let tokens = numericTokens
                ? NumericAwareTokeniser.tokens(entry.text)
                : MirroredTokeniser.tokens(entry.text)
            tokensByDocument[entry.candidate.documentID] = tokens
            candidates[entry.candidate.documentID] = entry.candidate
            for token in tokens { documentFrequency[token, default: 0] += 1 }
        }
        let total = Double(max(1, documents.count))
        // Smoothed IDF, always positive: a token every document carries still contributes a little rather
        // than exactly nothing, so a query made only of common words degrades instead of collapsing.
        self.idf = documentFrequency.mapValues { log(1 + total / Double(1 + $0)) }
        self.tokensByDocument = tokensByDocument
        self.candidates = candidates
    }

    /// The shipped arm: raw overlap count, cut at 16.
    func shippedHits(question: String) -> [SelectionCandidate] {
        let queryTokens = MirroredTokeniser.tokens(question)
        guard !queryTokens.isEmpty else { return [] }
        return tokensByDocument
            .compactMap { documentID, tokens -> (SelectionCandidate, Int)? in
                let overlap = tokens.intersection(queryTokens).count
                guard overlap > 0, let candidate = candidates[documentID] else { return nil }
                return (candidate, overlap)
            }
            .sorted {
                if $0.1 == $1.1 { return $0.0.documentID < $1.0.documentID }
                return $0.1 > $1.1
            }
            .prefix(Self.candidateLimit)
            .map(\.0)
    }

    /// The proposed arm: IDF-weighted, and every hit carries the share of query IDF mass it matched.
    func weightedHits(question: String, numericTokens: Bool) -> [SelectionCandidate] {
        let queryTokens = numericTokens
            ? NumericAwareTokeniser.tokens(question)
            : MirroredTokeniser.tokens(question)
        guard !queryTokens.isEmpty else { return [] }
        // Tokens absent from the collection still carry weight in the denominator: a query term nothing
        // matches is a term the retrieval genuinely missed, and pretending the query was shorter would
        // reward that.
        let unseen = log(1 + Double(max(1, tokensByDocument.count)))
        let queryMass = queryTokens.reduce(0.0) { $0 + (idf[$1] ?? unseen) }
        guard queryMass > 0 else { return [] }

        return tokensByDocument
            .compactMap { documentID, tokens -> (SelectionCandidate, Double)? in
                let shared = tokens.intersection(queryTokens)
                guard !shared.isEmpty, var candidate = candidates[documentID] else { return nil }
                let matched = shared.reduce(0.0) { $0 + (idf[$1] ?? unseen) }
                candidate.lexicalMass = min(1, matched / queryMass)
                return (candidate, matched)
            }
            .sorted {
                if $0.1 == $1.1 { return $0.0.documentID < $1.0.documentID }
                return $0.1 > $1.1
            }
            .prefix(Self.candidateLimit * 2)
            .map(\.0)
    }
}
