import Foundation
import WhoopProtocol

// WorkoutHeartRateFill.swift — the heart rate NOOP adds to a workout its source brought without one.
//
// Apple Health workouts arrive with sport, duration, energy and distance but no average, peak or Effort.
// The heart rate that belongs to them is already at hand: the band's own trace for the window, or the
// minute-averaged samples HealthKit keeps with the workout. This decides which one describes the session
// and what it says, with the rules the cardio load uses, so a session's Effort, load and zone split rest
// on the same heart rate.
//
// Pure: the caller reads the band samples, the workout's minute buckets and the resting rates.

public enum WorkoutHeartRateFill {

    /// Where a filled value came from.
    public enum Source: String, Equatable, Sendable {
        case band
        case watch
    }

    /// What a session's own heart rate says about it.
    public struct Result: Equatable, Sendable {
        public let averageHR: Int
        public let maxHR: Int
        /// Nil when no resting rate was known for the day, or the trace was too thin to score.
        public let strain: Double?
        public let source: Source
        public let restingHR: Double?
        public let coveredMinutes: Int
        public let possibleMinutes: Int
    }

    /// Fewest minutes a trace must carry, and the share of the window it must cover, to stand as the
    /// session's heart rate. The cardio load's rule: two stray samples are not a trace.
    public static let minimumCoveredMinutes = 10
    public static let minimumCoverage = 0.70

    /// Minutes of `[start, end]` a trace carries a reading for, and how many it could.
    public static func coverage(_ samples: [HRSample], start: Int, end: Int) -> (covered: Int, possible: Int) {
        let possible = max(1, Int(ceil(Double(end - start) / 60.0)))
        let covered = Set(samples.filter { $0.ts >= start && $0.ts <= end }.map { ($0.ts - start) / 60 }).count
        return (covered, possible)
    }

    /// Whether a trace describes enough of a window to stand as that session's heart rate.
    public static func hasUsableCoverage(_ samples: [HRSample], start: Int, end: Int) -> Bool {
        let result = coverage(samples, start: start, end: end)
        return result.covered >= minimumCoveredMinutes
            && Double(result.covered) / Double(result.possible) >= minimumCoverage
    }

    /// HealthKit's one averaged value per minute as samples: each minute twice, thirty seconds apart, so it
    /// has its width for Effort and time-in-zone and resolves nothing shorter.
    public static func minuteTrace(_ minutes: [(start: Int, bpm: Double)]) -> [HRSample] {
        minutes.filter { $0.bpm.isFinite && $0.bpm > 0 }.sorted { $0.start < $1.start }.flatMap { minute in
            [HRSample(ts: minute.start, bpm: Int(minute.bpm.rounded())),
             HRSample(ts: minute.start + 30, bpm: Int(minute.bpm.rounded()))]
        }
    }

    /// The session's heart rate: the band when it covers the window, else the watch's minutes, never both.
    ///
    /// Average and peak come from the chosen trace as recorded: the band's samples, or the watch's minute
    /// values (so the peak is the highest minute, a few beats under the highest beat). Effort needs the
    /// day's resting rate; without one it stays nil rather than being scored against a default.
    public static func resolve(band: [HRSample], watchMinutes: [(start: Int, bpm: Double)],
                               start: Int, end: Int, maxHR: Double, restingHR: Double?,
                               method: StrainScorer.Method, sex: String) -> Result? {
        guard end > start else { return nil }
        let window = band.filter { $0.ts >= start && $0.ts <= end && $0.bpm > 0 }
        if hasUsableCoverage(window, start: start, end: end) {
            let values = window.map { Double($0.bpm) }
            return make(values: values, trace: window, source: .band, start: start, end: end,
                        maxHR: maxHR, restingHR: restingHR, method: method, sex: sex)
        }
        let minutes = watchMinutes.filter { $0.start >= start && $0.start <= end && $0.bpm.isFinite && $0.bpm > 0 }
        let trace = minuteTrace(minutes)
        guard hasUsableCoverage(trace, start: start, end: end) else { return nil }
        return make(values: minutes.map(\.bpm), trace: trace, source: .watch, start: start, end: end,
                    maxHR: maxHR, restingHR: restingHR, method: method, sex: sex)
    }

    private static func make(values: [Double], trace: [HRSample], source: Source, start: Int, end: Int,
                             maxHR: Double, restingHR: Double?, method: StrainScorer.Method,
                             sex: String) -> Result? {
        guard !values.isEmpty, let peak = values.max() else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let strain = restingHR.flatMap {
            StrainScorer.strain(trace, maxHR: maxHR, restingHR: $0, method: method, sex: sex)
        }
        let span = coverage(trace, start: start, end: end)
        return Result(averageHR: Int(mean.rounded()), maxHR: Int(peak.rounded()), strain: strain,
                      source: source, restingHR: restingHR, coveredMinutes: span.covered,
                      possibleMinutes: span.possible)
    }

    // MARK: - Resting rate

    /// How far either side of a day an Apple Watch resting rate may stand in for the day's own.
    public static let appleRestingWindowDays = 3

    /// The resting rate a past session is scored against: the day's own (WHOOP or NOOP), else the Apple
    /// Watch's nearest within `appleRestingWindowDays`, else none.
    ///
    /// Never the last known value, however old: a wearer's resting rate moves with fitness, and a walk from
    /// a year without the band must not be scored against the rate of a year with it.
    public static func restingHR(on day: String, own: [String: Double],
                                 apple: [String: Double]) -> Double? {
        if let value = own[day], value > 0 { return value }
        for distance in 0...appleRestingWindowDays {
            for offset in distance == 0 ? [0] : [-distance, distance] {
                if let value = apple[WeeklyDigestEngine.addDays(day, offset)], value > 0 { return value }
            }
        }
        return nil
    }

    /// How long an earlier resting rate may stand in for a day without one, where a caller carries it.
    public static let restingCarryDays = 14

    /// The day's own resting rate, else the newest earlier one no older than `restingCarryDays`.
    public static func carriedRestingHR(on day: String, in byDay: [String: Double]) -> Double? {
        if let value = byDay[day], value > 0 { return value }
        let earliest = WeeklyDigestEngine.addDays(day, -restingCarryDays)
        return byDay.filter { $0.key < day && $0.key >= earliest && $0.value > 0 }
            .max { $0.key < $1.key }?.value
    }
}
