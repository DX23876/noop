import Foundation
import StrandAnalytics
import WhoopStore

/// The span the day in progress is measured over, for everything that states one of its figures.
///
/// In `midnight` mode a day is the calendar day. In `sleepOnset` mode, which is the default, a day begins
/// when the wearer fell asleep: the nightly pass scores each cycle from its onset onward
/// (`DayCycleIntelligenceIntegration`) and stores that onset under the cycle's wake day
/// (`DayCycleIntelligenceIntegration.onsetKey`).
///
/// Anything stating today's figure before the pass runs has to take the same span, and two readouts of
/// Effort did not: the live re-score (`LiveEffortScore`) and the today-activity refresh both ran from
/// local midnight, which in sleep-onset mode falls in the middle of the PREVIOUS cycle for anyone who
/// goes to bed after midnight. Their waking hours before bed were counted twice, once in yesterday's
/// stored cycle and again in today's live figure, and `StrainScorer.effectiveEffort` takes the larger of
/// live and stored, so the number stayed up: a tester who fell asleep at 04:41 and woke at 13:19 found
/// Effort at 47 before getting out of bed (2026-11-19).
///
/// So the span is resolved here, once, from the evidence the pass itself uses.
public enum CycleDayWindow {

    /// The cycle the wearer is in: when it began, and the day it is filed under (its wake day).
    public struct Cycle: Equatable, Sendable {
        public let onset: Int
        public let wakeDay: String
        public init(onset: Int, wakeDay: String) {
            self.onset = onset
            self.wakeDay = wakeDay
        }
    }

    /// How far back the reads below look for a cycle. Past `DayCycleResolver.absoluteMaxOpenSeconds` an
    /// onset no longer opens a window at all, so three days is already generous.
    public static let lookbackSeconds = 3 * 86_400

    /// The cycle in progress, from the pass's stored onsets and the nights the store holds.
    ///
    /// Both, not one. The markers are what the pass scored and so the authority, but they appear only
    /// once a pass has run, and the morning after a night it has not seen yet is exactly when a live
    /// figure matters. A night the store already holds answers for that morning. Whichever opened later
    /// is the cycle the wearer is in.
    ///
    /// A night still running is left out. The pass does roll the day at onset, but nobody reads a screen
    /// then, and rolling early would drop the evening out of the figure the wearer last looked at.
    public static func current(onsets: [MetricPoint], sleeps: [CachedSleepSession],
                               now: Int, offsetSec: Int) -> Cycle? {
        let stored = onsets
            .filter { Int($0.value) <= now && now - Int($0.value) <= lookbackSeconds }
            .max(by: { $0.value < $1.value })
            .map { Cycle(onset: Int($0.value), wakeDay: $0.day) }
        let slept = sleeps
            .filter { $0.endTs <= now && now - $0.effectiveStartTs <= lookbackSeconds }
            .max(by: { $0.effectiveStartTs < $1.effectiveStartTs })
            .map { Cycle(onset: $0.effectiveStartTs,
                         wakeDay: AnalyticsEngine.dayString($0.endTs, offsetSec: offsetSec)) }
        switch (stored, slept) {
        case (nil, nil): return nil
        case (let onlyStored?, nil): return onlyStored
        case (nil, let onlySlept?): return onlySlept
        case (let a?, let b?): return a.onset >= b.onset ? a : b
        }
    }

    /// The two reads `current` needs, so both platforms gather the same evidence.
    public static func current(reader: StoreReader, now: Int, offsetSec: Int) async -> Cycle? {
        let fromDay = AnalyticsEngine.dayString(now - lookbackSeconds - 86_400, offsetSec: offsetSec)
        let toDay = AnalyticsEngine.dayString(now + 86_400, offsetSec: offsetSec)
        async let onsets = reader.unionMetricSeries(key: DayCycleIntelligenceIntegration.onsetKey,
                                                    from: fromDay, to: toDay)
        async let sleeps = reader.allSleepSessions(from: now - lookbackSeconds, to: now)
        return await current(onsets: onsets, sleeps: sleeps, now: now, offsetSec: offsetSec)
    }

    /// The span of the day in progress: `from` inclusive to `now`.
    ///
    /// `DayCycleResolver.activeWindow` decides it, the resolver the pass asks, including its safety cap:
    /// a cycle left open past `absoluteMaxOpenSeconds` falls back to a synthetic midnight rather than
    /// growing without end.
    public static func window(mode: DayCycleMode, cycle: Cycle?, now: Int,
                              offsetSec: Int) -> (from: Int, to: Int) {
        let latest = cycle.map {
            DayCycleWindow(id: $0.wakeDay, startInclusive: $0.onset, endExclusive: now,
                           displayDay: $0.wakeDay, source: .detectedSleep)
        }
        let active = DayCycleResolver.activeWindow(mode: mode, latestSleep: latest, now: now,
                                                   offsetSec: offsetSec)
        return (min(active.startInclusive, now), now)
    }

    /// Which day that span belongs to: the cycle's wake day, or the calendar day when there is no cycle
    /// to go by. Beside `window` because a figure filed under the wrong day is the same defect as a
    /// figure measured over the wrong span.
    public static func day(mode: DayCycleMode, cycle: Cycle?, now: Int, offsetSec: Int) -> String {
        guard mode == .sleepOnset, let cycle,
              now - cycle.onset < DayCycleResolver.absoluteMaxOpenSeconds else {
            return AnalyticsEngine.dayString(now, offsetSec: offsetSec)
        }
        return cycle.wakeDay
    }
}
