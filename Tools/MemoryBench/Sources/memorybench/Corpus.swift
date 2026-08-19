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
    /// Which index this document lives in.
    ///
    /// The unit of realism. A person has ONE index, holding their own notes in the language or two they
    /// actually write in — not nine translations of the same fact, which is what the first version of this
    /// corpus accidentally measured. `main` is the large German-dominant index with real English memories
    /// mixed in at roughly one in ten, and each `locale-<lang>` is a small set that only answers "does this
    /// model work in this language at all". Defaults to `locale-<lang>` so the older per-locale files need no
    /// edit.
    private let indexName: String?
    var index: String { indexName ?? "locale-\(lang)" }
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

    enum CodingKeys: String, CodingKey {
        case id, lang, kind, scope, priority, ageDays, conversation, text
        case indexName = "index"
    }

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

/// What a query is testing. Each is scored separately, because a variant that helps one and wrecks another
/// is not an improvement and a single global average would hide the trade.
///
/// The first version of this corpus had four of these. The split below is finer because the coarse ones were
/// hiding exactly the trades that matter: `paraphrase` was carrying synonyms, negation AND terse questions,
/// which fail for different reasons and are fixed by different things.
enum QueryCategory: String, Codable, CaseIterable {
    /// A different word for the same thing. The semantic arm's core competence and the reason an embedding
    /// model is bundled at all.
    case synonym
    /// A rephrasing that keeps the vocabulary but changes the sentence. Easier than `synonym` and worth
    /// separating: a model can be good at one and weak at the other.
    case paraphrase
    /// The question turns on a NOT. Embeddings are notoriously weak here — "which supplement did I stop"
    /// sits very close to "which supplement do I take" in most spaces — and nothing in the current pipeline
    /// addresses it.
    case negation
    /// A name, a date, a number, a dose. What the two rescue slots were kept for, and what the shipped
    /// tokeniser cannot see: it discards runs under three characters, so `42`, `8h` and the day and month of
    /// an ISO date all vanish.
    case numeric
    /// Two or more memories contradict each other and the NEWER one is right. The recency term either earns
    /// its place here or nowhere.
    case recency
    /// Several memories are almost the same sentence and only one answers the question — a different knee, a
    /// different dose, a different time of day. This is the category a large index makes possible and a small
    /// one cannot express, and the one a reranker should be best at.
    case nearMiss = "near-miss"
    /// Three or four words, the way people actually type into a chat box. Short queries carry little signal
    /// for either arm and are the most common shape in a real transcript.
    case terse
    /// Nothing in the index answers this. The target is ZERO emitted lines, and it is the only category that
    /// measures restraint rather than reach.
    case unanswerable

    /// Whether nDCG is defined for the category. `unanswerable` has no ideal ranking, so it is scored by how
    /// many lines the pipeline emitted instead.
    var isAnswerable: Bool { self != .unanswerable }
}

struct CorpusQuery: Codable {
    let id: String
    let lang: String
    /// The index this question is asked against; defaults to the query's own locale set.
    private let indexName: String?
    var index: String { indexName ?? "locale-\(lang)" }
    let category: QueryCategory
    let text: String
    /// Source id → grade (2 = the document the question is about, 1 = worth having in context, 0 = judged
    /// and rejected). A `crosslingual` case is an ordinary query whose graded documents are in another
    /// language; it needs no category of its own, only a judgment pointing across.
    let judgments: [String: Int]

    enum CodingKeys: String, CodingKey {
        case id, lang, category, text, judgments
        case indexName = "index"
    }
}

struct Corpus {
    let documents: [CorpusDocument]
    let queries: [CorpusQuery]

    var documentsByID: [String: CorpusDocument] {
        Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var languages: [String] { Array(Set(documents.map(\.lang))).sorted() }

    /// Indexes, largest first — the unit a question is asked against.
    var indexes: [String] {
        let counts = documents.reduce(into: [String: Int]()) { $0[$1.index, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

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
            if !query.category.isAnswerable && relevant {
                problems.append("\(query.id): unanswerable query has a relevant judgment")
            }
            if query.category.isAnswerable && !relevant {
                problems.append("\(query.id): \(query.category.rawValue) query has no relevant judgment")
            }
            // A judgment pointing outside the query's own index is unreachable: the search will never see
            // that document, so the query would score zero for a reason that has nothing to do with ranking.
            for judged in query.judgments.keys where query.judgments[judged]! > 0 {
                if let document = documents.first(where: { $0.id == judged }), document.index != query.index {
                    problems.append("\(query.id): graded \(judged) lives in index \(document.index), "
                        + "not \(query.index)")
                }
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
