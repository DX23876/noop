import Foundation

/// Session-local counters for how semantic retrieval is actually behaving on this device.
///
/// The retrieval path races the embedding model against a 2.5-second budget and answers with the keyword
/// ranker when it loses. That fallback costs the whole semantic arm for the turn — a much larger loss than any
/// ranking detail — and until now nothing counted it: `lastRetrievalMode` shows the most recent turn and
/// forgets the one before. So "how often does the model actually win?" had no answer, on any device, and the
/// first question of a session (which pays the model's cold load inside the same budget) was the case nobody
/// could see.
///
/// This is measurement, not behaviour: nothing here changes what is retrieved. It lives in memory for the
/// lifetime of the process, is never written to disk, never enters `.noopbak`, and never leaves the device —
/// it is read by one Expert-settings row and by tests.
struct CoachSemanticTelemetry: Equatable {
    private(set) var semanticTurns = 0
    private(set) var keywordFallbackTurns = 0
    private(set) var unavailableTurns = 0
    /// Query-embedding durations, most recent last. Bounded so a long session cannot grow this without limit.
    private(set) var queryEmbedMilliseconds: [Double] = []
    /// How long the last cold load of the model took, when one happened in this process.
    private(set) var modelLoadMilliseconds: Double?

    static let sampleLimit = 200

    /// Turns where retrieval was attempted at all. `unavailable` means nothing matched or the feature was off,
    /// which is neither a win nor a fallback, so it is counted separately rather than folded into either.
    var attemptedTurns: Int { semanticTurns + keywordFallbackTurns }

    /// The number that decides whether latency work comes before ranking work. `nil` until a turn has run.
    var semanticWinRate: Double? {
        guard attemptedTurns > 0 else { return nil }
        return Double(semanticTurns) / Double(attemptedTurns)
    }

    mutating func record(mode: CoachSemanticRetrievalMode) {
        switch mode {
        case .semantic: semanticTurns += 1
        case .keywordFallback: keywordFallbackTurns += 1
        case .unavailable: unavailableTurns += 1
        }
    }

    mutating func recordQueryEmbed(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        queryEmbedMilliseconds.append(milliseconds)
        if queryEmbedMilliseconds.count > Self.sampleLimit {
            queryEmbedMilliseconds.removeFirst(queryEmbedMilliseconds.count - Self.sampleLimit)
        }
    }

    mutating func recordModelLoad(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        modelLoadMilliseconds = milliseconds
    }

    /// Nearest-rank percentile over the retained samples. Deliberately not interpolated: with a handful of
    /// samples an interpolated p95 is a number between two real measurements that nothing ever measured.
    func queryEmbedPercentile(_ fraction: Double) -> Double? {
        guard !queryEmbedMilliseconds.isEmpty else { return nil }
        let sorted = queryEmbedMilliseconds.sorted()
        let clamped = min(1, max(0, fraction))
        let index = Int((Double(sorted.count - 1) * clamped).rounded())
        return sorted[index]
    }

    /// One line for the Expert card, or `nil` before anything has been measured — an empty row is worse than
    /// no row.
    var summary: String? {
        guard let winRate = semanticWinRate else { return nil }
        var parts = ["semantic won \(semanticTurns)/\(attemptedTurns) turns (\(Int((winRate * 100).rounded()))%)"]
        if let median = queryEmbedPercentile(0.5), let p95 = queryEmbedPercentile(0.95) {
            parts.append("query embed p50 \(Int(median.rounded())) ms · p95 \(Int(p95.rounded())) ms")
        }
        if let load = modelLoadMilliseconds {
            parts.append("model cold load \(Int(load.rounded())) ms")
        }
        return parts.joined(separator: " · ")
    }
}
