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
    /// Whole-turn durations: from entering `retrieve` to handing context back, most recent last.
    ///
    /// Separate from `queryEmbedMilliseconds` because they answer different questions and only the first was
    /// being measured. The embedding is one step inside a turn that also reconciles sources, runs the keyword
    /// arm, scans the index and fuses — and it is the TURN that has to fit the 2.5-second budget. A healthy
    /// embedding percentile next to a turn that overruns is precisely the picture that would have been invisible.
    private(set) var turnMilliseconds: [Double] = []
    /// High-water resident footprint observed at the end of a turn, in MB.
    ///
    /// The high-water mark rather than the current value: the number that matters is the peak the OS saw, since
    /// that is what gets a process jetsammed on a phone, and it is gone by the time anyone looks.
    private(set) var peakFootprintMB: Double?
    /// The most severe thermal state seen during any turn in this session.
    ///
    /// Worst rather than current, for the same reason as the footprint: sustained embedding work heats a phone
    /// and the throttling that follows is the thing that would explain a latency cliff. `nominal` is not stored
    /// as "seen" — it is the absence of a finding, and reporting it would imply a measurement of nothing.
    private(set) var worstThermalState: ProcessInfo.ThermalState?

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

    mutating func recordTurn(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        turnMilliseconds.append(milliseconds)
        if turnMilliseconds.count > Self.sampleLimit {
            turnMilliseconds.removeFirst(turnMilliseconds.count - Self.sampleLimit)
        }
    }

    /// Raises the high-water mark; a lower reading is not a correction, it is just a later moment.
    mutating func recordFootprint(megabytes: Double) {
        guard megabytes.isFinite, megabytes > 0 else { return }
        if megabytes > (peakFootprintMB ?? 0) { peakFootprintMB = megabytes }
    }

    /// Keeps the most severe state, ordered by `rawValue` (nominal 0 → critical 3). `nominal` is ignored so the
    /// field stays `nil` until something actually happened.
    mutating func recordThermalState(_ state: ProcessInfo.ThermalState) {
        guard state != .nominal else { return }
        if state.rawValue > (worstThermalState?.rawValue ?? -1) { worstThermalState = state }
    }

    /// Nearest-rank percentile over the retained samples. Deliberately not interpolated: with a handful of
    /// samples an interpolated p95 is a number between two real measurements that nothing ever measured.
    func queryEmbedPercentile(_ fraction: Double) -> Double? {
        Self.percentile(queryEmbedMilliseconds, fraction)
    }

    func turnPercentile(_ fraction: Double) -> Double? {
        Self.percentile(turnMilliseconds, fraction)
    }

    private static func percentile(_ samples: [Double], _ fraction: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let clamped = min(1, max(0, fraction))
        let index = Int((Double(sorted.count - 1) * clamped).rounded())
        return sorted[index]
    }

    private static func name(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// One line for the Expert card, or `nil` before anything has been measured — an empty row is worse than
    /// no row.
    var summary: String? {
        guard let winRate = semanticWinRate else { return nil }
        var parts = ["semantic won \(semanticTurns)/\(attemptedTurns) turns (\(Int((winRate * 100).rounded()))%)"]
        if let median = queryEmbedPercentile(0.5), let p95 = queryEmbedPercentile(0.95) {
            parts.append("query embed p50 \(Int(median.rounded())) ms · p95 \(Int(p95.rounded())) ms")
        }
        if let median = turnPercentile(0.5), let p95 = turnPercentile(0.95) {
            parts.append("whole turn p50 \(Int(median.rounded())) ms · p95 \(Int(p95.rounded())) ms")
        }
        if let load = modelLoadMilliseconds {
            parts.append("model cold load \(Int(load.rounded())) ms")
        }
        if let peak = peakFootprintMB {
            parts.append("peak footprint \(Int(peak.rounded())) MB")
        }
        if let thermal = worstThermalState {
            parts.append("thermal reached \(Self.name(for: thermal))")
        }
        return parts.joined(separator: " · ")
    }
}
