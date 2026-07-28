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
