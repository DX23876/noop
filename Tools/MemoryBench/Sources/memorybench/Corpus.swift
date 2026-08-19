import Foundation
import SemanticMemory

// The corpus: synthetic personal memories and the questions they should answer.
//
// Committed, because a benchmark nobody can re-run is the situation this tool exists to end. Synthetic,
// because the real thing is a wearer's health history and has no business in a git repository. Written to
// LOOK like the real index rather than like a clean evaluation set: a mix of curated facts and raw chat
// turns, short sentences and long summaries, recent and stale, across every shipped locale.

struct CorpusDocument: Codable {
    let id: String
    let lang: String
    /// Must parse as a `SemanticSourceKind`; validated at load so a typo fails loudly rather than
    /// silently dropping a document out of the run.
    let kind: String
    let scope: String
    let priority: Int
    /// Age in days, relative to the moment the bench runs.
    ///
    /// Relative rather than an absolute date so the corpus cannot go stale: the recency ablations need
    /// real age deltas, and a committed `2026-08-19` would quietly turn every "recent" document into an
    /// old one a year from now, changing the benchmark's answer without anyone editing it.
    let ageDays: Double
    /// Present only for `userMessage` / `conversationSummary` / `conversationTitle` documents. Two
    /// documents sharing a `conversation` belong to one thread, which is what the per-conversation cap in
    /// the proposed selection is measured against.
    let conversation: String?
    let text: String

    var sourceKind: SemanticSourceKind? { SemanticSourceKind(rawValue: kind) }
    var consentScope: SemanticConsentScope? { SemanticConsentScope(rawValue: scope) }

    /// The group a diversity cap applies to: the thread for conversation-derived text, otherwise the
    /// document's own kind.
    var diversityGroup: String { conversation ?? kind }

    func updatedAt(now: Date) -> Date { now.addingTimeInterval(-ageDays * 86_400) }

    /// The document as the app would build it. `chunkIndex` is 0 here and the chunker is applied
    /// separately in `Score`, so the long-summary documents genuinely produce several chunks and P4 can
    /// actually occur in the measurement.
    func semanticDocument(now: Date) -> SemanticDocument? {
        guard let sourceKind, let consentScope else { return nil }
        return SemanticDocument(sourceKind: sourceKind,
                                sourceID: id,
                                text: text,
                                updatedAt: updatedAt(now: now),
                                consentScope: consentScope,
                                priority: priority)
    }
}

/// The four things a query can be testing. Each is scored separately, because a variant that helps one
/// and wrecks another is not an improvement and a single global average would hide the trade.
enum QueryCategory: String, Codable, CaseIterable {
    /// Synonym, rephrasing, negation — the semantic arm's core competence and the reason Nomic is bundled.
    case paraphrase
    /// A name, a date, a number, a supplement brand. The case the two rescue slots were explicitly kept
    /// for, and the one the current tokeniser cannot reach (it discards runs under three characters, so
    /// "42", "8h" and the day and month of an ISO date all vanish).
    case exact
    /// Two documents contradict each other and the NEWER one is right. The current semantic ranking has no
    /// notion of time at all, so this category is where a recency term either earns its place or does not.
    case temporal
    /// Nothing in the corpus answers this. The target is ZERO emitted lines. The keyword ranker already
    /// declines to answer here on principle ("a ranking is not a reason to disclose"); the semantic arm
    /// has no equivalent floor and fills all eight slots regardless.
    case irrelevant
}

struct CorpusQuery: Codable {
    let id: String
    let lang: String
    let category: QueryCategory
    let text: String
    /// Source id → grade (2 = the document the question is about, 1 = worth having in context, 0 = judged
    /// and rejected). A `crosslingual` case is an ordinary query whose graded documents are in another
    /// language; it needs no category of its own, only a judgment pointing across.
    let judgments: [String: Int]

    var isCrosslingual: Bool { false }
}

struct Corpus {
    let documents: [CorpusDocument]
    let queries: [CorpusQuery]

    var documentsByID: [String: CorpusDocument] {
        Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var languages: [String] { Array(Set(documents.map(\.lang))).sorted() }

    /// Loads every `<lang>.documents.json` / `<lang>.queries.json` pair in a directory and rejects anything
    /// that cannot be scored.
    ///
    /// One file pair per locale, rather than two big ones, because that is how the corpus is actually
    /// maintained: adding a language is adding two files, and a reviewer who reads Polish can review the
    /// Polish file without scrolling past nine others. Every failure below is a hard error — a benchmark
    /// that silently skips half its queries reports a number that means nothing.
    static func load(directory: URL) throws -> Corpus {
        struct DocumentFile: Codable { let version: Int; let documents: [CorpusDocument] }
        struct QueryFile: Codable { let version: Int; let queries: [CorpusQuery] }

        let decoder = JSONDecoder()
        let entries = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .sorted()
        var documents: [CorpusDocument] = []
        var queries: [CorpusQuery] = []
        for name in entries where name.hasSuffix(".documents.json") {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            documents += try decoder.decode(DocumentFile.self, from: data).documents
        }
        for name in entries where name.hasSuffix(".queries.json") {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            queries += try decoder.decode(QueryFile.self, from: data).queries
        }
        guard !documents.isEmpty, !queries.isEmpty else {
            throw CorpusError.invalid([
                "no <lang>.documents.json / <lang>.queries.json pairs found in \(directory.path)",
            ])
        }

        var problems: [String] = []
        var seen = Set<String>()
        for document in documents {
            if !seen.insert(document.id).inserted { problems.append("duplicate document id \(document.id)") }
            if document.sourceKind == nil { problems.append("\(document.id): unknown kind \(document.kind)") }
            if document.consentScope == nil { problems.append("\(document.id): unknown scope \(document.scope)") }
            if document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append("\(document.id): empty text")
            }
        }
        let ids = Set(documents.map(\.id))
        var queryIDs = Set<String>()
        for query in queries {
            if !queryIDs.insert(query.id).inserted { problems.append("duplicate query id \(query.id)") }
            for judged in query.judgments.keys where !ids.contains(judged) {
                problems.append("\(query.id): judgment references unknown document \(judged)")
            }
            let relevant = query.judgments.values.contains { $0 > 0 }
            // The two halves of the same rule: an `irrelevant` query with a relevant document is not
            // irrelevant, and any other query without one can never be scored.
            if query.category == .irrelevant && relevant {
                problems.append("\(query.id): irrelevant query has a relevant judgment")
            }
            if query.category != .irrelevant && !relevant {
                problems.append("\(query.id): \(query.category.rawValue) query has no relevant judgment")
            }
        }
        guard problems.isEmpty else {
            throw CorpusError.invalid(problems)
        }
        return Corpus(documents: documents, queries: queries)
    }
}

enum CorpusError: LocalizedError {
    case invalid([String])

    var errorDescription: String? {
        switch self {
        case let .invalid(problems):
            return "The corpus is not scoreable:\n  - " + problems.joined(separator: "\n  - ")
        }
    }
}
