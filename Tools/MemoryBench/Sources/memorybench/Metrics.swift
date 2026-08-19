import Foundation

// The scoring primitives. Everything here is a pure function over a ranked list of source ids and a
// judgment table, so `memorybenchTests` pins all of it on hand-built inputs.

/// Graded relevance on the corpus's four-point scale: 3 = the one document that directly answers, 2 =
/// strongly relevant, 1 = supporting, 0 = judged and rejected. `CorpusQuery.judgments` carries the full
/// definition and the invariants that keep it meaningful.
///
/// `0` is explicitly stored rather than omitted for the documents a query deliberately must NOT retrieve — an
/// omitted judgment and a judged-irrelevant one are the same for scoring, but writing the zero down is how
/// the corpus records that the case was considered.
public typealias Judgments = [String: Int]

/// The retrieval metric that matches what the coach actually consumes.
///
/// `k` is 8 in every real call, because 8 lines is what `context(from:documents:)` emits. Anything the
/// selection ranks 9th is invisible to the model, so a metric measured at a deeper cutoff would reward
/// improvements the product never sees.
public let contextSlots = 8

/// Standard exponential gain, `2^grade − 1`: 7 for the document that directly answers, 3 for a strongly
/// relevant one, 1 for supporting context, 0 for a rejected one. The exponent is what makes the metric refuse
/// to accept padding — under a linear gain three loosely-related lines would outscore the one correct
/// answer, which is precisely the failure this benchmark exists to catch.
///
/// The scale grew from 0–2 to 0–3 on 2026-08-19, which steepened the answer-to-support ratio from 3:1 to 7:1.
/// That is a deliberate change of the instrument, not a tweak: it moves nDCG@8 by up to 0.149 on a single
/// query. Nothing measured before it may be compared with anything measured after.
func gain(_ grade: Int) -> Double {
    grade <= 0 ? 0 : pow(2, Double(grade)) - 1
}

func discountedCumulativeGain(_ grades: [Int]) -> Double {
    var total = 0.0
    for (index, grade) in grades.enumerated() {
        total += gain(grade) / log2(Double(index + 2))
    }
    return total
}

/// nDCG@k, or `nil` when the query has nothing relevant to find.
///
/// The `nil` is load-bearing, not defensive. The `irrelevant` category exists to check that the
/// selection emits NOTHING when nothing is relevant; its ideal DCG is zero, so nDCG is undefined. If
/// this returned 0 instead, averaging it in would punish the correct behaviour and reward a system that
/// pads every turn with 8 lines — the exact defect (P1) the corpus was built to expose. Those queries
/// are scored by `emittedLineCount` instead.
func normalizedDCG(ranked: [String], judgments: Judgments, k: Int = contextSlots) -> Double? {
    let ideal = discountedCumulativeGain(judgments.values.filter { $0 > 0 }.sorted(by: >).prefix(k).map { $0 })
    guard ideal > 0 else { return nil }
    let actual = discountedCumulativeGain(ranked.prefix(k).map { judgments[$0] ?? 0 })
    return actual / ideal
}

/// Share of the emitted lines that are relevant at all (grade ≥ 1).
///
/// The denominator is the number of lines ACTUALLY emitted, not `k`. A selection that correctly emits
/// two lines, both right, has precision 1.0 — it should not be marked down to 0.25 for declining to
/// invent six more. That is the whole point of giving the pipeline permission to return fewer than 8.
func precision(ranked: [String], judgments: Judgments, k: Int = contextSlots) -> Double? {
    let emitted = ranked.prefix(k)
    guard !emitted.isEmpty else { return nil }
    let hits = emitted.filter { (judgments[$0] ?? 0) > 0 }.count
    return Double(hits) / Double(emitted.count)
}

func recall(ranked: [String], judgments: Judgments, k: Int) -> Double? {
    let relevant = Set(judgments.filter { $0.value > 0 }.keys)
    guard !relevant.isEmpty else { return nil }
    let found = ranked.prefix(k).filter { relevant.contains($0) }.count
    return Double(found) / Double(relevant.count)
}

/// 1/rank of the first relevant hit, 0 when none is retrieved at all.
func reciprocalRank(ranked: [String], judgments: Judgments, k: Int = contextSlots) -> Double? {
    guard judgments.values.contains(where: { $0 > 0 }) else { return nil }
    for (index, id) in ranked.prefix(k).enumerated() where (judgments[id] ?? 0) > 0 {
        return 1.0 / Double(index + 1)
    }
    return 0
}

/// How many lines the selection actually handed to the model. For the `irrelevant` category this IS the
/// score: the target is zero, and every line above zero is a line of noise the coach paid context for.
func emittedLineCount(ranked: [String], k: Int = contextSlots) -> Int {
    min(ranked.count, k)
}

// MARK: - Selection-shape metrics

/// The largest share any single group (a `sourceKind`, or a conversation) holds among the emitted lines.
///
/// `fuse` deduplicates per `sourceID`, but every user message IS its own source, so eight paraphrases of
/// one complaint from one conversation can legally take all eight slots and crowd out the curated
/// `memoryFact`. Nothing in the retrieval metrics above notices that — each of those lines may well be
/// relevant. This is the metric that does.
func dominance(_ groups: [String]) -> Double {
    guard !groups.isEmpty else { return 0 }
    var counts: [String: Int] = [:]
    for group in groups { counts[group, default: 0] += 1 }
    return Double(counts.values.max() ?? 0) / Double(groups.count)
}

/// True when the selection emitted fewer lines than it had room for while relevant candidates were still
/// available — the shape of P4 (a candidate pool that collapses when many chunks share one source) and of
/// P9 (hits dropped after the cut with nothing moved up to replace them).
func slotUnderrun(emitted: Int, availableRelevant: Int, k: Int = contextSlots) -> Bool {
    emitted < min(k, availableRelevant)
}

// MARK: - Aggregation

/// Mean over the queries where the metric is defined, plus how many those were.
///
/// Reported as a pair on purpose: a variant that improves the mean by scoring fewer queries has not
/// improved anything, and a bare average hides that. Every table in `score` prints the count beside the
/// value for this reason.
func mean(_ values: [Double?]) -> (value: Double, count: Int)? {
    let defined = values.compactMap { $0 }
    guard !defined.isEmpty else { return nil }
    return (defined.reduce(0, +) / Double(defined.count), defined.count)
}

// MARK: - Abstention and coverage

// The metrics that make the floor's actual value visible.
//
// nDCG is `nil` for an `unanswerable` query, which is mathematically right — there is no ideal ranking to
// normalise against — but it means the biggest measured effect of the floor never appears in the primary
// number at all. Going from eight irrelevant lines to nearly none is plausibly worth more to the product than
// ±0.02 nDCG, and it was invisible.
//
// The reverse error needs its own number too, and had none: a floor tuned to silence noise will eventually
// silence answers. `falseAbstentionRate` is the cost side of every threshold decision, and without it a
// tighter floor looks free.

/// Share of `unanswerable` queries the pipeline correctly said nothing about. Higher is better.
func abstentionRate(emittedCounts: [Int]) -> Double? {
    guard !emittedCounts.isEmpty else { return nil }
    return Double(emittedCounts.filter { $0 == 0 }.count) / Double(emittedCounts.count)
}

/// Share of ANSWERABLE queries the pipeline wrongly said nothing about. Lower is better, and it is the price
/// of every floor: silence on a question that had an answer is a worse failure than a mediocre ranking,
/// because the coach then has nothing at all to work from.
func falseAbstentionRate(emittedCounts: [Int]) -> Double? {
    guard !emittedCounts.isEmpty else { return nil }
    return Double(emittedCounts.filter { $0 == 0 }.count) / Double(emittedCounts.count)
}

/// Mean lines handed to the model, over every query. Reported beside precision on purpose: precision divides
/// by what was emitted, so a pipeline that answers one line and gets it right scores 1.0, and only this column
/// shows that it did so by declining to say anything else.
func meanEmittedLines(_ emittedCounts: [Int]) -> Double? {
    guard !emittedCounts.isEmpty else { return nil }
    return Double(emittedCounts.reduce(0, +)) / Double(emittedCounts.count)
}

// MARK: - Uncertainty

// Why every comparison needs an interval, not just a delta.
//
// The decisions taken so far turned on differences between 0.002 and 0.043 nDCG@8, ranked as though the order
// were meaningful. It was not: a model read 0.850, then 0.806, then 0.677 as the measurement got more honest,
// and a ranking built on 0.004 was noise presented as a finding. A paired bootstrap is the cheapest way to
// stop that, because it answers the only question that matters — is this difference bigger than the corpus's
// own sampling error?
//
// PAIRED is the important word. Both variants answer the SAME queries, so the per-query differences carry far
// less variance than two independent means would, and the interval is correspondingly tighter. Comparing
// independent confidence intervals instead would throw that away and call almost everything inconclusive.

struct BootstrapInterval {
    let delta: Double
    let low: Double
    let high: Double
    /// Queries both variants scored. A difference measured over fewer queries is a weaker claim, so the count
    /// travels with the interval.
    let n: Int

    /// True when the interval straddles zero, i.e. the corpus cannot tell these two apart. Such a pair must be
    /// reported as indistinguishable rather than ranked.
    var isInconclusive: Bool { low <= 0 && high >= 0 }
}

/// Percentile bootstrap over the per-query differences of two variants.
///
/// Deterministic for a given seed, so a reported interval can be reproduced exactly rather than shifting on
/// every run — the same reason the dev/test split is committed instead of derived.
func pairedBootstrap(baseline: [String: Double],
                     candidate: [String: Double],
                     samples: Int = 2_000,
                     seed: UInt64 = 20_260_819) -> BootstrapInterval? {
    // Only queries both variants actually scored. nDCG is nil for unanswerable questions, and a variant that
    // silences a query has no score for it, so the intersection is the honest common ground.
    let shared = Set(baseline.keys).intersection(candidate.keys).sorted()
    guard shared.count >= 2 else { return nil }
    let differences = shared.map { candidate[$0]! - baseline[$0]! }
    let delta = differences.reduce(0, +) / Double(differences.count)

    var rng = SplitMix64(seed: seed)
    var means: [Double] = []
    means.reserveCapacity(samples)
    for _ in 0..<samples {
        var total = 0.0
        for _ in differences.indices {
            total += differences[Int(rng.next() % UInt64(differences.count))]
        }
        means.append(total / Double(differences.count))
    }
    means.sort()
    func percentile(_ fraction: Double) -> Double {
        let index = min(means.count - 1, max(0, Int((Double(means.count - 1) * fraction).rounded())))
        return means[index]
    }
    return BootstrapInterval(delta: delta,
                             low: percentile(0.025),
                             high: percentile(0.975),
                             n: differences.count)
}
