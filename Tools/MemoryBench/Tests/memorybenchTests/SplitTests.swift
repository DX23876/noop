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

    /// Recomputing must reproduce the committed assignment. If it did not, every corpus edit would quietly
    /// move the boundary, and the holdout would be contaminated by everything measured before the move —
    /// silently, because the numbers themselves would not change shape.
    func testRecomputingWithTheCommittedSeedReproducesTheCommittedSplit() throws {
        let (corpus, split) = try loaded()
        let recomputed = corpus.computeSplit(testFraction: split.testFraction, seed: split.seed)
        XCTAssertEqual(recomputed.devQueryIDs, split.devQueryIDs)
        XCTAssertEqual(recomputed.testQueryIDs, split.testQueryIDs)
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
        // Two queries sharing a graded document must share a group.
        let main = corpus.queries.filter { $0.index == Corpus.splitIndex }
        for a in main {
            for b in main where a.id < b.id {
                let sharedEvidence = Set(a.judgments.filter { $0.value > 0 }.keys)
                    .intersection(b.judgments.filter { $0.value > 0 }.keys)
                if !sharedEvidence.isEmpty {
                    XCTAssertEqual(groupOfQuery[a.id], groupOfQuery[b.id],
                                   "\(a.id) and \(b.id) share evidence but sit in different groups")
                }
            }
        }
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
        let main = corpus.queries.filter { $0.index == Corpus.splitIndex }
        // Find a document graded by two queries, then force those queries onto opposite sides.
        var byDocument: [String: [String]] = [:]
        for query in main {
            for (document, grade) in query.judgments where grade > 0 {
                byDocument[document, default: []].append(query.id)
            }
        }
        guard let shared = byDocument.first(where: { $0.value.count >= 2 }) else {
            return XCTFail("corpus has no co-graded document to build a leak from")
        }
        let leaking = CorpusSplit(version: split.version,
                                  seed: split.seed,
                                  testFraction: split.testFraction,
                                  devQueryIDs: main.map(\.id).filter { $0 != shared.value[1] },
                                  testQueryIDs: [shared.value[1]])
        XCTAssertTrue(corpus.splitProblems(leaking).contains { $0.contains("leaks") },
                      "a document graded from both sides must be reported")
    }
}
