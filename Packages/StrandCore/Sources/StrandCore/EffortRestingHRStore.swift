import Foundation
import StrandAnalytics
import WhoopStore

extension EffortRestingHR {
    /// The resting heart rate Effort reads on each of `days` for the readers outside the daily pass (the live
    /// score, the activity refresh, the Effort rescore, Android): the value the pass stored for the day
    /// (`seriesKey`), else one resolved here from the night means (`nightMeanSeriesKey`) and lowest bins (the
    /// daily rows' resting heart rate) stored for it and the nights before, as the pass resolves a day. `ids`
    /// are the computed ("-noop") sources in precedence order; the first that holds a day wins.
    public static func stored(days: [String], store: WhoopStore, ids: [String]) async -> [String: Double] {
        guard let first = days.min(), let last = days.max() else { return [:] }
        func read(_ key: String, from: String) async -> [String: Double] {
            var byDay: [String: Double] = [:]
            for id in ids {
                for point in (try? await store.metricSeries(deviceId: id, key: key, from: from, to: last)) ?? []
                where byDay[point.day] == nil {
                    byDay[point.day] = point.value
                }
            }
            return byDay
        }
        let resolved = await read(seriesKey, from: first)
        var nights: (means: [String: Double], lowest: [String: Double])?
        var out: [String: Double] = [:]
        for day in days {
            if let value = resolved[day] { out[day] = value; continue }
            if nights == nil {
                let from = lookbackStart(for: first)
                var lowest: [String: Double] = [:]
                for id in ids {
                    for row in (try? await store.dailyMetrics(deviceId: id, from: from, to: last)) ?? []
                    where lowest[row.day] == nil {
                        lowest[row.day] = row.restingHr.map(Double.init)
                    }
                }
                nights = (await read(nightMeanSeriesKey, from: from), lowest)
            }
            let n = nights ?? ([:], [:])
            out[day] = resolve(nightMean: n.means[day], nightLowest: n.lowest[day],
                               recentNights: nightsBefore(day, means: n.means, lowest: n.lowest),
                               deviceProvided: nil)
        }
        return out
    }
}

extension StoreReader {
    /// The Effort resting heart rate the daily pass stored for each day in `[fromDay, toDay]` that it scored,
    /// and nothing for the others: for a caller with its own fallback for days without strap data.
    public func storedEffortRestingHRByDay(fromDay: String, toDay: String) async -> [String: Double] {
        var byDay: [String: Double] = [:]
        for id in rawComputedReadIds {
            for point in (try? await store.metricSeries(deviceId: id, key: EffortRestingHR.seriesKey,
                                                        from: fromDay, to: toDay)) ?? []
            where byDay[point.day] == nil {
                byDay[point.day] = point.value
            }
        }
        return byDay
    }

    /// The resting heart rate a workout filled from the band is scored against on each day in `[fromDay,
    /// toDay]`: the Effort resting rate the pass stored for a day it scored, so the session sits on the yardstick
    /// of the day around it, else the day's own resting rate (`restingHrByDay`). Every fill reads it here.
    public func fillRestingHRByDay(fromDay: String, toDay: String) async -> [String: Double] {
        (await restingHrByDay(fromDay: fromDay, toDay: toDay))
            .merging(await storedEffortRestingHRByDay(fromDay: fromDay, toDay: toDay)) { _, effort in effort }
    }

    /// The resting heart rate Effort reads on `day` (`EffortRestingHR.stored` over this wearer's computed
    /// sources).
    public func effortRestingHR(day: String) async -> Double {
        await EffortRestingHR.stored(days: [day], store: store, ids: rawComputedReadIds)[day]
            ?? StrainScorer.defaultRestingHR
    }
}
