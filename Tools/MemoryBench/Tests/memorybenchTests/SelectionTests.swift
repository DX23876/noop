import SemanticMemory
import XCTest

@testable import memorybench

/// The selection policies, pinned on hand-built candidates. No index, no vectors file, no model.
final class SelectionTests: XCTestCase {

    /// A unit vector in `dimension`, so MMR redundancy between two different candidates is 0 unless a test
    /// deliberately makes them identical.
    private func basis(_ dimension: Int, width: Int = 8) -> [Float] {
        var vector = [Float](repeating: 0, count: width)
        vector[dimension % width] = 1
        return vector
    }

    private func candidate(_ id: String,
                           kind: SemanticSourceKind = .userMessage,
                           group: String? = nil,
                           cosine: Double,
                           ageDays: Double = 0,
                           priority: Int = 30,
                           chunk: Int = 0,
                           vectorDimension: Int = 0) -> SelectionCandidate {
        SelectionCandidate(documentID: chunkID(id, chunk),
                           sourceID: id,
                           kind: kind,
                           diversityGroup: group ?? kind.rawValue,
                           ageDays: ageDays,
                           priority: priority,
                           cosine: cosine,
                           vector: basis(vectorDimension))
    }

    // MARK: - The baseline is the shipped code

    /// `today` must not be a re-description of production; it must BE production. If this ever diverges the
    /// whole table loses its zero point.
    func testTodayVariantDelegatesToTheShippedFusion() {
        let semantic = [candidate("s1", cosine: 0.9), candidate("s2", cosine: 0.8)]
        let lexical = [candidate("L1", cosine: 3)]
        let mine = select(semantic: semantic, lexical: lexical, config: .today)
        let theirs = SemanticRanking.fuse(semantic: semantic.map {
            SemanticHit(documentID: $0.documentID, sourceKind: $0.kind, sourceID: $0.sourceID,
                        chunkIndex: 0, score: $0.cosine, consentScope: .memory)
        }, lexical: lexical.map {
            SemanticHit(documentID: $0.documentID, sourceKind: $0.kind, sourceID: $0.sourceID,
                        chunkIndex: 0, score: $0.cosine, consentScope: .memory)
        }, limit: contextSlots).map(\.sourceID)
        XCTAssertEqual(mine, theirs)
    }

    func testSemanticOnlyAdmitsNoLexicalOnlySource() {
        let ranked = select(semantic: [candidate("s1", cosine: 0.5)],
                            lexical: [candidate("L1", cosine: 9)],
                            config: .semanticOnly)
        XCTAssertEqual(ranked, ["s1"])
    }

    // MARK: - Floor

    /// The defect the floor exists for: today the eight slots are filled whatever the cosine says, so a
    /// question nothing in memory answers still ships eight lines of noise to the model.
    func testWithoutAFloorEverySlotIsFilledHoweverPoorTheMatch() {
        let weak = (0..<8).map { candidate("s\($0)", cosine: 0.05 + Double($0) * 0.001) }
        XCTAssertEqual(select(semantic: weak, lexical: [], config: .today).count, 8)
    }

    func testFloorDropsEverythingBelowItAndDoesNotPadBackUp() {
        var config = SelectionConfig.proposed(floor: 0.35)
        config.quotas = false
        config.mmrLambda = nil
        let mixed = [candidate("good", cosine: 0.8), candidate("weak", cosine: 0.1)]
        XCTAssertEqual(select(semantic: mixed, lexical: [], config: config), ["good"])
    }

    func testAFloorAboveEverythingYieldsNoContextAtAll() {
        let config = SelectionConfig.proposed(floor: 0.99)
        XCTAssertTrue(select(semantic: [candidate("s1", cosine: 0.4)], lexical: [], config: config).isEmpty)
    }

    // MARK: - Recency

    /// Same cosine, different age. Today these tie and the order falls out of a dictionary; with a recency
    /// term the newer one wins, which is the whole point for a health coach — the knee from eight months ago
    /// is not the knee from last week.
    func testRecencySeparatesTwoEquallySimilarChatTurns() {
        var config = SelectionConfig(name: "recency", useProductionFuse: false, recencyWeight: 0.25)
        config.perSourceMax = true
        let old = candidate("old", cosine: 0.7, ageDays: 240)
        let fresh = candidate("new", cosine: 0.7, ageDays: 1)
        XCTAssertEqual(select(semantic: [old, fresh], lexical: [], config: config).first, "new")
    }

    /// A memory fact's currency comes from its confirmation lifecycle and `validUntil`, not from its age, so
    /// the decay must not apply to it. Otherwise a two-year-old confirmed injury quietly stops surfacing.
    func testAMemoryFactIsNotDecayedByAge() {
        var config = SelectionConfig(name: "recency", useProductionFuse: false, recencyWeight: 0.25)
        config.perSourceMax = true
        let oldFact = candidate("fact", kind: .memoryFact, cosine: 0.7, ageDays: 700, priority: 100)
        let freshFact = candidate("fact2", kind: .memoryFact, cosine: 0.69, ageDays: 0, priority: 100)
        XCTAssertEqual(select(semantic: [oldFact, freshFact], lexical: [], config: config).first, "fact")
    }

    // MARK: - Per-source aggregation

    func testPerSourceMaxKeepsTheBestChunkNotTheFirstOne() {
        var config = SelectionConfig(name: "max", useProductionFuse: false, perSourceMax: true)
        config.quotas = false
        let weakChunk = candidate("summary", cosine: 0.30, chunk: 0)
        let strongChunk = candidate("summary", cosine: 0.90, chunk: 1)
        let rival = candidate("other", cosine: 0.50)
        XCTAssertEqual(select(semantic: [weakChunk, strongChunk, rival], lexical: [], config: config).first,
                       "summary")
    }

    // MARK: - Quotas and diversity

    /// Eight paraphrases of one complaint from one thread can legally take all eight slots today, because
    /// every user message is its own `sourceID` and per-source deduplication never fires.
    func testOneThreadCannotTakeEverySlot() {
        let config = SelectionConfig.proposed(floor: nil)
        let flood = (0..<8).map {
            candidate("m\($0)", group: "thread-1", cosine: 0.9 - Double($0) * 0.01, vectorDimension: $0)
        }
        let ranked = select(semantic: flood, lexical: [], config: config)
        XCTAssertLessThanOrEqual(ranked.count, maximumPerGroup)
    }

    func testUserMessagesAreCappedAcrossThreads() {
        let config = SelectionConfig.proposed(floor: nil)
        let flood = (0..<8).map {
            candidate("m\($0)", group: "thread-\($0)", cosine: 0.9, vectorDimension: $0)
        }
        XCTAssertLessThanOrEqual(select(semantic: flood, lexical: [], config: config).count,
                                 maximumUserMessages)
    }

    /// The curated document has to keep a seat even when it is outscored, because it is outnumbered in the
    /// index by raw chat turns by orders of magnitude.
    func testACuratedFactKeepsASeatAgainstBetterScoringChatTurns() {
        let config = SelectionConfig.proposed(floor: nil)
        var pool = (0..<8).map {
            candidate("m\($0)", group: "thread-\($0)", cosine: 0.95, vectorDimension: $0)
        }
        pool.append(candidate("fact", kind: .memoryFact, cosine: 0.40, priority: 120, vectorDimension: 7))
        XCTAssertTrue(select(semantic: pool, lexical: [], config: config).contains("fact"))
    }

    /// A reservation that cannot be filled must lapse rather than leave the context short — an empty slot
    /// helps nobody.
    func testAnUnfillableReservationDoesNotShortenTheContext() {
        var config = SelectionConfig.proposed(floor: nil)
        config.mmrLambda = nil
        let pool = (0..<6).map {
            candidate("j\($0)", kind: .journalNote, group: "j\($0)", cosine: 0.9 - Double($0) * 0.01)
        }
        // Journal notes ARE a reserved kind, so this also checks the reservation cannot starve itself.
        XCTAssertEqual(select(semantic: pool, lexical: [], config: config).count, 6)
    }

    // MARK: - MMR

    func testMMRDemotesANearDuplicateOfSomethingAlreadyChosen() {
        var config = SelectionConfig(name: "mmr", useProductionFuse: false, perSourceMax: true, mmrLambda: 0.7)
        config.quotas = false
        let first = candidate("a", cosine: 0.90, vectorDimension: 0)
        let duplicate = candidate("a-dup", cosine: 0.89, vectorDimension: 0) // identical vector
        let different = candidate("b", cosine: 0.80, vectorDimension: 3)
        let ranked = select(semantic: [first, duplicate, different], lexical: [], config: config)
        XCTAssertEqual(ranked.prefix(2).map { $0 }, ["a", "b"])
    }

    // MARK: - Lexical arm

    func testTheShippedLexicalArmCannotTellARareTermFromACommonOne() {
        // Every document mentions sleep; only one mentions ferritin. Raw overlap scores both matches 1, so
        // the arm kept for exact terms has no way to prefer the rare one.
        let texts = [
            ("ferritin", "Ferritin measured 42 during the sleep study"),
            ("sleepy1", "sleep quality dropped after the sleep study"),
            ("sleepy2", "sleep felt shallow during the sleep study"),
        ]
        let entries = texts.map { id, text -> (candidate: SelectionCandidate, text: String) in
            (candidate(id, cosine: 0), text)
        }
        let shipped = LexicalIndex(documents: entries, numericTokens: false)
        let weighted = LexicalIndex(documents: entries, numericTokens: true)

        let question = "What was my ferritin?"
        XCTAssertEqual(weighted.weightedHits(question: question, numericTokens: true).first?.sourceID,
                       "ferritin")
        // The shipped arm does find it here (only one document shares the token at all) — the point pinned
        // below is that its SCORE carries no information about rarity.
        let shippedHits = shipped.shippedHits(question: "sleep study ferritin")
        let scores = Set(shippedHits.map(\.lexicalMass))
        XCTAssertEqual(scores, [0], "the shipped arm carries no IDF mass at all")
    }

    func testWeightedHitsCarryABoundedLexicalMass() {
        let entries = [(candidate("a", cosine: 0), "magnesium before bed helps me fall asleep")]
        let index = LexicalIndex(documents: entries, numericTokens: true)
        let hit = index.weightedHits(question: "magnesium before bed helps me fall asleep",
                                     numericTokens: true).first
        let mass = try? XCTUnwrap(hit?.lexicalMass)
        XCTAssertNotNil(mass)
        XCTAssertGreaterThan(mass ?? 0, 0)
        XCTAssertLessThanOrEqual(mass ?? 2, 1)
    }
}
