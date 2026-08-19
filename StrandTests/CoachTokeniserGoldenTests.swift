import XCTest
@testable import Strand

/// The app's half of a golden fixture shared with `Tools/MemoryBench`.
///
/// The benchmark that measures semantic retrieval cannot import this target — it is a SwiftPM executable, and
/// `Strand` is an Xcode app target — so it carries hand transcriptions of `CoachMemory.tokens` and
/// `CoachSemanticMemory.chunkTexts`. That is the arrangement's one real hazard: two copies, each with its own
/// passing tests, free to drift apart while every check stays green and the benchmark quietly reports numbers
/// for a pipeline this app no longer runs. `CoachMemoryTokenizerTests` pins this side's behaviour; it cannot
/// notice the other side moving.
///
/// `Tools/MemoryBench/Fixtures/tokeniser-golden.json` closes that. Both suites read the same file, so a
/// one-sided change breaks one of them on the next run. When THIS test fails, the two implementations have
/// genuinely diverged: fix whichever side is wrong, then regenerate with
/// `swift run memorybench golden --write` — never regenerate first to make the red go away.
///
/// The fixture is read from the repository rather than a test bundle resource on purpose: a copied resource
/// would be a third artifact to keep in sync, which is the problem this file exists to remove.
@MainActor
final class CoachTokeniserGoldenTests: XCTestCase {

    private struct GoldenCase: Decodable {
        let id: String
        let text: String
        let tokens: [String]
        let chunks: [String]
    }

    private struct GoldenFixture: Decodable {
        let version: Int
        let cases: [GoldenCase]
    }

    private func fixture() throws -> GoldenFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // StrandTests
            .deletingLastPathComponent()      // repository root
            .appendingPathComponent("Tools/MemoryBench/Fixtures/tokeniser-golden.json")
        return try JSONDecoder().decode(GoldenFixture.self, from: Data(contentsOf: url))
    }

    func testTheFixtureIsPresentAndCoversEnoughGround() throws {
        let fixture = try self.fixture()
        XCTAssertEqual(fixture.version, 1)
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 15,
                                    "the shared fixture is the only thing tying the two tokenisers together")
    }

    /// `tokens` returns a `Set`, so the fixture stores it sorted — a set has no order, and a golden file has to
    /// be byte-stable across runs.
    func testTheTokeniserAgreesWithTheSharedFixture() throws {
        for entry in try fixture().cases {
            XCTAssertEqual(CoachMemory.tokens(entry.text).sorted(), entry.tokens,
                           "\(entry.id): the app's tokeniser and Tools/MemoryBench have diverged")
        }
    }

    func testTheChunkerAgreesWithTheSharedFixture() throws {
        for entry in try fixture().cases {
            XCTAssertEqual(CoachSemanticMemory.chunkTexts(entry.text), entry.chunks,
                           "\(entry.id): the app's chunker and Tools/MemoryBench have diverged")
        }
    }
}
