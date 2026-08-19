// swift-tools-version:5.9
import PackageDescription

// MemoryBench — an offline retrieval harness for the coach's semantic memory.
//
// The coach picks 8 lines of local text memory per turn out of the whole index. Which 8 is decided by
// `SemanticIndexStore.search` plus `SemanticRanking.fuse`, and until now the only evidence for that
// choice was a 6-document self-test on device and a 300-query measurement that was never committed —
// so no change to the ranking could be argued for or against. This tool is that missing instrument.
//
// It runs in two deliberately separate stages, because the embedder is iOS-only (the vendored
// llama.xcframework carries no macOS slice) and because a model comparison is only fair if the
// selection is identical:
//
//   `memorybench embed`  — one run per model, OUTSIDE this repository, driving the pinned llama.cpp's
//                          own `llama-embedding` binary and writing a vectors file.
//   `memorybench score`  — model-independent, deterministic, no model and no device needed: loads
//                          vectors files, replays the REAL `SemanticIndexStore` and `SemanticRanking`,
//                          and scores every ablation on the committed corpus.
//
// The corpus under `Corpus/` is SYNTHETIC and committed. No wearer's health data is involved at any
// point, no NOOP database is opened, and vectors files are build outputs that are never committed.
let package = Package(
    name: "memorybench",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/SemanticMemory"),
    ],
    targets: [
        .executableTarget(name: "memorybench", dependencies: ["SemanticMemory"]),
        // The metrics are pure functions over ranked id lists and judgment tables, so `swift test`
        // here needs no vectors file, no model and no `--vectors` argument.
        .testTarget(name: "memorybenchTests", dependencies: ["memorybench"]),
    ]
)
