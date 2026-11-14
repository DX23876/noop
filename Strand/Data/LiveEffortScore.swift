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

    /// The window the score is taken over: the logical day's midnight to now. One clock sample supplies
    /// both ends, so the two can never straddle a tick.
    public static func window(now: Date) -> (from: Int, to: Int) {
        let dayStart = Calendar.current.startOfDay(for: LogicalDay.date(now))
        return (Int(dayStart.timeIntervalSince1970), Int(now.timeIntervalSince1970))
    }

    /// How far back workout rows are read for the spans below: a session that began before midnight
    /// still counts inside today's window.
    public static func workoutWindow(now: Date) -> (from: Int, to: Int) {
        let (from, to) = window(now: now)
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
