import Foundation
import SemanticMemory

/// Drives the pinned llama.cpp's own `llama-embedding` binary over the corpus and writes a vectors set.
///
/// It shells out rather than linking a runtime on purpose. The app's llama.cpp arrives as a verified,
/// SHA-pinned iOS-only XCFramework (`Tools/bootstrap-nomic.sh`), so there is nothing for a macOS executable
/// to link against — and building a second, differently-configured copy of the runtime just for the bench
/// would mean the benchmark measures a runtime the product does not have. Pointing at a binary built from
/// the pinned tag keeps one runtime in the picture.
///
/// Nothing here is normalised by llama.cpp: `--embd-normalize -1` asks for the raw pooled vector, and
/// `SemanticVector.normalizedTruncated` then does truncate-then-renormalise exactly as
/// `NomicTextEmbeddingProvider.embedOne` does. That way the Matryoshka step under test is the app's step.
struct Embedder {
    let binary: URL
    let model: URL
    let contract: EmbeddingContract
    /// Extra arguments passed through verbatim, for a model that needs a flag this tool does not know about.
    let extraArguments: [String]
    let batchSize: Int
    /// Prompt separator handed to `--embd-separator`. Must not occur in any prompt — the default is a
    /// control character, because a query template can legitimately contain a newline (every decoder-only
    /// candidate's instruction does) and the default newline separator would silently split it into two
    /// prompts and shift every subsequent vector onto the wrong text.
    let separator: String

    init(binary: URL,
         model: URL,
         contract: EmbeddingContract,
         extraArguments: [String] = [],
         batchSize: Int = 32,
         separator: String = "\u{1}") {
        self.binary = binary
        self.model = model
        self.contract = contract
        self.extraArguments = extraArguments
        self.batchSize = batchSize
        self.separator = separator
    }

    /// Raw pooled vectors for `texts`, in order.
    func embed(_ texts: [String]) throws -> [[Float]] {
        var result: [[Float]] = []
        result.reserveCapacity(texts.count)
        var index = 0
        while index < texts.count {
            let end = min(texts.count, index + batchSize)
            let batch = Array(texts[index..<end])
            result += try runBatch(batch)
            index = end
            FileHandle.standardError.write(Data("  embedded \(result.count)/\(texts.count)\r".utf8))
        }
        FileHandle.standardError.write(Data("\n".utf8))
        return result
    }

    private func runBatch(_ texts: [String]) throws -> [[Float]] {
        for text in texts where text.contains(separator) {
            throw VectorError.tooling("A prompt contains the separator byte; pass a different --separator.")
        }
        let promptFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorybench-\(UUID().uuidString).txt")
        try texts.joined(separator: separator).write(to: promptFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: promptFile) }

        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "-m", model.path,
            "-f", promptFile.path,
            "--pooling", contract.pooling,
            "--embd-normalize", "-1",
            "--embd-output-format", "json",
            "--embd-separator", separator,
            // 512 matches `NomicEmbeddingContract.modelMaximumTokens` and the app's context/batch setting.
            // A model with a larger window is still asked for the same window: the app would not give it one.
            "-c", "512",
            "-b", "512",
            "-ub", "512",
            "--no-warmup",
        ] + extraArguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Drained before `waitUntilExit`: a full pipe buffer deadlocks the child, and a 32-prompt batch of
        // 768 floats in JSON is comfortably larger than the buffer.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VectorError.tooling("""
                llama-embedding exited \(process.terminationStatus).
                \(String(data: errorData, encoding: .utf8) ?? "")
                """)
        }
        return try parse(data, expected: texts.count)
    }

    /// `--embd-output-format json` yields an OpenAI-shaped envelope. Parsed defensively because a wrong
    /// `--pooling` produces token-level embeddings (an array of arrays) rather than one vector per prompt,
    /// and that has to fail loudly instead of scoring the first token of each text.
    private func parse(_ data: Data, expected: Int) throws -> [[Float]] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]]
        else {
            throw VectorError.malformed("llama-embedding did not return a JSON embedding list")
        }
        guard entries.count == expected else {
            throw VectorError.malformed("asked for \(expected) embeddings, received \(entries.count)")
        }
        var result: [[Float]] = []
        for entry in entries {
            guard let numbers = entry["embedding"] as? [Any] else {
                throw VectorError.malformed("an entry carried no embedding")
            }
            if numbers.first is [Any] {
                throw VectorError.malformed(
                    "token-level embeddings received — check --pooling for \(contract.id)"
                )
            }
            let vector = numbers.compactMap { ($0 as? NSNumber)?.floatValue }
            guard vector.count == numbers.count else {
                throw VectorError.malformed("an embedding carried a non-numeric component")
            }
            guard vector.count == contract.fullDimensions else {
                throw VectorError.malformed(
                    "\(contract.id) returned \(vector.count) dimensions, contract says \(contract.fullDimensions)"
                )
            }
            result.append(vector)
        }
        return result
    }
}

/// Embeds the whole corpus for one model and writes the vectors set.
func runEmbed(corpus: Corpus,
              contract: EmbeddingContract,
              embedder: Embedder,
              output: URL) throws {
    if let reason = contract.incomparable {
        FileHandle.standardError.write(Data("""
            WARNING: \(contract.id) is recorded as not comparable on the pinned runtime.
              \(reason)
            Proceeding only because you asked explicitly; do not put this row in a comparison table.

            """.utf8))
    }

    // Documents are chunked first, exactly as the app chunks them, so a long summary produces the several
    // candidates it produces in production.
    var documentTexts: [(id: String, text: String)] = []
    for document in corpus.documents {
        for (index, chunk) in MirroredChunker.chunks(document.text).enumerated() {
            documentTexts.append((chunkID(document.id, index), chunk))
        }
    }
    let queryTexts = corpus.queries.map { (id: $0.id, text: $0.text) }

    let started = Date()
    let rawDocuments = try embedder.embed(documentTexts.map { contract.document($0.text) })
    let rawQueries = try embedder.embed(queryTexts.map { contract.query($0.text) })
    let elapsed = Date().timeIntervalSince(started) * 1000

    var documents: [String: [Float]] = [:]
    for (entry, raw) in zip(documentTexts, rawDocuments) {
        documents[entry.id] = try SemanticVector.normalizedTruncated(raw, dimensions: contract.storedDimensions)
    }
    var queries: [String: [Float]] = [:]
    for (entry, raw) in zip(queryTexts, rawQueries) {
        queries[entry.id] = try SemanticVector.normalizedTruncated(raw, dimensions: contract.storedDimensions)
    }

    let meta = VectorSetMeta(model: contract.id,
                             pooling: contract.pooling,
                             queryTemplate: contract.queryTemplate,
                             documentTemplate: contract.documentTemplate,
                             fullDimensions: contract.fullDimensions,
                             storedDimensions: contract.storedDimensions,
                             matryoshka: contract.matryoshka,
                             documentIDs: documentTexts.map(\.id),
                             queryIDs: queryTexts.map(\.id),
                             embedMilliseconds: elapsed,
                             embeddedTexts: documentTexts.count + queryTexts.count)
    try VectorSet.write(directory: output, meta: meta, documents: documents, queries: queries)
    print("""
        wrote \(documentTexts.count) document and \(queryTexts.count) query vectors for \(contract.id)
          \(contract.storedDimensions) dimensions\(contract.matryoshka ? "" : " (no Matryoshka — full width)")
          index bytes for this corpus: \(documentTexts.count * contract.storedDimensions * 2)
          embedding wall clock: \(Int(elapsed)) ms
          → \(output.path)
        """)
}
