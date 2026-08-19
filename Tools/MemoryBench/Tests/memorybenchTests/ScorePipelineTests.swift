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

    func testTheWholeLadderRunsAndEveryVariantIsScored() async throws {
        let reports = try await ladder(floors: [0.30])
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
        let today = try XCTUnwrap(reports.first { $0.name == SelectionConfig.today.name })
        // Essentially a full context rather than exactly eight lines: with the candidate set restricted to the
        // query's own language, a few `irrelevant` queries simply have fewer than eight documents in their
        // language to pad with. The point stands — the pipeline fills every slot it can for a question nothing
        // answers, because it has no notion of "nothing here is relevant".
        XCTAssertGreaterThan(today.irrelevantLines, Double(contextSlots) - 0.5,
                             "today's pipeline pads a question with no answer up to a full context")

        let floored = try XCTUnwrap(reports.first { $0.name.contains("floor") })
        XCTAssertLessThan(floored.irrelevantLines, today.irrelevantLines)
    }

    /// P3: one thread flooding the context. The corpus has a five-message sleep thread per language, and the
    /// quota variant must hold a smaller share of the eight lines than the unquotaed one.
    func testQuotasReduceHowMuchOneThreadCanOwn() async throws {
        let reports = try await ladder(floors: [0.30])
        let beforeQuotas = try XCTUnwrap(reports.first { $0.name == "+floor" }?.dominance?.value)
        let afterQuotas = try XCTUnwrap(reports.first { $0.name == "+quotas" }?.dominance?.value)
        XCTAssertLessThanOrEqual(afterQuotas, beforeQuotas)
    }

    /// The instrument has to be able to answer "is there a usable floor at all?", including when the answer is
    /// no. For these synthetic vectors it IS no — an exact-overlap-only representation scores a keyword-rich
    /// off-topic question above a paraphrase of the right document — and the run must still complete and
    /// report that rather than silently picking a threshold.
    func testAFloorThatSuitsNothingStillProducesAReport() async throws {
        let reports = try await ladder(floors: [0.99])
        let extreme = try XCTUnwrap(reports.first { $0.name == "+MMR (= proposed)" })
        XCTAssertEqual(extreme.irrelevantLines, 0, accuracy: 0.001)
        XCTAssertNil(extreme.precision, "with everything floored out there is nothing to be precise about")
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
