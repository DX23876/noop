import XCTest

@testable import memorybench

/// This tool's half of the cross-target golden test.
///
/// `MirroredTokeniser` and `MirroredChunker` exist because a SwiftPM executable cannot import the app target,
/// so they are hand transcriptions of `CoachMemory.tokens` and `CoachSemanticMemory.chunkTexts`. Testing each
/// copy against its own expectations is the trap this file closes: both sides could stay internally consistent
/// while drifting apart, every test green, and the benchmark quietly measuring a pipeline the app no longer
/// runs.
///
/// `StrandTests/CoachTokeniserGoldenTests.swift` reads the SAME file against the app's own functions. Change
/// one side only, and one of the two suites fails immediately — the property neither side can provide alone.
final class GoldenFixtureTests: XCTestCase {

    private var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    private func fixture() throws -> GoldenFixture {
        try GoldenFixture.load(directory: fixturesDirectory)
    }

    func testEveryCaseHasExpectedValuesRecorded() throws {
        let fixture = try self.fixture()
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 15)
        for entry in fixture.cases {
            XCTAssertNotNil(entry.tokens, "\(entry.id) has no expected tokens — run `memorybench golden --write`")
            XCTAssertNotNil(entry.chunks, "\(entry.id) has no expected chunks — run `memorybench golden --write`")
        }
    }

    func testTheMirroredTokeniserMatchesTheSharedFixture() throws {
        for entry in try fixture().cases {
            XCTAssertEqual(MirroredTokeniser.tokens(entry.text).sorted(), entry.tokens,
                           "\(entry.id): this tool's tokeniser no longer agrees with the shared fixture")
        }
    }

    func testTheMirroredChunkerMatchesTheSharedFixture() throws {
        for entry in try fixture().cases {
            XCTAssertEqual(MirroredChunker.chunks(entry.text), entry.chunks,
                           "\(entry.id): this tool's chunker no longer agrees with the shared fixture")
        }
    }

    /// The cases that carry the fixture's weight. A golden file full of ordinary Latin sentences would pass
    /// while every real edge drifted, so these assert that the awkward paths are actually exercised: CJK
    /// bigrams, mixed script, an ISO date, sub-three-character runs, and text long enough to chunk.
    func testTheFixtureCoversTheEdgesThatActuallyDiffer() throws {
        let entries = try fixture().cases
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

        // CJK: bigrams, not words — the one path where token count explodes relative to character count.
        let cjk = try XCTUnwrap(byID["cjk-bigrams"])
        XCTAssertTrue(cjk.tokens!.allSatisfy { $0.count <= 2 })
        XCTAssertGreaterThan(cjk.tokens!.count, 2)

        // A single ideograph survives whole; dropping it would lose the shortest questions.
        XCTAssertEqual(try XCTUnwrap(byID["cjk-single"]).tokens!.count, 1)

        // Mixed script must yield the Latin word AND the ideographic bigrams from one run.
        let mixed = try XCTUnwrap(byID["mixed-script"])
        XCTAssertTrue(mixed.tokens!.contains { $0.count > 2 }, "no Latin token survived the mixed run")
        XCTAssertTrue(mixed.tokens!.contains { $0.count == 2 }, "no bigram survived the mixed run")

        // The known lossy case, pinned deliberately: an ISO date is cut at its punctuation and the
        // two-digit parts fall under the three-character floor, so only the year is searchable. This is
        // exactly P5, and the fixture records it rather than wishing it away.
        let date = try XCTUnwrap(byID["iso-date"]).tokens!
        XCTAssertTrue(date.contains("2026"))
        XCTAssertFalse(date.contains("2026-03-14"), "the date never survives as one searchable token")
        XCTAssertFalse(date.contains("03"))
        XCTAssertFalse(date.contains("14"))
        XCTAssertFalse(date.contains("42"), "the value the question is about is not searchable either")

        // Numbers and units below three characters are dropped: "42", "8h", "5k" are not searchable today.
        let short = try XCTUnwrap(byID["short-runs-dropped"])
        XCTAssertFalse(short.tokens!.contains("42"))
        XCTAssertFalse(short.tokens!.contains("8h"))

        // Unsegmented text switches the chunker to characters, and long text has to produce >1 chunk or the
        // chunk boundary logic is untested.
        XCTAssertGreaterThan(try XCTUnwrap(byID["long-word-chunker"]).chunks!.count, 1)

        // Empty and punctuation-only inputs yield nothing at all — not one empty chunk.
        XCTAssertEqual(try XCTUnwrap(byID["empty"]).chunks!, [])
        XCTAssertEqual(try XCTUnwrap(byID["punctuation-only"]).tokens!, [])
    }

    /// Regenerating the fixture must be a no-op when nothing changed, or `--write` would silently paper over a
    /// drift the moment anyone ran it.
    func testRegeneratingTheFixtureIsIdempotent() throws {
        let fixture = try self.fixture()
        let filled = fixture.filled()
        XCTAssertEqual(filled.cases.map(\.tokens), fixture.cases.map(\.tokens))
        XCTAssertEqual(filled.cases.map(\.chunks), fixture.cases.map(\.chunks))
    }
}
