import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

// Fork: the daily-rhythm readout (CosinorAge beta, `RhythmAge`), experimental and off by default.
//
// Scored once per local day from the seven days BEFORE that day, so the window is fixed for the whole day and a
// second pass has nothing new to find. A week of per-second `@41` is about 600 000 rows; reading it on every
// screen open would cost seconds and battery, so the readout is stored and the screens read finished numbers.
// Each day keeps its own row, which is also the history that shows whether the value follows a change in how
// the wearer moves.
//
// Analysis migration required: no. New series only; no stored value changes meaning.
extension DailyAnalysis {

    public nonisolated static let rhythmAdvanceKey = "rhythm_age_advance"
    public nonisolated static let rhythmMesorKey = "rhythm_mesor"
    public nonisolated static let rhythmAmplitudeKey = "rhythm_amplitude"
    public nonisolated static let rhythmPeakKey = "rhythm_peak_hour"
    public nonisolated static let rhythmSDKey = "rhythm_sd_years"
    /// Observed hours in the window. Written for every scored day, so its presence marks the day as done.
    public nonisolated static let rhythmHoursKey = "rhythm_hours"

    /// The window's average movement in one local clock hour, `rhythm_hour_00` to `rhythm_hour_23`.
    public nonisolated static func rhythmHourKey(_ hour: Int) -> String { String(format: "rhythm_hour_%02d", hour) }

    public nonisolated static var rhythmKeys: [String] {
        [rhythmAdvanceKey, rhythmMesorKey, rhythmAmplitudeKey, rhythmPeakKey, rhythmSDKey, rhythmHoursKey]
            + (0..<24).map(rhythmHourKey)
    }

    /// The stored rows of one outcome. A collecting window keeps only its hours, so no readout survives from a
    /// fuller window it replaced.
    public nonisolated static func rhythmRows(_ outcome: RhythmAge.Outcome, day: String) -> [MetricPoint] {
        switch outcome {
        case .noData:
            return []
        case .collecting(let hours):
            return [MetricPoint(day: day, key: rhythmHoursKey, value: hours)]
        case .reading(let r):
            var rows = [
                MetricPoint(day: day, key: rhythmAdvanceKey, value: r.result.advance),
                MetricPoint(day: day, key: rhythmMesorKey, value: r.result.mesor),
                MetricPoint(day: day, key: rhythmAmplitudeKey, value: r.result.amplitude),
                MetricPoint(day: day, key: rhythmPeakKey, value: r.peakHour),
                MetricPoint(day: day, key: rhythmHoursKey, value: r.result.coverage.observedHours),
            ]
            if let sd = r.result.jackknifeSDYears { rows.append(MetricPoint(day: day, key: rhythmSDKey, value: sd)) }
            for (hour, value) in r.hourly.enumerated() {
                if let value { rows.append(MetricPoint(day: day, key: rhythmHourKey(hour), value: value)) }
            }
            return rows
        }
    }

    /// Score `day` from the seven local days before it, unless it was already scored (`force` re-scores, e.g.
    /// when the switch is turned on). A failed read writes nothing: it is not an empty week.
    public nonisolated static func runRhythmAgePass(store: WhoopStore, strapId: String, computedId: String, age: Int,
                                             sex: String, day: String, tzOffset: Int, force: Bool = false) async {
        guard age > 0, let dayStart = midnightForDayKey(day, offsetSec: tzOffset) else { return }
        do {
            if !force, !(try await store.metricSeries(deviceId: computedId, key: rhythmHoursKey,
                                                      from: day, to: day)).isEmpty { return }
            let rows = try await store.gravitySamples(deviceId: strapId, from: dayStart - 7 * 86_400,
                                                      to: dayStart - 1, limit: Int.max)
            let samples = rows.compactMap { g in g.dynAccel.map { CosinorAgeEngine.ActivitySample(ts: g.ts, g: $0) } }
            let outcome = RhythmAge.evaluate(dyn41: samples, age: Double(age),
                                             sex: RhythmAge.sex(profileValue: sex), tzOffsetSeconds: tzOffset)
            let fresh = rhythmRows(outcome, day: day)
            guard !fresh.isEmpty else { return }
            for key in rhythmKeys where !fresh.contains(where: { $0.key == key }) {
                _ = try await store.deleteMetricSeriesPoint(deviceId: computedId, day: day, key: key)
            }
            _ = try await store.upsertMetricSeries(fresh, deviceId: computedId)
        } catch {
            // Leave the stored rows as they were; the next pass tries again.
        }
    }
}
