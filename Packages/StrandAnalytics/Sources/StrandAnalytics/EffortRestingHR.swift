import Foundation

/// The resting heart rate Effort is scored against (#2438, decided 2026-11-25).
///
/// The Effort curve was fitted on WHOOP's zones and Strain, which WHOOP computes from its own resting heart
/// rate: a dynamic average weighted towards the night's last deep sleep. The resting heart rate NOOP shows is
/// the night's lowest five minutes, which sits well below that (on one wearer's nights since October the main
/// night's mean ran about 10 bpm above it; on a paired wearer WHOOP's value ran 4 to 6 above it). Scored
/// against the lower value every reading sits higher in the reserve, which lifted light days most. So Effort,
/// its zones and the workouts it is scored from read the main night's mean HR (`PrimarySessionRestingHR`,
/// stored as `rhr_primary_session`), while the shown resting heart rate and every other model keep theirs.
///
/// This is the one resolver. The daily pass resolves each day here and stores the answer; the live score, the
/// activity refresh, the wake-day cycle and Android read what the pass stored and resolve through here only
/// for a day the pass has not reached yet.
public enum EffortRestingHR {
    /// How many nights before the day stand in when the day has no night of its own.
    public static let fallbackNights = 7
    /// How far back, in days, those nights are looked for, so a few unworn days do not empty the fallback.
    public static let fallbackLookbackDays = 30
    /// The metric series the daily pass stores each day's resolved value under (computed "-noop" id).
    public static let seriesKey = "rhr_effort"
    /// The metric series of the main night's mean HR (`AnalyticsEngine.primarySessionRestingHR`).
    public static let nightMeanSeriesKey = "rhr_primary_session"
    /// A resting heart rate outside this range is treated as missing.
    public static let plausible: ClosedRange<Double> = 30 ... 130

    /// The means of the last `fallbackNights` nights with one before `day` (`yyyy-MM-dd`), within
    /// `fallbackLookbackDays`, oldest first: `resolve`'s `recentNightMeans`.
    public static func nightsBefore(_ day: String, in means: [String: Double]) -> [Double] {
        let start = AnalyticsEngine.dayStartUtcSeconds(day)
        var found: [Double] = []
        for back in 1 ... fallbackLookbackDays where found.count < fallbackNights {
            if let v = means[AnalyticsEngine.dayString(start - back * 86_400)] { found.append(v) }
        }
        return found.reversed()
    }

    /// The first day `nightsBefore` can reach for `day`: where a read of the night means for it starts.
    public static func lookbackStart(for day: String) -> String {
        AnalyticsEngine.dayString(AnalyticsEngine.dayStartUtcSeconds(day) - fallbackLookbackDays * 86_400)
    }

    /// The day's value: the main night's mean; without one, the median of the last `fallbackNights` nights'
    /// means (`recentNightMeans` oldest first, before the day); without those, a device's own resting heart
    /// rate (a lowest reading, so only as a last resort); then `StrainScorer.defaultRestingHR`.
    public static func resolve(nightMean: Double?, recentNightMeans: [Double], deviceProvided: Int?) -> Double {
        if let nightMean, plausible.contains(nightMean) { return nightMean }
        let recent = recentNightMeans.filter { plausible.contains($0) }.suffix(fallbackNights).sorted()
        if !recent.isEmpty {
            let mid = recent.count / 2
            return recent.count % 2 == 1 ? recent[recent.startIndex + mid]
                : (recent[recent.startIndex + mid - 1] + recent[recent.startIndex + mid]) / 2
        }
        if let deviceProvided, plausible.contains(Double(deviceProvided)) { return Double(deviceProvided) }
        return StrainScorer.defaultRestingHR
    }
}
