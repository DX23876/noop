import XCTest

@testable import memorybench

/// Guards the committed corpus itself. It needs no vectors and no model, so CI runs it on every change —
/// which is the point: a corpus with a duplicate id, a judgment pointing at a document that was renamed, or
/// an `irrelevant` query that quietly acquired a relevant answer would otherwise only surface as a strange
/// number in a table months later.
final class CorpusTests: XCTestCase {

    /// Located relative to this source file rather than the working directory, because `swift test` runs from
    /// wherever the caller happens to be.
    private var corpusDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // memorybenchTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // MemoryBench
            .appendingPathComponent("Corpus")
    }

    private func loadedCorpus() throws -> Corpus {
        try Corpus.load(directory: corpusDirectory)
    }

    func testTheCommittedCorpusLoadsAndValidates() throws {
        // `Corpus.load` is the validator: duplicate ids, unknown kinds and scopes, dangling judgments and
        // miscategorised queries are all hard errors there.
        let corpus = try loadedCorpus()
        XCTAssertGreaterThan(corpus.documents.count, 200)
        XCTAssertGreaterThan(corpus.queries.count, 200)
    }

    /// The app ships ten locales. A corpus missing one of them cannot detect a model or tokeniser change that
    /// only hurts that language, which is exactly the kind of regression a per-language table exists to catch.
    func testEveryShippedLocaleIsRepresented() throws {
        let corpus = try loadedCorpus()
        let shipped = ["de", "en", "es", "fr", "it", "pl", "pt-PT", "ru", "zh-Hans", "zh-Hant"]
        for locale in shipped {
            XCTAssertTrue(corpus.documents.contains { $0.lang == locale },
                          "no documents for shipped locale \(locale)")
            XCTAssertTrue(corpus.queries.contains { $0.lang == locale },
                          "no queries for shipped locale \(locale)")
        }
    }

    /// Each category has to be present in every language, or a per-language average silently compares
    /// different question mixes.
    func testEveryLanguageCoversEveryCategory() throws {
        let corpus = try loadedCorpus()
        for language in corpus.languages {
            let queries = corpus.queries.filter { $0.lang == language }
            for category in QueryCategory.allCases {
                XCTAssertFalse(queries.filter { $0.category == category }.isEmpty,
                               "\(language) has no \(category.rawValue) queries")
            }
        }
    }

    /// The `temporal` design: two documents that contradict each other, the newer graded 2 and the older
    /// graded 0. Without both halves present the category measures nothing.
    func testTemporalQueriesContrastANewerAndAnOlderDocument() throws {
        let corpus = try loadedCorpus()
        let documents = corpus.documentsByID
        for query in corpus.queries where query.category == .temporal {
            let winners = query.judgments.filter { $0.value > 0 }.keys.compactMap { documents[$0] }
            let losers = query.judgments.filter { $0.value == 0 }.keys.compactMap { documents[$0] }
            XCTAssertFalse(winners.isEmpty, "\(query.id) has no current answer")
            XCTAssertFalse(losers.isEmpty, "\(query.id) has no superseded answer to be fooled by")
            let newest = winners.map(\.ageDays).min() ?? .infinity
            let oldest = losers.map(\.ageDays).max() ?? 0
            XCTAssertLessThan(newest, oldest,
                              "\(query.id): the graded-relevant document must be NEWER than the distractor")
        }
    }

    /// The `exact` design: the question turns on a token the embedding may well miss — a number, a date, a
    /// unit. If none of the graded documents carries a digit the case is an ordinary paraphrase in disguise.
    func testExactQueriesTurnOnATokenThatCarriesADigit() throws {
        let corpus = try loadedCorpus()
        let documents = corpus.documentsByID
        for query in corpus.queries where query.category == .exact {
            let graded = query.judgments.filter { $0.value > 0 }.keys.compactMap { documents[$0] }
            XCTAssertTrue(graded.contains { $0.text.contains(where: \.isNumber) },
                          "\(query.id): no graded document carries a number or date")
        }
    }

    /// The flood that makes the diversity cap measurable: at least one conversation per language holds more
    /// documents than the per-group cap allows, all of them plausible answers to one question.
    func testEveryLanguageHasAConversationLargeEnoughToFloodTheContext() throws {
        let corpus = try loadedCorpus()
        for language in corpus.languages {
            let byConversation = Dictionary(grouping: corpus.documents.filter { $0.lang == language }) {
                $0.conversation ?? ""
            }
            let largest = byConversation.filter { !$0.key.isEmpty }.map(\.value.count).max() ?? 0
            XCTAssertGreaterThan(largest, maximumPerGroup,
                                 "\(language) has no thread big enough to test the per-conversation cap")
        }
    }

    /// Crosslingual cases are ordinary queries whose graded documents sit in another language. At least one
    /// has to exist, or the multilingual claim is untested.
    func testAtLeastOneQueryIsAnsweredByADocumentInAnotherLanguage() throws {
        let corpus = try loadedCorpus()
        let documents = corpus.documentsByID
        let crosslingual = corpus.queries.contains { query in
            query.judgments.filter { $0.value > 0 }.keys.contains { documents[$0]?.lang != query.lang }
        }
        XCTAssertTrue(crosslingual)
    }

    /// Long documents must actually chunk, or P4 — a candidate pool that collapses because many chunks share
    /// one source — cannot occur in the measurement even though it occurs in the app.
    func testTheCorpusContainsDocumentsThatChunkIntoSeveralPieces() throws {
        let corpus = try loadedCorpus()
        let multiChunk = corpus.documents.filter { MirroredChunker.chunks($0.text).count > 1 }
        XCTAssertFalse(multiChunk.isEmpty, "no document is long enough to produce more than one chunk")
    }
}
