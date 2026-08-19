import Foundation
import SemanticMemory

// The thing under test: how a ranked list of chunk hits becomes the ≤8 lines the coach reads.
//
// The BASELINE variants call the real shipped code — `SemanticRanking.fuse` — rather than a re-description
// of it, so "today" in every table below is genuinely today. The proposed variants are implemented here and
// only here: this benchmark is what has to argue for them, and nothing ships until it does.

/// One chunk that the semantic or lexical arm returned, with the metadata a selection policy could use.
/// Everything here except `cosine` and `vector` is already stored in `semanticDocument` today — which is
/// why the proposed scoring needs no schema migration.
struct SelectionCandidate {
    let documentID: String
    let sourceID: String
    let kind: SemanticSourceKind
    /// The conversation a chunk belongs to, or its kind when it belongs to none. What a per-thread cap
    /// applies to.
    let diversityGroup: String
    let ageDays: Double
    let priority: Int
    let cosine: Double
    let vector: [Float]
    /// Share of the query's IDF mass this source matches by exact token. 0 when the lexical arm never saw it.
    var lexicalMass: Double = 0
    /// A cross-encoder's relevance score, when a reranking stage ran. Kept beside the cosine rather than
    /// overwriting it so a rerank row can still be read against the embedding order it replaced.
    var rerankScore: Double?
}

struct SelectionConfig {
    var name: String
    /// K — how many chunk hits the store returns before anything is cut. Production is 32.
    var candidateLimit = 32
    var rescueSlots = SemanticRanking.defaultRescueSlots
    /// Route the baseline through `SemanticRanking.fuse` (the shipped path) instead of the proposed pipeline.
    var useProductionFuse = true
    /// Feed the lexical arm the numeric/date-aware tokeniser instead of the shipped one.
    var numericTokens = false
    /// Weight the lexical arm by IDF instead of raw overlap count.
    var lexicalIDF = false
    /// Aggregate several chunks of one source by their BEST cosine rather than by whichever came first.
    var perSourceMax = false
    /// How much of the score recency is allowed to move, 0…1.
    var recencyWeight = 0.0
    /// How much of the score the indexing `priority` is allowed to move, 0…1.
    var priorityWeight = 0.0
    /// Additive bonus for an exact lexical match, in cosine units.
    var idfBonus = 0.0
    /// Absolute cosine below which a line is not worth a context slot. `nil` = today's behaviour, which is
    /// to always fill all eight.
    var floor: Double?
    var quotas = false
    /// λ for maximal-marginal-relevance diversification; `nil` disables it.
    var mmrLambda: Double?
    /// Keep a candidate only if its score is at least this fraction of the TOP score for the query.
    ///
    /// A dynamic floor, which an absolute one cannot be: cosine scale drifts per model and per query type, so
    /// one number that suits a well-answered question throws away everything on a weakly-answered one, and one
    /// that suits the weak case lets noise through on the strong case. Relative to the best hit, "clearly
    /// worse than what we already found" means the same thing everywhere.
    var floorRelativeToTop: Double?
    /// Emit NOTHING when the best hit for the query is below this. The absolute floor's remaining job once the
    /// relative one handles the shape: deciding whether the question is answerable at all.
    var confidenceGate: Double?
    /// Score on the reranker's scale instead of the embedding cosine. Only the base term changes; every policy
    /// above it — floor, quotas, MMR — is the same code, so a rerank row isolates the relevance model.
    var usesRerankScore = false
}

// MARK: - Named variants

extension SelectionConfig {
    /// The semantic arm alone, through the real `fuse`. The honest zero point: `fuse` with no lexical
    /// input is exactly per-source deduplication plus a cut at 8.
    static let semanticOnly = SelectionConfig(name: "semantic-only", rescueSlots: 0)

    /// What ships today: semantic order authoritative, two rescue slots for lexical-only sources.
    static let today = SelectionConfig(name: "today (+rescue)")

    static func proposed(floor: Double?) -> SelectionConfig {
        SelectionConfig(name: "proposed",
                        candidateLimit: 128,
                        useProductionFuse: false,
                        numericTokens: true,
                        lexicalIDF: true,
                        perSourceMax: true,
                        recencyWeight: 0.25,
                        priorityWeight: 0.20,
                        idfBonus: 0.05,
                        floor: floor,
                        quotas: true,
                        mmrLambda: 0.7)
    }

    /// What the measurement actually supports, as opposed to what `proposed` guessed.
    ///
    /// Against real Nomic vectors the kind prior and MMR both cost nDCG@8 (−0.005 and −0.017) and MMR bought
    /// no diversity at all next to the quotas that precede it, so neither is here. Quotas are left out too:
    /// they trade 0.02 nDCG for a large drop in single-thread dominance, and on this corpus part of that cost
    /// is an artefact — the flood thread's messages are themselves graded relevant — so that is a judgement
    /// to make deliberately rather than a win to bank.
    static func recommended(floor: Double?) -> SelectionConfig {
        SelectionConfig(name: "recommended",
                        candidateLimit: 128,
                        useProductionFuse: false,
                        numericTokens: true,
                        lexicalIDF: true,
                        perSourceMax: true,
                        recencyWeight: 0.25,
                        priorityWeight: 0,
                        idfBonus: 0.05,
                        floor: floor,
                        quotas: false,
                        mmrLambda: nil)
    }

    /// One-feature-at-a-time ladder from `today` to `proposed`. Each step differs from the one before it in
    /// exactly one field, which is the only way a table like this can attribute a change to a cause.
    ///
    /// One ordering trap the first real run exposed: `K` is inert until something can RESCORE the candidates
    /// it admits. Deeper candidates all sit below rank 8, and while recency, the kind prior and the IDF bonus
    /// are still zero nothing can promote them, so an early `+K=128` step is guaranteed to measure exactly
    /// nothing — as it did. The two tail rows re-test it where it can actually bind.
    static func ladder(floor: Double?) -> [SelectionConfig] {
        var steps: [SelectionConfig] = [.semanticOnly, .today]
        var current = SelectionConfig(name: "", useProductionFuse: false)
        current.name = "+proposed pipeline (no features)"
        steps.append(current)
        current.candidateLimit = 128; current.name = "+K=128"; steps.append(current)
        current.perSourceMax = true; current.name = "+per-source max"; steps.append(current)
        current.numericTokens = true; current.name = "+numeric tokens"; steps.append(current)
        current.lexicalIDF = true; current.idfBonus = 0.05; current.name = "+IDF rescue"; steps.append(current)
        current.recencyWeight = 0.25; current.name = "+recency"; steps.append(current)
        current.priorityWeight = 0.20; current.name = "+kind prior"; steps.append(current)
        current.floor = floor; current.name = "+floor"; steps.append(current)
        current.quotas = true; current.name = "+quotas"; steps.append(current)
        current.mmrLambda = 0.7; current.name = "+MMR (= proposed)"; steps.append(current)
        // The two rows that isolate K where it can bind: identical to `recommended` apart from the candidate
        // depth, and placed after every rescoring feature is switched on.
        steps.append(recommended(floor: floor))
        // The dynamic floor, which is what an absolute threshold is a crude stand-in for. Two shapes: keep
        // what is within a fraction of the best hit, and refuse to answer at all when the best hit is weak.
        for relative in [0.9, 0.8, 0.7] {
            var dynamic = recommended(floor: nil)
            dynamic.floorRelativeToTop = relative
            dynamic.confidenceGate = floor
            dynamic.name = "recommended, top×\(String(format: "%.1f", relative)) + gate"
            steps.append(dynamic)
        }
        var gateOnly = recommended(floor: nil)
        gateOnly.confidenceGate = floor
        gateOnly.name = "recommended, gate only"
        steps.append(gateOnly)
        var shallow = recommended(floor: floor)
        shallow.candidateLimit = 32
        shallow.name = "recommended, K=32"
        steps.append(shallow)
        return steps
    }
}

// MARK: - Scoring

/// How fast a kind's relevance decays. `nil` means age is not staleness for that kind.
///
/// A `memoryFact` is not stale because it is old — it carries `validUntil` and a confirmation lifecycle,
/// which is a better statement about its currency than its age is. A chat turn is different: what someone
/// typed eight months ago about their knee is usually not what is true now, and the keyword ranker has
/// always said so with a 30-day half-life. These numbers mirror that ranker where it has an opinion and
/// stay conservative where it does not.
func recencyHalfLifeDays(_ kind: SemanticSourceKind) -> Double? {
    switch kind {
    case .memoryFact, .habitHypothesis:
        return nil
    case .conversationTitle, .conversationSummary, .userMessage:
        return 30
    case .journalQuestion, .journalNote:
        return 60
    case .recommendationFeedback:
        return 90
    }
}

/// The highest `priority` the app assigns (a pinned memory fact). Used only to normalise, so the prior is
/// a multiplier in a known range rather than an unbounded term.
let maximumDocumentPriority = 120.0

/// Cosine, modulated by recency and kind, then nudged by exact lexical evidence.
///
/// Modulation is MULTIPLICATIVE and bounded by its weight, deliberately: it keeps the result on the cosine
/// scale, so one absolute floor stays meaningful across every variant. An additive recency term would move
/// scores off that scale and the floor would have to be re-calibrated per variant — which would make the
/// ablation table incomparable, the same way a re-ordering lexical term made RRF incomparable.
func score(_ candidate: SelectionCandidate, _ config: SelectionConfig) -> Double {
    // A rerank score is a LOGIT, not a similarity: the sanity pair scored +1.77 and −3.58. Squashed to a
    // probability before anything else touches it, for two reasons. Multiplying a negative logit by a decay
    // below one makes it LARGER, so recency would reward staleness on exactly the candidates it should
    // punish — silent and in the right direction to look plausible. And a threshold on (0,1) means the same
    // thing for a reranker as for a cosine, so the floor and the gate stay comparable across the table.
    var value = config.usesRerankScore
        ? 1 / (1 + exp(-(candidate.rerankScore ?? 0)))
        : candidate.cosine
    if config.recencyWeight > 0, let halfLife = recencyHalfLifeDays(candidate.kind) {
        let decay = exp(-log(2.0) * max(0, candidate.ageDays) / halfLife)
        value *= (1 - config.recencyWeight) + config.recencyWeight * decay
    }
    if config.priorityWeight > 0 {
        let normalised = min(1, max(0, Double(candidate.priority) / maximumDocumentPriority))
        value *= (1 - config.priorityWeight) + config.priorityWeight * normalised
    }
    return value + config.idfBonus * candidate.lexicalMass
}

// MARK: - The pipeline

/// Kinds that always keep a seat at the table.
///
/// These are the curated ones: a fact the user confirmed, a journal answer they wrote, a habit hypothesis
/// the app derived and labelled. They are outnumbered in the index by raw chat turns by orders of
/// magnitude, so on cosine alone they lose slots to whichever eight messages happened to be phrased most
/// like the question.
let reservedKinds: Set<SemanticSourceKind> = [.memoryFact, .journalQuestion, .journalNote, .habitHypothesis]
let reservedSlots = 2
let maximumUserMessages = 4
let maximumPerGroup = 2

/// Selects the ≤`limit` source ids the coach will read.
///
/// Returns SOURCE ids, not document ids, because that is what the context builder deduplicates on and what
/// the judgments are written against.
func select(semantic: [SelectionCandidate],
            lexical: [SelectionCandidate],
            config: SelectionConfig,
            limit: Int = contextSlots) -> [String] {
    guard limit > 0 else { return [] }

    if config.useProductionFuse {
        // The shipped path, through the shipped code. `fuse` does its own per-source deduplication and its
        // own cut, so nothing here may pre-empt either.
        let fused = SemanticRanking.fuse(semantic: semantic.map(\.hit),
                                         lexical: lexical.map(\.hit),
                                         limit: limit,
                                         rescueSlots: config.rescueSlots)
        return fused.map(\.sourceID)
    }

    // 1. Per-source aggregation. `first` reproduces today's behaviour (whichever chunk ranked highest
    //    arrives first anyway, so the two agree on the semantic arm — they differ once a rescue or a
    //    recency term can move a lower chunk of the same source above a higher one).
    var bestBySource: [String: SelectionCandidate] = [:]
    for candidate in semantic {
        if let existing = bestBySource[candidate.sourceID] {
            guard config.perSourceMax, candidate.cosine > existing.cosine else { continue }
        }
        bestBySource[candidate.sourceID] = candidate
    }
    // 2. Lexical-only sources still enter, but as ordinary scored candidates rather than as two guaranteed
    //    tail slots. A rescue that is worth a slot wins one on its evidence; one that is not, does not
    //    displace a better semantic hit.
    for candidate in lexical where bestBySource[candidate.sourceID] == nil {
        bestBySource[candidate.sourceID] = candidate
    }
    // Carry the lexical mass onto whichever record survived, so an exact match counts even when the
    // source was also found semantically.
    for candidate in lexical {
        if var existing = bestBySource[candidate.sourceID], existing.lexicalMass < candidate.lexicalMass {
            existing.lexicalMass = candidate.lexicalMass
            bestBySource[candidate.sourceID] = existing
        }
    }

    // 3. Score, then floor. Sorted with a stable id tiebreak so a run is reproducible.
    var pool = bestBySource.values
        .map { (candidate: $0, value: score($0, config)) }
        .sorted {
            if $0.value == $1.value { return $0.candidate.sourceID < $1.candidate.sourceID }
            return $0.value > $1.value
        }
    if let floor = config.floor {
        pool = pool.filter { $0.value >= floor }
    }
    // The gate first: if even the best candidate is weak, the honest answer is no context at all, and the
    // relative floor below cannot express that — everything is 100% of the top score when the top score is bad.
    if let gate = config.confidenceGate, let best = pool.first?.value, best < gate {
        pool = []
    }
    if let relative = config.floorRelativeToTop, let best = pool.first?.value, best > 0 {
        pool = pool.filter { $0.value >= best * relative }
    }

    // 4. Greedy selection under quotas and MMR.
    var selected: [SelectionCandidate] = []
    var groupCounts: [String: Int] = [:]
    var userMessages = 0
    var reservedTaken = 0

    while selected.count < limit {
        var bestIndex: Int?
        var bestValue = -Double.infinity
        // Once the slots left equal the reservations still owed, only a reserved kind may take one. If none
        // is available the reservation lapses rather than leaving the context short — an empty slot helps
        // nobody.
        let slotsLeft = limit - selected.count
        let reservationsOwed = max(0, reservedSlots - reservedTaken)
        let reservedOnly = slotsLeft <= reservationsOwed
            && pool.contains { reservedKinds.contains($0.candidate.kind) }

        for (index, entry) in pool.enumerated() {
            let candidate = entry.candidate
            if selected.contains(where: { $0.sourceID == candidate.sourceID }) { continue }
            if config.quotas {
                if reservedOnly && !reservedKinds.contains(candidate.kind) { continue }
                if candidate.kind == .userMessage && userMessages >= maximumUserMessages { continue }
                if groupCounts[candidate.diversityGroup, default: 0] >= maximumPerGroup { continue }
            }
            var value = entry.value
            if let lambda = config.mmrLambda, !selected.isEmpty {
                let redundancy = selected
                    .map { SemanticVector.cosine(candidate.vector, $0.vector) }
                    .max() ?? 0
                value = lambda * value - (1 - lambda) * redundancy
            }
            if value > bestValue {
                bestValue = value
                bestIndex = index
            }
        }
        guard let bestIndex else { break }
        let chosen = pool.remove(at: bestIndex).candidate
        selected.append(chosen)
        groupCounts[chosen.diversityGroup, default: 0] += 1
        if chosen.kind == .userMessage { userMessages += 1 }
        if reservedKinds.contains(chosen.kind) { reservedTaken += 1 }
    }
    return selected.map(\.sourceID)
}

private extension SelectionCandidate {
    /// The candidate as the shipped types see it. `consentScope` is irrelevant to `fuse` (the store already
    /// filtered on it) so any value is faithful here; `.memory` is used so the record is well-formed.
    var hit: SemanticHit {
        SemanticHit(documentID: documentID,
                    sourceKind: kind,
                    sourceID: sourceID,
                    chunkIndex: 0,
                    score: cosine,
                    consentScope: .memory)
    }
}
