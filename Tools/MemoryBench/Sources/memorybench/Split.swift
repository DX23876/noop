import Foundation

// The development / holdout split, and the reason it exists.
//
// Floor thresholds, recency weight, the kind prior, MMR, quotas, candidate depth, rerank depth, rerank-plus-
// recency, three relative-floor ratios, three embedding models and an untrained truncation have all been
// chosen by looking at scores on ONE corpus. That is roughly a dozen decisions fitted to 110 questions, and
// nothing so far has stopped the architecture from being shaped to this particular benchmark rather than to
// retrieval. A holdout is the only mechanism that catches that.
//
// Two properties matter more than the exact ratio:
//
//  * LEAK-FREE BY CONSTRUCTION. Splitting individual queries would scatter variants of one scenario across
//    both sides — the second ferritin value on dev, the third on test — and a model that had seen the
//    scenario would look like a model that generalised. Measured on this corpus, 48 of 110 queries grade
//    documents from more than one naive topic prefix, so prefix grouping cannot do it either. What does work
//    is the connected components of the query-document graph: two documents are joined when any query grades
//    both, so a whole scenario is indivisible. There are 51 such components here, the largest holding 15% of
//    queries.
//  * COMMITTED, NOT RECOMPUTED. The assignment lives in `Corpus/split.json`. If it were derived at run time,
//    every corpus edit would quietly move the boundary and the holdout would silently become contaminated by
//    everything measured before the move.
struct CorpusSplit: Codable {
    /// Bumped when the assignment is deliberately regenerated, so a stale `split.json` cannot be mistaken for
    /// the current one.
    let version: Int
    let seed: UInt64
    let testFraction: Double
    let devQueryIDs: [String]
    let testQueryIDs: [String]

    static let currentVersion = 1
    static let filename = "split.json"

    var dev: Set<String> { Set(devQueryIDs) }
    var test: Set<String> { Set(testQueryIDs) }

    static func load(directory: URL) throws -> CorpusSplit {
        let data = try Data(contentsOf: directory.appendingPathComponent(filename))
        return try JSONDecoder().decode(CorpusSplit.self, from: data)
    }

    func write(directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.filename))
    }
}

extension Corpus {
    /// Which index the split applies to. The locale sets stay whole: they are a language smoke test, and
    /// halving 24 documents would leave neither side able to say anything at all.
    static let splitIndex = "main"

    /// Groups of queries that must not be separated, as connected components of the query-document graph.
    ///
    /// Returned sorted by size descending and then by key, so packing is deterministic without depending on
    /// dictionary iteration order — which Swift randomises per process and would otherwise make the split
    /// depend on which run produced it.
    func scenarioGroups() -> [(key: String, queryIDs: [String])] {
        let documents = Set(self.documents.filter { $0.index == Corpus.splitIndex }.map(\.id))
        let queries = self.queries.filter { $0.index == Corpus.splitIndex }

        var parent: [String: String] = Dictionary(uniqueKeysWithValues: documents.map { ($0, $0) })
        func find(_ x: String) -> String {
            var root = x
            while parent[root] != root { root = parent[root]! }
            var walk = x                                  // path compression, so deep chains stay cheap
            while parent[walk] != root { let next = parent[walk]!; parent[walk] = root; walk = next }
            return root
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        for query in queries {
            let graded = query.judgments.filter { $0.value > 0 && documents.contains($0.key) }.keys.sorted()
            guard let first = graded.first else { continue }
            for other in graded.dropFirst() { union(first, other) }
        }

        // Queries with no graded document — the `unanswerable` ones — join no component and cannot leak at
        // all: there is no relevant document for a model to have been shown. So each becomes its own group of
        // one and is packed individually.
        //
        // Grouping them together instead was the first attempt, and it put all ten on the dev side, leaving
        // the holdout with zero abstention cases — unable to measure the very behaviour the floor exists for.
        // Indivisibility is a property of shared evidence, and these share none.
        var byComponent: [String: [String]] = [:]
        for query in queries {
            let graded = query.judgments.filter { $0.value > 0 && documents.contains($0.key) }.keys.sorted()
            let key = graded.first.map { find($0) } ?? "«no-graded-evidence»:\(query.id)"
            byComponent[key, default: []].append(query.id)
        }
        return byComponent
            .map { (key: $0.key, queryIDs: $0.value.sorted()) }
            .sorted { $0.queryIDs.count != $1.queryIDs.count
                ? $0.queryIDs.count > $1.queryIDs.count
                : $0.key < $1.key }
    }

    /// Packs whole scenario groups into a dev and a test side, keeping each category's share close to
    /// `testFraction` on both.
    ///
    /// Greedy rather than optimal on purpose: with 51 groups and a largest group of 15% there is no packing
    /// that hits every category exactly, and a solver would trade reviewability for a decimal place. Each
    /// group goes to whichever side is furthest behind on the categories that group actually contains, which
    /// keeps the small categories (`negation`, `terse`) from ending up one-sided.
    func computeSplit(testFraction: Double = 0.35, seed: UInt64 = 20_260_819) -> CorpusSplit {
        let queries = Dictionary(uniqueKeysWithValues:
            self.queries.filter { $0.index == Corpus.splitIndex }.map { ($0.id, $0) })
        var groups = scenarioGroups()

        // A seeded shuffle among equal-sized groups, so the split is not a pure function of size order —
        // otherwise every category's largest scenario would land on the same side by construction.
        var rng = SplitMix64(seed: seed)
        groups = groups
            .map { (order: rng.next(), group: $0) }
            .sorted {
                $0.group.queryIDs.count != $1.group.queryIDs.count
                    ? $0.group.queryIDs.count > $1.group.queryIDs.count
                    : $0.order < $1.order
            }
            .map(\.group)

        var devCategoryCounts: [QueryCategory: Int] = [:]
        var testCategoryCounts: [QueryCategory: Int] = [:]
        var dev: [String] = []
        var test: [String] = []

        for group in groups {
            let categories = group.queryIDs.compactMap { queries[$0]?.category }
            // How far behind its target each side is, counted only over the categories in this group.
            func deficit(_ counts: [QueryCategory: Int], share: Double) -> Double {
                categories.reduce(0.0) { total, category in
                    let assigned = Double(counts[category] ?? 0)
                    let target = Double(self.queries.filter {
                        $0.index == Corpus.splitIndex && $0.category == category
                    }.count) * share
                    return total + (target - assigned)
                }
            }
            let testIsHungrier = deficit(testCategoryCounts, share: testFraction)
                > deficit(devCategoryCounts, share: 1 - testFraction)
            if testIsHungrier {
                test += group.queryIDs
                for category in categories { testCategoryCounts[category, default: 0] += 1 }
            } else {
                dev += group.queryIDs
                for category in categories { devCategoryCounts[category, default: 0] += 1 }
            }
        }

        return CorpusSplit(version: CorpusSplit.currentVersion,
                           seed: seed,
                           testFraction: testFraction,
                           devQueryIDs: dev.sorted(),
                           testQueryIDs: test.sorted())
    }

    /// Everything that would make a split untrustworthy. Hard errors, not warnings: a contaminated holdout is
    /// worse than no holdout, because it looks like evidence.
    func splitProblems(_ split: CorpusSplit) -> [String] {
        var problems: [String] = []
        let queries = Dictionary(uniqueKeysWithValues:
            self.queries.filter { $0.index == Corpus.splitIndex }.map { ($0.id, $0) })

        let assigned = split.dev.union(split.test)
        for id in queries.keys where !assigned.contains(id) {
            problems.append("\(id) is in neither side of the split — regenerate it")
        }
        for id in assigned where queries[id] == nil {
            problems.append("split names \(id), which is not a `\(Corpus.splitIndex)` query any more")
        }
        for id in split.dev.intersection(split.test) {
            problems.append("\(id) is on BOTH sides")
        }

        // The property the whole design rests on: no document may be graded from both sides.
        func gradedDocuments(_ ids: Set<String>) -> Set<String> {
            Set(ids.compactMap { queries[$0] }
                .flatMap { $0.judgments.filter { $0.value > 0 }.keys })
        }
        let shared = gradedDocuments(split.dev).intersection(gradedDocuments(split.test))
        for document in shared.sorted() {
            problems.append("document \(document) is graded relevant on BOTH sides — the split leaks")
        }
        return problems
    }
}

/// A small seeded generator, so the split is reproducible without pulling in a dependency and without
/// `SystemRandomNumberGenerator`, which would make it different on every run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
