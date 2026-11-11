import Foundation
import WhoopStore

// MARK: - Menstrual cycle tracker storage
//
// A logged period start is one value-1 metricSeries point under the dedicated local source
// `noop-cycle`. The source is intentionally separate from strap/import/computed ids so an import or
// re-analysis cannot overwrite sensitive user-entered history. This is the byte-parity twin of Android
// `CycleTrackingStore`: same source id, key, value, local ISO day, ordering, and real-delete semantics.
// No schema change is needed and no data leaves the device.

// `CycleTrackingStore` itself (source, key and the store reads) is shared with the Android core in
// `CycleReading.swift`; these are the iPhone's entry points.

extension Repository {

    /// Logged period-start days, oldest first. A value gate makes reads forward-compatible if another
    /// cycle event kind is ever projected into this source.
    func periodStarts(from: String = CycleTrackingStore.earliestDay,
                      to: String = CycleTrackingStore.latestDay) async -> [String] {
        guard let store = await storeHandle() else { return [] }
        return await CycleTrackingStore.periodStarts(store: store, from: from, to: to)
    }

    /// Log (or idempotently re-log) one local calendar day as cycle day 1.
    func logPeriodStart(day: String) async {
        guard let store = await storeHandle() else { return }
        await CycleTrackingStore.logPeriodStart(store: store, day: day)
        noteCycleTrackingChanged()
    }

    /// Remove one logged start. This is a physical row delete, not a zero/sentinel marker.
    func deletePeriodStart(day: String) async {
        guard let store = await storeHandle() else { return }
        _ = try? await store.deleteMetricSeriesPoint(deviceId: CycleTrackingStore.sourceId,
                                                      day: day,
                                                      key: CycleTrackingStore.periodStartKey)
        noteCycleTrackingChanged()
    }

    /// Delete every logged period start after an explicit user confirmation.
    func deleteAllPeriodStarts() async {
        guard let store = await storeHandle() else { return }
        _ = try? await store.deleteMetricSeries(deviceId: CycleTrackingStore.sourceId,
                                                 key: CycleTrackingStore.periodStartKey)
        noteCycleTrackingChanged()
    }
}
