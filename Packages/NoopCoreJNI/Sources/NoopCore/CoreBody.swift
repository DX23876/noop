import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// The Body screen on Android (parity plan 2.3): the measurements the shared reader resolves, with the shared
/// comparisons, Navy estimate, labels and tape guidance. New readings are built here and written by the host
/// through its input lane, so the classic screens and the core hold the same rows.
enum CoreBody {
    struct Reading: Encodable {
        var day: String; var value: Double; var source: String; var id: String?
        /// The instant of a weigh-in (unix seconds), so the Today timeline can place it; nil for a day value.
        var takenAt: Int? = nil
    }
    struct Site: Encodable { var key: String; var label: String; var current: Double?; var change: Double?; var guidance: String? }
    struct Change: Encodable {
        var key: String; var label: String; var fromDay: String; var deltaCm: Double
        /// The same site then and now, and whether the change beats the wearer's own tape scatter there.
        var fromValue: Double = 0; var toValue: Double = 0; var exceedsTypicalStep = false
    }
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
        /// `CircumferenceTotal`: sites beyond their scatter each way, and every site with a usable comparison.
        /// Each measured site's readings in the window, for its sparkline and the comparison chart's waist line.
        var siteSeries: [String: [Reading]] = [:]
        var growingSites = 0
        var shrinkingSites = 0
        var comparedSites = 0
        /// The Navy estimate's error against DEXA, in percentage points, for the line under it.
        var navyErrorBand = NavyBodyFat.errorBandPercentagePoints
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
            metrics.series(key).map { Reading(day: $0.day, value: $0.value, source: $0.source, id: $0.id, takenAt: $0.takenAt) }
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
                .map { Reading(day: $0.day, value: $0.weightKg, source: $0.source, id: $0.id, takenAt: $0.takenAt) },
            bodyFat: readings("body_fat"),
            leanMass: readings("lean_mass"),
            height: metrics.asOf("height", day: today).map { Reading(day: $0.day, value: $0.value, source: $0.source, id: $0.id) },
            measured: BodyPreparation.measuredSites(metrics).map(site),
            unmeasured: (["height"] + BodyPreparation.unmeasuredSites(metrics)).filter { $0 != "height" || metrics.asOf("height", day: today) == nil }.map(site),
            changes: changes.map { Change(key: $0.key, label: BodyPreparation.label($0.key), fromDay: $0.fromDay, deltaCm: $0.deltaCm,
                                          fromValue: $0.fromValue, toValue: $0.toValue, exceedsTypicalStep: $0.exceedsTypicalStep) },
            lostCm: total?.lostCm, gainedCm: total?.gainedCm,
            siteSeries: Dictionary(uniqueKeysWithValues: BodyPreparation.measuredSites(metrics).map { ($0, readings($0)) }),
            growingSites: total?.growingSites ?? 0, shrinkingSites: total?.shrinkingSites ?? 0,
            comparedSites: total?.comparedSites ?? 0,
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
        await weighIn(store: store, kg: kg, at: at, note: note, source: "manual") != nil
    }

    /// The stored row of a weigh-in on NOOP's own weight lane, or nil when it was not written. `source` is the row's
    /// token (`WeightSource.storageToken` for the coach's).
    static func weighIn(store: WhoopStore, kg: Double, at: Date, note: String?, source: String) async -> BodyWeightRow? {
        guard kg > 0, kg.isFinite else { return nil }
        let row = BodyWeightRow(id: UUID().uuidString, deviceId: WhoopStore.noopWeightSourceId,
                                day: StoreReader.localDayKey(at), takenAt: Int(at.timeIntervalSince1970), weightKg: kg,
                                source: source, note: note?.isEmpty == true ? nil : note)
        return (try? await store.upsertBodyWeights([row])) != nil ? row : nil
    }

    /// Deletes a weigh-in NOOP owns; false for an unknown id.
    static func deleteWeight(store: WhoopStore, id: String) async -> Bool {
        (try? await store.deleteBodyWeight(id: id)) ?? false
    }
}
