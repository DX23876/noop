import Foundation
import WhoopProtocol

/// Fork (DX23876), Android without Room (`docs/fork/android/CORE-ONLY-PLAN.md`, decision 6): on-device SHORT-NAP
/// detection, moved into the shared core from Android's `NapDetector.kt` (reimplemented from @cbarrado's PR #569)
/// line for line. A daytime nap is a short stretch where the wrist goes quiet AND the heart rate settles below the
/// wearer's resting band. The verdict is tri-state and never writes a sleep session: a NAP is offered for review,
/// an INCONCLUSIVE window is shown as "couldn't tell". All times are wall-clock unix seconds.
public enum NapDetector {
    public enum Verdict: String, Sendable { case nap, none, inconclusive }

    public struct Candidate: Equatable, Sendable {
        public let start: Int
        public let end: Int
        /// Mean HR over the quiet stretch, nil when no HR landed.
        public let meanHr: Int?
        /// 0...1 ordering confidence; not a probability, not a diagnosis.
        public let confidence: Double
        public var durationS: Int { end - start }
    }

    public struct Decision: Equatable, Sendable {
        public let verdict: Verdict
        public let candidate: Candidate?
    }

    public struct Config: Equatable, Sendable {
        public var enabled: Bool
        public var minNapMinutes: Int
        public var maxNapMinutes: Int
        public var stillThresholdG: Double
        public var hrSettleMarginBpm: Int
        public var smoothWindowSeconds: Double
        public init(enabled: Bool = false, minNapMinutes: Int = 20, maxNapMinutes: Int = 90,
                    stillThresholdG: Double = 0.08, hrSettleMarginBpm: Int = 8, smoothWindowSeconds: Double = 120) {
            self.enabled = enabled; self.minNapMinutes = minNapMinutes; self.maxNapMinutes = maxNapMinutes
            self.stillThresholdG = stillThresholdG; self.hrSettleMarginBpm = hrSettleMarginBpm
            self.smoothWindowSeconds = smoothWindowSeconds
        }
    }

    /// A data hole longer than this ends a quiet run: a hole is not sleep.
    public static let maxGapS = 10 * 60
    public static let minGravitySamples = 20
    public static let maxMedianGapS = 90

    /// Whether the gravity window is dense enough to judge: enough rows, and a median gap no larger than the cap.
    public static func isWindowDense(_ gravity: [GravitySample], minSamples: Int = minGravitySamples,
                                     maxMedianGap: Int = maxMedianGapS) -> Bool {
        guard gravity.count >= minSamples else { return false }
        let ts = gravity.map(\.ts).sorted()
        let gaps = zip(ts, ts.dropFirst()).map { $1 - $0 }.filter { $0 >= 0 }
        guard !gaps.isEmpty else { return false }
        let sorted = gaps.sorted()
        return sorted[sorted.count / 2] <= maxMedianGap
    }

    /// The longest stretch of smoothed wrist-motion at or under `stillThresholdG`, unbroken by motion or by a gap
    /// longer than `maxGapS`, as (start, end); nil when there is none.
    public static func longestQuietRun(_ gravity: [GravitySample], stillThresholdG: Double = 0.08,
                                       smoothWindowSeconds: Double = 120) -> (start: Int, end: Int)? {
        let rows = gravity.sorted { $0.ts < $1.ts }
        guard rows.count >= 2 else { return nil }
        let motion = WorkoutDetector.activitySeries(rows)
        let smoothed = WorkoutDetector.smoothedIntensity(motion, windowS: smoothWindowSeconds)
        let ts = motion.map(\.ts)
        var best: (start: Int, end: Int)?
        var runStart = -1
        func closeRun(_ endIdx: Int) {
            if runStart >= 0, runStart <= endIdx {
                let s = ts[runStart], e = ts[endIdx]
                if best == nil || (e - s) > (best!.end - best!.start) { best = (s, e) }
            }
            runStart = -1
        }
        for i in ts.indices {
            if i > 0, ts[i] - ts[i - 1] > maxGapS { closeRun(i - 1) }
            if smoothed[i] > stillThresholdG {
                closeRun(i - 1)
            } else if runStart < 0 {
                runStart = i
            }
        }
        closeRun(ts.count - 1)
        return best
    }

    /// Mean HR over `[start, end]` from plausible samples, nil when none fell in the window.
    public static func meanHr(_ hr: [HRSample], start: Int, end: Int) -> Int? {
        let inWindow = hr.filter { $0.ts >= start && $0.ts <= end && (25...220).contains($0.bpm) }
        guard !inWindow.isEmpty else { return nil }
        return Int(Double(inWindow.reduce(0) { $0 + $1.bpm }) / Double(inWindow.count))
    }

    /// The tri-state verdict for one window: off or sparse is inconclusive, no long enough quiet run is none, a run
    /// longer than a nap is inconclusive, a run whose HR did not settle is none, anything else is a nap.
    public static func evaluate(gravity: [GravitySample], hr: [HRSample], restingHr: Int?, config: Config) -> Decision {
        guard config.enabled, isWindowDense(gravity) else { return Decision(verdict: .inconclusive, candidate: nil) }
        guard let quiet = longestQuietRun(gravity, stillThresholdG: config.stillThresholdG,
                                          smoothWindowSeconds: config.smoothWindowSeconds) else {
            return Decision(verdict: .none, candidate: nil)
        }
        let durationMin = Double(quiet.end - quiet.start) / 60
        if durationMin < Double(config.minNapMinutes) { return Decision(verdict: .none, candidate: nil) }
        if durationMin > Double(config.maxNapMinutes) { return Decision(verdict: .inconclusive, candidate: nil) }
        let mean = meanHr(hr, start: quiet.start, end: quiet.end)
        if let restingHr, let mean, mean > restingHr + config.hrSettleMarginBpm {
            return Decision(verdict: .none, candidate: nil)
        }
        return Decision(verdict: .nap, candidate: Candidate(
            start: quiet.start, end: quiet.end, meanHr: mean,
            confidence: confidence(durationMin: durationMin, restingHr: restingHr, meanHr: mean, config: config)))
    }

    /// Longer and a known, settled HR band order higher; an unknown band caps the total at 0.7.
    static func confidence(durationMin: Double, restingHr: Int?, meanHr: Int?, config: Config) -> Double {
        let span = Double(max(config.maxNapMinutes - config.minNapMinutes, 1))
        let durTerm = 0.4 + 0.45 * min(max((durationMin - Double(config.minNapMinutes)) / span, 0), 1)
        guard let restingHr, let meanHr else { return min(max(durTerm, 0), 0.7) }
        let headroom = Double(max(config.hrSettleMarginBpm, 1))
        let below = Double(max(restingHr + config.hrSettleMarginBpm - meanHr, 0))
        let hrTerm = 0.15 * min(max(below / headroom, 0), 1)
        return min(max(durTerm + hrTerm, 0), 1)
    }
}
