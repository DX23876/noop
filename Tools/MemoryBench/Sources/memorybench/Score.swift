import Foundation
import SemanticMemory

/// One query's outcome under one variant.
struct QueryResult {
    let query: CorpusQuery
    let ranked: [String]
    let groups: [String]
    let availableRelevant: Int
}

/// Everything one variant scored, aggregated the ways that can actually change a decision.
struct VariantReport {
    let name: String
    var ndcg: (value: Double, count: Int)?
    var precision: (value: Double, count: Int)?
    var recall1: (value: Double, count: Int)?
    var recall3: (value: Double, count: Int)?
    var recall8: (value: Double, count: Int)?
    var mrr: (value: Double, count: Int)?
    /// Mean lines emitted for `irrelevant` queries. The target is 0.
    var irrelevantLines: Double
    var dominance: (value: Double, count: Int)?
    /// Queries that emitted fewer lines than they had relevant material for — but only meaningful for a
    /// variant with NO floor.
    ///
    /// With a floor, emitting fewer lines is the policy working, not a fault, and the recall columns already
    /// price whatever that costs. Counting it here too would report the same thing twice and bury the
    /// structural case this column exists for: a pool that collapsed because many chunks shared one source.
    var underruns: Int?
    var perCategory: [QueryCategory: (value: Double, count: Int)?]
    var perLanguage: [String: (value: Double, count: Int)?]
}

/// Builds the index, runs every variant, and reports.
///
/// The index is the REAL `SemanticIndexStore`, in memory, holding the REAL Float16 encoding and searched
/// through the REAL cosine scan. Only the selection above it is swapped per variant, so a difference in the
/// table is a difference in the selection and nothing else.
func runScore(corpus: Corpus,
              vectors: VectorSet,
              floors: [Double],
              candidateCeiling: Int = 128,
              now: Date = Date(),
              quiet: Bool = false) async throws -> [VariantReport] {
    let store = try SemanticIndexStore(inMemory: true)
    let documentsByID = corpus.documentsByID

    // MARK: index
    // Enqueued as ONE batch, the way the app's reconcile does it: `enqueue` runs its whole loop inside a
    // single write transaction, and paying a transaction per chunk instead turned a two-second run into a
    // thirty-second one.
    var chunkTexts: [String: String] = [:]
    var chunkOwner: [String: CorpusDocument] = [:]
    var semanticDocuments: [(chunk: String, document: SemanticDocument)] = []
    for document in corpus.documents {
        for (index, chunk) in MirroredChunker.chunks(document.text).enumerated() {
            let id = chunkID(document.id, index)
            chunkTexts[id] = chunk
            chunkOwner[id] = document
            guard let kind = document.sourceKind, let scope = document.consentScope else {
                throw CorpusError.invalid(["\(document.id): unusable kind/scope at index time"])
            }
            semanticDocuments.append((id, SemanticDocument(sourceKind: kind,
                                                           sourceID: document.id,
                                                           chunkIndex: index,
                                                           text: chunk,
                                                           updatedAt: document.updatedAt(now: now),
                                                           consentScope: scope,
                                                           priority: document.priority)))
        }
    }
    try await store.enqueue(semanticDocuments.map(\.document))
    for entry in semanticDocuments {
        guard let vector = vectors.documents[entry.chunk] else {
            throw VectorError.missing("vector for chunk \(entry.chunk) — re-run `embed` for this corpus")
        }
        // The store keys the vector on (documentId, contentHash), the same pairing the app uses to invalidate
        // a vector when its text changes. Writing it any other way would let a stale vector score a document
        // it no longer describes.
        try await store.storeEmbedding(documentID: entry.document.documentID,
                                       contentHash: entry.document.contentHash,
                                       modelID: vectors.meta.model,
                                       vector: vector)
    }

    // MARK: lexical arms (model-independent, so built once)
    func candidateSkeleton(chunk: String, cosine: Double) -> SelectionCandidate? {
        guard let owner = chunkOwner[chunk], let kind = owner.sourceKind else { return nil }
        return SelectionCandidate(documentID: chunk,
                                  sourceID: owner.id,
                                  kind: kind,
                                  diversityGroup: owner.diversityGroup,
                                  ageDays: owner.ageDays,
                                  priority: owner.priority,
                                  cosine: cosine,
                                  vector: vectors.documents[chunk] ?? [])
    }
    let lexicalEntries = chunkTexts.compactMap { chunk, text -> (candidate: SelectionCandidate, text: String)? in
        guard let skeleton = candidateSkeleton(chunk: chunk, cosine: 0) else { return nil }
        return (skeleton, text)
    }
    let shippedLexical = LexicalIndex(documents: lexicalEntries, numericTokens: false)
    let numericLexical = LexicalIndex(documents: lexicalEntries, numericTokens: true)

    // MARK: one search per query, deepest cut once
    // Truncating a deeper ranked list to K is identical to having searched with limit K — the order is by
    // score either way — so the K ablation costs no extra scans.
    var semanticByQuery: [String: [SelectionCandidate]] = [:]
    var relevantCosines: [Double] = []
    var bestIrrelevantCosines: [Double] = []
    for query in corpus.queries {
        guard let vector = vectors.queries[query.id] else {
            throw VectorError.missing("vector for query \(query.id) — re-run `embed` for this corpus")
        }
        let hits = try await store.search(vector: vector,
                                         allowedScopes: Set(SemanticConsentScope.allCases),
                                         limit: candidateCeiling)
        let candidates = hits.compactMap { hit in
            candidateSkeleton(chunk: chunkID(hit.sourceID, hit.chunkIndex), cosine: hit.score)
        }
        semanticByQuery[query.id] = candidates
        // Floor calibration inputs: the cosine of a genuinely relevant hit, versus the best cosine a query
        // with nothing relevant produces. A threshold has to come out of these two distributions; guessing
        // one costs recall on the first and buys nothing on the second.
        for candidate in candidates where (query.judgments[candidate.sourceID] ?? 0) > 0 {
            relevantCosines.append(candidate.cosine)
        }
        if query.category == .irrelevant, let best = candidates.first?.cosine {
            bestIrrelevantCosines.append(best)
        }
    }

    // MARK: variants
    let calibratedFloor = floors.first
    var configs = SelectionConfig.ladder(floor: calibratedFloor)
    for floor in floors.dropFirst() {
        var swept = SelectionConfig.proposed(floor: floor)
        swept.name = "proposed, floor \(String(format: "%.2f", floor))"
        configs.append(swept)
    }

    var reports: [VariantReport] = []
    for config in configs {
        var results: [QueryResult] = []
        for query in corpus.queries {
            let semantic = Array((semanticByQuery[query.id] ?? []).prefix(config.candidateLimit))
            let lexical: [SelectionCandidate]
            if config.lexicalIDF {
                lexical = numericLexical.weightedHits(question: query.text,
                                                      numericTokens: config.numericTokens)
            } else if config.numericTokens {
                lexical = numericLexical.shippedHits(question: query.text)
            } else {
                lexical = shippedLexical.shippedHits(question: query.text)
            }
            let ranked = select(semantic: semantic, lexical: lexical, config: config)
            let groups = ranked.compactMap { documentsByID[$0]?.diversityGroup }
            let available = query.judgments.values.filter { $0 > 0 }.count
            results.append(QueryResult(query: query,
                                       ranked: ranked,
                                       groups: groups,
                                       availableRelevant: available))
        }
        reports.append(report(name: config.name, results: results, countsUnderruns: config.floor == nil))
    }

    if !quiet {
        printCalibration(relevant: relevantCosines, irrelevant: bestIrrelevantCosines)
        printTable(reports, vectors: vectors, corpus: corpus)
    }
    return reports
}

private func report(name: String, results: [QueryResult], countsUnderruns: Bool) -> VariantReport {
    let scored = results.filter { $0.query.category != .irrelevant }
    let irrelevant = results.filter { $0.query.category == .irrelevant }
    var perCategory: [QueryCategory: (value: Double, count: Int)?] = [:]
    for category in QueryCategory.allCases where category != .irrelevant {
        let subset = results.filter { $0.query.category == category }
        perCategory[category] = mean(subset.map { normalizedDCG(ranked: $0.ranked, judgments: $0.query.judgments) })
    }
    var perLanguage: [String: (value: Double, count: Int)?] = [:]
    for language in Set(scored.map(\.query.lang)) {
        let subset = scored.filter { $0.query.lang == language }
        perLanguage[language] = mean(subset.map { normalizedDCG(ranked: $0.ranked, judgments: $0.query.judgments) })
    }
    return VariantReport(
        name: name,
        ndcg: mean(scored.map { normalizedDCG(ranked: $0.ranked, judgments: $0.query.judgments) }),
        precision: mean(scored.map { precision(ranked: $0.ranked, judgments: $0.query.judgments) }),
        recall1: mean(scored.map { recall(ranked: $0.ranked, judgments: $0.query.judgments, k: 1) }),
        recall3: mean(scored.map { recall(ranked: $0.ranked, judgments: $0.query.judgments, k: 3) }),
        recall8: mean(scored.map { recall(ranked: $0.ranked, judgments: $0.query.judgments, k: 8) }),
        mrr: mean(scored.map { reciprocalRank(ranked: $0.ranked, judgments: $0.query.judgments) }),
        irrelevantLines: irrelevant.isEmpty
            ? 0
            : Double(irrelevant.reduce(0) { $0 + emittedLineCount(ranked: $1.ranked) }) / Double(irrelevant.count),
        dominance: mean(scored.map { $0.groups.isEmpty ? nil : dominance($0.groups) }),
        underruns: countsUnderruns
            ? scored.filter {
                slotUnderrun(emitted: emittedLineCount(ranked: $0.ranked),
                             availableRelevant: $0.availableRelevant)
            }.count
            : nil,
        perCategory: perCategory,
        perLanguage: perLanguage
    )
}

// MARK: - Output

private func format(_ metric: (value: Double, count: Int)?) -> String {
    guard let metric else { return "    —" }
    return String(format: "%5.3f", metric.value)
}

private func printCalibration(relevant: [Double], irrelevant: [Double]) {
    func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[index]
    }
    print("""

        ================================================================================
        A. FLOOR CALIBRATION
        ================================================================================
        Cosine of a genuinely relevant hit, against the best cosine a query with nothing
        relevant produces. A usable floor lies between these two distributions; if they
        overlap heavily, no single threshold exists and the floor must be per-kind or
        relative to the top hit instead of absolute.

        relevant hits      n=\(relevant.count)   p05 \(String(format: "%.3f", percentile(relevant, 0.05)))   p25 \(String(format: "%.3f", percentile(relevant, 0.25)))   median \(String(format: "%.3f", percentile(relevant, 0.5)))
        best-of-irrelevant n=\(irrelevant.count)   median \(String(format: "%.3f", percentile(irrelevant, 0.5)))   p75 \(String(format: "%.3f", percentile(irrelevant, 0.75)))   p95 \(String(format: "%.3f", percentile(irrelevant, 0.95)))
        """)
}

private func printTable(_ reports: [VariantReport], vectors: VectorSet, corpus: Corpus) {
    print("""

        ================================================================================
        B. ABLATION LADDER — model \(vectors.meta.model), \(vectors.dimensions) dims
        ================================================================================
        \(corpus.documents.count) documents / \(corpus.queries.count) queries / \(corpus.languages.count) languages
        index bytes at Float16: \(vectors.indexBytes)

        nDCG@8 and P@8 exclude the `irrelevant` category (it has no ideal ranking); that
        category is scored by `irrel.` — mean lines emitted, where the target is 0.
        `domin.` is the largest share one conversation or kind holds among the 8 lines.
        `under` counts queries that emitted fewer lines than they had relevant material for —
        only reported for variants with NO floor, where a short context is a fault rather
        than the policy working (the recall columns price the floor's cost already).

        variant                          nDCG@8   P@8   R@1   R@3   R@8   MRR  irrel. domin. under
        ------------------------------------------------------------------------------------------
        """)
    for report in reports {
        let name = report.name.padding(toLength: 32, withPad: " ", startingAt: 0)
        print("\(name) \(format(report.ndcg)) \(format(report.precision)) \(format(report.recall1)) "
            + "\(format(report.recall3)) \(format(report.recall8)) \(format(report.mrr)) "
            + String(format: "%5.2f", report.irrelevantLines) + " \(format(report.dominance)) "
            + (report.underruns.map { String(format: "%5d", $0) } ?? "    —"))
    }

    print("""

        ================================================================================
        C. PER CATEGORY (nDCG@8)
        ================================================================================
        A variant is only an improvement if it wins its own category without losing
        another. This is the table that would have rejected symmetric RRF.

        variant                          \(QueryCategory.allCases.filter { $0 != .irrelevant }.map { $0.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0) }.joined())
        ------------------------------------------------------------------------------------------
        """)
    for report in reports {
        let name = report.name.padding(toLength: 32, withPad: " ", startingAt: 0)
        let cells = QueryCategory.allCases.filter { $0 != .irrelevant }.map { category -> String in
            format(report.perCategory[category] ?? nil).padding(toLength: 11, withPad: " ", startingAt: 0)
        }
        print("\(name) \(cells.joined())")
    }

    let languages = (reports.first?.perLanguage.keys).map { Array($0).sorted() } ?? []
    print("""

        ================================================================================
        D. PER LANGUAGE (nDCG@8)
        ================================================================================
        The app ships ten locales. A model or a tokeniser change that helps English and
        hurts Polish or Chinese is not an improvement, and only this table can say so.

        variant                          \(languages.map { $0.padding(toLength: 8, withPad: " ", startingAt: 0) }.joined())
        ------------------------------------------------------------------------------------------
        """)
    for report in reports {
        let name = report.name.padding(toLength: 32, withPad: " ", startingAt: 0)
        let cells = languages.map { language in
            format(report.perLanguage[language] ?? nil).padding(toLength: 8, withPad: " ", startingAt: 0)
        }
        print("\(name) \(cells.joined())")
    }
    print("")
}
