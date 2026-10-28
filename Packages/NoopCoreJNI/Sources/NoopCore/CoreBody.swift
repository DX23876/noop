import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// The Body screen on Android (parity plan 2.3): the measurements the shared reader resolves, with the shared
/// comparisons, Navy estimate, labels and tape guidance. New readings are built here and written by the host
/// through its input lane, so the classic screens and the core hold the same rows.
enum CoreBody {
    struct Reading: Encodable { var day: String; var value: Double; var source: String; var id: String? }
    struct Site: Encodable { var key: String; var label: String; var current: Double?; var change: Double?; var guidance: String? }
    struct Change: Encodable { var key: String; var label: String; var fromDay: String; var deltaCm: Double }
    struct Output: Encodable {
        var today: String
        var weight: [Reading]
        /// NOOP's own weigh-ins, newest first, with the ids an edit or delete needs.
        var weighIns: [Reading]
        var bodyFat: [Reading]
        var leanMass: [Reading]
        var height: Reading?
        var measured: [Site]
        var unmeasured: [Site]
        var changes: [Change]
        var lostCm: Double?
        var gainedCm: Double?
        var weightChangeKg: Double?
        var navyEstimate: Double?
        var navyMissing: [String]
    }

    @MainActor
    static func snapshot(reader: StoreReader, days: Int, comparisonDays: Int, equation: NavyEquation?, now: Date = Date()) async -> Output {
        let metrics = await BodyMetricsReader.read(reader: reader, activeDeviceId: reader.activeDeviceId, days: days)
        let today = StoreReader.localDayKey(now)
        let from = StoreReader.localDayKey(now.addingTimeInterval(-Double(comparisonDays) * 86_400))
        func readings(_ key: String) -> [Reading] {
            metrics.series(key).map { Reading(day: $0.day, value: $0.value, source: $0.source, id: $0.id) }
        }
        func site(_ key: String) -> Site {
            Site(key: key, label: BodyPreparation.label(key), current: metrics.asOf(key, day: today)?.value,
                 change: BodyPreparation.siteChange(metrics, key), guidance: BodyPreparation.guidance(key))
        }
        let changes = BodyPreparation.circumferenceChanges(metrics, from: from, to: today)
        let total = changes.isEmpty ? nil : CircumferenceProgress.total(changes)
        return Output(
            today: today, weight: readings(WhoopStore.bodyWeightMetricKey),
            weighIns: ((try? await reader.store.bodyWeights(deviceId: WhoopStore.noopWeightSourceId)) ?? [])
                .sorted { $0.takenAt > $1.takenAt }.prefix(30)
                .map { Reading(day: $0.day, value: $0.weightKg, source: $0.source, id: $0.id) },
            bodyFat: readings("body_fat"),
            leanMass: readings("lean_mass"),
            height: metrics.asOf("height", day: today).map { Reading(day: $0.day, value: $0.value, source: $0.source, id: $0.id) },
            measured: BodyPreparation.measuredSites(metrics).map(site),
            unmeasured: (["height"] + BodyPreparation.unmeasuredSites(metrics)).filter { $0 != "height" || metrics.asOf("height", day: today) == nil }.map(site),
            changes: changes.map { Change(key: $0.key, label: BodyPreparation.label($0.key), fromDay: $0.fromDay, deltaCm: $0.deltaCm) },
            lostCm: total?.lostCm, gainedCm: total?.gainedCm,
            weightChangeKg: BodyPreparation.weightChangeKg(metrics, from: from, to: today),
            navyEstimate: equation.flatMap { BodyPreparation.navyEstimate(metrics, today: today, equation: $0) },
            navyMissing: equation.map { BodyPreparation.navyMissingSites(metrics, today: today, equation: $0).map(BodyPreparation.label) } ?? [])
    }

    /// The rows for one measurement session, in Room's column shape, for the host to write through its lane.
    static func rows(values: [String: Double], deviceId: String, takenAt: Date, note: String?) -> [LabMarkerRow] {
        BodyPreparation.measurementRows(values, deviceId: deviceId, takenAt: takenAt, source: "manual", note: note)
    }

    /// A weigh-in on NOOP's own weight lane, as Apple's `logWeight` writes it; the store re-projects the day.
    static func logWeight(store: WhoopStore, kg: Double, at: Date, note: String?) async -> Bool {
        guard kg > 0, kg.isFinite else { return false }
        let row = BodyWeightRow(id: UUID().uuidString, deviceId: WhoopStore.noopWeightSourceId,
                                day: StoreReader.localDayKey(at), takenAt: Int(at.timeIntervalSince1970), weightKg: kg,
                                source: "manual", note: note?.isEmpty == true ? nil : note)
        return (try? await store.upsertBodyWeights([row])) != nil
    }

    /// Deletes a weigh-in NOOP owns; false for an unknown id.
    static func deleteWeight(store: WhoopStore, id: String) async -> Bool {
        (try? await store.deleteBodyWeight(id: id)) ?? false
    }
}
