import Foundation
import StrandAnalytics
import StrandImport
import WhoopStore

/// The one body-measurement resolver, assembled from every store that holds a reading (moved from `Repository`,
/// Android plan B3 step 4). Weight goes through `WeightSeries`, the canonical weight resolver; every other
/// measurement is a `LabMarkerRow` in the `bodyMeasurement` category under the active strap or Apple Health; and
/// Apple Health's body fat and lean mass are daily metric points under `apple-health`, read under their own source.
public enum BodyMetricsReader {
    /// Apple Health body readings stored as daily metric points rather than markers.
    public static let appleHealthBodyKeys = ["body_fat", "lean_mass"]

    public static func read(reader: StoreReader, activeDeviceId: String, days: Int, now: Date = Date()) async -> BodyMetrics {
        var readings: [String: [BodyReading]] = [:]
        let from = StoreReader.localDayKey(now.addingTimeInterval(-Double(days) * 86_400))
        let to = StoreReader.localDayKey(now.addingTimeInterval(86_400))

        for point in await WeightSeries.series(reader: reader, from: from, to: to) {
            let instant = WeightSeries.date(forDay: point.day)
                .map { Int($0.timeIntervalSince1970) } ?? 0
            readings[WhoopStore.bodyWeightMetricKey, default: []].append(
                BodyReading(day: point.day, takenAt: instant, value: point.value,
                            source: point.source == .manual ? "manual" : MetricResolver.appleHealthSource))
        }

        let store = reader.store
        // BOTH device scopes. Lab markers are stored per device, and body readings legitimately
        // arrive under two: what the wearer types lands under the active strap's id, while the
        // waist HealthKit imports lands under `apple-health`. Reading only one silently hid a whole
        // source — and it hid the Apple one, which is exactly the sync the Body page promises.
        var rows: [LabMarkerRow] = []
        for scope in Set([activeDeviceId, MetricResolver.appleHealthSource]) {
            rows += (try? await store.labMarkers(
                deviceId: scope,
                category: LabMarkerCategory.bodyMeasurement.rawValue)) ?? []
        }
        for row in rows {
            // A qualitative entry has no number and cannot answer a body question.
            guard let value = row.value else { continue }
            // Weight is resolved above from its own canonical path. A `weight` marker row would
            // otherwise arrive as a second, unreconciled opinion on a day.
            guard row.markerKey != WhoopStore.bodyWeightMetricKey else { continue }
            readings[row.markerKey, default: []].append(
                BodyReading(day: row.day, takenAt: row.takenAt, value: value,
                            source: row.source, id: row.id))
        }
        for key in appleHealthBodyKeys {
            for point in (try? await store.metricSeries(deviceId: MetricResolver.appleHealthSource, key: key,
                                                        from: from, to: to)) ?? [] {
                let instant = WeightSeries.date(forDay: point.day).map { Int($0.timeIntervalSince1970) } ?? 0
                readings[key, default: []].append(
                    BodyReading(day: point.day, takenAt: instant, value: point.value,
                                source: MetricResolver.appleHealthSource))
            }
        }

        return BodyMetrics(readings: readings)
    }
}
