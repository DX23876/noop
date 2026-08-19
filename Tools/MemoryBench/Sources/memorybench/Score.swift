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
/// Which queries a report covers.
///
/// The unit exists because pooling them was a real error: the answerable queries are split between one
/// realistic 272-document index and ten 24-document locale sets, and a single mean over all of them is largely
/// driven by the easy problem. Every number now says which scope it came from, and the pooled one is labelled
/// as mixed difficulty rather than quoted as a result. (The exact counts used to be written out here and in the
/// printed header; both went stale the first time the corpus grew, so the header computes them now.)
enum ReportScope: String {
    /// The development half of the large realistic index. **This is where tuning happens** and the only scope
    /// printed by default: floors, weights, candidate depths, rerank settings and model choice are all chosen
    /// here, and choosing them on the holdout would make the holdout worthless.
    case dev
    /// The holdout half. Frozen — see `CorpusSplit`. Reaching it needs `--holdout <reason>`, and every access
    /// is appended to `Corpus/holdout-access.log` so the repository records how often it has been consulted.
    case test
    /// Dev and holdout together. Kept for diagnosis only, because a number measured across both is exactly
    /// the tuned-on-your-own-test-set figure the split exists to stop producing.
    case main
    /// The ten locale sets combined. A language smoke test on 24-document indexes, not a ranking measurement.
    case locales
    /// Everything at once. Kept only so the old pooled figure stays reproducible; never a result on its own.
    case all
}

struct VariantReport {
    let name: String
    let scope: ReportScope
    var ndcg: (value: Double, count: Int)?
    var precision: (value: Double, count: Int)?
    var recall1: (value: Double, count: Int)?
    var recall3: (value: Double, count: Int)?
    var recall8: (value: Double, count: Int)?
    var mrr: (value: Double, count: Int)?
    /// Mean lines emitted for `irrelevant` queries. The target is 0.
    var irrelevantLines: Double
    /// Share of `unanswerable` queries answered with nothing at all — the floor working, and invisible in nDCG.
    var abstention: Double?
    /// Share of ANSWERABLE queries answered with nothing — the floor's cost, and the column that stops a
    /// tighter threshold from looking free.
    var falseAbstention: Double?
    /// Mean lines handed over across every query, so precision can never be read on its own.
    var meanEmitted: Double?
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
    /// nDCG per query id, so two variants can be compared on the SAME questions. Without this a comparison
    /// could only put two independent means side by side, which discards most of the available precision and
    /// would call nearly every difference inconclusive.
    var perQueryNDCG: [String: Double]
}

/// Which scopes a run is allowed to produce.
///
/// The holdout is absent unless explicitly unlocked, so the ordinary path cannot report it even by accident —
/// which is the whole point: a frozen set that is easy to glance at is not frozen.
private func scopesToReport(showHoldout: Bool, split: CorpusSplit?) -> [ReportScope] {
    guard split != nil else { return [.main, .locales, .all] }   // no split committed yet
    return showHoldout ? [.dev, .test, .locales, .all] : [.dev, .locales, .all]
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
              quiet: Bool = false,
              rerank: RerankClient? = nil,
              mixedLanguageIndex: Bool = false,
              split: CorpusSplit? = nil,
              showHoldout: Bool = false) async throws -> [VariantReport] {
    // ONE STORE PER INDEX, not one store filtered afterwards.
    //
    // A device holds one person's index and searches that. Filtering after a shared search is not the same
    // thing: with many candidates tied on score, `search(limit:)` returns an arbitrary slice of the whole
    // pile and the filter can leave fewer than the eight lines the context has room for. That is an artifact
    // of the harness, not of the app, and it showed up immediately on synthetic vectors — where every
    // unanswerable query ties at cosine 0.
    var stores: [String: SemanticIndexStore] = [:]
    for index in corpus.indexes {
        stores[index] = try SemanticIndexStore(inMemory: true)
    }
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
    for (index, entries) in Dictionary(grouping: semanticDocuments, by: { chunkOwner[$0.chunk]!.index }) {
        try await stores[index]!.enqueue(entries.map(\.document))
    }
    for entry in semanticDocuments {
        guard let vector = vectors.documents[entry.chunk] else {
            throw VectorError.missing("vector for chunk \(entry.chunk) — re-run `embed` for this corpus")
        }
        let store = stores[chunkOwner[entry.chunk]!.index]!
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
    // Keyed by scope, not pooled. See `printCalibration` for why pooling here was the worst possible place
    // for it: this section is where the floor is CHOSEN.
    var relevantCosines: [ReportScope: [Double]] = [:]
    var bestIrrelevantCosines: [ReportScope: [Double]] = [:]
    for query in corpus.queries {
        guard let vector = vectors.queries[query.id] else {
            throw VectorError.missing("vector for query \(query.id) — re-run `embed` for this corpus")
        }
        // Searched against the query's OWN index, which is also what makes `--mixed-language-index` a
        // deliberate opt-in rather than the default: it pools every locale set into one pile.
        let searched = mixedLanguageIndex ? corpus.indexes : [query.index]
        var hits: [SemanticHit] = []
        for index in searched {
            hits += try await stores[index]!.search(vector: vector,
                                                   allowedScopes: Set(SemanticConsentScope.allCases),
                                                   limit: candidateCeiling)
        }
        hits = Array(hits.sorted { $0.score > $1.score }.prefix(candidateCeiling))
        let candidates = hits.compactMap { hit in
            candidateSkeleton(chunk: chunkID(hit.sourceID, hit.chunkIndex), cosine: hit.score)
        }
        semanticByQuery[query.id] = candidates
        // Floor calibration inputs: the cosine of a genuinely relevant hit, versus the best cosine a query
        // with nothing relevant produces. A threshold has to come out of these two distributions; guessing
        // one costs recall on the first and buys nothing on the second.
        let calibrationScope = memorybench.calibrationScope(for: query, split: split)
        for candidate in candidates where (query.judgments[candidate.sourceID] ?? 0) > 0 {
            relevantCosines[calibrationScope, default: []].append(candidate.cosine)
        }
        if !query.category.isAnswerable, let best = candidates.first?.cosine {
            bestIrrelevantCosines[calibrationScope, default: []].append(best)
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
        // `under` only means something for a variant that never declines a line. The dynamic floor and the
        // confidence gate decline lines too, so they are excluded on the same grounds as the absolute floor.
        let restrains = config.floor != nil || config.floorRelativeToTop != nil || config.confidenceGate != nil
        for scope in scopesToReport(showHoldout: showHoldout, split: split) {
            reports.append(report(name: config.name, scope: scope, allResults: results,
                                  split: split, countsUnderruns: !restrains))
        }
    }

    // The reranker ceilings. Not variants of the pipeline — they cheat, by construction — but the bound on
    // what any reranking stage plugged in at that candidate depth could achieve. `K=32` is the depth the app
    // searches today, so its row is the one that prices a cross-encoder for the shipped configuration.
    for depth in [32, candidateCeiling] {
        for padded in [true, false] {
            var results: [QueryResult] = []
            for query in corpus.queries {
                let candidates = Array((semanticByQuery[query.id] ?? []).prefix(depth))
                let ranked = padded
                    ? RerankOracle.rank(candidates: candidates, judgments: query.judgments)
                    : RerankOracle.rankWithoutPadding(candidates: candidates, judgments: query.judgments)
                results.append(QueryResult(query: query,
                                           ranked: ranked,
                                           groups: ranked.compactMap { documentsByID[$0]?.diversityGroup },
                                           availableRelevant: query.judgments.values.filter { $0 > 0 }.count))
            }
            for scope in scopesToReport(showHoldout: showHoldout, split: split) {
                reports.append(report(name: "ORACLE ceiling K=\(depth)\(padded ? "" : ", no padding")",
                                      scope: scope, allResults: results, split: split,
                                      countsUnderruns: false))
            }
        }
    }

    // MARK: the reranking stage, when a server was provided
    //
    // Only the best chunk per source is scored. The context holds one line per source, so paying a
    // cross-encoder forward pass to reorder two chunks of the same conversation buys nothing — and a
    // reranker's whole problem is that its passes are expensive.
    //
    // The floor is deliberately dropped for these rows: a rerank score is not a cosine, and carrying the
    // cosine-calibrated threshold onto a different scale would measure a mistake instead of a model. Its own
    // thresholds are swept separately below, because "does the relevance model know when nothing matches"
    // is a fair question to ask of it and one it could plausibly answer better than a threshold can.
    if let rerank {
        var cost = RerankCost()
        for depth in [8, 16, 32] {
            var scored: [String: [SelectionCandidate]] = [:]
            for query in corpus.queries {
                var bestPerSource: [String: SelectionCandidate] = [:]
                for candidate in semanticByQuery[query.id] ?? [] {
                    if let existing = bestPerSource[candidate.sourceID],
                       existing.cosine >= candidate.cosine { continue }
                    bestPerSource[candidate.sourceID] = candidate
                }
                let shortlist = Array(bestPerSource.values
                    .sorted { $0.cosine > $1.cosine }
                    .prefix(depth))
                let texts = shortlist.compactMap { chunkTexts[$0.documentID] }
                guard texts.count == shortlist.count else {
                    throw VectorError.missing("chunk text for a rerank candidate")
                }
                let startedAt = DispatchTime.now().uptimeNanoseconds
                let relevance = try await rerank.scores(query: query.text, documents: texts)
                cost.record(milliseconds: Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000,
                            pairs: texts.count)
                // The rerank score replaces the cosine, so the SAME selection policy runs on top of it and the
                // comparison isolates the relevance model rather than the policy.
                scored[query.id] = zip(shortlist, relevance).map { candidate, score in
                    var rescored = candidate
                    rescored.rerankScore = score
                    return rescored
                }
            }
            // Thresholds on the RERANKER's scale, which is a logit and not a cosine: the sanity pair scored
            // +1.77 for the right document and −3.58 for an off-topic one. Zero is the natural decision
            // boundary, so that and one notch above it are the two worth trying.
            // Thresholds are probabilities now that the logit is squashed, so 0.5 is the model's own decision
            // boundary. `withRecency` is the row the per-category table asked for: the reranker wins
            // paraphrase, negation and near-miss while recency wins its own category and synonym, so the
            // interesting question is whether they add up or fight.
            for (threshold, withRecency) in [(nil, false), (0.5, false), (nil, true), (0.5, true)]
                as [(Double?, Bool)] {
                var config = SelectionConfig.recommended(floor: threshold)
                config.recencyWeight = withRecency ? 0.25 : 0
                config.idfBonus = 0
                config.usesRerankScore = true
                config.name = "RERANK@\(depth)"
                    + (withRecency ? " +recency" : "")
                    + (threshold == nil ? "" : " p≥\(String(format: "%.1f", threshold!))")
                var results: [QueryResult] = []
                for query in corpus.queries {
                    let ranked = select(semantic: scored[query.id] ?? [], lexical: [], config: config)
                    results.append(QueryResult(query: query,
                                               ranked: ranked,
                                               groups: ranked.compactMap { documentsByID[$0]?.diversityGroup },
                                               availableRelevant: query.judgments.values.filter { $0 > 0 }.count))
                }
                for scope in scopesToReport(showHoldout: showHoldout, split: split) {
                    reports.append(report(name: config.name, scope: scope, allResults: results,
                                          split: split, countsUnderruns: threshold == nil))
                }
            }
        }
        if !quiet {
            print("\nrerank cost: \(cost.summary)")
        }
    }

    if !quiet {
        printCalibration(relevant: relevantCosines,
                         irrelevant: bestIrrelevantCosines,
                         showHoldout: showHoldout)
        printTable(reports, vectors: vectors, corpus: corpus)
    }
    return reports
}

private func report(name: String,
                    scope: ReportScope,
                    allResults: [QueryResult],
                    split: CorpusSplit?,
                    countsUnderruns: Bool) -> VariantReport {
    let results: [QueryResult]
    switch scope {
    case .dev:
        results = allResults.filter { $0.query.index == "main" && split?.dev.contains($0.query.id) != false }
    case .test:
        results = allResults.filter { $0.query.index == "main" && split?.test.contains($0.query.id) == true }
    case .main: results = allResults.filter { $0.query.index == "main" }
    case .locales: results = allResults.filter { $0.query.index != "main" }
    case .all: results = allResults
    }
    let scored = results.filter { $0.query.category.isAnswerable }
    let irrelevant = results.filter { !$0.query.category.isAnswerable }
    var perCategory: [QueryCategory: (value: Double, count: Int)?] = [:]
    for category in QueryCategory.allCases where category.isAnswerable {
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
        scope: scope,
        ndcg: mean(scored.map { normalizedDCG(ranked: $0.ranked, judgments: $0.query.judgments) }),
        precision: mean(scored.map { precision(ranked: $0.ranked, judgments: $0.query.judgments) }),
        recall1: mean(scored.map { recall(ranked: $0.ranked, judgments: $0.query.judgments, k: 1) }),
        recall3: mean(scored.map { recall(ranked: $0.ranked, judgments: $0.query.judgments, k: 3) }),
        recall8: mean(scored.map { recall(ranked: $0.ranked, judgments: $0.query.judgments, k: 8) }),
        mrr: mean(scored.map { reciprocalRank(ranked: $0.ranked, judgments: $0.query.judgments) }),
        irrelevantLines: irrelevant.isEmpty
            ? 0
            : Double(irrelevant.reduce(0) { $0 + emittedLineCount(ranked: $1.ranked) }) / Double(irrelevant.count),
        abstention: abstentionRate(emittedCounts: irrelevant.map { emittedLineCount(ranked: $0.ranked) }),
        falseAbstention: falseAbstentionRate(emittedCounts: scored.map { emittedLineCount(ranked: $0.ranked) }),
        meanEmitted: meanEmittedLines(results.map { emittedLineCount(ranked: $0.ranked) }),
        dominance: mean(scored.map { $0.groups.isEmpty ? nil : dominance($0.groups) }),
        underruns: countsUnderruns
            ? scored.filter {
                slotUnderrun(emitted: emittedLineCount(ranked: $0.ranked),
                             availableRelevant: $0.availableRelevant)
            }.count
            : nil,
        perCategory: perCategory,
        perLanguage: perLanguage,
        perQueryNDCG: Dictionary(uniqueKeysWithValues: scored.compactMap { result in
            normalizedDCG(ranked: result.ranked, judgments: result.query.judgments)
                .map { (result.query.id, $0) }
        })
    )
}

// MARK: - Output

private func format(_ metric: (value: Double, count: Int)?) -> String {
    guard let metric else { return "    —" }
    return String(format: "%5.3f", metric.value)
}

/// Which calibration bucket a query's cosines belong to.
///
/// Extracted so it can be tested, because the rule it encodes is the one that matters and the samples are
/// otherwise only ever printed: **a holdout query must never contribute to the distribution a floor is chosen
/// from.** Without a test, that could regress into a pooled calibration again — which is how it started, and the
/// symptom would be a slightly different threshold rather than anything that looks like a failure.
///
/// With no split loaded every `main` query counts as dev. That is deliberate: no split means no freeze to
/// protect, and silently treating everything as holdout would suppress the only row the report is meant to show.
func calibrationScope(for query: CorpusQuery, split: CorpusSplit?) -> ReportScope {
    guard query.index == Corpus.splitIndex else { return .locales }
    if let split, split.test.contains(query.id) { return .test }
    return .dev
}

private func printCalibration(relevant: [ReportScope: [Double]],
                              irrelevant: [ReportScope: [Double]],
                              showHoldout: Bool) {
    func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[index]
    }
    print("""

        ================================================================================
        A. FLOOR CALIBRATION — per scope, and the floor is chosen on DEV only
        ================================================================================
        Cosine of a genuinely relevant hit, against the best cosine a query with nothing
        relevant produces. A usable floor lies between these two distributions; if they
        overlap heavily, no single threshold exists and the floor must be per-kind or
        relative to the top hit instead of absolute.

        This used to pool every query in the corpus, which is the worst place in the report
        for that mistake: this section is where the threshold is CHOSEN, so a pooled floor is
        fitted partly on the frozen holdout — leaking exactly what the split exists to
        prevent — and partly on ten 24-document locale sets whose cosines come from a much
        easier problem. Read the DEV row. The others are diagnostics.

        Absolute cosines are also not comparable BETWEEN models, so this is per model too: a
        floor calibrated on one and applied to another measures the mismatch, not the model.
        """)
    func row(_ label: String, _ scope: ReportScope) {
        let hits = relevant[scope] ?? []
        let noise = irrelevant[scope] ?? []
        guard !hits.isEmpty || !noise.isEmpty else { return }
        print("""

              \(label)
                relevant hits      n=\(hits.count)   p05 \(String(format: "%.3f", percentile(hits, 0.05)))   p25 \(String(format: "%.3f", percentile(hits, 0.25)))   median \(String(format: "%.3f", percentile(hits, 0.5)))
                best-of-irrelevant n=\(noise.count)   median \(String(format: "%.3f", percentile(noise, 0.5)))   p75 \(String(format: "%.3f", percentile(noise, 0.75)))   p95 \(String(format: "%.3f", percentile(noise, 0.95)))
            """)
    }
    row("DEV of `main` — the only scope a floor may be chosen from", .dev)
    if showHoldout {
        row("HOLDOUT of `main` — read once, never used to pick a threshold", .test)
    } else {
        print("\n  HOLDOUT of `main` — withheld (pass --holdout <reason> to see it)")
    }
    row("locale sets — 24-document indexes, an easier problem and a different distribution", .locales)
}

private func printTable(_ reports: [VariantReport], vectors: VectorSet, corpus: Corpus) {
    func rows(_ scope: ReportScope) -> [VariantReport] { reports.filter { $0.scope == scope } }

    let mainDocuments = corpus.documents.filter { $0.index == "main" }.count
    let localeDocuments = corpus.documents.filter { $0.index != "main" }.count
    let localeIndexes = corpus.indexes.filter { $0 != "main" }.count
    let answerable = corpus.queries.filter { $0.category.isAnswerable }
    let answerableTotal = answerable.count
    let answerableOnMain = answerable.filter { $0.index == "main" }.count

    print("""

        ================================================================================
        B. ABLATION LADDER — \(vectors.meta.model), \(vectors.dimensions) dims
           SCOPE: DEVELOPMENT half of `main` — \(mainDocuments) documents, \(rows(.dev).first?.ndcg?.count ?? 0) scored queries
        ================================================================================
        Tuning happens here and nowhere else. Floors, weights, candidate depths, rerank
        settings and model choice are all chosen on this half; the holdout stays frozen
        (see Corpus/split.json) and needs --holdout <reason> to appear at all, which is
        logged. Roughly a dozen decisions have already been fitted to this corpus, so
        without that separation the numbers would increasingly describe the benchmark
        rather than retrieval.

        Also deliberately NOT an average over the whole corpus: of \(answerableTotal) answerable
        queries \(answerableOnMain) sit on `main` and \(answerableTotal - answerableOnMain) on the
        ten 24-document locale sets, so a pooled mean is largely driven by a problem too easy to
        separate anything. (Computed, not carried — these counts were written out by hand once and
        went stale the first time the corpus grew.)

        nDCG@8 and P@8 exclude `unanswerable` (no ideal ranking), which is exactly why the
        abstention columns exist: the floor's largest measured effect never shows up in nDCG.
        `abst.` = share of unanswerable questions answered with NOTHING (higher is better).
        `f.abst` = share of ANSWERABLE questions wrongly answered with nothing — the price of
        every threshold, and without it a tighter floor looks free. `irrel.` = mean lines on an
        unanswerable question (target 0). `lines` = mean lines over all queries, so `P@8` can
        never be read alone: a pipeline that emits one correct line scores P@8 = 1.00, and only
        `lines` and `f.abst` reveal that it bought that by staying silent elsewhere.

        variant                          nDCG@8   P@8   R@1   R@8   MRR  abst. f.abst irrel. lines domin.
        ------------------------------------------------------------------------------------------
        """)
    for report in rows(.dev) { printRow(report) }

    if !rows(.test).isEmpty {
        print("""

            ================================================================================
            B0. HOLDOUT — frozen half of `main`, \(rows(.test).first?.ndcg?.count ?? 0) scored queries
            ================================================================================
            UNLOCKED FOR THIS RUN. Every access is recorded in Corpus/holdout-access.log.

            Read this to CONFIRM a configuration chosen on dev, never to choose one. At the
            corpus's current size a paired bootstrap here spans roughly ±0.11, so it can
            catch a large regression and cannot resolve the 0.002–0.043 differences the
            decisions so far turned on. It becomes decisive once `main` grows.

            variant                          nDCG@8   P@8   R@1   R@8   MRR  abst. f.abst irrel. lines domin.
            ------------------------------------------------------------------------------------------
            """)
        for report in rows(.test) { printRow(report) }
    }


    print("""

        ================================================================================
        B2. LOCALE SETS — \(localeIndexes) indexes, \(localeDocuments) documents in total
        ================================================================================
        A LANGUAGE SMOKE TEST, not a ranking measurement. Each of these indexes holds about
        two dozen documents, which is few enough that most variants tie and the ones that do
        not are separating noise. Read it to answer "does this model work in this language at
        all", never to choose between selection variants.

        variant                          nDCG@8   P@8   R@1   R@8   MRR  abst. f.abst irrel. lines domin.
        ------------------------------------------------------------------------------------------
        """)
    for report in rows(.locales) { printRow(report) }

    print("""

        ================================================================================
        B3. POOLED — every index at once
        ================================================================================
        MIXED DIFFICULTY. Kept only so the figures published before this split stay
        reproducible. Do not quote a number from this table.

        variant                          nDCG@8   P@8   R@1   R@8   MRR  abst. f.abst irrel. lines domin.
        ------------------------------------------------------------------------------------------
        """)
    for report in rows(.all) { printRow(report) }

    printComparisons(rows(.dev), baselineName: SelectionConfig.today.name,
                     scopeLabel: "development half of `main`")
    if !rows(.test).isEmpty {
        printComparisons(rows(.test), baselineName: SelectionConfig.today.name,
                         scopeLabel: "FROZEN HOLDOUT — confirmation only")
    }

    printCategories(rows(.dev), title: "C. PER CATEGORY (nDCG@8) — development half of `main`")
    printLanguages(rows(.dev), title: "D1. PER LANGUAGE within the development half (nDCG@8)",
                   note: """
                   Both cells come from the same 272-document index, so they are comparable to
                   each other. The English one rests on very few queries — a smoke signal.
                   """)
    printLanguages(rows(.locales), title: "D2. PER LANGUAGE across the locale sets (nDCG@8)",
                   note: """
                   Each cell is its own ~24-document index. Comparable to each other, and NOT
                   comparable to D1: those questions are asked against an index ten times larger.
                   """)
    print("")
}

/// Every variant against the shipped baseline, with a paired bootstrap interval.
///
/// The section exists because a table of bare deltas invites a ranking, and several rankings in this file's
/// history were noise: one model read 0.850, then 0.806, then 0.677 as the measurement got more honest, and a
/// 0.004 gap was once reported as an ordering. A row whose interval straddles zero is marked `~` and must be
/// described as indistinguishable, not placed above or below anything.
private func printComparisons(_ reports: [VariantReport], baselineName: String, scopeLabel: String) {
    guard let baseline = reports.first(where: { $0.name == baselineName }) else { return }
    print("")
    print("================================================================================")
    print("E. VS `\(baselineName)` — paired bootstrap, 95% CI  (\(scopeLabel))")
    print("================================================================================")
    print("Paired on purpose: both variants answer the same questions, so the per-query")
    print("differences carry far less variance than two independent means would. A row marked")
    print("`~` has an interval containing zero — the corpus cannot tell it apart from the")
    print("baseline, and it must not be ranked above or below it however tempting the delta is.")
    print("")
    print("variant                            Δ nDCG@8      95% CI            n  verdict")
    print("------------------------------------------------------------------------------------")
    for report in reports where report.name != baselineName {
        guard let interval = pairedBootstrap(baseline: baseline.perQueryNDCG,
                                             candidate: report.perQueryNDCG) else { continue }
        let verdict = interval.isInconclusive
            ? "~ indistinguishable"
            : (interval.delta > 0 ? "+ better" : "- worse")
        let name = report.name.padding(toLength: 34, withPad: " ", startingAt: 0)
        print(name
            + String(format: "%+8.3f", interval.delta)
            + String(format: "   [%+.3f, %+.3f]", interval.low, interval.high)
            + String(format: "  %3d  ", interval.n)
            + verdict)
    }
}

private func printRow(_ report: VariantReport) {
    func pct(_ value: Double?) -> String {
        guard let value else { return "    —" }
        return String(format: "%5.2f", value)
    }
    let name = report.name.padding(toLength: 32, withPad: " ", startingAt: 0)
    print("\(name) \(format(report.ndcg)) \(format(report.precision)) \(format(report.recall1)) "
        + "\(format(report.recall8)) \(format(report.mrr)) "
        + "\(pct(report.abstention)) \(pct(report.falseAbstention)) "
        + String(format: "%5.2f", report.irrelevantLines) + " "
        + String(format: "%5.2f", report.meanEmitted ?? 0) + " \(format(report.dominance))")
}

private func printCategories(_ reports: [VariantReport], title: String) {
    let categories = QueryCategory.allCases.filter(\.isAnswerable)
    print("""

        ================================================================================
        \(title)
        ================================================================================
        A variant is only an improvement if it wins its own category without losing another.
        This is the table that would have rejected symmetric RRF.

        variant                          \(categories.map { $0.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0) }.joined())
        ------------------------------------------------------------------------------------------
        """)
    for report in reports {
        let name = report.name.padding(toLength: 32, withPad: " ", startingAt: 0)
        let cells = categories.map {
            format(report.perCategory[$0] ?? nil).padding(toLength: 10, withPad: " ", startingAt: 0)
        }
        print("\(name) \(cells.joined())")
    }
}

private func printLanguages(_ reports: [VariantReport], title: String, note: String) {
    let languages = (reports.first?.perLanguage.keys).map { Array($0).sorted() } ?? []
    guard !languages.isEmpty else { return }
    print("""

        ================================================================================
        \(title)
        ================================================================================
        \(note)

        variant                          \(languages.map { $0.padding(toLength: 8, withPad: " ", startingAt: 0) }.joined())
        ------------------------------------------------------------------------------------------
        """)
    for report in reports {
        let name = report.name.padding(toLength: 32, withPad: " ", startingAt: 0)
        let cells = languages.map {
            format(report.perLanguage[$0] ?? nil).padding(toLength: 8, withPad: " ", startingAt: 0)
        }
        print("\(name) \(cells.joined())")
    }
}
