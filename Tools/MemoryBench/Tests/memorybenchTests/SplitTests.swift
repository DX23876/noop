import XCTest

@testable import memorybench

/// The properties a development / holdout split has to have to be worth anything. Every one of these is a
/// property the committed `Corpus/split.json` must satisfy, not a property of some synthetic fixture — a split
/// that is leak-free in theory and contaminated in the repository would be worse than none, because it looks
/// like evidence.
final class SplitTests: XCTestCase {

    private var corpusDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Corpus")
    }

    private func loaded() throws -> (Corpus, CorpusSplit) {
        (try Corpus.load(directory: corpusDirectory), try CorpusSplit.load(directory: corpusDirectory))
    }

    // MARK: - The committed split

    /// The single property the design rests on: no document may be graded relevant from both sides. If one is,
    /// a model that memorised that scenario on dev scores on test as though it had generalised.
    func testTheCommittedSplitDoesNotLeak() throws {
        let (corpus, split) = try loaded()
        XCTAssertEqual(corpus.splitProblems(split), [],
                       "the committed split must satisfy its own checks")
    }

    func testTheCommittedSplitCoversEveryMainQueryExactlyOnce() throws {
        let (corpus, split) = try loaded()
        let main = Set(corpus.queries.filter { $0.index == Corpus.splitIndex }.map(\.id))
        XCTAssertEqual(split.dev.union(split.test), main)
        XCTAssertTrue(split.dev.isDisjoint(with: split.test))
    }

    /// Both halves need every category, or the holdout cannot confirm the thing dev chose. The first attempt
    /// failed exactly here: grouping all `unanswerable` queries into one indivisible block put all ten on dev
    /// and left the holdout unable to measure abstention at all — the very behaviour the floor exists for.
    func testBothSidesCarryEveryCategory() throws {
        let (corpus, split) = try loaded()
        let main = corpus.queries.filter { $0.index == Corpus.splitIndex }
        for category in QueryCategory.allCases {
            let dev = main.filter { split.dev.contains($0.id) && $0.category == category }
            let test = main.filter { split.test.contains($0.id) && $0.category == category }
            XCTAssertFalse(dev.isEmpty, "dev has no \(category.rawValue) queries")
            XCTAssertFalse(test.isEmpty, "the holdout has no \(category.rawValue) queries")
        }
    }

    /// A holdout that holds almost nothing cannot confirm anything, and one that holds almost everything
    /// starves the tuning half. Wide bounds on purpose: whole scenarios move together, so the ratio cannot be
    /// hit exactly and should not be asserted as though it could.
    func testTheHoldoutIsAMeaningfulFractionWithoutStarvingDev() throws {
        let (corpus, split) = try loaded()
        let total = corpus.queries.filter { $0.index == Corpus.splitIndex }.count
        let fraction = Double(split.test.count) / Double(total)
        XCTAssertGreaterThan(fraction, 0.25)
        XCTAssertLessThan(fraction, 0.45)
    }

    // MARK: - The generator

    /// The committed split is deliberately NOT the from-scratch computation any more, and this test records why
    /// the assertion was inverted rather than deleted.
    ///
    /// It used to demand that `computeSplit` reproduce `split.json`, which was the right guard while the split
    /// was generated once: it caught a hand-edited file and a corpus edit that moved the boundary. But the
    /// corpus grows, and recomputing on a grown corpus repacks everything — spending holdout queries that were
    /// kept honest and pulling tuned-on queries into the holdout. Growth therefore extends the assignment
    /// instead, which by construction makes the committed file diverge from a fresh computation.
    ///
    /// What still has to hold is the property the old test was really protecting: the committed assignment must
    /// be exactly what the maintenance path produces from it. That is idempotence of `extendedSplit`, asserted
    /// here and again in `testExtendingAnUnchangedCorpusReproducesTheCommittedSplitExactly` from the growth
    /// side. A hand-edited split.json still fails, which was the point.
    func testTheCommittedSplitIsAFixedPointOfTheMaintenancePath() throws {
        let (corpus, split) = try loaded()
        let extended = try corpus.extendedSplit(from: split)
        XCTAssertEqual(extended.devQueryIDs, split.devQueryIDs)
        XCTAssertEqual(extended.testQueryIDs, split.testQueryIDs)

        // The companion check is against the audit log, not against the generator.
        //
        // A first version asserted that the committed split must DIFFER from a fresh computation, on the theory
        // that equality would reveal an accidental regeneration. That assertion is nearly vacuous: any corpus
        // edit that touches categories re-steers the packing, so the two drift apart on their own and the test
        // passes for a reason unrelated to what it claims. It was passing that way when written.
        //
        // What actually matters is that a regeneration left a trace. `memorybench split --regenerate --write`
        // refuses without a reason and appends a REGENERATED line, so if the committed file does match a fresh
        // computation, the log has to show why.
        let recomputed = corpus.computeSplit(testFraction: split.testFraction, seed: split.seed)
        if recomputed.testQueryIDs == split.testQueryIDs {
            let log = try String(contentsOf: corpusDirectory.appendingPathComponent("holdout-access.log"),
                                encoding: .utf8)
            XCTAssertTrue(log.contains("REGENERATED"),
                          "the committed split matches a fresh computation, but no regeneration is recorded — "
                          + "the freeze was thrown away silently")
        }
    }

    /// Determinism within one seed, across processes. Swift randomises dictionary iteration order per process,
    /// so a split derived from an unsorted traversal would differ between runs on identical input.
    func testTheGeneratorIsDeterministicForAGivenSeed() throws {
        let (corpus, _) = try loaded()
        let a = corpus.computeSplit(testFraction: 0.35, seed: 4242)
        let b = corpus.computeSplit(testFraction: 0.35, seed: 4242)
        XCTAssertEqual(a.testQueryIDs, b.testQueryIDs)
    }

    /// And a different seed must actually produce a different partition, or the seed is decorative and the
    /// packing is a pure function of size order — which would put every category's largest scenario on the
    /// same side by construction.
    func testADifferentSeedProducesADifferentPartition() throws {
        let (corpus, _) = try loaded()
        let a = corpus.computeSplit(testFraction: 0.35, seed: 1)
        let b = corpus.computeSplit(testFraction: 0.35, seed: 999_983)
        XCTAssertNotEqual(a.testQueryIDs, b.testQueryIDs)
    }

    /// Every seed must still yield a leak-free split, not just the one that happens to be committed.
    func testEverySeedYieldsALeakFreeSplit() throws {
        let (corpus, _) = try loaded()
        for seed in [UInt64(1), 7, 12_345, 20_260_819, 999_983] {
            let split = corpus.computeSplit(testFraction: 0.35, seed: seed)
            XCTAssertEqual(corpus.splitProblems(split), [], "seed \(seed) produced a leaking split")
        }
    }

    // MARK: - Scenario grouping

    /// Grouping is what makes the split leak-free, so it has to be indivisible by construction: any two
    /// documents graded by one query must land in one group.
    func testScenarioGroupsKeepCoGradedDocumentsTogether() throws {
        let (corpus, _) = try loaded()
        let groups = corpus.scenarioGroups()
        var groupOfQuery: [String: String] = [:]
        for group in groups {
            for id in group.queryIDs { groupOfQuery[id] = group.key }
        }
        // Two queries sharing an ANSWER (grade ≥ the scenario floor) must share a group. This used to read
        // `> 0`, and the corpus outgrew it: with realistic cross-theme questions, grade-1 support wires 73% of
        // all queries into one component and no holdout can exist. See `Corpus.scenarioGradeFloor`.
        let main = corpus.queries.filter { $0.index == Corpus.splitIndex }
        var sawGradeOneOnlySharing = false
        for a in main {
            for b in main where a.id < b.id {
                let strong = Set(a.judgments.filter { $0.value >= Corpus.scenarioGradeFloor }.keys)
                    .intersection(b.judgments.filter { $0.value >= Corpus.scenarioGradeFloor }.keys)
                if !strong.isEmpty {
                    XCTAssertEqual(groupOfQuery[a.id], groupOfQuery[b.id],
                                   "\(a.id) and \(b.id) share an answer but sit in different groups")
                    continue
                }
                let anyShared = Set(a.judgments.filter { $0.value > 0 }.keys)
                    .intersection(b.judgments.filter { $0.value > 0 }.keys)
                if !anyShared.isEmpty, groupOfQuery[a.id] != groupOfQuery[b.id] {
                    sawGradeOneOnlySharing = true
                }
            }
        }
        // And the weakening is asserted rather than merely tolerated: grade-1-only sharing across groups has to
        // actually occur, or the floor is doing nothing and the stricter definition should be restored.
        XCTAssertTrue(sawGradeOneOnlySharing,
                      "no pair shares only grade-1 support across groups — the grade floor buys nothing here, "
                      + "so it should go back to 1")
    }

    func testEveryMainQueryLandsInExactlyOneGroup() throws {
        let (corpus, _) = try loaded()
        let groups = corpus.scenarioGroups()
        let all = groups.flatMap(\.queryIDs)
        XCTAssertEqual(Set(all).count, all.count, "a query appears in two groups")
        XCTAssertEqual(Set(all), Set(corpus.queries.filter { $0.index == Corpus.splitIndex }.map(\.id)))
    }

    /// A deliberately constructed leak has to be caught, or the check is decorative. Built by hand rather than
    /// by mutating the real corpus, so the assertion is about the detector and not about today's data.
    func testSplitProblemsDetectsAHandBuiltLeak() throws {
        let (corpus, split) = try loaded()
        // Built from a document two queries grade at or above the scenario floor, chosen deterministically.
        //
        // This test was flaky, and the flake was a real signal rather than noise. It used to pick any document
        // with two positive judgments via `Dictionary.first(where:)` — whose order Swift randomises per process
        // — and since the leak check now only fires at grade ≥2, a run that happened to pick a grade-1 document
        // saw no leak reported and failed. Both halves of that are fixed here: the choice is sorted, and the
        // grade is the one the check actually enforces.
        guard let shared = coGradedDocument(in: corpus, atLeast: Corpus.scenarioGradeFloor) else {
            return XCTFail("corpus has no co-graded document to build a leak from")
        }
        let main = corpus.queries.filter { $0.index == Corpus.splitIndex }
        let leaking = CorpusSplit(version: split.version,
                                  seed: split.seed,
                                  testFraction: split.testFraction,
                                  devQueryIDs: main.map(\.id).filter { $0 != shared.queries[1] },
                                  testQueryIDs: [shared.queries[1]])
        XCTAssertTrue(corpus.splitProblems(leaking).contains { $0.contains("leaks") },
                      "a document graded as an answer on both sides must be reported")
    }

    /// The other half of the same rule, and the one that makes the weakening explicit: a document that only
    /// SUPPORTS on both sides is not a leak. That is deliberate — forbidding it makes the corpus unsplittable —
    /// and without this assertion the design could tighten back by accident and nothing would notice until the
    /// split failed to generate.
    func testADocumentThatOnlySupportsOnBothSidesIsNotReportedAsALeak() throws {
        let (corpus, split) = try loaded()
        let main = corpus.queries.filter { $0.index == Corpus.splitIndex }.sorted { $0.id < $1.id }

        // A pair that shares grade-1 support and NO answer. Isolating the pair is the point: a first attempt put
        // every other query on the dev side, and that one test query shared its own answers with a dozen dev
        // queries, so real leaks were reported and the assertion failed for a reason unrelated to what it claims.
        func strong(_ query: CorpusQuery) -> Set<String> {
            Set(query.judgments.filter { $0.value >= Corpus.scenarioGradeFloor }.keys)
        }
        func supporting(_ query: CorpusQuery) -> Set<String> {
            Set(query.judgments.filter { $0.value == 1 }.keys)
        }
        var pair: (CorpusQuery, CorpusQuery)?
        outer: for a in main {
            for b in main where a.id < b.id {
                if !supporting(a).intersection(supporting(b)).isEmpty,
                   strong(a).intersection(strong(b)).isEmpty {
                    pair = (a, b)
                    break outer
                }
            }
        }
        guard let (a, b) = pair else {
            throw XCTSkip("no two queries share only grade-1 support")
        }

        let sharing = CorpusSplit(version: split.version,
                                  seed: split.seed,
                                  testFraction: split.testFraction,
                                  devQueryIDs: [a.id],
                                  testQueryIDs: [b.id])
        let problems = corpus.splitProblems(sharing)
        XCTAssertFalse(problems.contains { $0.contains("leaks") },
                       "grade-1 support on both sides is allowed by design — see Corpus.scenarioGradeFloor: "
                       + "\(problems.filter { $0.contains("leaks") })")
        // Every other query is unassigned in this hand-built split, which `splitProblems` rightly complains
        // about. Asserting that keeps the test honest about what it did rather than reading as a clean split.
        XCTAssertTrue(problems.contains { $0.contains("neither side") })
    }

    /// Deterministic by construction: sorted at every step, because dictionary order is per-process random and a
    /// test that depends on it fails one run in four.
    private func coGradedDocument(in corpus: Corpus,
                                  atLeast minimum: Int,
                                  atMost maximum: Int = 3) -> (document: String, queries: [String])? {
        var byDocument: [String: [String]] = [:]
        for query in corpus.queries.filter({ $0.index == Corpus.splitIndex }) {
            for (document, grade) in query.judgments where grade >= minimum && grade <= maximum {
                byDocument[document, default: []].append(query.id)
            }
        }
        return byDocument
            .filter { $0.value.count >= 2 }
            .map { (document: $0.key, queries: $0.value.sorted()) }
            .sorted { $0.document < $1.document }
            .first
    }

    // MARK: - Growing the corpus

    /// Helper: a probe query built by decoding, because `CorpusQuery.index` is derived from a private field.
    private func probe(id: String,
                       category: String = "paraphrase",
                       judgments: [String: Int]) throws -> CorpusQuery {
        struct ProbeFile: Decodable { let queries: [CorpusQuery] }
        let body = judgments.map { "\"\($0.key)\": \($0.value)" }.sorted().joined(separator: ", ")
        let json = "{\"queries\": [{\"id\": \"\(id)\", \"index\": \"main\", \"lang\": \"de\", "
            + "\"category\": \"\(category)\", \"text\": \"probe \(id)\", \"judgments\": {\(body)}}]}"
        return try JSONDecoder().decode(ProbeFile.self, from: Data(json.utf8)).queries[0]
    }

    /// A graded document belonging to exactly one side, used to aim a probe query at that side's scenario.
    private func gradedDocument(on side: Set<String>, in corpus: Corpus, split: CorpusSplit) throws -> String {
        let queries = Dictionary(uniqueKeysWithValues: corpus.queries.map { ($0.id, $0) })
        func graded(_ ids: Set<String>) -> Set<String> {
            Set(ids.compactMap { queries[$0] }.flatMap { $0.judgments.filter { $0.value > 0 }.keys })
        }
        let other = side == split.dev ? split.test : split.dev
        return try XCTUnwrap(graded(side).subtracting(graded(other)).sorted().first)
    }

    /// The property that makes growth safe: adding nothing changes nothing. If extension could reshuffle even
    /// one query, the freeze would expire every time the corpus was touched.
    func testExtendingAnUnchangedCorpusReproducesTheCommittedSplitExactly() throws {
        let (corpus, committed) = try loaded()
        let extended = try corpus.extendedSplit(from: committed)
        XCTAssertEqual(extended.devQueryIDs, committed.devQueryIDs)
        XCTAssertEqual(extended.testQueryIDs, committed.testQueryIDs)
    }

    /// A new query that stays inside one existing scenario inherits that scenario's side — including when that
    /// side is the holdout, which is the case that would otherwise silently hand tuning material a free pass.
    func testANewQueryInsideAnExistingScenarioInheritsItsSide() throws {
        let (corpus, committed) = try loaded()

        for side in [committed.dev, committed.test] {
            let document = try gradedDocument(on: side, in: corpus, split: committed)
            let fresh = try probe(id: "probe-inherit", judgments: [document: 3])
            let grown = Corpus(documents: corpus.documents, queries: corpus.queries + [fresh])
            let extended = try grown.extendedSplit(from: committed)
            if side == committed.dev {
                XCTAssertTrue(extended.dev.contains("probe-inherit"))
            } else {
                XCTAssertTrue(extended.test.contains("probe-inherit"),
                              "a query about held-out evidence must not land in the tuning half")
            }
            XCTAssertTrue(grown.splitProblems(extended).isEmpty)
        }
    }

    /// The failure the mechanism exists for, and the reason it is an error rather than a heuristic: a new query
    /// grading evidence from both halves merges two scenarios that were separated on purpose. There is no
    /// correct side for the result, so the corpus has to change — and the message has to say which query.
    func testANewQueryBridgingBothHalvesIsARejectedRatherThanResolved() throws {
        let (corpus, committed) = try loaded()
        let devDocument = try gradedDocument(on: committed.dev, in: corpus, split: committed)
        let testDocument = try gradedDocument(on: committed.test, in: corpus, split: committed)

        let bridge = try probe(id: "probe-bridge", judgments: [devDocument: 3, testDocument: 2])
        let grown = Corpus(documents: corpus.documents, queries: corpus.queries + [bridge])
        do {
            _ = try grown.extendedSplit(from: committed)
            XCTFail("a bridging query was accepted, which silently thaws the holdout")
        } catch let CorpusError.invalid(problems) {
            XCTAssertTrue(problems.contains { $0.contains("probe-bridge") },
                          "the report has to name the query to regrade: \(problems)")
            XCTAssertTrue(problems.contains { $0.contains("spans both sides") })
        }
    }

    /// A brand-new scenario, connected to nothing, is free to place — and gets placed rather than dropped.
    func testAnIndependentNewScenarioIsAssignedToOneSide() throws {
        let (corpus, committed) = try loaded()
        // An unanswerable query shares no evidence with anything, which is exactly an independent scenario.
        let fresh = try probe(id: "probe-fresh", category: "unanswerable", judgments: [:])
        let grown = Corpus(documents: corpus.documents, queries: corpus.queries + [fresh])
        let extended = try grown.extendedSplit(from: committed)
        XCTAssertEqual(extended.dev.contains("probe-fresh") || extended.test.contains("probe-fresh"), true)
        XCTAssertFalse(extended.dev.contains("probe-fresh") && extended.test.contains("probe-fresh"))
        XCTAssertTrue(grown.splitProblems(extended).isEmpty)
    }
}
