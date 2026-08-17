import Foundation

public enum SemanticRanking {
    /// How many places at the end of the list the keyword arm may claim for documents the semantic
    /// arm never returned.
    public static let defaultRescueSlots = 2

    /// Legacy source-id overload: the keyword arm can only re-order what the semantic search already
    /// found, never contribute a document of its own.
    public static func fuse(semantic: [SemanticHit],
                            lexicalSourceIDs: [String],
                            limit: Int,
                            rescueSlots: Int = defaultRescueSlots) -> [SemanticHit] {
        let semanticBySource = Dictionary(semantic.map { ($0.sourceID, $0) },
                                          uniquingKeysWith: { first, _ in first })
        let lexical = lexicalSourceIDs.compactMap { semanticBySource[$0] }
        return fuse(semantic: semantic, lexical: lexical, limit: limit, rescueSlots: rescueSlots)
    }

    /// Combines the two retrieval arms. The semantic order is authoritative; the keyword arm may only
    /// **rescue** documents the semantic arm did not return at all, into the last `rescueSlots` places.
    ///
    /// This used to be a symmetric reciprocal-rank fusion (k = 60), which measurably cost hits rather
    /// than adding them. Over the ten-language evaluation corpus (300 queries, cached Nomic vectors,
    /// the same 256-dimension contract the app stores) the arms scored:
    ///
    ///     semantic alone           R@1 258/300   R@3 290/300
    ///     symmetric RRF            R@1 215/300   R@3 270/300
    ///     RRF, lexical weight 0.1  R@1 241/300   R@3 283/300
    ///     rescue-only (this)       R@1 258/300   R@3 290/300
    ///
    /// Weighting the lexical arm down cannot fix it: with k = 60 the gap between two adjacent semantic
    /// ranks is ~0.0003, while a rank-1 lexical contribution at weight 0.1 is 0.0016 — any weight worth
    /// having still re-orders the semantic list. Only removing the lexical arm's power to re-order does.
    ///
    /// What the keyword arm is genuinely for survives: an exact name, date or number that the embedding
    /// missed still enters the context through the rescue slots. That is the case the corpus above
    /// cannot measure — every one of its targets is reachable semantically — so the slots are kept on
    /// the evidence of the retrieval they were built for, and cost nothing in the measurement.
    ///
    /// A source appears once even when several of its chunks match. The returned `score` is whichever
    /// arm's own score the hit carried (cosine for semantic, token overlap for a rescue); the two are
    /// not comparable, so the ORDER of this list is the result, not the scores in it.
    public static func fuse(semantic: [SemanticHit],
                            lexical: [SemanticHit],
                            limit: Int,
                            rescueSlots: Int = defaultRescueSlots) -> [SemanticHit] {
        guard limit > 0 else { return [] }
        let ranked = firstPerSource(semantic)
        guard !ranked.isEmpty else { return Array(firstPerSource(lexical).prefix(limit)) }

        let searched = Set(semantic.map(\.sourceID))
        let rescues = firstPerSource(lexical)
            .filter { !searched.contains($0.sourceID) }
            .prefix(max(0, rescueSlots))
        guard !rescues.isEmpty else { return Array(ranked.prefix(limit)) }

        let kept = max(0, limit - rescues.count)
        return Array((ranked.prefix(kept) + rescues).prefix(limit))
    }

    private static func firstPerSource(_ hits: [SemanticHit]) -> [SemanticHit] {
        var seen = Set<String>()
        return hits.filter { seen.insert($0.sourceID).inserted }
    }
}
