import XCTest
@testable import SemanticMemory

final class SemanticMemoryTests: XCTestCase {
    func testHashIsStableOverUTF16() {
        XCTAssertEqual(SemanticHash.fnv1a64Hex("Schlaf 💤"), "cd4ddc1741a926cd")
    }

    func testTruncateThenNormalize() throws {
        let result = try SemanticVector.normalizedTruncated([3, 4, 99], dimensions: 2)
        XCTAssertEqual(result[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(result[1], 0.8, accuracy: 0.0001)
    }

    func testNomicEmbeddingContractIsPinned() {
        XCTAssertEqual(NomicEmbeddingContract.outputDimensions, 256)
        XCTAssertEqual(NomicEmbeddingContract.maximumInputTokens, 384)
        XCTAssertLessThan(NomicEmbeddingContract.maximumInputTokens,
                          NomicEmbeddingContract.modelMaximumTokens)
        XCTAssertEqual(NomicEmbeddingContract.documentText("Schlaf"),
                       "search_document: Schlaf")
        XCTAssertEqual(NomicEmbeddingContract.queryText("Erholung"),
                       "search_query: Erholung")
    }

    func testIndexStatusReportsStableCompletionProgress() {
        let partial = SemanticIndexStatus(modelID: "test",
                                          indexedDocuments: 63,
                                          pendingDocuments: 5_399,
                                          byteSize: 0,
                                          lastRunAt: nil,
                                          lastError: nil,
                                          isModelLoaded: true)
        XCTAssertEqual(partial.totalDocuments, 5_462)
        XCTAssertEqual(partial.completionPercentage, 1)
        XCTAssertEqual(partial.completionFraction, 63.0 / 5_462.0, accuracy: 0.000_001)

        let complete = SemanticIndexStatus(modelID: "test",
                                           indexedDocuments: 12,
                                           pendingDocuments: 0,
                                           byteSize: 0,
                                           lastRunAt: nil,
                                           lastError: nil,
                                           isModelLoaded: false)
        XCTAssertEqual(complete.completionPercentage, 100)

        let empty = SemanticIndexStatus(modelID: "test",
                                        indexedDocuments: 0,
                                        pendingDocuments: 0,
                                        byteSize: 0,
                                        lastRunAt: nil,
                                        lastError: nil,
                                        isModelLoaded: false)
        XCTAssertEqual(empty.completionPercentage, 100)
    }

    func testFloat16RoundTrip() {
        let values: [Float] = [0.25, -0.5, 1]
        let decoded = SemanticVector.decodeFloat16(SemanticVector.encodeFloat16(values))
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded ?? [], values)
    }

    /// The binary16 edges the three friendly powers of two above never reach: subnormals, the rounding
    /// boundary, overflow to Inf, and underflow to a signed zero. These run on EVERY architecture —
    /// unlike `testFloat16MatchesHardware` below, which can only run where `Float16` exists.
    func testFloat16HandlesSubnormalsOverflowAndSignedZero() {
        XCTAssertEqual(SemanticVector.binary16Bits(0), 0x0000)
        XCTAssertEqual(SemanticVector.binary16Bits(-0.0), 0x8000)
        XCTAssertEqual(SemanticVector.binary16Bits(1), 0x3C00)
        XCTAssertEqual(SemanticVector.binary16Bits(-2), 0xC000)
        // Largest finite binary16 (65504) and the first value that overflows it.
        XCTAssertEqual(SemanticVector.binary16Bits(65504), 0x7BFF)
        XCTAssertEqual(SemanticVector.binary16Bits(70000), 0x7C00)
        XCTAssertEqual(SemanticVector.binary16Bits(-.infinity), 0xFC00)
        // Smallest normal (2^-14) and smallest subnormal (2^-24); half of the latter underflows to ±0
        // rather than rounding away from zero.
        XCTAssertEqual(SemanticVector.binary16Bits(0x1p-14), 0x0400)
        XCTAssertEqual(SemanticVector.binary16Bits(0x1p-24), 0x0001)
        XCTAssertEqual(SemanticVector.binary16Bits(0x1p-25), 0x0000)
        XCTAssertEqual(SemanticVector.binary16Bits(-0x1p-25), 0x8000)
        // Round-to-nearest-EVEN, not round-half-up: an exact tie goes to the even neighbour.
        XCTAssertEqual(SemanticVector.binary16Bits(Float(bitPattern: 0x3F80_1000)), 0x3C00)
        XCTAssertEqual(SemanticVector.binary16Bits(Float(bitPattern: 0x3F80_3000)), 0x3C02)
        // A NaN must survive as a NaN; truncating its payload to zero would turn it into Inf.
        XCTAssertTrue(SemanticVector.float(fromBinary16: SemanticVector.binary16Bits(.nan)).isNaN)
        // Decoding covers the same edges.
        XCTAssertEqual(SemanticVector.float(fromBinary16: 0x0001), 0x1p-24)
        XCTAssertEqual(SemanticVector.float(fromBinary16: 0x03FF), 1023 * 0x1p-24)
        XCTAssertEqual(SemanticVector.float(fromBinary16: 0x7C00), .infinity)
        XCTAssertTrue(SemanticVector.float(fromBinary16: 0x8000).sign == .minus)
    }

    /// The manual conversion must be BYTE-IDENTICAL to the hardware `Float16` it replaced, or every
    /// embedding already indexed on a user's device would decode differently after this change. Runs only
    /// where `Float16` exists (arm64) — which is exactly where the old implementation ever ran, so this is
    /// a true differential test against the previous behaviour rather than a re-statement of the new one.
    #if arch(arm64)
    func testFloat16MatchesHardware() {
        var checked = 0
        // Every representable binary16 bit pattern, decoded and re-encoded through both paths.
        for raw in UInt16.min...UInt16.max {
            let hardware = Float16(bitPattern: raw)
            guard !hardware.isNaN else { continue }              // NaN != NaN; payloads are covered above
            let value = Float(hardware)
            XCTAssertEqual(SemanticVector.float(fromBinary16: raw), value, "decode differs at \(raw)")
            XCTAssertEqual(SemanticVector.binary16Bits(value), Float16(value).bitPattern,
                           "encode differs at \(raw)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 60_000)
        // Values BETWEEN representable binary16s, where the rounding mode is what actually decides.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20_000 {
            let value = Float.random(in: -70_000...70_000, using: &generator)
            XCTAssertEqual(SemanticVector.binary16Bits(value), Float16(value).bitPattern,
                           "rounding differs for \(value)")
        }
        for _ in 0..<20_000 {
            // Subnormal and near-subnormal magnitudes, where the shift-and-round path is exercised.
            let value = Float.random(in: -0x1p-13...0x1p-13, using: &generator)
            XCTAssertEqual(SemanticVector.binary16Bits(value), Float16(value).bitPattern,
                           "subnormal rounding differs for \(value)")
        }
    }
    #endif

    func testStoreQueuesOnlyChangedDocumentsAndSearchesAllowedScopes() async throws {
        let store = try SemanticIndexStore(inMemory: true)
        let doc = SemanticDocument(sourceKind: .memoryFact,
                                   sourceID: "fact-1",
                                   text: "Joggen am Wochenende passt nicht",
                                   updatedAt: Date(timeIntervalSince1970: 100),
                                   consentScope: .memory)
        try await store.enqueue([doc])
        let firstPending = try await store.pending(limit: 10)
        XCTAssertEqual(firstPending.count, 1)
        try await store.storeEmbedding(documentID: doc.documentID,
                                       contentHash: doc.contentHash,
                                       modelID: "test",
                                       vector: [1, 0])
        let pendingAfterEmbedding = try await store.pending(limit: 10)
        XCTAssertEqual(pendingAfterEmbedding.count, 0)

        let hits = try await store.search(vector: [1, 0], allowedScopes: [.memory], limit: 5)
        XCTAssertEqual(hits.map(\.sourceID), ["fact-1"])
        let disallowedHits = try await store.search(vector: [1, 0],
                                                    allowedScopes: [.personalLogs],
                                                    limit: 5)
        XCTAssertTrue(disallowedHits.isEmpty)

        try await store.enqueue([doc])
        let pendingAfterUnchangedEnqueue = try await store.pending(limit: 10)
        XCTAssertEqual(pendingAfterUnchangedEnqueue.count, 0)
    }

    func testConsentScopeRemovalPurgesDerivedVectors() async throws {
        let store = try SemanticIndexStore(inMemory: true)
        let memory = SemanticDocument(sourceKind: .memoryFact,
                                      sourceID: "memory",
                                      text: "Knie",
                                      updatedAt: .distantPast,
                                      consentScope: .memory)
        let journal = SemanticDocument(sourceKind: .journalNote,
                                       sourceID: "journal",
                                       text: "Stress",
                                       updatedAt: .distantPast,
                                       consentScope: .sensitiveLogs)
        try await store.enqueue([memory, journal])
        try await store.remove(scopes: [.sensitiveLogs])
        let remaining = try await store.pending(limit: 10)
        XCTAssertEqual(remaining.map(\.sourceID), ["memory"])
    }

    func testInterruptedBatchLeavesCommittedRowsSearchableAndRemainderPending() async throws {
        let store = try SemanticIndexStore(inMemory: true)
        let first = SemanticDocument(sourceKind: .memoryFact, sourceID: "first",
                                     text: "first", updatedAt: Date(),
                                     consentScope: .memory, priority: 10)
        let second = SemanticDocument(sourceKind: .memoryFact, sourceID: "second",
                                      text: "second", updatedAt: Date(),
                                      consentScope: .memory, priority: 5)
        try await store.enqueue([first, second])
        try await store.storeEmbedding(documentID: first.documentID,
                                       contentHash: first.contentHash,
                                       modelID: "model-v1",
                                       vector: [1, 0])

        let pending = try await store.pending(limit: 10)
        let hits = try await store.search(vector: [1, 0],
                                          allowedScopes: [.memory],
                                          limit: 10)
        XCTAssertEqual(pending.map(\.sourceID), ["second"])
        XCTAssertEqual(hits.map(\.sourceID), ["first"])
    }

    func testModelOrDimensionChangeInvalidatesVectorsForRebuild() async throws {
        let store = try SemanticIndexStore(inMemory: true)
        let document = SemanticDocument(sourceKind: .userMessage, sourceID: "message",
                                        text: "sleep routine", updatedAt: Date(),
                                        consentScope: .memory)
        try await store.enqueue([document])
        try await store.storeEmbedding(documentID: document.documentID,
                                       contentHash: document.contentHash,
                                       modelID: "old-model",
                                       vector: [1, 0])
        try await store.invalidate(modelID: "new-model", dimensions: 256)

        let pending = try await store.pending(limit: 10)
        let hits = try await store.search(vector: Array(repeating: 0, count: 256),
                                          allowedScopes: [.memory],
                                          limit: 10)
        XCTAssertEqual(pending.map(\.sourceID), ["message"])
        XCTAssertTrue(hits.isEmpty)
    }

    func testRemovingMissingCanonicalSourcePurgesEveryChunk() async throws {
        let store = try SemanticIndexStore(inMemory: true)
        let chunks = (0...2).map {
            SemanticDocument(sourceKind: .journalNote, sourceID: "journal-row",
                             chunkIndex: $0, text: "part \($0)", updatedAt: Date(),
                             consentScope: .personalLogs)
        }
        try await store.enqueue(chunks)
        try await store.removeDocuments(notIn: [], sourceKinds: [.journalNote])

        let pending = try await store.pending(limit: 10)
        XCTAssertTrue(pending.isEmpty)
    }

    func testReciprocalRankFusionKeepsSemanticAndExactMatches() {
        let semantic = [
            SemanticHit(documentID: "memory:a:0", sourceKind: .memoryFact, sourceID: "a",
                        chunkIndex: 0, score: 0.9, consentScope: .memory),
            SemanticHit(documentID: "memory:b:0", sourceKind: .memoryFact, sourceID: "b",
                        chunkIndex: 0, score: 0.8, consentScope: .memory),
        ]
        let fused = SemanticRanking.fuse(semantic: semantic,
                                         lexicalSourceIDs: ["b", "a"],
                                         limit: 2)
        XCTAssertEqual(fused.map(\.sourceID), ["a", "b"])
    }

    func testReciprocalRankFusionRetainsLexicalOnlyHit() {
        let semantic = [
            SemanticHit(documentID: "memory:a:0", sourceKind: .memoryFact, sourceID: "a",
                        chunkIndex: 0, score: 0.9, consentScope: .memory),
        ]
        let exact = SemanticHit(documentID: "journal:date:0", sourceKind: .journalNote,
                                sourceID: "date", chunkIndex: 0, score: 1,
                                consentScope: .personalLogs)
        let fused = SemanticRanking.fuse(semantic: semantic, lexical: [exact], limit: 2)
        XCTAssertEqual(Set(fused.map(\.sourceID)), Set(["a", "date"]))
    }
}
