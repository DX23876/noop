import Foundation
import StrandAnalytics
import StrandImport
import WhoopStore

// BodyMetricsSeries.swift — assembling the one body-measurement resolver from the stores that hold
// the readings.
//
// The analytics half (`BodyMetrics`) knows how to answer "what was true then" without ever looking
// forward. This file is the other half: where the readings come from.
//
// TWO SOURCES, DELIBERATELY NOT MERGED INTO ONE TABLE:
//
//   • Weight goes through `weightSeries`, which is already THE canonical resolver for it — it unions
//     NOOP weigh-ins with Apple Health under the "one source wins a day, never a sum" rule. Resolving
//     weight a fourth way here is precisely the duplication this feature exists to end.
//   • Every other measurement is a `LabMarkerRow` in the `bodyMeasurement` category, which already
//     carries day, instant, value, unit, source and note, and already has CSV import, backup, Explore
//     and a detail screen behind it.
//
// The energy path keeps `CausalWeightResolver`: it smooths over ten days and bounds staleness at 90,
// and changing what it computes is not part of moving where data lives.

extension Repository {

    /// The body-measurement resolver, assembled from every store that holds a reading.
    ///
    /// Built fresh rather than cached: the callers that need it on a hot path hold onto the resolved
    /// value, not the resolver, and a stale cache here would resurrect exactly the "two places
    /// disagree about the same body" problem this replaces.
    func bodyMetrics(days: Int = 4_000) async -> BodyMetrics {
        var readings: [String: [BodyReading]] = [:]

        for point in await weightSeries(days: days) {
            let instant = WeightSeries.date(forDay: point.day)
                .map { Int($0.timeIntervalSince1970) } ?? 0
            readings[WhoopStore.bodyWeightMetricKey, default: []].append(
                BodyReading(day: point.day, takenAt: instant, value: point.value,
                            source: point.source == .manual ? "manual" : Self.appleHealthSource))
        }

        if let store = await storeHandle() {
            // BOTH device scopes. Lab markers are stored per device, and body readings legitimately
            // arrive under two: what the wearer types lands under the active strap's id, while the
            // waist HealthKit imports lands under `apple-health`. Reading only one silently hid a whole
            // source — and it hid the Apple one, which is exactly the sync the Body page promises.
            var rows: [LabMarkerRow] = []
            for scope in Set([deviceId, Self.appleHealthSource]) {
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
        }

        return BodyMetrics(readings: readings)
    }

    /// Writes one measurement session: one instant, n values, one optional note.
    ///
    /// A session rather than a value at a time because that is how people measure — tape in hand,
    /// several sites in a row — and because one shared instant is what lets the sides of a pair be
    /// compared without matching up two separate entries afterwards.
    ///
    /// Returns how many readings were stored.
    @discardableResult
    func recordBodyMeasurements(_ values: [String: Double], takenAt: Date = Date(),
                                source: String = "manual", note: String? = nil) async -> Int {
        guard let store = await storeHandle() else { return 0 }
        let epoch = Int(takenAt.timeIntervalSince1970)
        let day = Self.localDayKey(takenAt)
        let rows = values.compactMap { key, value -> LabMarkerRow? in
            guard value.isFinite, value > 0 else { return nil }
            let definition = MarkerCatalog.definition(for: key)
            return LabMarkerRow(
                id: "\(key)-\(epoch)-\(UUID().uuidString.prefix(8))",
                deviceId: deviceId, markerKey: key,
                category: (definition?.category ?? .bodyMeasurement).rawValue,
                day: day, takenAt: epoch, value: value, valueText: nil,
                unit: definition?.canonicalUnit ?? "cm",
                source: source, note: note, referenceText: nil)
        }
        guard !rows.isEmpty, (try? await store.upsertLabMarkers(rows)) != nil else { return 0 }
        return rows.count
    }
}

// MARK: - Retiring the undated scalars

extension Repository {

    /// One-shot: turns the typed profile scalars into dated readings, so no body value is left as an
    /// undated number that two parts of the app can disagree about.
    ///
    /// **What date, when the scalar has none.** `ProfileStore` never recorded when weight, height or
    /// waist were typed, so "the date it was last known" is not recoverable. Stamping them at today
    /// would claim a measurement that was not taken today. Stamping them at the wearer's EARLIEST
    /// recorded day is both honest and behaviour-preserving: the scalar already applied to all of that
    /// wearer's history — every caller reading it got the same number for every day — so a reading
    /// effective from the start reproduces exactly what they see now, and any real dated measurement
    /// supersedes it from its own day. A fresh install with no history falls back to today, which is
    /// then the truthful date: the number was typed just now.
    ///
    /// **Only what is missing.** A scalar is written only when its key has no reading at all. Someone
    /// who has been logging weigh-ins does not get a profile-sourced duplicate underneath them.
    ///
    /// The `profile` source token is what keeps this honest downstream: these rows say where they came
    /// from, and a chart can tell a typed standing value from a measurement.
    func migrateProfileBodyScalarsIfNeeded(weightKg: Double, heightCm: Double,
                                           waistCm: Double) async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.bodyScalarMigrationKey) else { return }

        let existing = await bodyMetrics()
        let candidates: [(key: String, value: Double)] = [
            (WhoopStore.bodyWeightMetricKey, weightKg), ("height", heightCm), ("waist", waistCm),
        ]
        var pending: [String: Double] = [:]
        for candidate in candidates where candidate.value > 0 {
            guard existing.latest(candidate.key) == nil else { continue }
            pending[candidate.key] = candidate.value
        }

        if !pending.isEmpty {
            let earliest = days.first?.day
            let stamp = earliest.flatMap { WeightSeries.date(forDay: $0) } ?? Date()
            let stored = await recordBodyMeasurements(pending, takenAt: stamp, source: "profile")
            // Only latch once the write actually landed. A failed write that latched anyway would
            // retire the scalars from a store that never received them.
            guard stored > 0 else { return }
        }
        defaults.set(true, forKey: Self.bodyScalarMigrationKey)
    }

    /// Latch for the one-shot above.
    static let bodyScalarMigrationKey = "body.scalars.migrated.v1"
}

// MARK: - Changing what was recorded

extension Repository {

    /// Corrects one stored reading — its value, the day it was taken, or both.
    ///
    /// Only readings NOOP owns can be corrected. A `nil` id means the reading came from somewhere else
    /// (Apple Health, or the weight series) and belongs to that source; silently writing a NOOP copy
    /// over it would create exactly the two-places-disagree problem this feature exists to end.
    @discardableResult
    func updateBodyMeasurement(id: String, markerKey: String, value: Double,
                               takenAt: Date) async -> Bool {
        guard let store = await storeHandle(), value.isFinite, value > 0 else { return false }
        let definition = MarkerCatalog.definition(for: markerKey)
        let row = LabMarkerRow(
            id: id, deviceId: deviceId, markerKey: markerKey,
            category: (definition?.category ?? .bodyMeasurement).rawValue,
            day: Self.localDayKey(takenAt), takenAt: Int(takenAt.timeIntervalSince1970),
            value: value, valueText: nil, unit: definition?.canonicalUnit ?? "cm",
            source: "manual", note: nil, referenceText: nil)
        return (try? await store.upsertLabMarkers([row])) != nil
    }

    /// Removes one stored reading. The caller confirms first — this does not ask.
    @discardableResult
    func deleteBodyMeasurement(id: String) async -> Bool {
        guard let store = await storeHandle() else { return false }
        return (try? await store.deleteLabMarker(id: id)) ?? false
    }
}
