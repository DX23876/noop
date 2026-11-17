import Foundation
import StrandAnalytics
import WhoopProtocol
import StrandCore
import WhoopStore

/// Today's in-progress Effort, as every Today surface must read it.
///
/// The stored Effort is rewritten only when the heavy daily pass runs, so early in the day it still holds
/// yesterday's figure or a stale zero. Correcting for that means re-scoring today's raw heart rate, and
/// the part that must not drift is not the arithmetic but the PARAMETERS: the window, the row limit, the
/// resting-rate fallback and which workout time counts. A surface that got one of them wrong would not
/// fail, it would quietly show a different number for the same day.
///
/// That is exactly what happened: the Apple screens share this read, the Android Forge screen never had
/// it and showed the stored row raw, so the same wearer saw 4.9 on one Today and 6.5 on the other, and
/// the first only caught up after the nightly pass (issue #41). This holds the parameters in one place;
/// each platform performs its own two reads over the window it is given here.
public enum LiveEffortScore {

    /// An EXPLICIT limit, not the chart-sized default: `hrSamples` orders by time and truncates the
    /// NEWEST rows, so a smaller cap silently stops the live score climbing partway through the day.
    public static let hrLimit = 200_000

    /// The window the score is taken over. One clock sample supplies both ends, so the two can never
    /// straddle a tick.
    ///
    /// `cycleStart` is the active day cycle's start, from `cycleStart(onsetMarkers:now:offsetSec:)`. It is
    /// not a refinement: when the wearer's day begins at sleep onset — which is the DEFAULT
    /// (`DayCycleMode.persisted(nil)`) — the pass scores the STORED Effort over exactly that span
    /// (`DayCycleIntelligenceIntegration.compute` re-scores strain over the cycle's heart rate), and the
    /// live figure is floored against the stored one. A live window of a different length therefore does
    /// not fail; it quietly makes `effectiveEffort` return the larger of two figures taken over two
    /// different spans, which is a number over no window at all.
    ///
    /// nil — the midnight cycle, where the pass keeps no onset markers, or no cycle established yet — is
    /// the logical day's midnight, which is what the pass scores then too.
    public static func window(now: Date, cycleStart: Int? = nil) -> (from: Int, to: Int) {
        let dayStart = Calendar.current.startOfDay(for: LogicalDay.date(now))
        return (cycleStart ?? Int(dayStart.timeIntervalSince1970), Int(now.timeIntervalSince1970))
    }

    /// The active cycle's start, from the pass's own onset markers
    /// (`DayCycleIntelligenceIntegration.onsetKey`, written under the computed "-noop" sources), or nil
    /// when no cycle applies.
    ///
    /// The markers exist only while the wearer's day starts at sleep onset: in midnight mode the pass
    /// replaces them with an empty set, so their presence IS the mode and no preference has to be read
    /// here and kept in step with the pass's. Resolution is `DayCycleResolver.activeWindow`, the pass's
    /// own, including its cap past which an open cycle becomes a synthetic midnight — so the live window
    /// cannot stretch back further than the stored figure's does.
    ///
    /// A marker left behind by a switch to the midnight cycle is read until the next pass clears it. That
    /// is the same stale state the stored row is in, so the two still agree, which is the point.
    public static func cycleStart(onsetMarkers: [Double], now: Date,
                                  offsetSec: Int = TimeZone.current.secondsFromGMT()) -> Int? {
        let nowTs = Int(now.timeIntervalSince1970)
        // Compared as Double before converting: `Int(_:)` TRAPS on a value outside its range, and these
        // come out of a stored series. A corrupt marker must leave the window alone, not stop the app.
        let usable = onsetMarkers.filter { $0.isFinite && $0 > 0 && $0 <= Double(nowTs) }
        guard let newest = usable.max() else { return nil }
        let latest = DayCycleWindow(id: "live", startInclusive: Int(newest), endExclusive: nowTs,
                                    displayDay: "", source: .detectedSleep)
        return DayCycleResolver.activeWindow(mode: .sleepOnset, latestSleep: latest, now: nowTs,
                                             offsetSec: offsetSec).startInclusive
    }

    /// How far back the onset markers are read: the cycle in force now was written on today's or
    /// yesterday's wake day, and a day either side costs nothing.
    public static let onsetMarkerDays = 3

    /// How far back workout rows are read for the spans below: a session that began before the window
    /// still counts inside it.
    public static func workoutWindow(now: Date, cycleStart: Int? = nil) -> (from: Int, to: Int) {
        let (from, to) = window(now: now, cycleStart: cycleStart)
        return (from - 86_400, to + 1)
    }

    /// The score from the two reads and the two parameters, or nil when there is too little heart rate to
    /// score — callers then fall back to the stored row rather than to a fabricated number.
    ///
    /// [restingHr] is the shown day's own resting rate, the daily pass's input; nil falls back to the
    /// scorer's default, exactly as the pass does. Below 50 % of heart-rate reserve only workout time
    /// counts, and those spans come from the same resolver the stored day reads.
    public static func score(hr: [HRSample], workoutRows: [WorkoutRow],
                             maxHR: Double?, restingHr: Int?) -> Double? {
        StrainScorer.strain(hr, maxHR: maxHR,
                            restingHR: restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR,
                            lowIntensity: .countedIn(DailyAnalysis.effortWorkoutSpans(workoutRows)))
    }
}
