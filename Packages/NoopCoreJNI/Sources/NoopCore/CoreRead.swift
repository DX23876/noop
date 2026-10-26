import Foundation
import StrandCore
import WhoopStore

/// What the Android screens read from the core's store (Android plan E-2), as small JSON documents. The reads go
/// through `StoreReader` and resolve as the Apple screens' `Repository` does: imported values win field by field,
/// the core's computed ("-noop") rows fill the rest, and the active strap wins over the canonical import. Values
/// the store does not have stay null.
public enum CoreRead {
    /// One day as the Today screen shows it.
    public struct Day: Codable, Equatable, Sendable {
        public var day: String
        public var charge: Double?, effort: Double?, rest: Double?
        public var sleepMinutes: Double?, deepMinutes: Double?, remMinutes: Double?, lightMinutes: Double?
        public var efficiency: Double?, restingHr: Int?, hrv: Double?, respRate: Double?, spo2: Double?
        public var skinTempDev: Double?, steps: Int?
    }

    /// One night with its stages: `stages` is the timeline (empty for an imported night that stores totals only),
    /// `minutes` the stage totals the Sleep screen states, summed over the night's blocks as on iOS.
    public struct Night: Codable, Equatable, Sendable {
        public struct Stage: Codable, Equatable, Sendable {
            public var stage: String, start: Int, end: Int
        }
        public struct Minutes: Codable, Equatable, Sendable {
            public var wake: Double, light: Double, deep: Double, rem: Double
        }
        public var startTs: Int, endTs: Int, efficiency: Double?, restingHr: Int?, hrv: Double?, edited: Bool
        public var stages: [Stage]
        public var minutes: Minutes?
    }

    /// One value of a metric on one day.
    public struct Point: Codable, Equatable, Sendable {
        public var day: String, value: Double
        public init(day: String, value: Double) { self.day = day; self.value = value }
    }

    /// The mean heart rate of one five-minute stretch; `ts` is its start in unix seconds.
    public struct HeartPoint: Codable, Equatable, Sendable {
        public var ts: Int, bpm: Double
        public init(ts: Int, bpm: Double) { self.ts = ts; self.bpm = bpm }
    }

    /// The metrics a trend screen can chart.
    public enum Metric: String, CaseIterable, Sendable {
        case charge, effort, rest, hrv, restingHr, sleepMinutes, respRate
    }

    public static func day(_ day: String, reader: StoreReader) async -> Day? {
        guard let row = await merged(from: day, to: day, reader: reader).first(where: { $0.day == day }) else {
            return nil
        }
        let rest = await restSeries(from: day, to: day, reader: reader).last?.value
        return Day(day: row.day, charge: row.recovery, effort: row.strain, rest: rest,
                   sleepMinutes: row.totalSleepMin, deepMinutes: row.deepMin, remMinutes: row.remMin,
                   lightMinutes: row.lightMin, efficiency: row.efficiency, restingHr: row.restingHr,
                   hrv: row.avgHrv, respRate: row.respRateBpm, spo2: row.spo2Pct, skinTempDev: row.skinTempDevC,
                   steps: row.steps)
    }

    /// The main night of every day between `from` and `to` (unix seconds), oldest first, as the Apple Sleep tab
    /// shows them (`SleepNight`): a night split into blocks reads as one, a nap is not a night, and a sleepless
    /// lead stub does not move the bedtime. The stages are absolute, with the gaps between blocks as "wake".
    public static func nights(from: Int, to: Int, reader: StoreReader,
                              offsetSec: Int = TimeZone.current.secondsFromGMT()) async -> [Night] {
        let sessions = await reader.allSleepSessions(from: from, to: to)
        // The learner reads the whole history, as `Repository.habitualMidsleepSec()` does, not just the window.
        let now = Int(Date().timeIntervalSince1970)
        let habitual = await reader.habitualMidsleepSec(from: now - 4000 * 86_400, to: now + 86_400,
                                                        offsetSec: offsetSec)
        return SleepNight.days(sessions).compactMap { day -> Night? in
            guard let main = SleepNight.main(day, offsetSec: offsetSec, habitualMidsleepSec: habitual) else {
                return nil
            }
            let longest = main.group.max { ($0.endTs - $0.effectiveStartTs) < ($1.endTs - $1.effectiveStartTs) }
            let stages = main.intervals.map {
                Night.Stage(stage: $0.stage == "awake" ? "wake" : $0.stage,
                            start: main.onset + Int($0.start), end: main.onset + Int($0.end))
            }
            return Night(startTs: main.onset, endTs: main.wake,
                         efficiency: main.minutes.total > 0 ? main.minutes.asleep / main.minutes.total : nil,
                         restingHr: longest?.restingHr, hrv: longest?.avgHrv,
                         edited: main.group.contains { $0.userEdited }, stages: stages,
                         minutes: Night.Minutes(wake: main.minutes.awake, light: main.minutes.light,
                                                deep: main.minutes.deep, rem: main.minutes.rem))
        }.sorted { $0.startTs < $1.startTs }
    }

    public static func series(_ metric: Metric, from: String, to: String, reader: StoreReader) async -> [Point] {
        if metric == .rest { return await restSeries(from: from, to: to, reader: reader) }
        return await merged(from: from, to: to, reader: reader).compactMap { row in
            let value: Double? = switch metric {
            case .charge: row.recovery
            case .effort: row.strain
            case .hrv: row.avgHrv
            case .restingHr: row.restingHr.map(Double.init)
            case .sleepMinutes: row.totalSleepMin
            case .respRate: row.respRateBpm
            case .rest: nil
            }
            return value.map { Point(day: row.day, value: $0) }
        }.sorted { $0.day < $1.day }
    }

    /// The heart rate between `from` and `to` (unix seconds) in five-minute means, across every strap the wearer
    /// has, as the Apple Today screen's banked trace reads it (`StoreReader.hrBuckets`).
    public static func heartRate(from: Int, to: Int, reader: StoreReader) async -> [HeartPoint] {
        await reader.hrBuckets(from: from, to: to, bucketSeconds: 300).map { HeartPoint(ts: $0.ts, bpm: $0.bpm) }
    }

    /// Imported days with the computed rows filling their gaps, one row per day (`Repository`'s daily cache).
    private static func merged(from: String, to: String, reader: StoreReader) async -> [DailyMetric] {
        StoreReader.mergeDaily(imported: await reader.unionDailyMetrics(from: from, to: to),
                               computed: await reader.unionComputedDailyMetrics(from: from, to: to))
    }

    /// Rest has no daily column: the imported series wins a day, the computed one fills it, the active strap
    /// wins within each layer (`Repository.exploreSeries`' order).
    private static func restSeries(from: String, to: String, reader: StoreReader) async -> [Point] {
        var byDay: [String: Double] = [:]
        for id in reader.computedReadIds.reversed() + reader.importedReadIds.reversed() {
            for p in (try? await reader.store.metricSeries(deviceId: id, key: "sleep_performance", from: from,
                                                           to: to)) ?? [] { byDay[p.day] = p.value }
        }
        return byDay.sorted { $0.key < $1.key }.map { Point(day: $0.key, value: $0.value) }
    }

    /// Compact JSON with sorted keys, so the same answer is the same text.
    public static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}
