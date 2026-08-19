import Foundation
import SemanticMemory

/// Deterministic stand-in vectors: a hashed bag of tokens, L2-normalised and stored through the app's own
/// Float16 encoding.
///
/// This is NOT a model and must never appear in a model comparison. It exists for two jobs the real thing
/// cannot do:
///
///  * CI. The scoring path — index, Float16 round trip, cosine scan, every selection variant, every metric —
///    is exercised on the committed corpus on every change, with no 328 MB model and no device. A `score`
///    run that crashes or silently drops queries is caught here rather than by whoever next borrows a Mac
///    and a GGUF.
///  * Development. `score --synthetic` prints the whole report immediately, so the tables and the ablation
///    ladder can be worked on without an embedding run in the loop.
///
/// It has just enough retrieval signal to be non-degenerate (exact token overlap survives hashing) and
/// deliberately no semantic signal at all: paraphrases score near zero. That asymmetry is the honest shape
/// of the thing — it is a keyword baseline wearing a vector's clothes, which makes it a useful floor and a
/// useless ceiling.
enum SyntheticVectors {
    static func build(for corpus: Corpus, dimensions: Int = 256) -> VectorSet {
        var documents: [String: [Float]] = [:]
        var documentIDs: [String] = []
        for document in corpus.documents {
            for (index, chunk) in MirroredChunker.chunks(document.text).enumerated() {
                let id = chunkID(document.id, index)
                documentIDs.append(id)
                documents[id] = vector(for: chunk, dimensions: dimensions)
            }
        }
        var queries: [String: [Float]] = [:]
        for query in corpus.queries {
            queries[query.id] = vector(for: query.text, dimensions: dimensions)
        }
        let meta = VectorSetMeta(model: "synthetic-hashed-tokens (NOT a model)",
                                 pooling: "none",
                                 queryTemplate: "%@",
                                 documentTemplate: "%@",
                                 fullDimensions: dimensions,
                                 storedDimensions: dimensions,
                                 matryoshka: false,
                                 documentIDs: documentIDs,
                                 queryIDs: corpus.queries.map(\.id),
                                 embedMilliseconds: 0,
                                 embeddedTexts: documentIDs.count + corpus.queries.count)
        return VectorSet(meta: meta, documents: documents, queries: queries)
    }

    /// A token is hashed to a dimension with the same platform-neutral FNV-1a the index uses for content
    /// hashes, so the result is identical on every machine and every run.
    private static func vector(for text: String, dimensions: Int) -> [Float] {
        var values = [Float](repeating: 0, count: dimensions)
        let tokens = NumericAwareTokeniser.tokens(text)
        for token in tokens {
            let hex = SemanticHash.fnv1a64Hex(token)
            // The low 32 bits are plenty of spread and fit an Int on every platform.
            let bucket = Int(UInt32(hex.suffix(8), radix: 16) ?? 0) % dimensions
            values[bucket] += 1
        }
        // An empty token set (a query of nothing but stopwords) would be an un-normalisable zero vector, and
        // the store would then reject it. One fixed non-zero component keeps it well-formed and orthogonal to
        // essentially everything, which is the right answer for a query that says nothing.
        if tokens.isEmpty { values[0] = 1 }
        return (try? SemanticVector.normalizedTruncated(values, dimensions: dimensions)) ?? values
    }
}
