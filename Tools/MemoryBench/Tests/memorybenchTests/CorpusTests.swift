import XCTest

@testable import memorybench

/// Guards the committed corpus. It needs no vectors and no model, so CI runs it on every change — which is
/// the point: a duplicate id, a judgment pointing at a renamed document, or an `unanswerable` query that
/// quietly acquired a relevant answer would otherwise surface as a strange number in a table months later.
///
/// These assertions are about the corpus's DESIGN, not its syntax. `Corpus.load` already rejects malformed
/// files; what follows checks that each category can still measure the thing it exists for.
final class CorpusTests: XCTestCase {

    /// Located relative to this source file rather than the working directory, because `swift test` runs from
    /// wherever the caller happens to be.
    private var corpusDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Corpus")
    }

    private func loadedCorpus() throws -> Corpus {
        try Corpus.load(directory: corpusDirectory)
    }

    private static let mainIndex = "main"

    func testTheCommittedCorpusLoadsAndValidates() throws {
        let corpus = try loadedCorpus()
        XCTAssertGreaterThan(corpus.documents.count, 400)
        XCTAssertGreaterThan(corpus.queries.count, 300)
    }

    /// The reason this corpus was rebuilt. With ~25 candidates per query the retrieval problem is trivial and
    /// every ranking change measures noise; the ranking questions can only be asked against an index that
    /// holds a realistic number of a person's own notes.
    func testTheMainIndexIsLargeEnoughToRank() throws {
        let corpus = try loadedCorpus()
        let main = corpus.documents.filter { $0.index == Self.mainIndex }
        XCTAssertGreaterThanOrEqual(main.count, 250,
                                    "the main index has to be big enough that ranking, not recall, decides")
        XCTAssertGreaterThanOrEqual(corpus.queries.filter { $0.index == Self.mainIndex }.count, 100)
    }

    /// A bilingual person's own index, not nine translations of one fact. The ratio matters: too little
    /// English and the crosslingual cases are anecdotes, too much and it stops resembling anyone.
    func testTheMainIndexIsBilingualAtRoughlyOneInTen() throws {
        let corpus = try loadedCorpus()
        let main = corpus.documents.filter { $0.index == Self.mainIndex }
        let english = Double(main.filter { $0.lang == "en" }.count) / Double(main.count)
        XCTAssertGreaterThan(english, 0.03)
        XCTAssertLessThan(english, 0.25)
        // And no two documents in one index may be translations of each other — that artifact is what made
        // the first measurement meaningless. Approximated by requiring distinct text.
        XCTAssertEqual(Set(main.map(\.text)).count, main.count, "duplicate text in one index")
    }

    func testTheMainIndexCoversEveryCategory() throws {
        let corpus = try loadedCorpus()
        let queries = corpus.queries.filter { $0.index == Self.mainIndex }
        for category in QueryCategory.allCases {
            XCTAssertGreaterThanOrEqual(queries.filter { $0.category == category }.count, 8,
                                        "\(category.rawValue) needs enough cases to mean something")
        }
    }

    /// The locale sets have a narrower job — "does this model work in this language at all" — so they only owe
    /// the categories they were built for, but every shipped locale still has to be present.
    func testEveryShippedLocaleHasItsOwnIndex() throws {
        let corpus = try loadedCorpus()
        for locale in ["de", "en", "es", "fr", "it", "pl", "pt-PT", "ru", "zh-Hans", "zh-Hant"] {
            let documents = corpus.documents.filter { $0.index == "locale-\(locale)" }
            XCTAssertFalse(documents.isEmpty, "no locale index for shipped locale \(locale)")
            XCTAssertFalse(corpus.queries.filter { $0.index == "locale-\(locale)" }.isEmpty)
        }
    }

    /// `recency`: two documents contradict and the newer one is right. Without both halves the category
    /// measures nothing, and if the graded one were the older the recency term would be scored backwards.
    func testRecencyQueriesContrastANewerAndAnOlderDocument() throws {
        let corpus = try loadedCorpus()
        let documents = corpus.documentsByID
        for query in corpus.queries where query.category == .recency {
            let winners = query.judgments.filter { $0.value > 0 }.keys.compactMap { documents[$0] }
            let losers = query.judgments.filter { $0.value == 0 }.keys.compactMap { documents[$0] }
            XCTAssertFalse(winners.isEmpty, "\(query.id) has no current answer")
            XCTAssertFalse(losers.isEmpty, "\(query.id) has no superseded answer to be fooled by")
            let newest = winners.map(\.ageDays).min() ?? .infinity
            let oldest = losers.map(\.ageDays).max() ?? 0
            XCTAssertLessThan(newest, oldest,
                              "\(query.id): the graded document must be NEWER than the distractor")
        }
    }

    /// `numeric`: the question turns on a token the embedding may well miss. If no graded document carries a
    /// digit the case is an ordinary paraphrase wearing the wrong label.
    func testNumericQueriesTurnOnATokenThatCarriesADigit() throws {
        let corpus = try loadedCorpus()
        let documents = corpus.documentsByID
        for query in corpus.queries where query.category == .numeric {
            let graded = query.judgments.filter { $0.value > 0 }.keys.compactMap { documents[$0] }
            XCTAssertTrue(graded.contains { $0.text.contains(where: \.isNumber) },
                          "\(query.id): no graded document carries a number or date")
        }
    }

    /// `near-miss`: the whole point is a graded-0 sibling that is almost the same sentence. A near-miss query
    /// without one is just a paraphrase, and would quietly inflate the category a reranker is judged on.
    func testNearMissQueriesCarryAGradedZeroSibling() throws {
        let corpus = try loadedCorpus()
        for query in corpus.queries where query.category == .nearMiss {
            XCTAssertTrue(query.judgments.values.contains(0),
                          "\(query.id): a near-miss case needs a deliberately rejected sibling")
        }
    }

    /// `negation`: the question is about what is NOT the case, so the corpus has to name the positive
    /// counterpart and grade it zero. Otherwise a model that ignores the negation entirely still scores well.
    func testNegationQueriesNameThePositiveCounterpart() throws {
        let corpus = try loadedCorpus()
        let negations = corpus.queries.filter { $0.category == .negation }
        XCTAssertFalse(negations.isEmpty)
        let withCounterpart = negations.filter { $0.judgments.values.contains(0) }
        // Not every negation has a single clean opposite ("wann trage ich die Bandage nicht") — but most
        // should, or the category is not testing what it claims.
        XCTAssertGreaterThan(Double(withCounterpart.count) / Double(negations.count), 0.5)
    }

    /// `terse`: three or four words, the way people type. A long sentence in this category would be measuring
    /// something else.
    func testTerseQueriesAreActuallyShort() throws {
        let corpus = try loadedCorpus()
        for query in corpus.queries where query.category == .terse {
            XCTAssertLessThanOrEqual(query.text.split(separator: " ").count, 4,
                                     "\(query.id) is not terse: \(query.text)")
        }
    }

    /// At least one question must be answered by a document in the other language of the same index — that is
    /// the realistic crosslingual case, as opposed to nine translations sitting in one pile.
    func testAtLeastOneQueryIsAnsweredAcrossLanguagesWithinOneIndex() throws {
        let corpus = try loadedCorpus()
        let documents = corpus.documentsByID
        let crosslingual = corpus.queries.contains { query in
            query.judgments.filter { $0.value > 0 }.keys.contains { documents[$0]?.lang != query.lang }
        }
        XCTAssertTrue(crosslingual)
    }

    // MARK: - The four-point grade scale

    /// The scale grew from 0–2 to 0–3 on 2026-08-19. These are the invariants that keep the new band from
    /// decaying into a second word for "relevant", which is what happens to every graded scale nobody enforces.
    func testEveryJudgmentSitsOnTheFourPointScale() throws {
        for query in try loadedCorpus().queries {
            for (judged, grade) in query.judgments {
                XCTAssertTrue((0...3).contains(grade), "\(query.id): grade \(grade) for \(judged)")
            }
        }
    }

    /// Grade 3 means "the one document that directly answers". More than one per query would make it a synonym
    /// for grade 2 and throw away the distinction the scale was widened to express.
    func testAtMostOneDocumentPerQueryIsTheDirectAnswer() throws {
        for query in try loadedCorpus().queries {
            XCTAssertLessThanOrEqual(query.judgments.filter { $0.value == 3 }.count, 1,
                                     "\(query.id): co-equal answers belong at grade 2")
        }
    }

    /// The other half of the same rule: a question with several equally good answers must NOT be forced to name
    /// a winner. If every answerable query had a 3, the middle band would go unused and the scale would be 0–2
    /// again with different numbers on it.
    func testQuestionsWithCoEqualAnswersMayHaveNoSingleWinner() throws {
        let answerable = try loadedCorpus().queries.filter { $0.category.isAnswerable }
        let withoutWinner = answerable.filter { !$0.judgments.values.contains(3) }
        XCTAssertFalse(withoutWinner.isEmpty,
                       "not one question has co-equal answers, which is implausible for a real index")
        XCTAssertTrue(withoutWinner.allSatisfy { $0.judgments.values.contains(2) },
                      "a query with no direct answer still needs a strongly relevant one")
    }

    /// All four bands must be in use, or the scale is decoration. The supporting band matters most: it is what
    /// lets `gain` express that one answer beats a context packed with loosely-related lines.
    func testAllFourBandsAreActuallyUsed() throws {
        let grades = Set(try loadedCorpus().queries.flatMap { $0.judgments.values })
        XCTAssertEqual(grades, [0, 1, 2, 3], "an unused band is a scale that does not exist")
    }

    /// The validator's own teeth, shown a broken corpus rather than the committed one.
    ///
    /// The committed files passing proves only that they pass. A check earns trust by rejecting something, and
    /// this is the test that makes it do so — including the last assertion, that a legal grading is still
    /// accepted, without which an over-eager validator would look just as green.
    func testTheValidatorRejectsAnOffScaleGradeAndASecondDirectAnswer() throws {
        let corpus = try loadedCorpus()
        let first = try XCTUnwrap(corpus.documents.first { $0.index == Self.mainIndex })
        let second = try XCTUnwrap(corpus.documents.last { $0.index == Self.mainIndex })

        func problems(_ judgments: [String: Int]) throws -> [String] {
            struct ProbeFile: Decodable { let queries: [CorpusQuery] }
            let body = judgments.map { "\"\($0.key)\": \($0.value)" }.sorted().joined(separator: ", ")
            let json = "{\"queries\": [{\"id\": \"probe\", \"index\": \"\(Self.mainIndex)\", \"lang\": \"de\", "
                + "\"category\": \"paraphrase\", \"text\": \"probe\", \"judgments\": {\(body)}}]}"
            let probe = try JSONDecoder().decode(ProbeFile.self, from: Data(json.utf8))
            do {
                _ = try Corpus.validated(documents: corpus.documents, queries: probe.queries)
                return []
            } catch let CorpusError.invalid(problems) {
                return problems
            }
        }

        XCTAssertTrue(try problems([first.id: 4]).contains { $0.contains("outside the 0…3 scale") })
        XCTAssertTrue(try problems([first.id: -1]).contains { $0.contains("outside the 0…3 scale") })
        XCTAssertTrue(try problems([first.id: 3, second.id: 3]).contains { $0.contains("graded 3") })
        XCTAssertEqual(try problems([first.id: 3, second.id: 2]), [],
                       "a legal grading must not be rejected")
    }

    /// The flood that makes the diversity cap measurable, and long documents that make chunking occur.
    func testTheMainIndexHasAThreadBigEnoughToFloodAContextAndDocumentsThatChunk() throws {
        let corpus = try loadedCorpus()
        let main = corpus.documents.filter { $0.index == Self.mainIndex }
        let byConversation = Dictionary(grouping: main.filter { $0.conversation != nil }) { $0.conversation! }
        XCTAssertGreaterThan(byConversation.values.map(\.count).max() ?? 0, maximumPerGroup)
        XCTAssertFalse(main.filter { MirroredChunker.chunks($0.text).count > 1 }.isEmpty)
    }
}
