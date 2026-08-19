import Foundation
import SemanticMemory

/// What a model needs to be asked correctly.
///
/// This table is the reason the two stages are split. Every one of these models will happily return a
/// vector for a bare string, and every one of them returns a WORSE vector for it: an asymmetric retrieval
/// model that never sees its query prefix, or a decoder-only model that never sees its instruction, is being
/// measured on a task it was not trained for. A comparison that skips this is not a comparison of the
/// models, it is a comparison of how well each tolerates being used wrongly.
///
/// `nomic` is transcribed from `NomicEmbeddingContract`, so the bench asks the shipped model exactly what
/// the app asks it.
struct EmbeddingContract {
    let id: String
    /// `%@` is replaced by the text.
    let queryTemplate: String
    let documentTemplate: String
    /// `mean` or `last` — passed to `llama-embedding --pooling`.
    let pooling: String
    /// The model's native output width.
    let fullDimensions: Int
    /// What the index would store. Equal to `fullDimensions` for models with no Matryoshka training, because
    /// truncating those is extrapolation rather than a supported mode.
    let storedDimensions: Int
    /// Whether truncating to `storedDimensions` is a trained, documented mode.
    let matryoshka: Bool
    /// Set when the model cannot be measured on the pinned runtime at all. Recorded, never worked around.
    let incomparable: String?

    func query(_ text: String) -> String { queryTemplate.replacingOccurrences(of: "%@", with: text) }
    func document(_ text: String) -> String { documentTemplate.replacingOccurrences(of: "%@", with: text) }
}

extension EmbeddingContract {
    /// The shipped model and contract. Any variant measured against this one must be measured through the
    /// same `SemanticVector.normalizedTruncated` and the same Float16 storage.
    static let nomic = EmbeddingContract(
        id: "nomic-embed-text-v2-moe",
        queryTemplate: NomicEmbeddingContract.queryPrefix + "%@",
        documentTemplate: NomicEmbeddingContract.documentPrefix + "%@",
        pooling: "mean",
        fullDimensions: 768,
        storedDimensions: NomicEmbeddingContract.outputDimensions,
        matryoshka: true,
        incomparable: nil
    )

    /// The same recipe as Nomic — mean pooling, asymmetric prefixes, trained Matryoshka at 256 — which is
    /// what makes it the one candidate that is a genuine drop-in rather than a new retrieval contract.
    static let embeddingGemma = EmbeddingContract(
        id: "embeddinggemma-300m",
        queryTemplate: "task: search result | query: %@",
        documentTemplate: "title: none | text: %@",
        pooling: "mean",
        fullDimensions: 768,
        storedDimensions: 256,
        matryoshka: true,
        incomparable: nil
    )

    /// Decoder-only, last-token pooling, instruction on the query only. No documented Matryoshka, so it is
    /// measured at its full 640 — which costs 2.5× the index bytes of the current 256 and is part of its
    /// price, not a detail to hide.
    static let harrier270m = EmbeddingContract(
        id: "harrier-oss-v1-270m",
        queryTemplate: "Instruct: Given a question about the user's own health, sleep and training notes, retrieve the notes that answer it\nQuery: %@",
        documentTemplate: "%@",
        pooling: "last",
        fullDimensions: 640,
        storedDimensions: 640,
        matryoshka: false,
        incomparable: nil
    )

    static let harrier06b = EmbeddingContract(
        id: "harrier-oss-v1-0.6b",
        queryTemplate: harrier270m.queryTemplate,
        documentTemplate: "%@",
        pooling: "last",
        fullDimensions: 1024,
        storedDimensions: 1024,
        matryoshka: false,
        incomparable: nil
    )

    /// The cheap control. If a 118M model is close on short personal facts, the interesting question stops
    /// being "which big model" and becomes "why are we carrying 328 MB".
    static let e5Small = EmbeddingContract(
        id: "multilingual-e5-small",
        queryTemplate: "query: %@",
        documentTemplate: "passage: %@",
        pooling: "mean",
        fullDimensions: 384,
        storedDimensions: 384,
        matryoshka: false,
        incomparable: nil
    )

    /// The reference ceiling, not a shipping candidate.
    static let qwen3 = EmbeddingContract(
        id: "qwen3-embedding-0.6b",
        queryTemplate: harrier270m.queryTemplate,
        documentTemplate: "%@",
        pooling: "last",
        fullDimensions: 1024,
        storedDimensions: 256,
        matryoshka: true,
        incomparable: nil
    )

    /// Ternary weights, but the published GGUF is `bf16-i2_s` at 367 MB / 428 MB — larger than the model it
    /// would replace — and the throughput claim needs bitnet.cpp's kernels. Running it would mean giving up
    /// the pinned official llama.cpp XCFramework, which is the property that makes the current supply chain
    /// verifiable.
    static let bitnet270m = EmbeddingContract(
        id: "bitnet-embedding-270m",
        queryTemplate: harrier270m.queryTemplate,
        documentTemplate: "%@",
        pooling: "last",
        fullDimensions: 640,
        storedDimensions: 640,
        matryoshka: false,
        incomparable: "i2_s is a bitnet.cpp quantisation; the pinned llama.cpp release does not carry its kernels, and the GGUF is not smaller than the incumbent."
    )

    /// Official GGUFs exist, but the nano tier needs Jina's own llama.cpp branch. Measuring it on a fork
    /// would measure a runtime the app cannot ship, so it is recorded as incomparable instead.
    static let jinaNano = EmbeddingContract(
        id: "jina-embeddings-v5-text-nano-retrieval",
        queryTemplate: "Query: %@",
        documentTemplate: "Document: %@",
        pooling: "last",
        fullDimensions: 768,
        storedDimensions: 256,
        matryoshka: true,
        incomparable: "The nano tier requires Jina's llama.cpp fork; the app ships a pinned upstream release artifact. Also CC BY-NC 4.0."
    )

    static let all: [EmbeddingContract] = [
        .nomic, .embeddingGemma, .harrier270m, .harrier06b, .e5Small, .qwen3, .bitnet270m, .jinaNano,
    ]

    static func named(_ id: String) -> EmbeddingContract? {
        all.first { $0.id == id }
    }
}
