import Foundation

/// The resting heart rate Effort is scored against (#2438, decided 2026-11-25).
///
/// The Effort curve was fitted on WHOOP's zones and Strain, which WHOOP computes from its own resting heart
/// rate: a dynamic average weighted towards the night's last deep sleep, so a value between the night's lowest
/// stretch and its plain mean. NOOP shows the night's lowest five minutes, which sits well below it: on one
/// paired wearer WHOOP's value ran 4 to 6 bpm above NOOP's lowest bin, while the main night's mean runs about 10
/// above it (the owner's nights since October; 8 to 16 by sleep stage in ryanbr/noop#2522). Scored against the
/// lowest bin every reading sat higher in the reserve, which lifted light days most; scored against the mean,
/// hard days fell about twice as far as expected. So a night's value is halfway between the two
/// (`nightValue`), the point that meets the paired wearer and adapts to how much each wearer's night moves.
/// The aim is ranges comparable with WHOOP's, not a copy of its number (owner, 2026-11-25). Effort, its bouts
/// and the workouts it is scored from read it; the shown resting heart rate and every other model keep theirs.
///
/// This is the one resolver. The daily pass resolves each day here and stores the answer; the live score, the
/// activity refresh, the wake-day cycle and Android read what the pass stored and resolve through here only
/// for a day the pass has not reached yet.
public enum EffortRestingHR {
    /// How far from the night's lowest bin towards its mean a night's value sits.
    public static let towardsMean = 0.5
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

    /// A night's value: `towardsMean` of the way from its lowest five-minute bin (the day's shown resting heart
    /// rate) to its main-night mean. nil unless both are there and plausible.
    public static func nightValue(mean: Double?, lowest: Double?) -> Double? {
        guard let mean, let lowest, plausible.contains(mean), plausible.contains(lowest) else { return nil }
        return lowest + (max(mean, lowest) - lowest) * towardsMean
    }

    /// The values of the last `fallbackNights` nights with one before `day` (`yyyy-MM-dd`), within
    /// `fallbackLookbackDays`, oldest first: `resolve`'s `recentNights`. `means` and `lowest` are the stored
    /// main-night means and lowest bins by day.
    public static func nightsBefore(_ day: String, means: [String: Double], lowest: [String: Double]) -> [Double] {
        let start = AnalyticsEngine.dayStartUtcSeconds(day)
        var found: [Double] = []
        for back in 1 ... fallbackLookbackDays where found.count < fallbackNights {
            let key = AnalyticsEngine.dayString(start - back * 86_400)
            if let v = nightValue(mean: means[key], lowest: lowest[key]) { found.append(v) }
        }
        return found.reversed()
    }

    /// The first day `nightsBefore` can reach for `day`: where a read of the nights for it starts.
    public static func lookbackStart(for day: String) -> String {
        AnalyticsEngine.dayString(AnalyticsEngine.dayStartUtcSeconds(day) - fallbackLookbackDays * 86_400)
    }

    /// The day's value: its night's (`nightValue`); without one, the median of the last `fallbackNights` nights'
    /// values (`recentNights` oldest first, before the day); without those, a device's own resting heart rate (a
    /// lowest reading, so only as a last resort); then `StrainScorer.defaultRestingHR`.
    public static func resolve(nightMean: Double?, nightLowest: Double?, recentNights: [Double],
                               deviceProvided: Int?) -> Double {
        if let night = nightValue(mean: nightMean, lowest: nightLowest) { return night }
        let recent = recentNights.filter { plausible.contains($0) }.suffix(fallbackNights).sorted()
        if !recent.isEmpty {
            let mid = recent.count / 2
            return recent.count % 2 == 1 ? recent[recent.startIndex + mid]
                : (recent[recent.startIndex + mid - 1] + recent[recent.startIndex + mid]) / 2
        }
        if let deviceProvided, plausible.contains(Double(deviceProvided)) { return Double(deviceProvided) }
        return StrainScorer.defaultRestingHR
    }
}
