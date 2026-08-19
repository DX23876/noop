import SemanticMemory
import XCTest

@testable import Strand

/// The hand-off from ranked hits to the ≤8 lines the model reads. Pure and static, so it is pinned here
/// without an index, a model or a coach engine.
final class CoachSemanticContextTests: XCTestCase {

    private func document(_ sourceID: String,
                          chunk: Int = 0,
                          text: String,
                          kind: SemanticSourceKind = .userMessage) -> SemanticDocument {
        SemanticDocument(sourceKind: kind,
                         sourceID: sourceID,
                         chunkIndex: chunk,
                         text: text,
                         updatedAt: Date(),
                         consentScope: .memory)
    }

    private func hit(_ sourceID: String, chunk: Int = 0,
                     kind: SemanticSourceKind = .userMessage) -> SemanticHit {
        SemanticHit(documentID: "\(kind.rawValue):\(sourceID):\(chunk)",
                    sourceKind: kind,
                    sourceID: sourceID,
                    chunkIndex: chunk,
                    score: 1,
                    consentScope: .memory)
    }

    private func lines(_ context: String) -> [String] {
        context.split(separator: "\n").dropFirst().map(String.init)   // drop the header
    }

    /// The bug this test exists for: `lexicalHits` ranks CHUNKS, and eight chunks of one long conversation
    /// are one line. The keyword-fallback callers used to hand over `lexical.prefix(8)`, so a question whose
    /// best chunks clustered in a few sources produced a two- or three-line context while plenty of other
    /// sources sat unused further down the list — in the one path that runs when the embedding model loses
    /// its race, which is exactly when the context is already at its thinnest.
    func testChunksOfOneSourceDoNotCrowdOutOtherSources() {
        // 9 chunks of one conversation first, then 8 other sources.
        var hits = (0..<9).map { hit("thread", chunk: $0) }
        hits += (0..<8).map { hit("other-\($0)") }

        var documents: [String: SemanticDocument] = [:]
        for index in 0..<9 {
            let doc = document("thread", chunk: index, text: "thread chunk \(index)")
            documents[doc.documentID] = doc
        }
        for index in 0..<8 {
            let doc = document("other-\(index)", text: "other source \(index)")
            documents[doc.documentID] = doc
        }

        let result = Self.render(hits: hits, documents: documents)
        XCTAssertEqual(lines(result).count, 8, "all eight slots must be filled from distinct sources")
        XCTAssertEqual(lines(result).filter { $0.contains("thread chunk") }.count, 1,
                       "one source contributes exactly one line")
    }

    func testOneLinePerSourceInHitOrder()  {
        let hits = [hit("a"), hit("b"), hit("a", chunk: 1)]
        let documents = [document("a", text: "first"), document("b", text: "second"),
                         document("a", chunk: 1, text: "also first source")]
        let result = Self.render(hits: hits,
                                documents: Dictionary(uniqueKeysWithValues: documents.map { ($0.documentID, $0) }))
        XCTAssertEqual(lines(result), ["• [Past conversation] first", "• [Past conversation] second"])
    }

    func testTheContextIsCappedAtEightLines() {
        let hits = (0..<20).map { hit("s\($0)") }
        let documents = (0..<20).map { document("s\($0)", text: "text \($0)") }
        let result = Self.render(hits: hits,
                                documents: Dictionary(uniqueKeysWithValues: documents.map { ($0.documentID, $0) }))
        XCTAssertEqual(lines(result).count, 8)
    }

    /// A hit the live set cannot resolve — an index row whose canonical source has since been deleted — must
    /// not spend its source's slot. Defensive today (a miss and a duplicate source cannot currently meet in
    /// one list), and the reason the lookup now precedes the bookkeeping rather than following it.
    func testAnUnresolvableChunkDoesNotBlockALaterChunkOfTheSameSource() {
        let hits = [hit("a", chunk: 0), hit("a", chunk: 1), hit("b")]
        // Chunk 0 is missing from the live set; chunk 1 is present.
        let documents = [document("a", chunk: 1, text: "survivor"), document("b", text: "other")]
        let result = Self.render(hits: hits,
                                documents: Dictionary(uniqueKeysWithValues: documents.map { ($0.documentID, $0) }))
        XCTAssertEqual(lines(result), ["• [Past conversation] survivor", "• [Past conversation] other"])
    }

    func testNoResolvableHitsYieldsNoBlockAtAll() {
        XCTAssertTrue(Self.render(hits: [hit("a")], documents: [:]).isEmpty,
                      "an empty context must be empty, not a bare header")
    }

    func testEachKindIsLabelled() {
        let kinds: [SemanticSourceKind: String] = [
            .memoryFact: "Memory",
            .userMessage: "Past conversation",
            .journalNote: "Journal",
            .recommendationFeedback: "Recommendation feedback",
            .habitHypothesis: "Habit hypothesis",
        ]
        for (kind, label) in kinds {
            let doc = document("s", text: "text", kind: kind)
            let result = Self.render(hits: [hit("s", kind: kind)], documents: [doc.documentID: doc])
            XCTAssertTrue(result.contains("• [\(label)] text"), "expected \(label) for \(kind.rawValue)")
        }
    }

    /// `context` is `@MainActor` by way of its enclosing type, so every case above goes through this one hop.
    private static func render(hits: [SemanticHit],
                               documents: [String: SemanticDocument]) -> String {
        MainActor.assumeIsolated {
            CoachSemanticMemory.context(from: hits, documents: documents)
        }
    }
}
