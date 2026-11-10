import Foundation
import StrandAnalytics
import WhoopStore

/// The stored traits each night's Rest score was computed with (AI-34): `sleep_need_min` and
/// `sleep_consistency`, written by the daily pass beside `sleep_performance`. Every readout that rebuilds a
/// night's Rest from its daily row, or quotes a sleep need, reads them here, so no screen can score a night
/// with a need the pass did not use.
///
/// A night without stored traits (just synced, before the pass reached it) carries the newest earlier
/// night's: the traits are learned from the nights before a night and move slowly, and the pass replaces
/// them with the exact ones on its next run. With nothing stored at all it is the cold start
/// (`Rest.Inputs.coldStart`), the same inputs the pass uses on a first night.
public struct RestTraitLookup: Equatable, Sendable {
    public static let needKey = "sleep_need_min"
    public static let consistencyKey = "sleep_consistency"
    /// How far back a read reaches for an earlier night to carry from.
    public static let carryLookbackDays = 30

    /// Day → stored need (minutes) and regularity (percent), from the computed series.
    public let needMinByDay: [String: Double]
    public let consistencyPctByDay: [String: Double]

    public init(needMinByDay: [String: Double], consistencyPctByDay: [String: Double]) {
        self.needMinByDay = needMinByDay
        self.consistencyPctByDay = consistencyPctByDay
    }

    public static let empty = RestTraitLookup(needMinByDay: [:], consistencyPctByDay: [:])

    /// The traits `day`'s Rest was (or, for a night not yet scored, will most nearly be) computed with.
    public func inputs(forDay day: String) -> AnalyticsEngine.Rest.Inputs {
        if let need = needMinByDay[day] {
            return .stored(needMin: need, consistencyPct: consistencyPctByDay[day])
        }
        guard let carried = needMinByDay.keys.filter({ $0 < day }).max() else { return .coldStart }
        return .stored(needMin: needMinByDay[carried], consistencyPct: consistencyPctByDay[carried])
    }

    /// The need (minutes) `day`'s Rest was scored with: the one need every sleep readout names for that night.
    public func needMin(forDay day: String) -> Double {
        inputs(forDay: day).needHours * 60.0
    }

    /// The need tonight is measured against: the newest of `days`' (the debt ledger, the Sleep tab's
    /// headline, the coach's ledger). The cold-start population need when `days` is empty.
    public func currentNeedMin(days: [String]) -> Double {
        guard let newest = days.max() else { return AnalyticsEngine.Rest.Inputs.coldStart.needHours * 60.0 }
        return needMin(forDay: newest)
    }

    /// The traits stored under `deviceIds` (computed ids, first wins a day) over `[from, to]`, reaching
    /// `carryLookbackDays` earlier so the first nights of the range can carry.
    public static func read(store: WhoopStore, deviceIds: [String], from: String, to: String) async -> RestTraitLookup {
        let start = HealthspanWindow.dayKey(from, plus: -carryLookbackDays)
        var need: [String: Double] = [:], consistency: [String: Double] = [:]
        for id in deviceIds {
            for p in (try? await store.metricSeries(deviceId: id, key: needKey, from: start, to: to)) ?? []
            where need[p.day] == nil { need[p.day] = p.value }
            for p in (try? await store.metricSeries(deviceId: id, key: consistencyKey, from: start, to: to)) ?? []
            where consistency[p.day] == nil { consistency[p.day] = p.value }
        }
        return RestTraitLookup(needMinByDay: need, consistencyPctByDay: consistency)
    }
}

extension StoreReader {
    /// The Rest traits of the wearer's own nights (the computed ids, active strap first).
    public func restTraits(from: String, to: String) async -> RestTraitLookup {
        await RestTraitLookup.read(store: store, deviceIds: computedReadIds, from: from, to: to)
    }
}
