import Foundation
import SemanticMemory

// The trivial-pair check: the difference between measuring a model and reporting quantisation damage as
// model quality. `multilingual-e5-small`'s Q4_K_M quant scored an off-topic passage above the correct one for
// a magnesium query (0.9367 against 0.9303) while producing a plausible-looking nDCG@8 of 0.187 — a broken
// artifact, not a weak model, and nothing in the retrieval metrics alone would have said so. This was run by
// hand with `curl` against every model in this file's history; it is now enforced by `embed` itself instead
// of being a rule someone has to remember to follow.

/// One question with a document that answers it and one that plainly does not.
///
/// Free-standing text, not corpus documents: the check has to work identically whether or not `Corpus/` is
/// even present, and it has to survive corpus edits without silently going stale.
struct SanityPair {
    let id: String
    let query: String
    let correct: String
    let wrong: String
}

extension SanityPair {
    /// Three pairs, deliberately not more: this is a five-second sniff test before an expensive corpus run,
    /// not a benchmark. Each texts the retrieval contract from a different angle — a paraphrase, an exact
    /// number pinned to a wrong-but-plausible sibling, and a check that the German-only pairs above are not
    /// hiding an English-specific failure.
    static let all: [SanityPair] = [
        SanityPair(
            id: "supplement-timing",
            query: "Magnesium vor dem Schlafengehen",
            correct: "Bestätigte Erinnerung: Magnesium etwa eine Stunde vor dem Schlafengehen hilft mir beim Einschlafen.",
            wrong: "Wie wechsle ich den Ölfilter an einem Dieselmotor?"
        ),
        SanityPair(
            id: "exact-date-value",
            query: "Wie hoch war mein Ferritin am 2026-03-14?",
            correct: "Bestätigte Erinnerung: Ferritin lag im Blutbild vom 2026-03-14 bei 42.",
            wrong: "Bestätigte Erinnerung: ich nehme im Winter jeden Morgen 2000 IE Vitamin D."
        ),
        SanityPair(
            id: "english-injury",
            query: "What did the physio say about my knee?",
            correct: "Confirmed memory: the physio in London called it patellar tendon overload, not a meniscus problem.",
            wrong: "Confirmed memory: on long rides I need electrolytes, plain water alone gives me cramps after two hours."
        ),
    ]

    /// The three vector-set keys one pair needs, in the shape `runSanityCheck` writes and `evaluate` reads.
    var keys: (query: String, correct: String, wrong: String) {
        ("\(id)#query", "\(id)#correct", "\(id)#wrong")
    }
}

struct SanityCheckResult {
    let pair: SanityPair
    let correctScore: Double
    let wrongScore: Double

    var passed: Bool { correctScore > wrongScore }
}

enum SanityCheck {
    /// Pure: scores each pair from already-embedded vectors. No model, no network — this is the half of the
    /// check that `SanityCheckTests` pins directly, on hand-built vectors, the same way every other pure
    /// scoring function in this tool is tested.
    static func evaluate(_ pairs: [SanityPair], vectors: [String: [Float]]) throws -> [SanityCheckResult] {
        try pairs.map { pair in
            let keys = pair.keys
            guard let query = vectors[keys.query], let correct = vectors[keys.correct],
                  let wrong = vectors[keys.wrong]
            else {
                throw VectorError.missing("sanity pair '\(pair.id)' is missing a vector")
            }
            return SanityCheckResult(pair: pair,
                                     correctScore: SemanticVector.cosine(query, correct),
                                     wrongScore: SemanticVector.cosine(query, wrong))
        }
    }
}

/// Embeds `SanityPair.all` through THIS model's own contract — its own query/document templates, its own
/// pooling, the app's own truncate-renormalise-Float16 path — and scores them. This is the impure half:
/// it needs a live model, so it is exercised only by a real `embed` run, never by `swift test`.
///
/// Deliberately goes through `contract.query`/`contract.document`, not the raw pair text: a model measured
/// without its own prefix or instruction is being asked a question it was not trained to answer, which is
/// the same mistake this whole two-stage design exists to avoid — see `EmbeddingContract`'s own doc comment.
func runSanityCheck(contract: EmbeddingContract, embedder: Embedder) throws -> [SanityCheckResult] {
    let pairs = SanityPair.all
    var texts: [(key: String, text: String)] = []
    for pair in pairs {
        let keys = pair.keys
        texts.append((keys.query, contract.query(pair.query)))
        texts.append((keys.correct, contract.document(pair.correct)))
        texts.append((keys.wrong, contract.document(pair.wrong)))
    }
    let raw = try embedder.embed(texts.map(\.text))
    var vectors: [String: [Float]] = [:]
    for (entry, vector) in zip(texts, raw) {
        vectors[entry.key] = try SemanticVector.normalizedTruncated(vector, dimensions: contract.storedDimensions)
    }
    return try SanityCheck.evaluate(pairs, vectors: vectors)
}
