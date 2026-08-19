import Foundation
import SemanticMemory

// How the index behaves when the history is a real one, and why the filler is generated at run time.
//
// The corpus holds 272 documents in `main`. A lived-in index is bigger: fifty conversations, a journal running
// for years, and `noop-db-layout-cost` puts the main database at 1.83 GB. Two questions follow, and neither is
// about ranking quality:
//
//  1. Is K=32 still enough when the pool it is drawn from is twenty times larger?
//  2. `SemanticIndexStore.search` is a full table scan that Float16-decodes every row. How does it grow?
//
// The plan called for committed `scale-1k` and `scale-5k` indexes of generated distractors, with a test
// forbidding any judgment from pointing at them. Generating at run time is strictly safer for the same cost:
// generated text cannot leak into a quality claim if it never exists in the corpus at all, so there is no rule
// to enforce and no way to forget it. It also keeps the repository honest — six thousand machine-written German
// sentences would be the largest thing in it, and every model would have to embed them.
//
// The filler is vectors, not text, and that is the design's real limit. Uniform random directions would be
// useless: in 256 dimensions they are near-orthogonal to everything, so they would sit below every real
// document and the scan would look free. Instead each filler vector is a real corpus vector pushed away by
// gaussian noise, with the push calibrated so the resulting cosine distribution matches the corpus's own
// document-to-document distribution. That reproduces the GEOMETRY of a larger index faithfully.
//
// It does not reproduce SEMANTICS. A real distractor can be confusable in ways only text carries — the same
// supplement at a different dose, the other knee — and no amount of noise invents that. So the K-sufficiency
// number here is the difficulty that comes from crowding alone, which makes it a floor on the real difficulty
// and not an estimate of it. Stated plainly because the number is otherwise easy to over-read.

struct ScaleTier {
    let documents: Int
    /// The corpus's own document-to-document cosine spread, which is what the filler was calibrated to.
    ///
    /// Printed because it is the tier's most important caveat and it is invisible otherwise. If the corpus is
    /// itself near-orthogonal, calibrated filler is near-orthogonal too, and the tier then measures scan cost
    /// honestly while saying nothing at all about crowding — which is exactly the case for `--synthetic`, where
    /// hashed token bags barely overlap. A reader who cannot see this column cannot tell an informative K
    /// measurement from an empty one.
    let spreadMedian: Double
    let spreadP95: Double
    let indexBytes: Int64
    let scanMillisecondsP50: Double
    let scanMillisecondsP95: Double
    /// Share of answerable queries whose best relevant chunk is still inside the cut.
    let withinTop8: Double
    let withinTop32: Double
    let withinTop128: Double
    let scoredQueries: Int
}

/// Deterministic standard normal, from the same generator the split uses so a tier is reproducible.
private func gaussian(_ rng: inout SplitMix64) -> Double {
    // Box–Muller. The uniform must exclude zero, or the logarithm diverges.
    let u1 = Double(rng.next() >> 11) / Double(1 << 53)
    let u2 = Double(rng.next() >> 11) / Double(1 << 53)
    return sqrt(-2 * log(max(u1, .leastNormalMagnitude))) * cos(2 * .pi * u2)
}

private func normalised(_ vector: [Float]) -> [Float] {
    let norm = sqrt(vector.reduce(0) { $0 + Double($1 * $1) })
    guard norm > 0 else { return vector }
    return vector.map { Float(Double($0) / norm) }
}

private func cosine(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count else { return 0 }
    var dot = 0.0
    for index in a.indices { dot += Double(a[index]) * Double(b[index]) }
    return dot
}

/// The corpus's own document-to-document cosine distribution, sampled rather than computed in full.
///
/// This is what calibrates the filler. Guessing a spread instead would decide the answer: a tight one makes
/// every filler vector a near-duplicate and K=32 look hopeless, a loose one makes the scan look free.
func sampledPairwiseCosines(_ vectors: [[Float]], samples: Int = 4_000, seed: UInt64) -> [Double] {
    guard vectors.count >= 2 else { return [] }
    var rng = SplitMix64(seed: seed)
    var result: [Double] = []
    result.reserveCapacity(samples)
    for _ in 0..<samples {
        let a = Int(rng.next() % UInt64(vectors.count))
        var b = Int(rng.next() % UInt64(vectors.count))
        if a == b { b = (b + 1) % vectors.count }
        result.append(cosine(vectors[a], vectors[b]))
    }
    return result.sorted()
}

/// One filler vector: a real one pushed to a target cosine.
///
/// For a unit `v` and per-component standard normal noise `n` in `d` dimensions, `‖n‖ ≈ √d`, so
/// `‖v + σn‖ ≈ √(1 + σ²d)` and the expected cosine to `v` is `1/√(1 + σ²d)`. Inverting gives
/// `σ = √((1/c² − 1)/d)`.
///
/// **The `/d` is the whole thing, and leaving it out is not a small error.** A first version used
/// `σ = √(1/c² − 1)`, which at 256 dimensions is sixteen times too much noise: asking for cosine 0.8 produced
/// 0.088, and every filler vector came out near-orthogonal to the entire corpus. That is precisely the failure
/// the calibration exists to avoid — orthogonal filler sits below every real document, so the crowding is
/// invisible and the tier reports that scale costs nothing. `ScaleTests.testFillerHitsItsTargetCosine` caught it
/// on the first run, after a full release measurement had already been taken with the broken generator.
///
/// Targets at or below zero fall back to a pure random direction, which is the correct behaviour for the tail of
/// a real distribution that reaches zero and below.
func fillerVector(from parent: [Float], targetCosine: Double, rng: inout SplitMix64) -> [Float] {
    guard targetCosine > 0.01, !parent.isEmpty else {
        return normalised(parent.map { _ in Float(gaussian(&rng)) })
    }
    let sigma = sqrt(max(0, (1 / (targetCosine * targetCosine) - 1) / Double(parent.count)))
    return normalised(parent.map { component in
        component + Float(sigma * gaussian(&rng))
    })
}

/// Whether this binary can report a latency at all.
///
/// A debug build decodes Float16 and walks the cosine loop unoptimised, and the difference is not a rounding
/// error: the first run of this command reported 76 ms per scan at 1 000 documents, which would have been a
/// headline finding about the app's 2.5-second race budget and was an artefact of `swift run` defaulting to
/// debug. Reporting it would have been worse than not measuring at all, so the timing columns refuse rather than
/// mislead.
var latencyIsMeasurable: Bool {
    #if DEBUG
    return false
    #else
    return true
    #endif
}

/// Builds one tier and measures it. Returns `nil` when the tier is smaller than the real index, which would
/// mean removing real documents to hit a target — a different measurement than the one asked for.
func measureTier(targetDocuments: Int,
                 corpus: Corpus,
                 vectors: VectorSet,
                 seed: UInt64) async throws -> ScaleTier? {
    let index = Corpus.splitIndex
    let documents = corpus.documents.filter { $0.index == index }
    let now = Date()

    // The real chunks first, exactly as `score` builds them, so the tier contains the actual retrieval problem
    // rather than a synthetic approximation of it.
    var real: [(id: String, document: SemanticDocument, vector: [Float])] = []
    for document in documents {
        for (chunkIndex, chunk) in MirroredChunker.chunks(document.text).enumerated() {
            let id = chunkID(document.id, chunkIndex)
            guard let kind = document.sourceKind, let scope = document.consentScope else { continue }
            guard let vector = vectors.documents[id] else {
                throw VectorError.missing("vector for chunk \(id) — re-run `embed` for this corpus")
            }
            real.append((id, SemanticDocument(sourceKind: kind,
                                              sourceID: document.id,
                                              chunkIndex: chunkIndex,
                                              text: chunk,
                                              updatedAt: document.updatedAt(now: now),
                                              consentScope: scope,
                                              priority: document.priority), vector))
        }
    }
    guard targetDocuments >= real.count else { return nil }

    // File-backed, not in-memory, for two reasons that both turned out to matter. `byteSize()` returns 0 for an
    // in-memory store, so the index-size column was silently useless; and the app searches a file on disk, so a
    // memory-only scan measures something the product never does.
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("memorybench-scale-\(targetDocuments)-\(seed)", isDirectory: true)
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SemanticIndexStore(path: directory.appendingPathComponent("index.sqlite").path)
    var enqueued = real.map(\.document)
    var embeddings = real.map { (document: $0.document, vector: $0.vector) }

    // Filler, calibrated against the corpus's own spread.
    let spread = sampledPairwiseCosines(real.map(\.vector), seed: seed)
    var rng = SplitMix64(seed: seed)
    for filler in 0..<(targetDocuments - real.count) {
        let parent = real[Int(rng.next() % UInt64(real.count))]
        let target = spread.isEmpty ? 0.2 : spread[Int(rng.next() % UInt64(spread.count))]
        let vector = fillerVector(from: parent.vector, targetCosine: target, rng: &rng)
        // Carries the parent's kind and scope so the scope filter and the per-kind logic see a realistic mix;
        // the id namespace is separate so filler can never be mistaken for a corpus document.
        let document = SemanticDocument(sourceKind: parent.document.sourceKind,
                                        sourceID: "«filler»-\(filler)",
                                        chunkIndex: 0,
                                        text: "«filler» \(filler)",
                                        updatedAt: now.addingTimeInterval(-Double(filler % 900) * 86_400),
                                        consentScope: parent.document.consentScope,
                                        priority: parent.document.priority)
        enqueued.append(document)
        embeddings.append((document, vector))
    }

    try await store.enqueue(enqueued)
    for entry in embeddings {
        try await store.storeEmbedding(documentID: entry.document.documentID,
                                       contentHash: entry.document.contentHash,
                                       modelID: vectors.meta.model,
                                       vector: entry.vector)
    }

    // Which chunk ids answer which query, so a rank can be resolved.
    var relevantChunks: [String: Set<String>] = [:]
    let documentIDForChunk = Dictionary(uniqueKeysWithValues: real.map { ($0.document.documentID, $0.id) })
    var chunkToDocumentID: [String: [String]] = [:]
    for entry in real {
        chunkToDocumentID[entry.id, default: []].append(entry.document.documentID)
    }
    _ = documentIDForChunk
    let queries = corpus.queries.filter { $0.index == index && $0.category.isAnswerable }
    for query in queries {
        var ids: Set<String> = []
        for (judged, grade) in query.judgments where grade > 0 {
            for entry in real where entry.document.sourceID == judged { ids.insert(entry.document.documentID) }
        }
        relevantChunks[query.id] = ids
    }

    // The scan, timed. A deep limit on purpose: the rank of the best hit cannot be read from a list cut at 32.
    let deepLimit = min(targetDocuments, 512)
    let scopes = Set(SemanticConsentScope.allCases)
    var milliseconds: [Double] = []
    var ranks: [Int] = []
    for query in queries {
        guard let vector = vectors.queries[query.id] else { continue }
        let start = DispatchTime.now().uptimeNanoseconds
        let hits = try await store.search(vector: vector, allowedScopes: scopes, limit: deepLimit)
        milliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        guard let relevant = relevantChunks[query.id], !relevant.isEmpty else { continue }
        if let position = hits.firstIndex(where: { relevant.contains($0.documentID) }) {
            ranks.append(position + 1)
        } else {
            ranks.append(.max)                                  // not reachable even at the deep limit
        }
    }

    func percentileOf(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))]
    }
    func share(withinRank cut: Int) -> Double {
        guard !ranks.isEmpty else { return 0 }
        return Double(ranks.filter { $0 <= cut }.count) / Double(ranks.count)
    }

    let indexBytes = await store.byteSize()
    func spreadAt(_ fraction: Double) -> Double {
        guard !spread.isEmpty else { return 0 }
        return spread[min(spread.count - 1, max(0, Int((Double(spread.count - 1) * fraction).rounded())))]
    }
    return ScaleTier(documents: targetDocuments,
                     spreadMedian: spreadAt(0.5),
                     spreadP95: spreadAt(0.95),
                     indexBytes: indexBytes,
                     scanMillisecondsP50: percentileOf(milliseconds, 0.5),
                     scanMillisecondsP95: percentileOf(milliseconds, 0.95),
                     withinTop8: share(withinRank: 8),
                     withinTop32: share(withinRank: 32),
                     withinTop128: share(withinRank: 128),
                     scoredQueries: ranks.count)
}
