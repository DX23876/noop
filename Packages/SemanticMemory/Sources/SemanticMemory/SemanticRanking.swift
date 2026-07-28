import Foundation

public enum SemanticRanking {
    /// Reciprocal-rank fusion keeps exact lexical matches competitive without trying to calibrate two
    /// unrelated score scales. A source appears once even when it has several overlapping chunks.
    public static func fuse(semantic: [SemanticHit],
                            lexicalSourceIDs: [String],
                            limit: Int,
                            rankConstant: Double = 60) -> [SemanticHit] {
        let semanticBySource = Dictionary(semantic.map { ($0.sourceID, $0) },
                                          uniquingKeysWith: { first, _ in first })
        let lexical = lexicalSourceIDs.compactMap { semanticBySource[$0] }
        return fuse(semantic: semantic, lexical: lexical, limit: limit, rankConstant: rankConstant)
    }

    /// Variant used by the app coordinator. Unlike the legacy source-id overload, it can retain an
    /// exact keyword match that has not appeared in the semantic top-N. That matters for names, dates
    /// and negations, where lexical retrieval is deliberately the stronger signal.
    public static func fuse(semantic: [SemanticHit],
                            lexical: [SemanticHit],
                            limit: Int,
                            rankConstant: Double = 60) -> [SemanticHit] {
        guard limit > 0 else { return [] }
        var hitsBySource: [String: SemanticHit] = [:]
        var scores: [String: Double] = [:]

        for (rank, hit) in semantic.enumerated() {
            if hitsBySource[hit.sourceID] == nil { hitsBySource[hit.sourceID] = hit }
            scores[hit.sourceID, default: 0] += 1 / (rankConstant + Double(rank + 1))
        }

        for (rank, hit) in lexical.enumerated() {
            if hitsBySource[hit.sourceID] == nil { hitsBySource[hit.sourceID] = hit }
            scores[hit.sourceID, default: 0] += 1 / (rankConstant + Double(rank + 1))
        }

        return scores
            .compactMap { sourceID, score -> SemanticHit? in
                guard let hit = hitsBySource[sourceID] else { return nil }
                return SemanticHit(documentID: hit.documentID,
                                   sourceKind: hit.sourceKind,
                                   sourceID: sourceID,
                                   chunkIndex: hit.chunkIndex,
                                   score: score,
                                   consentScope: hit.consentScope)
            }
            .sorted {
                if $0.score == $1.score { return $0.sourceID < $1.sourceID }
                return $0.score > $1.score
            }
            .prefix(limit)
            .map { $0 }
    }
}
