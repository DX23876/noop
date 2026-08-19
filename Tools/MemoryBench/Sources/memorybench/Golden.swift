import Foundation

// The shared golden fixture, and why it is the only real fix for the mirror problem.
//
// `MirroredTokeniser` and `MirroredChunker` are transcriptions of `CoachMemory.tokens` and
// `CoachSemanticMemory.chunkTexts`, because a SwiftPM executable cannot import the app target. Unit tests on
// each side pin each side's behaviour — and that is precisely the trap: both can stay internally consistent
// while drifting apart, and every test stays green while the benchmark quietly measures something the app no
// longer does.
//
// One file, read by both sides, makes that impossible. A one-sided change breaks one of the two test suites
// immediately, which is the property no amount of same-side testing can provide.

struct GoldenCase: Codable {
    let id: String
    let text: String
    /// Sorted, because a token set has no order and a fixture must be byte-stable across runs.
    var tokens: [String]?
    var chunks: [String]?
}

struct GoldenFixture: Codable {
    let version: Int
    /// Carried so the note travels with the data rather than living only in a commit message.
    let _note: String
    var cases: [GoldenCase]

    static let filename = "tokeniser-golden.json"

    static func load(directory: URL) throws -> GoldenFixture {
        try JSONDecoder().decode(GoldenFixture.self,
                                 from: Data(contentsOf: directory.appendingPathComponent(filename)))
    }

    func write(directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.filename))
    }

    /// Fills in expected values from the benchmark's own copies.
    ///
    /// Generated from the mirror rather than from the app only because the app cannot be run from here. That
    /// makes the APP-side test the real check: if the transcription is wrong, `StrandTests` fails on the first
    /// run against this file, which is the drift detection doing its job rather than a problem with it.
    func filled() -> GoldenFixture {
        var copy = self
        copy.cases = cases.map { entry in
            var filled = entry
            filled.tokens = MirroredTokeniser.tokens(entry.text).sorted()
            filled.chunks = MirroredChunker.chunks(entry.text)
            return filled
        }
        return copy
    }
}
