import Foundation
import WhoopProtocol

/// Experimental, side-by-side alternative to `StepsCounter` for the WHOOP 5/MG `step_motion_counter@57`.
///
/// The counter comes from the IMU's own pedometer (TDK APEX on the ICM-45686): it counts steps, reports a
/// walk/run class, and has no wider notion of whether the wearer is really walking. Free-living studies
/// find that this is where wrist step counts go wrong. The Oxford stepcount work (Small et al. 2023)
/// counted the same peaks with 63.5 % error, and with 12.5 % once a walking detector decided first which
/// 10-second windows were walking at all. NOOP cannot run that detector: it only sees one record per
/// second. This counter applies the same idea at bout level, with two rules and one repair:
///
/// 1. **Sustained walking counts.** A bout (walk/run increments no more than `maxGapSeconds` apart)
///    with at least `sustainedBoutTicks` ticks is kept whole.
/// 2. **Short bouts need walking nearby.** A shorter bout is kept only when a sustained bout lies within
///    `walkingContextSeconds` of it, which keeps the stop-and-go of a real walk and drops the isolated
///    snippets that arm movement at home produces.
/// 3. **The pedometer's start buffer is credited.** APEX releases the first 5 to 8 steps of a walk in one
///    increment once it has confirmed walking, while the record still says "still". `StepsCounter`
///    rejects that increment by class. Here it is credited to the bout that starts within
///    `maxGapSeconds` after it, and to nothing otherwise.
///
/// The thresholds come from 24 days of one wearer's data compared against iPhone step hours, not from a
/// labelled ground truth. That is why this only runs as a comparison and never replaces the daily total.
/// Pure and deterministic, so `swift test` covers it without a strap.
public enum GaitGatedStepCounter {
    /// Largest gap between two walk increments that still belong to one bout.
    public static let maxGapSeconds = 5
    /// Bouts with at least this many ticks count as sustained walking.
    public static let sustainedBoutTicks = 60
    /// How far a sustained bout may lie from a short one for the short one to count.
    public static let walkingContextSeconds = 180
    /// Size of the pedometer's start-of-walk release, in ticks.
    public static let startBurstTicks = 5...8
    /// Longest record spacing a start release may arrive over.
    public static let startBurstMaxElapsedSeconds = 2

    /// The window's ticks, split by the rule that kept or dropped them. `legacyTicks` is the current
    /// `StepsCounter` total over the same window, so the two can be compared directly.
    public struct Result: Equatable, Sendable {
        public let legacyTicks: Int
        public let sustainedTicks: Int
        public let contextTicks: Int
        public let rejectedTicks: Int
        /// Start releases inside the kept ticks above (already part of `totalTicks`).
        public let startBurstTicks: Int
        public let keptShortBouts: Int
        public let rejectedShortBouts: Int

        public var totalTicks: Int { sustainedTicks + contextTicks }

        public static let empty = Result(legacyTicks: 0, sustainedTicks: 0, contextTicks: 0, rejectedTicks: 0,
                                         startBurstTicks: 0, keptShortBouts: 0, rejectedShortBouts: 0)
    }

    struct Increment: Equatable {
        let ts: Int
        let ticks: Int
        let isStartBurst: Bool
    }

    struct Bout: Equatable {
        var start: Int
        var end: Int
        var increments: [Increment]
        var ticks: Int { increments.reduce(0) { $0 + $1.ticks } }
    }

    /// Count the ticks whose timestamps fall in `[windowStart, windowEndExclusive)`. `samples` should reach
    /// a few minutes past both edges so bouts crossing the edge and walking just outside it are judged
    /// correctly; only in-window increments are tallied. `legacyTicks` uses the in-window samples alone,
    /// exactly as the daily total does.
    public static func count(_ samples: [StepSample], windowStart: Int, windowEndExclusive: Int) -> Result {
        let sorted = samples.sorted { $0.ts < $1.ts }
        let inWindow = sorted.filter { $0.ts >= windowStart && $0.ts < windowEndExclusive }
        let legacy = StepsCounter.stepsInWindow(inWindow) ?? 0
        let all = bouts(sorted)
        let sustained = all.filter { $0.ticks >= sustainedBoutTicks }

        var kept = 0, context = 0, rejected = 0, bursts = 0, keptShort = 0, rejectedShort = 0
        for bout in all {
            let local = bout.increments.filter { $0.ts >= windowStart && $0.ts < windowEndExclusive }
            guard !local.isEmpty else { continue }
            let ticks = local.reduce(0) { $0 + $1.ticks }
            let burstTicks = local.filter(\.isStartBurst).reduce(0) { $0 + $1.ticks }
            if bout.ticks >= sustainedBoutTicks {
                kept += ticks; bursts += burstTicks
            } else if sustained.contains(where: {
                $0.start - walkingContextSeconds <= bout.end && $0.end + walkingContextSeconds >= bout.start
            }) {
                context += ticks; bursts += burstTicks; keptShort += 1
            } else {
                rejected += ticks; rejectedShort += 1
            }
        }
        return Result(legacyTicks: legacy, sustainedTicks: kept, contextTicks: context, rejectedTicks: rejected,
                      startBurstTicks: bursts, keptShortBouts: keptShort, rejectedShortBouts: rejectedShort)
    }

    /// Split time-ordered samples into walking bouts. Walk increments use the same class and plausibility
    /// gates as `StepsCounter`; a start release waits for the next walk increment and is dropped when
    /// none follows within `maxGapSeconds`.
    static func bouts(_ sorted: [StepSample]) -> [Bout] {
        guard sorted.count > 1 else { return [] }
        let hasClasses = StepsCounter.hasActivityClasses(sorted)
        var result: [Bout] = []
        var current: Bout?
        var pendingBurst: Increment?
        for i in 1..<sorted.count {
            let prior = sorted[i - 1], sample = sorted[i]
            guard sample.ts > prior.ts else { continue }
            let delta = (sample.counter - prior.counter) & 0xFFFF
            let isWalk = StepsCounter.shouldCountDelta(activityClass: sample.activityClass,
                                                       hasActivityClasses: hasClasses)
                && StepsCounter.isPlausibleDelta(previousTs: prior.ts, currentTs: sample.ts, delta: delta)
            guard isWalk else {
                if hasClasses, sample.activityClass == 0,
                   sample.ts - prior.ts <= startBurstMaxElapsedSeconds,
                   startBurstTicks.contains(delta) {
                    pendingBurst = Increment(ts: sample.ts, ticks: delta, isStartBurst: true)
                }
                continue
            }
            if let burst = pendingBurst, sample.ts - burst.ts > maxGapSeconds { pendingBurst = nil }
            var bout: Bout
            if let open = current, sample.ts - open.end <= maxGapSeconds {
                bout = open
                bout.end = sample.ts
            } else {
                if let open = current { result.append(open) }
                bout = Bout(start: sample.ts, end: sample.ts, increments: [])
            }
            if let burst = pendingBurst {
                bout.increments.append(burst)
                bout.start = min(bout.start, burst.ts)
                pendingBurst = nil
            }
            bout.increments.append(Increment(ts: sample.ts, ticks: delta, isStartBurst: false))
            current = bout
        }
        if let bout = current { result.append(bout) }
        return result
    }
}
