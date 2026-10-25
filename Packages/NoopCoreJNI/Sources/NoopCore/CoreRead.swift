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

    /// One stretch of sleep with its stages.
    public struct Night: Codable, Equatable, Sendable {
        public struct Stage: Codable, Equatable, Sendable {
            public var stage: String, start: Int, end: Int
        }
        public var startTs: Int, endTs: Int, efficiency: Double?, restingHr: Int?, hrv: Double?, edited: Bool
        public var stages: [Stage]
    }

    /// One value of a metric on one day.
    public struct Point: Codable, Equatable, Sendable {
        public var day: String, value: Double
        public init(day: String, value: Double) { self.day = day; self.value = value }
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

    public static func nights(from: Int, to: Int, reader: StoreReader) async -> [Night] {
        await reader.unionSleepSessions(from: from, to: to).map { session in
            let stages = session.stagesJSON.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([Night.Stage].self, from: $0) } ?? []
            return Night(startTs: session.startTsAdjusted ?? session.startTs, endTs: session.endTs,
                         efficiency: session.efficiency, restingHr: session.restingHr, hrv: session.avgHrv,
                         edited: session.userEdited, stages: stages)
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
