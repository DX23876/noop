#if os(iOS)
import Foundation
import SemanticMemory
import llama

struct NomicRetrievalSelfTestResult: Sendable {
    let semanticCorrect: Int
    let keywordCorrect: Int
    let total: Int
    let exactQueriesPreserved: Bool

    var passed: Bool {
        semanticCorrect > keywordCorrect && exactQueriesPreserved
    }
}

/// On-device Nomic Embed v2 adapter. Loading is explicit: constructing the provider does not touch the
/// 328 MB GGUF, so ordinary launches pay no memory cost. The coordinator prewarms it only when Coach is
/// opened or a background-processing lease is delivered by iOS.
actor NomicTextEmbeddingProvider: TextEmbeddingProvider {
    static let bundledFilename = "nomic-embed-text-v2-moe.Q4_K_M"
    static let bundledExtension = "gguf"
    static let pinnedRevision = "ffbcf4c99e5d617dda10ec8c0e9f75754b0cbb80"

    nonisolated let modelID = "nomic-embed-text-v2-moe-q4_k_m@\(pinnedRevision)"
    nonisolated let dimensions = NomicEmbeddingContract.outputDimensions

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var idleUnloadTask: Task<Void, Never>?
    private let modelURL: URL
    private let maximumInputTokens = NomicEmbeddingContract.maximumInputTokens

    private static let initializeBackend: Void = {
        llama_backend_init()
    }()

    init(modelURL: URL? = Bundle.main.url(forResource: bundledFilename,
                                           withExtension: bundledExtension)) {
        self.modelURL = modelURL ?? URL(fileURLWithPath: "/missing-nomic-model")
    }

    deinit {
        idleUnloadTask?.cancel()
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    func prepare() async throws {
        idleUnloadTask?.cancel()
        if model != nil, context != nil {
            scheduleIdleUnload()
            return
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw SemanticMemoryError.modelUnavailable(
                "The bundled Nomic model is missing. Run Tools/bootstrap-nomic.sh before xcodegen."
            )
        }

        _ = Self.initializeBackend
        var modelParameters = llama_model_default_params()
        #if targetEnvironment(simulator)
        // CoreSimulator's synthetic Metal device currently produces incorrect Nomic BERT-MoE
        // embeddings even though the same pinned runtime is correct on Apple-silicon Metal.
        // Simulator tests therefore use the CPU backend; physical iOS devices retain full Metal
        // offload below.
        modelParameters.n_gpu_layers = 0
        #else
        modelParameters.n_gpu_layers = -1
        #endif
        modelParameters.use_mmap = true
        modelParameters.use_mlock = false

        let loadedModel = modelURL.path.withCString {
            llama_model_load_from_file($0, modelParameters)
        }
        guard let loadedModel else {
            throw SemanticMemoryError.modelUnavailable("Nomic could not be loaded from the app bundle.")
        }
        // llama.cpp currently exposes the Nomic BERT-MoE architecture through its
        // decoder capability flag even though inference itself uses llama_encode().
        guard llama_model_has_decoder(loadedModel) else {
            llama_model_free(loadedModel)
            throw SemanticMemoryError.modelUnavailable(
                "The pinned Nomic model is not exposed as an embedding model by this llama.cpp runtime."
            )
        }

        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(NomicEmbeddingContract.modelMaximumTokens)
        contextParameters.n_batch = UInt32(NomicEmbeddingContract.modelMaximumTokens)
        contextParameters.n_ubatch = UInt32(NomicEmbeddingContract.modelMaximumTokens)
        contextParameters.n_seq_max = 1
        contextParameters.embeddings = true
        contextParameters.pooling_type = LLAMA_POOLING_TYPE_MEAN
        contextParameters.attention_type = LLAMA_ATTENTION_TYPE_NON_CAUSAL
        let threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)))
        contextParameters.n_threads = threads
        contextParameters.n_threads_batch = threads

        guard let loadedContext = llama_init_from_model(loadedModel, contextParameters) else {
            llama_model_free(loadedModel)
            throw SemanticMemoryError.modelUnavailable("Nomic loaded, but its embedding context failed.")
        }
        model = loadedModel
        context = loadedContext
        scheduleIdleUnload()
    }

    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        try await prepare()
        var result: [[Float]] = []
        result.reserveCapacity(texts.count)
        for text in texts {
            try Task.checkCancellation()
            result.append(try embedOne(NomicEmbeddingContract.documentText(text)))
        }
        scheduleIdleUnload()
        return result
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        try await prepare()
        let result = try embedOne(NomicEmbeddingContract.queryText(text))
        scheduleIdleUnload()
        return result
    }

    func unload() async {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        if let context {
            llama_free(context)
            self.context = nil
        }
        if let model {
            llama_model_free(model)
            self.model = nil
        }
    }

    func isLoaded() -> Bool {
        model != nil && context != nil
    }

    /// Fixed multilingual smoke/evaluation corpus for the real bundled model. It covers paraphrases,
    /// synonyms, negation and ambiguous health vocabulary, then checks that exact-name retrieval has
    /// not regressed. This intentionally runs only from the Expert settings action or device tests.
    func runRetrievalSelfTest() async throws -> NomicRetrievalSelfTestResult {
        let documents = [
            "Am Wochenende lehne ich Joggen meistens ab.",
            "Magnesium vor dem Schlafengehen scheint meine Abendroutine zu unterstützen.",
            "Koffein am späten Nachmittag macht das Einschlafen schwieriger.",
            "Mein linkes Knie fühlt sich nach schnellen Läufen gereizt an.",
            "Nach einem lockeren Radtraining fühle ich mich am nächsten Morgen erholt.",
            "CBD-Öl wurde am Freitag nicht verwendet.",
        ]
        let cases: [(query: String, expected: Int)] = [
            ("Samstags möchte ich normalerweise nicht laufen.", 0),
            ("Hilft mir Mg am Abend bei meiner Nachtroutine?", 1),
            ("Später Kaffee hält mich nachts wach.", 2),
            ("Beschwerden im linken Gelenk nach Tempoeinheiten", 3),
            ("Welche sanfte Einheit ging guter Regeneration voraus?", 4),
            ("Habe ich Cannabidiol am Freitag ausgelassen?", 5),
        ]
        let exactCases: [(query: String, expected: Int)] = [
            ("Magnesium vor dem Schlafengehen", 1),
            ("linkes Knie schnelle Läufe", 3),
        ]

        let documentVectors = try await embedDocuments(documents)
        func topIndex(for vector: [Float]) -> Int? {
            documentVectors.enumerated().max {
                SemanticVector.cosine(vector, $0.element)
                    < SemanticVector.cosine(vector, $1.element)
            }?.offset
        }
        func keywordTop(_ query: String) -> Int? {
            let queryTokens = Self.simpleTokens(query)
            var bestIndex: Int?
            var bestScore = 0
            for (index, document) in documents.enumerated() {
                let tokens = Self.simpleTokens(document)
                let score = tokens.intersection(queryTokens).count
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }
            return bestIndex
        }

        var semanticCorrect = 0
        var keywordCorrect = 0
        for item in cases {
            let semanticTop = topIndex(for: try await embedQuery(item.query))
            let keywordTop = keywordTop(item.query)
            if semanticTop == item.expected {
                semanticCorrect += 1
            }
            if keywordTop == item.expected { keywordCorrect += 1 }
        }
        var exactPreserved = true
        for item in exactCases {
            let semantic = topIndex(for: try await embedQuery(item.query))
            let keyword = keywordTop(item.query)
            if semantic != item.expected || keyword != item.expected {
                exactPreserved = false
            }
        }
        return NomicRetrievalSelfTestResult(semanticCorrect: semanticCorrect,
                                            keywordCorrect: keywordCorrect,
                                            total: cases.count,
                                            exactQueriesPreserved: exactPreserved)
    }

    private func embedOne(_ text: String) throws -> [Float] {
        guard let model, let context else {
            throw SemanticMemoryError.modelUnavailable("Nomic is not loaded.")
        }
        let tokens = try tokenize(text)

        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }
        batch.n_tokens = Int32(tokens.count)
        for index in tokens.indices {
            batch.token[index] = tokens[index]
            batch.pos[index] = Int32(index)
            batch.n_seq_id[index] = 1
            batch.seq_id[index]?[0] = 0
            batch.logits[index] = 1
        }
        let inferenceResult = llama_encode(context, batch)
        guard inferenceResult == 0,
              let embeddingPointer = llama_get_embeddings_seq(context, 0)
        else {
            throw SemanticMemoryError.invalidVector
        }

        let fullDimensions = Int(llama_model_n_embd(model))
        let raw = Array(UnsafeBufferPointer(start: embeddingPointer, count: fullDimensions))
        return try SemanticVector.normalizedTruncated(
            raw,
            dimensions: dimensions
        )
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        guard let model else {
            throw SemanticMemoryError.modelUnavailable("Nomic is not loaded.")
        }
        let vocabulary = llama_model_get_vocab(model)
        let byteCount = Int32(text.utf8.count)
        let required = text.withCString {
            llama_tokenize(vocabulary, $0, byteCount, nil, 0, true, false)
        }
        guard required != Int32.min else { throw SemanticMemoryError.invalidVector }
        let capacity = required < 0 ? -required : max(required, 1)
        var tokens = Array(repeating: llama_token(0), count: Int(capacity))
        let tokenCount = text.withCString { pointer in
            tokens.withUnsafeMutableBufferPointer { buffer in
                llama_tokenize(vocabulary, pointer, byteCount, buffer.baseAddress,
                               Int32(buffer.count), true, false)
            }
        }
        guard tokenCount > 0 else { throw SemanticMemoryError.invalidVector }
        tokens.removeSubrange(Int(tokenCount)..<tokens.count)
        if tokens.count > maximumInputTokens {
            // Match tokenizer truncation semantics: retain both boundary tokens. A raw prefix cut
            // would discard XLM-R's closing </s> token for long input.
            let closingToken = tokens.last!
            tokens = Array(tokens.prefix(maximumInputTokens - 1))
            tokens.append(closingToken)
        }
        return tokens
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    private nonisolated static func simpleTokens(_ text: String) -> Set<String> {
        Set(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 })
    }
}
#endif
