import SemanticMemory
import XCTest

@testable import memorybench

/// What the two mirrors of app-target logic must keep true. They exist because `CoachMemory.tokens` and
/// `CoachSemanticMemory.chunks` live in the `Strand` target and cannot be reached from this executable; these
/// tests are what contains the drift risk that comes with that.
final class MirrorTests: XCTestCase {

    // MARK: - Tokeniser

    func testShortRunsAreDroppedJustLikeTheShippedTokeniser() {
        XCTAssertTrue(MirroredTokeniser.tokens("my hr was 42").contains("was") == false)
        XCTAssertFalse(MirroredTokeniser.tokens("hr 42").contains("42"))
        XCTAssertTrue(MirroredTokeniser.tokens("ferritin").contains("ferritin"))
    }

    func testFunctionWordsAreRemovedForTheLanguagesTheListCovers() {
        // The same seven probes `CoachMemoryRankingTests.testStopwordsCoverTheShippedLanguages` uses.
        for word in ["the", "und", "que", "les", "che", "com", "как"] {
            XCTAssertTrue(MirroredTokeniser.tokens(word).isEmpty,
                          "'\(word)' is a function word and must not survive tokenisation")
        }
    }

    func testIdeographicTextBecomesOverlappingBigrams() {
        let tokens = MirroredTokeniser.tokens("睡眠质量")
        XCTAssertEqual(tokens, ["睡眠", "眠质", "质量"])
    }

    func testASingleIdeographIsKeptWhole() {
        XCTAssertEqual(MirroredTokeniser.tokens("痛"), ["痛"])
    }

    func testMixedScriptYieldsBothTheLatinWordAndTheBigrams() {
        let tokens = MirroredTokeniser.tokens("hrv低于平均")
        XCTAssertTrue(tokens.contains("hrv"))
        XCTAssertTrue(tokens.contains("低于"))
    }

    // MARK: - The numeric-aware proposal

    /// The gap the `exact` category measures: the two rescue slots exist for "an exact name, date or number
    /// that the embedding missed", and the shipped tokeniser cannot represent a number or a date at all.
    func testTheNumericAwareTokeniserRecoversNumbersAndDates() {
        XCTAssertTrue(NumericAwareTokeniser.tokens("resting hr 42").contains("42"))
        XCTAssertTrue(NumericAwareTokeniser.tokens("slept 8h").contains("8h"))
        XCTAssertTrue(NumericAwareTokeniser.tokens("on 2026-03-14 I felt worse").contains("2026-03-14"))
        XCTAssertFalse(MirroredTokeniser.tokens("on 2026-03-14 I felt worse").contains("2026-03-14"),
                       "the shipped tokeniser splits the date and drops the day and month")
    }

    func testTheNumericAwareTokeniserIsStrictlyAdditive() {
        // It may only ADD tokens: anything the shipped arm finds today must still be found, or the change
        // would trade one class of miss for another.
        let text = "Magnesium 400mg vor dem Schlafengehen am 2026-03-14"
        XCTAssertTrue(NumericAwareTokeniser.tokens(text).isSuperset(of: MirroredTokeniser.tokens(text)))
    }

    // MARK: - Chunker

    func testShortTextIsOneChunk() {
        XCTAssertEqual(MirroredChunker.chunks("Magnesium hilft mir beim Einschlafen.").count, 1)
    }

    func testLongWordyTextChunksWithOverlap() {
        let words = (0..<500).map { "w\($0)" }.joined(separator: " ")
        let chunks = MirroredChunker.chunks(words)
        XCTAssertGreaterThan(chunks.count, 1)
        // Consecutive chunks must share their overlap, or a fact split across a boundary is retrievable from
        // neither half.
        let firstTail = chunks[0].split(separator: " ").suffix(MirroredChunker.wordChunkOverlap)
        let secondHead = chunks[1].split(separator: " ").prefix(MirroredChunker.wordChunkOverlap)
        XCTAssertEqual(Array(firstTail), Array(secondHead))
    }

    /// Text without word boundaries has no whitespace to cut on, so it is cut on characters instead — the
    /// fix that stopped a long Chinese note being truncated to its first 384 tokens.
    func testUnsegmentedTextIsChunkedOnCharacters() {
        let unsegmented = String(repeating: "睡眠质量下降", count: 100)
        let chunks = MirroredChunker.chunks(unsegmented)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertLessThanOrEqual(chunks[0].count, MirroredChunker.characterChunkSize)
    }

    func testEveryChunkOfALongDocumentSharesOneSourceID() {
        // The precondition for P4 to be measurable: many chunks, one source.
        let chunks = MirroredChunker.chunks((0..<600).map { "w\($0)" }.joined(separator: " "))
        let ids = chunks.enumerated().map { chunkID("summary-1", $0.offset) }
        XCTAssertEqual(Set(ids.map { sourceID(ofChunk: $0) }), ["summary-1"])
    }

    // MARK: - Vector round trip

    func testVectorSetSurvivesAWriteAndRead() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorybench-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let documentVector = try SemanticVector.normalizedTruncated([0.3, 0.4, 0.5, 0.6], dimensions: 4)
        let queryVector = try SemanticVector.normalizedTruncated([0.6, 0.5, 0.4, 0.3], dimensions: 4)
        let meta = VectorSetMeta(model: "test", pooling: "mean", queryTemplate: "%@", documentTemplate: "%@",
                                fullDimensions: 4, storedDimensions: 4, matryoshka: true,
                                documentIDs: ["d#0"], queryIDs: ["q1"],
                                embedMilliseconds: 1, embeddedTexts: 2)
        try VectorSet.write(directory: directory, meta: meta,
                            documents: ["d#0": documentVector], queries: ["q1": queryVector])
        let read = try VectorSet.read(directory: directory)

        XCTAssertEqual(read.meta.model, "test")
        XCTAssertEqual(read.indexBytes, 8)
        // Float16 is lossy by design — the app stores Float16, so the benchmark must score Float16.
        XCTAssertEqual(SemanticVector.cosine(read.documents["d#0"]!, documentVector), 1, accuracy: 1e-3)
        XCTAssertEqual(SemanticVector.cosine(read.queries["q1"]!, queryVector), 1, accuracy: 1e-3)
    }

    func testAWrongSizedVectorFileIsRejectedRatherThanMisread() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorybench-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let meta = VectorSetMeta(model: "test", pooling: "mean", queryTemplate: "%@", documentTemplate: "%@",
                                fullDimensions: 4, storedDimensions: 4, matryoshka: true,
                                documentIDs: ["d#0", "d#1"], queryIDs: [],
                                embedMilliseconds: 0, embeddedTexts: 0)
        let encoder = JSONEncoder()
        try encoder.encode(meta).write(to: directory.appendingPathComponent("meta.json"))
        try Data(repeating: 0, count: 8).write(to: directory.appendingPathComponent("documents.f16"))
        try Data().write(to: directory.appendingPathComponent("queries.f16"))
        XCTAssertThrowsError(try VectorSet.read(directory: directory))
    }
}
