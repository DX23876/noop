import Foundation
import SemanticMemory

// memorybench — score the coach's semantic-memory retrieval on a committed synthetic corpus.
//
// USAGE
//   memorybench score  --corpus <dir> --vectors <dir> [--floor 0.30,0.35,0.40]
//   memorybench embed  --corpus <dir> --model <gguf> --contract <id> --llama-embedding <bin> --out <dir>
//   memorybench models
//
// `score` needs no model, no device and no network: it replays the real index and the real fusion over
// vectors that `embed` produced earlier. `embed` is the only stage that touches a model, runs outside this
// repository, and writes build outputs that are never committed.
//
// No wearer's health data is involved at any point, and no NOOP database is opened.

enum Command: String {
    case score
    case embed
    case models
    case lint
}

let usage = """
usage: memorybench <score|embed|models|lint> [options]

  lint   --corpus <dir>
         Validates the corpus and prints its shape per language and category. No model, no vectors.

  score  --corpus <dir> --vectors <dir> [--floor 0.30,0.35,0.40] [--candidates 128]
         Replays the shipped index + fusion and every proposed variant. Deterministic.
         --synthetic replaces the vectors with hashed token bags: it exercises the whole
         pipeline with no model, and is NOT a measurement of any model.
         --rerank-server <url> adds cross-encoder rerank rows, scored through llama.cpp's
         own /rerank endpoint. Opt-in on purpose: without it `score` needs no network and
         stays deterministic, which is what lets CI run it.
         --mixed-language-index searches all ten locales at once. The default restricts
         candidates to the query's own language, because a real index holds one person's
         memories rather than nine translations of them — see Score.swift.

  embed  --corpus <dir> --contract <id> --model <gguf> --llama-embedding <bin> --out <dir>
         [--batch 32] [--dimensions N] [--separator <string>] [-- <extra llama-embedding args>]
         One run per model. Build `llama-embedding` from the tag pinned in Tools/bootstrap-nomic.sh.
         --dimensions overrides the stored width. For a model with trained Matryoshka this is a
         supported mode; for one without it, it is an EXPERIMENT whose result is the answer to
         "what does truncating this cost", and the run is labelled as untrained truncation.

  models List the known embedding contracts and which are comparable on the pinned runtime.
"""

var arguments = Array(CommandLine.arguments.dropFirst())
guard let raw = arguments.first, let command = Command(rawValue: raw) else {
    print(usage)
    exit(2)
}
arguments.removeFirst()

var corpusPath = "Corpus"
var vectorsPath = ""
var outPath = ""
var modelPath = ""
var contractID = EmbeddingContract.nomic.id
var llamaEmbeddingPath = ""
var floors: [Double] = [0.30, 0.35, 0.40]
var candidates = 128
var batch = 32
var separator = "\u{1}"
var passthrough: [String] = []
var synthetic = false
var dimensionOverride: Int?
var rerankServer = ""
var rerankTop = 32
var mixedLanguageIndex = false

var iterator = arguments.makeIterator()
while let key = iterator.next() {
    switch key {
    case "--corpus": corpusPath = iterator.next() ?? corpusPath
    case "--vectors": vectorsPath = iterator.next() ?? ""
    case "--out": outPath = iterator.next() ?? ""
    case "--model": modelPath = iterator.next() ?? ""
    case "--contract": contractID = iterator.next() ?? contractID
    case "--llama-embedding": llamaEmbeddingPath = iterator.next() ?? ""
    case "--batch": batch = Int(iterator.next() ?? "") ?? batch
    case "--separator": separator = iterator.next() ?? separator
    case "--candidates": candidates = Int(iterator.next() ?? "") ?? candidates
    case "--synthetic": synthetic = true
    case "--dimensions": dimensionOverride = Int(iterator.next() ?? "")
    case "--rerank-server": rerankServer = iterator.next() ?? ""
    case "--rerank-top": rerankTop = Int(iterator.next() ?? "") ?? rerankTop
    case "--mixed-language-index": mixedLanguageIndex = true
    case "--floor":
        floors = (iterator.next() ?? "").split(separator: ",").compactMap { Double($0) }
    case "--":
        while let extra = iterator.next() { passthrough.append(extra) }
    default:
        FileHandle.standardError.write(Data("unknown argument \(key)\n".utf8))
        exit(2)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

switch command {
case .lint:
    do {
        let corpus = try Corpus.load(directory: URL(fileURLWithPath: corpusPath))
        let chunks = corpus.documents.reduce(0) { $0 + MirroredChunker.chunks($1.text).count }
        print("""

            corpus at \(corpusPath) is well formed
              \(corpus.documents.count) documents → \(chunks) chunks (what the index actually holds)
              \(corpus.queries.count) queries across \(corpus.languages.count) languages

            language   docs  queries  \(QueryCategory.allCases.map { $0.rawValue.prefix(5).padding(toLength: 7, withPad: " ", startingAt: 0) }.joined())
            ---------------------------------------------------------------
            """)
        for language in corpus.languages {
            let documents = corpus.documents.filter { $0.lang == language }.count
            let queries = corpus.queries.filter { $0.lang == language }
            let cells = QueryCategory.allCases.map { category in
                String(queries.filter { $0.category == category }.count)
                    .padding(toLength: 7, withPad: " ", startingAt: 0)
            }
            print("\(language.padding(toLength: 10, withPad: " ", startingAt: 0)) "
                + String(format: "%4d", documents) + "  " + String(format: "%7d", queries.count)
                + "  \(cells.joined())")
        }
        print("")
    } catch {
        fail(error.localizedDescription)
    }

case .models:
    print("known embedding contracts:\n")
    for contract in EmbeddingContract.all {
        let dims = contract.matryoshka
            ? "\(contract.fullDimensions) → \(contract.storedDimensions) (Matryoshka)"
            : "\(contract.fullDimensions) (no Matryoshka)"
        print("  \(contract.id)")
        print("    pooling \(contract.pooling), \(dims)")
        if let reason = contract.incomparable {
            print("    NOT COMPARABLE on the pinned runtime: \(reason)")
        }
    }
    print("")

case .embed:
    guard !modelPath.isEmpty, !llamaEmbeddingPath.isEmpty, !outPath.isEmpty else {
        print(usage)
        exit(2)
    }
    guard var contract = EmbeddingContract.named(contractID) else {
        fail("unknown contract \(contractID) — run `memorybench models`")
    }
    if let dimensionOverride {
        guard dimensionOverride > 0, dimensionOverride <= contract.fullDimensions else {
            fail("--dimensions must be between 1 and \(contract.fullDimensions) for \(contract.id)")
        }
        // Truncating a model that was never trained for it is an experiment, not a mode. Say so, and record
        // it in the vectors set's own metadata so a table built from it cannot quietly present the number as
        // a supported configuration.
        if !contract.matryoshka && dimensionOverride < contract.fullDimensions {
            FileHandle.standardError.write(Data("""
                NOTE: \(contract.id) documents no Matryoshka training, so \(dimensionOverride) dimensions is
                UNTRAINED truncation. The result is evidence about what truncating costs, not a supported mode.

                """.utf8))
        }
        contract = contract.truncated(to: dimensionOverride)
    }
    do {
        let corpus = try Corpus.load(directory: URL(fileURLWithPath: corpusPath))
        let embedder = Embedder(binary: URL(fileURLWithPath: llamaEmbeddingPath),
                                model: URL(fileURLWithPath: modelPath),
                                contract: contract,
                                extraArguments: passthrough,
                                batchSize: batch,
                                separator: separator)
        try runEmbed(corpus: corpus,
                     contract: contract,
                     embedder: embedder,
                     output: URL(fileURLWithPath: outPath))
    } catch {
        fail(error.localizedDescription)
    }

case .score:
    guard !vectorsPath.isEmpty || synthetic else {
        print(usage)
        exit(2)
    }
    do {
        let corpus = try Corpus.load(directory: URL(fileURLWithPath: corpusPath))
        let vectors: VectorSet
        if synthetic {
            FileHandle.standardError.write(Data("""
                NOTE: --synthetic. These vectors are hashed token bags, not a model. The tables below
                exercise the pipeline and say nothing about any embedding model's quality.

                """.utf8))
            vectors = SyntheticVectors.build(for: corpus)
        } else {
            vectors = try VectorSet.read(directory: URL(fileURLWithPath: vectorsPath))
        }
        var client: RerankClient?
        if !rerankServer.isEmpty {
            guard let url = URL(string: rerankServer) else { fail("--rerank-server is not a URL") }
            let candidate = RerankClient(baseURL: url, topCandidates: rerankTop)
            // Checked once, up front: 242 queries each timing out against a server that is not there is a
            // twenty-minute way to learn something a single request settles.
            try await candidate.checkReachable()
            client = candidate
        }
        _ = try await runScore(corpus: corpus,
                               vectors: vectors,
                               floors: floors,
                               candidateCeiling: candidates,
                               rerank: client,
                               mixedLanguageIndex: mixedLanguageIndex)
    } catch {
        fail(error.localizedDescription)
    }
}
