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
    case split
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
         Reports the DEVELOPMENT half of `main` by default. --holdout "<reason>" also reports the
         frozen half and appends the access to Corpus/holdout-access.log.
         --mixed-language-index searches all ten locales at once. The default restricts
         candidates to the query's own language, because a real index holds one person's
         memories rather than nine translations of them — see Score.swift.

  embed  --corpus <dir> --contract <id> --model <gguf> --llama-embedding <bin> --out <dir>
         [--batch 32] [--dimensions N] [--separator <string>] [-- <extra llama-embedding args>]
         One run per model. Build `llama-embedding` from the tag pinned in Tools/bootstrap-nomic.sh.
         --dimensions overrides the stored width. For a model with trained Matryoshka this is a
         supported mode; for one without it, it is an EXPERIMENT whose result is the answer to
         "what does truncating this cost", and the run is labelled as untrained truncation.
         Before writing any vectors, `embed` scores three fixed trivial pairs through this model's
         own contract and REFUSES to proceed if any of them ranks the wrong document first — this
         is the check that would have caught multilingual-e5-small's broken Q4_K_M quant before it
         produced a plausible-looking nDCG@8. --skip-sanity-check overrides it for deliberate
         debugging of a model already known to be broken; the run is loudly marked as such.

  models List the known embedding contracts and which are comparable on the pinned runtime.

  split  --corpus <dir> [--test-fraction 0.35] [--seed N] [--write]
         Computes the development / holdout split over the `main` index and prints its shape. Whole
         scenarios move together — the connected components of the query-document graph — so no
         document can be graded from both sides. Without --write it only reports; with --write it
         commits Corpus/split.json, which is what makes the boundary stable across corpus edits.
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
var skipSanityCheck = false
var testFraction = 0.35
var splitSeed: UInt64 = 20_260_819
var writeSplit = false
var holdoutReason = ""

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
    case "--skip-sanity-check": skipSanityCheck = true
    case "--test-fraction": testFraction = Double(iterator.next() ?? "") ?? testFraction
    case "--seed": splitSeed = UInt64(iterator.next() ?? "") ?? splitSeed
    case "--write": writeSplit = true
    case "--holdout": holdoutReason = iterator.next() ?? ""
    case "--floor":
        floors = (iterator.next() ?? "").split(separator: ",").compactMap { Double($0) }
    case "--":
        while let extra = iterator.next() { passthrough.append(extra) }
    default:
        FileHandle.standardError.write(Data("unknown argument \(key)\n".utf8))
        exit(2)
    }
}

/// Appends one line to the committed holdout access log.
///
/// The log is the enforcement: a frozen set is only frozen if looking at it leaves a trace. It records the
/// configuration alongside the reason, so a later reader can see whether settings changed AFTER a reading —
/// which is the specific failure this guards against, since tuning on the holdout is invisible in the
/// numbers themselves.
func appendHoldoutAccess(corpusDirectory: URL,
                         reason: String,
                         model: String,
                         floors: [Double],
                         candidates: Int,
                         rerankServer: String,
                         rerankTop: Int,
                         split: CorpusSplit) throws {
    let configuration = [
        "model=\(model)",
        "floors=\(floors.map { String(format: "%.2f", $0) }.joined(separator: "/"))",
        "candidates=\(candidates)",
        rerankServer.isEmpty ? "rerank=off" : "rerank=on@\(rerankTop)",
        "split=v\(split.version)/seed\(split.seed)",
    ].joined(separator: " ")
    let line = "\(ISO8601DateFormatter().string(from: Date()))  \(configuration)  reason=\(reason)\n"

    let url = corpusDirectory.appendingPathComponent("holdout-access.log")
    let header = "# Every reading of the frozen holdout half, appended by `memorybench score --holdout`.\n"
        + "# A short log means the holdout still means something. A long one means it has quietly become a\n"
        + "# second development set, and the honest fix is a fresh split rather than a fresh interpretation.\n\n"
    if FileManager.default.fileExists(atPath: url.path) {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    } else {
        try Data((header + line).utf8).write(to: url)
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
              \(corpus.queries.count) queries across \(corpus.indexes.count) indexes

            Reported per INDEX, because that is the unit a question is actually asked against: one
            person's own memories. Per-language totals would add up nine translations of the same
            fact and call it a big index, which is the mistake this corpus was rebuilt to stop making.

            index          docs  queries  langs         \(QueryCategory.allCases.map { $0.rawValue.prefix(5).padding(toLength: 7, withPad: " ", startingAt: 0) }.joined())
            ------------------------------------------------------------------------------------------------
            """)
        for index in corpus.indexes {
            let documents = corpus.documents.filter { $0.index == index }
            let queries = corpus.queries.filter { $0.index == index }
            let langs = Set(documents.map(\.lang)).sorted().joined(separator: "+")
            let cells = QueryCategory.allCases.map { category in
                String(queries.filter { $0.category == category }.count)
                    .padding(toLength: 7, withPad: " ", startingAt: 0)
            }
            print("\(index.padding(toLength: 14, withPad: " ", startingAt: 0)) "
                + String(format: "%4d", documents.count) + "  " + String(format: "%7d", queries.count)
                + "  \(langs.padding(toLength: 12, withPad: " ", startingAt: 0))  \(cells.joined())")
        }
        print("")
    } catch {
        fail(error.localizedDescription)
    }

case .split:
    do {
        let directory = URL(fileURLWithPath: corpusPath)
        let corpus = try Corpus.load(directory: directory)
        let split = corpus.computeSplit(testFraction: testFraction, seed: splitSeed)
        let problems = corpus.splitProblems(split)

        let queries = corpus.queries.filter { $0.index == Corpus.splitIndex }
        let groups = corpus.scenarioGroups()
        print("""

            split over `\(Corpus.splitIndex)` — seed \(split.seed), target test fraction \(split.testFraction)
              \(groups.count) indivisible scenario groups, largest holds \(groups.first?.queryIDs.count ?? 0) queries
              dev \(split.devQueryIDs.count) queries · test \(split.testQueryIDs.count) queries \
            (\(String(format: "%.0f%%", 100 * Double(split.testQueryIDs.count) / Double(max(1, queries.count)))) test)

            category      dev  test
            ------------------------
            """)
        for category in QueryCategory.allCases {
            let dev = queries.filter { split.dev.contains($0.id) && $0.category == category }.count
            let test = queries.filter { split.test.contains($0.id) && $0.category == category }.count
            print("\(category.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)) "
                + String(format: "%4d", dev) + String(format: "%6d", test))
        }

        if problems.isEmpty {
            print("\nleak check: PASS — no document is graded relevant on both sides")
        } else {
            print("\nleak check: FAIL")
            for problem in problems { print("  - \(problem)") }
        }

        if writeSplit {
            guard problems.isEmpty else { fail("\nrefusing to write a split that does not pass its own checks") }
            try split.write(directory: directory)
            print("\nwrote \(directory.appendingPathComponent(CorpusSplit.filename).path)")
        } else {
            print("\n(dry run — pass --write to commit this assignment)")
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

        // Three pairs, one prompt each way, before the expensive corpus run. This is what would have
        // caught e5-small's broken quant immediately instead of after a full nDCG@8 table looked plausible.
        let sanity = try runSanityCheck(contract: contract, embedder: embedder)
        print("sanity check for \(contract.id):")
        for result in sanity {
            let verdict = result.passed ? "PASS" : "FAIL"
            print("  \(result.pair.id.padding(toLength: 20, withPad: " ", startingAt: 0)) "
                + "correct \(String(format: "%+.4f", result.correctScore))  "
                + "wrong \(String(format: "%+.4f", result.wrongScore))  \(verdict)")
        }
        let failed = sanity.filter { !$0.passed }
        if !failed.isEmpty {
            if skipSanityCheck {
                FileHandle.standardError.write(Data("""

                    WARNING: \(failed.count) of \(sanity.count) sanity pairs failed for \(contract.id).
                      Proceeding only because --skip-sanity-check was passed. Do not put this row in a
                      comparison table without first ruling out a broken quantisation — see the
                      multilingual-e5-small entry in Contracts.swift for what that looks like.

                    """.utf8))
            } else {
                fail("""
                    \(failed.count) of \(sanity.count) sanity pairs failed for \(contract.id): \
                    \(failed.map(\.pair.id).joined(separator: ", ")).
                      The model ranked an unrelated document above the correct one for a trivial question.
                      This is the signature multilingual-e5-small's broken Q4_K_M quant showed — do not
                      trust retrieval numbers from this artifact. Try a different quantisation, or pass
                      --skip-sanity-check to proceed anyway for deliberate debugging.
                    """)
            }
        }
        print("")

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
        // The committed split, when there is one. Absent only before `split --write` has ever run, in which
        // case `score` falls back to reporting the whole index and says so loudly.
        let split = try? CorpusSplit.load(directory: URL(fileURLWithPath: corpusPath))
        if split == nil {
            FileHandle.standardError.write(Data(("NOTE: no Corpus/split.json — reporting the whole `main` "
                + "index, which means any tuning against these numbers is fitted to the same queries it will "
                + "later be judged on.\n  Run `memorybench split --corpus " + corpusPath
                + " --write` to fix that.\n\n").utf8))
        }
        if !holdoutReason.isEmpty {
            guard let split else {
                fail("--holdout needs a committed split; run `memorybench split --write` first")
            }
            try appendHoldoutAccess(corpusDirectory: URL(fileURLWithPath: corpusPath),
                                    reason: holdoutReason,
                                    model: synthetic ? "synthetic" : vectors.meta.model,
                                    floors: floors,
                                    candidates: candidates,
                                    rerankServer: rerankServer,
                                    rerankTop: rerankTop,
                                    split: split)
            FileHandle.standardError.write(Data(("HOLDOUT UNLOCKED — recorded in "
                + "Corpus/holdout-access.log.\n  Use it to confirm a configuration chosen on dev, not to "
                + "choose one. If any setting changes after reading these numbers, the holdout has been "
                + "spent and the next honest reading needs a fresh split.\n\n").utf8))
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
                               mixedLanguageIndex: mixedLanguageIndex,
                               split: split,
                               showHoldout: !holdoutReason.isEmpty)
    } catch {
        fail(error.localizedDescription)
    }
}
