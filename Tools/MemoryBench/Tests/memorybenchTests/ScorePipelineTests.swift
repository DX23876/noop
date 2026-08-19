import SemanticMemory
import XCTest

@testable import memorybench

/// Runs the whole scoring path — real `SemanticIndexStore`, real Float16 encoding, real cosine scan, every
/// selection variant, every metric — over the committed corpus, using synthetic vectors so no model and no
/// device is needed. This is what keeps `score` from rotting between the rare occasions someone has a GGUF
/// and a Mac to hand.
final class ScorePipelineTests: XCTestCase {

    private var corpus: Corpus {
        get throws {
            try Corpus.load(directory: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Corpus"))
        }
    }

    /// A full ladder run over 242 queries costs a few seconds — mostly the cosine scan and the MMR loop, which
    /// is the same cost shape the app pays on device. The inputs are deterministic, so the result is cached per
    /// floor list rather than recomputed for each assertion.
    private static var cache: [String: [VariantReport]] = [:]

    private func ladder(floors: [Double]) async throws -> [VariantReport] {
        let key = floors.map { String($0) }.joined(separator: ",")
        if let cached = Self.cache[key] { return cached }
        let corpus = try corpus
        let reports = try await runScore(corpus: corpus,
                                        vectors: SyntheticVectors.build(for: corpus),
                                        floors: floors,
                                        quiet: true)
        Self.cache[key] = reports
        return reports
    }

    /// Reports are per scope now, so the assertions below look at the headline scope unless they say otherwise.
    private func main(_ reports: [VariantReport]) -> [VariantReport] { reports.filter { $0.scope == .main } }

    func testTheWholeLadderRunsAndEveryVariantIsScored() async throws {
        let reports = main(try await ladder(floors: [0.30]))
        // Every ladder step must appear by name, and so must the oracle ceilings. A bare count would pass
        // just as happily if a variant vanished and a ceiling took its place.
        for config in SelectionConfig.ladder(floor: 0.30) {
            XCTAssertTrue(reports.contains { $0.name == config.name }, "\(config.name) is missing")
        }
        XCTAssertEqual(reports.filter { $0.name.hasPrefix("ORACLE") }.count, 4,
                       "two candidate depths, padded and unpadded")
        for report in reports {
            XCTAssertNotNil(report.ndcg, "\(report.name) scored no query at all")
            // Every variant must cover the SAME set of scoreable queries. A variant that improves its mean
            // by scoring fewer questions has not improved anything, and this is where that would show.
            XCTAssertEqual(report.ndcg?.count, reports[0].ndcg?.count, "\(report.name) changed the denominator")
        }
    }

    /// P1, demonstrated rather than asserted in prose: with no floor the eight slots are filled even for a
    /// question nothing in the corpus answers.
    func testWithoutAFloorIrrelevantQuestionsStillGetAFullContext() async throws {
        let reports = try await ladder(floors: [0.30])
        let today = try XCTUnwrap(main(reports).first { $0.name == SelectionConfig.today.name })
        // Essentially a full context rather than exactly eight lines: with the candidate set restricted to the
        // query's own language, a few `irrelevant` queries simply have fewer than eight documents in their
        // language to pad with. The point stands — the pipeline fills every slot it can for a question nothing
        // answers, because it has no notion of "nothing here is relevant".
        XCTAssertGreaterThan(today.irrelevantLines, Double(contextSlots) - 0.5,
                             "today's pipeline pads a question with no answer up to a full context")

        let floored = try XCTUnwrap(main(reports).first { $0.name.contains("floor") })
        XCTAssertLessThan(floored.irrelevantLines, today.irrelevantLines)
    }

    /// P3: one thread flooding the context. The corpus has a five-message sleep thread per language, and the
    /// quota variant must hold a smaller share of the eight lines than the unquotaed one.
    func testQuotasReduceHowMuchOneThreadCanOwn() async throws {
        let reports = try await ladder(floors: [0.30])
        let beforeQuotas = try XCTUnwrap(main(reports).first { $0.name == "+floor" }?.dominance?.value)
        let afterQuotas = try XCTUnwrap(main(reports).first { $0.name == "+quotas" }?.dominance?.value)
        XCTAssertLessThanOrEqual(afterQuotas, beforeQuotas)
    }

    /// The instrument has to be able to answer "is there a usable floor at all?", including when the answer is
    /// no. For these synthetic vectors it IS no — an exact-overlap-only representation scores a keyword-rich
    /// off-topic question above a paraphrase of the right document — and the run must still complete and
    /// report that rather than silently picking a threshold.
    func testAFloorThatSuitsNothingStillProducesAReport() async throws {
        let reports = try await ladder(floors: [0.99])
        let extreme = try XCTUnwrap(main(reports).first { $0.name == "+MMR (= proposed)" })
        XCTAssertEqual(extreme.irrelevantLines, 0, accuracy: 0.001)
        XCTAssertNil(extreme.precision, "with everything floored out there is nothing to be precise about")
    }

    /// The regression guard for the error this scope split exists to fix.
    ///
    /// Every published figure was once a mean over all 320 answerable queries, of which only 110 sit on the
    /// 272-document index and 210 on the ten 24-document locale sets — so two thirds of each headline came
    /// from a problem too easy to separate anything, and the numbers ran about 0.06 optimistic. This asserts
    /// the shape that makes that impossible to do accidentally again: every variant reports all three scopes,
    /// the two real ones genuinely disagree on this corpus, and the pooled figure sits between them rather
    /// than standing alone.
    func testEveryVariantReportsEachScopeAndPoolingIsVisiblyDifferent() async throws {
        let reports = try await ladder(floors: [0.30])
        let names = Set(reports.map(\.name))
        for name in names {
            let scopes = Set(reports.filter { $0.name == name }.map(\.scope))
            XCTAssertEqual(scopes, [.main, .locales, .all], "\(name) is missing a scope")
        }
        // The two real scopes must differ, or the corpus has lost the difficulty gap that makes `main`
        // the place ranking is decided — and the pooled mean must lie between them, which is exactly why
        // quoting it as a result was misleading.
        let baseline = SelectionConfig.semanticOnly.name
        let onMain = try XCTUnwrap(reports.first { $0.name == baseline && $0.scope == .main }?.ndcg?.value)
        let onLocales = try XCTUnwrap(reports.first { $0.name == baseline && $0.scope == .locales }?.ndcg?.value)
        let pooled = try XCTUnwrap(reports.first { $0.name == baseline && $0.scope == .all }?.ndcg?.value)
        XCTAssertNotEqual(onMain, onLocales, accuracy: 0.001,
                          "main and the locale sets should not score alike; the difficulty gap is the point")
        XCTAssertTrue((min(onMain, onLocales)...max(onMain, onLocales)).contains(pooled),
                      "a pooled mean has to sit between its parts — \(pooled) is outside")
    }

    /// The scoped counts have to add up, or a query is being dropped or double-counted somewhere.
    func testScopedQueryCountsPartitionTheCorpus() async throws {
        let reports = try await ladder(floors: [0.30])
        let baseline = SelectionConfig.semanticOnly.name
        func count(_ scope: ReportScope) throws -> Int {
            try XCTUnwrap(reports.first { $0.name == baseline && $0.scope == scope }?.ndcg?.count)
        }
        let onMain = try count(.main)
        let onLocales = try count(.locales)
        XCTAssertEqual(onMain + onLocales, try count(.all))
    }

    /// Synthetic vectors must be deterministic, or no two runs of the ladder are comparable.
    func testSyntheticVectorsAreReproducible() throws {
        let corpus = try corpus
        let first = SyntheticVectors.build(for: corpus)
        let second = SyntheticVectors.build(for: corpus)
        XCTAssertEqual(first.meta.documentIDs, second.meta.documentIDs)
        for id in first.meta.documentIDs {
            XCTAssertEqual(first.documents[id], second.documents[id])
        }
    }

    /// Every chunk of every corpus document must get a vector, or `runScore` throws instead of quietly
    /// scoring a smaller index than the corpus describes.
    func testAMissingVectorIsAnErrorNotASilentlySmallerIndex() async throws {
        let corpus = try corpus
        var vectors = SyntheticVectors.build(for: corpus)
        let dropped = try XCTUnwrap(vectors.meta.documentIDs.first)
        var documents = vectors.documents
        documents.removeValue(forKey: dropped)
        vectors = VectorSet(meta: vectors.meta, documents: documents, queries: vectors.queries)
        do {
            _ = try await runScore(corpus: corpus, vectors: vectors, floors: [0.3], quiet: true)
            XCTFail("a missing vector must fail the run")
        } catch {
            // Expected.
        }
    }
}

/// The rule behind section A: a holdout query may never contribute to the distribution a floor is chosen from.
///
/// Separate from the pipeline tests above because the calibration samples are only ever printed, so nothing else
/// can assert this. The failure it guards against does not look like a failure — it looks like a slightly
/// different threshold, which is how the pooled version survived as long as it did.
final class CalibrationScopeTests: XCTestCase {

    private var corpusDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Corpus")
    }

    func testHoldoutQueriesNeverLandInTheDevCalibration() throws {
        let corpus = try Corpus.load(directory: corpusDirectory)
        let split = try CorpusSplit.load(directory: corpusDirectory)
        var counts: [ReportScope: Int] = [:]
        for query in corpus.queries {
            let scope = calibrationScope(for: query, split: split)
            counts[scope, default: 0] += 1
            if split.test.contains(query.id) {
                XCTAssertEqual(scope, .test, "\(query.id) is frozen but calibrates as \(scope.rawValue)")
            }
        }
        XCTAssertEqual(counts[.dev], split.dev.count)
        XCTAssertEqual(counts[.test], split.test.count)
        XCTAssertEqual(counts[.locales], corpus.queries.count - split.dev.count - split.test.count)
    }

    /// The locale sets are a different problem, not a smaller one, so their cosines must not be mixed into the
    /// basis either — that half of the pooling error had nothing to do with the freeze.
    func testLocaleQueriesAreTheirOwnBasisEvenThoughTheyAreNotFrozen() throws {
        let corpus = try Corpus.load(directory: corpusDirectory)
        let split = try CorpusSplit.load(directory: corpusDirectory)
        for query in corpus.queries where query.index != Corpus.splitIndex {
            XCTAssertEqual(calibrationScope(for: query, split: split), .locales)
        }
    }

    /// No split loaded means no freeze to protect, so everything on `main` is dev. Treating it as holdout
    /// instead would suppress the one row the section exists to print.
    func testWithoutASplitEveryMainQueryCalibratesAsDev() throws {
        let corpus = try Corpus.load(directory: corpusDirectory)
        for query in corpus.queries where query.index == Corpus.splitIndex {
            XCTAssertEqual(calibrationScope(for: query, split: nil), .dev)
        }
    }
}

/// The partial-rebuild mode, which needs its own tests for a specific reason: it deliberately skips writing
/// vectors, and the guard it steps around (`a missing vector is an error, not a silently smaller index`) is one
/// this tool relies on everywhere else. If the mode leaked into the ordinary path, every number in every table
/// would quietly be measured against a smaller index than it claims.
final class RebuildFractionTests: XCTestCase {

    private var corpusDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Corpus")
    }

    private func run(_ fraction: Double?) async throws -> VariantReport {
        let corpus = try Corpus.load(directory: corpusDirectory)
        // The committed split is passed because `.dev` only exists as a scope when there is one — without it
        // the report is scoped `.main`, and the first version of this test unwrapped a row that never existed.
        let split = try CorpusSplit.load(directory: corpusDirectory)
        let reports = try await runScore(corpus: corpus,
                                        vectors: SyntheticVectors.build(for: corpus),
                                        floors: [0.35],
                                        quiet: true,
                                        split: split,
                                        rebuiltFraction: fraction)
        return try XCTUnwrap(reports.first { $0.scope == .dev && $0.name == "today (+rescue)" })
    }

    /// A fully rebuilt index must be indistinguishable from no flag at all. Without this the degradation curve
    /// could be measuring a side effect of the mode rather than the missing vectors — and its 100% row is the
    /// reference every other row is read against.
    func testAFullyRebuiltIndexMatchesTheOrdinaryPathExactly() async throws {
        let complete = try await run(1.0)
        let ordinary = try await run(nil)
        XCTAssertEqual(complete.ndcg?.value ?? .nan, ordinary.ndcg?.value ?? .nan, accuracy: 1e-12)
        XCTAssertEqual(complete.ndcg?.count, ordinary.ndcg?.count)
        XCTAssertEqual(complete.recall8?.value ?? .nan, ordinary.recall8?.value ?? .nan, accuracy: 1e-12)
        XCTAssertEqual(complete.meanEmitted ?? .nan, ordinary.meanEmitted ?? .nan, accuracy: 1e-12)
    }

    /// The negative control: a partial index must actually rank worse. A mode that silently stored everything
    /// would pass the test above and print a flat curve, which reads as "migrations are free".
    ///
    /// Only nDCG is asserted, and the reason is worth recording. A first version also required `recall8` to fall,
    /// and it did not: on SYNTHETIC vectors a quarter-sized index scored 0.407 against the full index's 0.348,
    /// because hashed token bags retrieve so poorly that deleting three quarters of the distractors helps more
    /// than losing three quarters of the answers hurts. With real vectors the curve is monotone in both
    /// (R@8 0.489 / 0.592 / 0.650 / 0.748). So recall falling is an empirical result about real embeddings, not
    /// an invariant of the mode, and asserting it here would pin the synthetic embedder's incompetence.
    func testAPartialIndexRanksMeasurablyWorse() async throws {
        let quarter = try await run(0.25)
        let complete = try await run(nil)
        XCTAssertLessThan(quarter.ndcg?.value ?? 1, complete.ndcg?.value ?? 0)
    }

    /// Reproducible from the seed, so a curve can be compared across runs rather than re-rolled each time.
    func testTheSameFractionSelectsTheSameChunksTwice() async throws {
        let first = try await run(0.5)
        let second = try await run(0.5)
        XCTAssertEqual(first.ndcg?.value ?? .nan, second.ndcg?.value ?? .nan, accuracy: 1e-12)
    }
}
