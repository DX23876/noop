import Foundation

/// A cross-encoder reranking stage, measured rather than argued about.
///
/// The case against one here was made from reasoning — semantic retrieval already reaches a high recall at
/// eight slots, the consumer is an LLM rather than a top-1 extractor, and a 278M–568M second model wants RAM,
/// a cold load and 16–32 forward passes inside a 2.5-second budget the embedder already loses. Reasoning is
/// not evidence, and this harness exists precisely so claims like that stop being assertions. So: an opt-in
/// stage, and two numbers to judge it by — what it adds to nDCG@8, and what it costs per query.
///
/// It is opt-in for a structural reason, not a stylistic one. `score` is deterministic and runs in CI with no
/// model and no network; a reranker needs a live `llama-server`. Wiring it into the default path would trade
/// the property that makes the rest of this tool trustworthy for one more row in a table. Without
/// `--rerank-server`, nothing here runs and nothing changes.
///
/// Talks to llama.cpp's own `/rerank` endpoint, so the model runs on the same pinned runtime as everything
/// else — a reranker measured on a different llama.cpp would not be a reranker this app could ship.
struct RerankClient {
    let baseURL: URL
    /// How many candidates the reranker sees. The whole point of a rerank stage is that it is expensive per
    /// pair, so this is the knob that decides whether it is affordable: 16 pairs is a very different latency
    /// story from 128.
    let topCandidates: Int

    private struct Response: Decodable {
        struct Result: Decodable {
            let index: Int
            let relevance_score: Double
        }
        let results: [Result]
    }

    /// Relevance scores for `documents`, in the order they were given.
    ///
    /// Returns the scores rather than a ranking so the caller can feed them into the same selection policy the
    /// embedding path uses — a reranker that also has to reimplement quotas and the floor would be measuring
    /// two changes at once.
    func scores(query: String, documents: [String]) async throws -> [Double] {
        guard !documents.isEmpty else { return [] }
        var request = URLRequest(url: baseURL.appendingPathComponent("rerank"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "documents": documents,
            // Ask for every score back, not a shortlist: the caller needs the full ordering to compare against
            // the embedding order pair for pair.
            "top_n": documents.count,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw VectorError.tooling("""
                the rerank endpoint answered \(http.statusCode). Start llama-server from the pinned tag with a \
                reranker model and --reranking, e.g.
                  llama-server -m jina-reranker-v2-base-multilingual-Q4_K_M.gguf --reranking --port 8080
                Body: \(String(data: data, encoding: .utf8)?.prefix(400) ?? "")
                """)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard decoded.results.count == documents.count else {
            throw VectorError.malformed(
                "asked for \(documents.count) rerank scores, received \(decoded.results.count)"
            )
        }
        // The endpoint returns results sorted by score, so they have to be put back into input order before
        // they can be zipped with the candidates.
        var ordered = [Double](repeating: 0, count: documents.count)
        for result in decoded.results {
            guard result.index >= 0, result.index < ordered.count else {
                throw VectorError.malformed("rerank result index \(result.index) is out of range")
            }
            ordered[result.index] = result.relevance_score
        }
        return ordered
    }

    /// Fails fast with an actionable message if no server is there, rather than letting every query time out.
    func checkReachable() async throws {
        _ = try await scores(query: "ping", documents: ["ping"])
    }
}

/// What a rerank run cost, so the quality column is never read on its own.
struct RerankCost {
    private(set) var callMilliseconds: [Double] = []
    private(set) var pairsScored = 0

    mutating func record(milliseconds: Double, pairs: Int) {
        callMilliseconds.append(milliseconds)
        pairsScored += pairs
    }

    func percentile(_ fraction: Double) -> Double? {
        guard !callMilliseconds.isEmpty else { return nil }
        let sorted = callMilliseconds.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }

    var summary: String {
        guard let median = percentile(0.5), let p95 = percentile(0.95) else { return "no calls" }
        let mean = callMilliseconds.reduce(0, +) / Double(callMilliseconds.count)
        return String(format: "%d calls, %d pairs, p50 %.0f ms, p95 %.0f ms, mean %.0f ms",
                      callMilliseconds.count, pairsScored, median, p95, mean)
    }
}
