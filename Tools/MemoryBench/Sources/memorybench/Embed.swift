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
    ///
    /// Batching is a throughput guess, and the guess is model-dependent in ways this tool cannot know up
    /// front: n_batch has to cover the sum of a batch's tokens, n_batch may not exceed n_ctx, and some models
    /// object to an n_ctx above what they were trained on. Every one of those tripped in turn here —
    /// `-b 512` truncated harrier's Chinese batch, raising only `-b` aborted inside `llama_context::decode`,
    /// and scaling `-c` with the batch then broke EmbeddingGemma, whose trained context is 2048.
    ///
    /// So the size is not predicted, it is discovered: on a batch failure, halve and retry. The floor of that
    /// recursion is a batch of one at `-c 512`, which is exactly what the app does, so the fallback is the
    /// most faithful configuration rather than a degraded one.
    func embed(_ texts: [String]) throws -> [[Float]] {
        var result: [[Float]] = []
        result.reserveCapacity(texts.count)
        var index = 0
        var size = max(1, batchSize)
        while index < texts.count {
            let end = min(texts.count, index + size)
            let batch = Array(texts[index..<end])
            do {
                result += try runBatch(batch)
            } catch let error as VectorError {
                guard size > 1 else { throw error }
                size = max(1, size / 2)
                FileHandle.standardError.write(Data("""

                    a batch of \(batch.count) failed; retrying at \(size). This is normal for a model whose
                    context or batch limits differ from the pinned defaults — see Embed.swift.

                    """.utf8))
                continue
            }
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
            // All three scale together, and they are a THROUGHPUT knob rather than part of the contract.
            //
            // n_batch/n_ubatch are the total tokens per compute batch — not per prompt — so they must cover
            // the whole batch: `batchSize` prompts of up to 512 tokens each. And n_batch must not exceed
            // n_ctx, which is the KV budget shared across the sequences in flight, so n_ctx has to scale with
            // them. Getting either half of that wrong is a hard failure, and both halves were got wrong here
            // in turn: `-b 512` (the app's value, for a process that embeds ONE text) truncated
            // llama-embedding's output mid-array on the batch holding two 240-character Chinese chunks, and
            // then raising only `-b` above `-c` aborted inside `llama_context::decode`.
            //
            // What this does NOT change is the window any single prompt gets. Every chunk the app produces is
            // bounded at 192 words or 240 characters, far below 512 tokens, so no prompt is affected by the
            // larger context — see the fidelity note in the README about the app's own 384-token cap.
            "-c", "\(batchSize * 512)",
            "-b", "\(batchSize * 512)",
            "-ub", "\(batchSize * 512)",
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
        // Parsed with our own diagnosis rather than letting Foundation's "the data couldn't be read because
        // it isn't in the correct format" escape to the user. The realistic failure is a TRUNCATED array —
        // llama-embedding stopping mid-write when a batch overflows n_batch — and that message names neither
        // the cause nor the fix.
        let object: [String: Any]?
        do {
            object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            throw VectorError.malformed("""
                \(contract.id): llama-embedding produced \(data.count) bytes that do not parse as JSON \
                (\(error.localizedDescription)).
                  The usual cause is a truncated array: n_batch must cover the SUM of the batch's tokens, so \
                a batch of long texts can overflow it and cut the output mid-array.
                  Try a smaller --batch, and check stderr for a llama.cpp diagnostic.
                """)
        }
        guard let object, let entries = object["data"] as? [[String: Any]] else {
            throw VectorError.malformed("\(contract.id): llama-embedding returned no JSON embedding list")
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
