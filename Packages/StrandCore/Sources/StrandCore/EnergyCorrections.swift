import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Energy reads and corrections the daily pass runs, moved from `Repository` so the Apple and Android passes price
/// workouts alike (Android parity plan 1.1). The app keeps its side effects (the Health rewrite, the scheduled
/// energy refresh) around the earliest correction these return.
public enum EnergyCorrections {
    /// Cursor the pass lowers to the first day a re-score re-derived, so the next energy refresh covers it.
    public static let rederivedFromCursor = "energy:rederivedFrom"

    /// The aerobic ceiling (METs) each day's energy model used, for this model generation, keyed by local day
    /// (`WorkoutEnergyDisplay.peakMET(on:in:)` reads it), including the carry window before `fromDay`.
    public static func peakMETByDay(store: WhoopStore, deviceId: String, fromDay: String,
                                    toDay: String) async -> [String: Double] {
        let rows = (try? await store.whoopDailyEnergy(
            deviceId: deviceId, from: WeeklyDigestEngine.addDays(fromDay, -EnergyModelRefresh.peakMETCarryDays),
            to: toDay)) ?? []
        var byDay: [String: Double] = [:]
        for row in rows where row.modelVersion == WhoopDailyEnergyEstimate.modelVersion {
            if let peak = row.peakMET, peak.isFinite, peak > 0 { byDay[row.day] = peak }
        }
        return byDay
    }

    /// Records that a re-score re-derived the days from `dayStartTs` on (their sleep and workouts are energy inputs
    /// the write sequence does not see), from the day before, since a night starts the evening before.
    public static func noteInputsRederived(store: WhoopStore, dayStartTs: Int) async {
        try? await store.lowerCursor(rederivedFromCursor, to: dayStartTs - 86_400)
    }

    /// Re-prices every manual workout with energy and no recorded source whose figure reproduces an old formula on
    /// the strap's heart rate for its window (`LegacyWorkoutEnergy.looksComputed`), using that day's weight and
    /// resting rate; a row already recorded as computed is priced again as it stands. Rows with entered provenance
    /// or without enough strap heart rate stay unchanged. Returns the start of the earliest corrected workout, and
    /// hands it to `committed` even when a later read throws, so corrections already written get their follow-ups.
    @MainActor public static func correctLegacyWorkoutEnergy(reader: StoreReader, profile base: UserProfile,
                                                  committed: (Int) -> Void = { _ in }) async throws -> Int? {
        let store = reader.store
        let now = Int(Date().timeIntervalSince1970)
        // Live sessions were historically saved under "my-whoop" even when the strap has a physical device id; a
        // failed registry lookup must not silently drop an archived owner from a pass whose cursor is then committed.
        let registered = try DeviceRegistryStore(dbQueue: store.registryWriter).all()
            .filter { $0.brand.caseInsensitiveCompare("WHOOP") == .orderedSame }
            .map(\.id)
        let readIds = StoreReader.rawWhoopSourceIds(activeDeviceId: reader.activeDeviceId, registeredWhoopIds: registered)
        var ownedRows: [(owner: String, row: WorkoutRow)] = []
        for owner in readIds {
            var offset = 0
            while true {
                let page = try await store.workouts(deviceId: owner, from: 0, to: now, limit: 500, offset: offset)
                ownedRows += page.compactMap { row in
                    guard row.source == "manual", row.endTs > row.startTs, (row.energyKcal ?? 0) > 0 else { return nil }
                    return (owner, row)
                }
                if page.count < 500 { break }
                offset += page.count
            }
        }
        guard let first = ownedRows.map({ $0.row.startTs }).min() else { return nil }
        var known: [WorkoutKey: WorkoutEnergySource] = [:]
        for owner in Set(ownedRows.map(\.owner)) {
            known.merge(try await store.workoutEnergySources(deviceId: owner, from: first, to: now)) { current, _ in current }
        }
        let pending: [(owner: String, row: WorkoutRow, source: WorkoutEnergySource?)] = ownedRows.compactMap { owned in
            let source = known[WorkoutKey(deviceId: owned.owner, startTs: owned.row.startTs, sport: owned.row.sport)]
            return source == .entered ? nil : (owned.owner, owned.row, source)
        }
        guard !pending.isEmpty else { return nil }
        let firstDay = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(first)))
        let today = StoreReader.localDayKey(Date())
        let restFrom = WeeklyDigestEngine.addDays(firstDay, -14)
        var imported: [String: DailyMetric] = [:], computed: [String: DailyMetric] = [:]
        for id in reader.importedReadIds {
            for m in try await store.dailyMetrics(deviceId: id, from: restFrom, to: today) {
                imported[m.day] = imported[m.day].map { StoreReader.coalesceDay($0, m) } ?? m
            }
        }
        for id in reader.computedReadIds {
            for m in try await store.dailyMetrics(deviceId: id, from: restFrom, to: today) {
                computed[m.day] = computed[m.day].map { StoreReader.coalesceDay($0, m) } ?? m
            }
        }
        var resting: [String: Double] = [:]
        for metric in StoreReader.mergeDaily(imported: Array(imported.values), computed: Array(computed.values)) {
            if let value = metric.restingHr, value > 0 { resting[metric.day] = Double(value) }
        }
        let peaks = await peakMETByDay(store: store, deviceId: reader.activeDeviceId, fromDay: firstDay, toDay: today)
        let weightFrom = StoreReader.localDayKey(Date().addingTimeInterval(-4_000 * 86_400))
        let weightTo = StoreReader.localDayKey(Date().addingTimeInterval(86_400))
        let observations = await WeightSeries.series(reader: reader, from: weightFrom, to: weightTo)
            .compactMap { point in
                WeightSeries.date(forDay: point.day).map {
                    CausalWeightObservation(timestamp: Int($0.timeIntervalSince1970), weightKg: point.value,
                                            source: point.source == .manual ? .manual : .health)
                }
            }
        var earliest: Int?
        defer { if let earliest { committed(earliest) } }
        for (owner, row, source) in pending {
            let day = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(row.startTs)))
            var byTimestamp: [Int: HRSample] = [:]
            for id in readIds {
                for sample in try await store.hrSamples(deviceId: id, from: row.startTs, to: row.endTs, limit: 40_000)
                    where byTimestamp[sample.ts] == nil {
                    byTimestamp[sample.ts] = sample
                }
            }
            let samples = byTimestamp.values.sorted { $0.ts < $1.ts }
            guard samples.count >= 2, let stored = row.energyKcal else { continue }
            var profile = base
            if let weight = CausalWeightResolver.weight(at: row.startTs, observations: observations) {
                profile.weightKg = weight
            }
            let restingHR = WorkoutHeartRateFill.carriedRestingHR(on: day, in: resting)
            let kcal = WorkoutEnergyEstimate.boutKcal(
                samples, sport: row.sport, profile: profile, hrMax: profile.maxHR, restingHR: restingHR,
                peakMET: EnergyModelRefresh.peakMET(on: day, in: peaks), distanceM: row.distanceM)
            guard kcal > 0 else { continue }
            let key = WorkoutKey(deviceId: owner, startTs: row.startTs, sport: row.sport)
            if source == .computed {
                guard abs(kcal - stored) >= 0.5 else { continue }
                if try await store.repriceComputedWorkoutEnergy(for: key, matching: stored, to: kcal) {
                    earliest = min(earliest ?? row.startTs, row.startTs)
                }
                continue
            }
            let matchesOffloaded = LegacyWorkoutEnergy.looksComputed(
                stored: stored, samples: samples, sport: row.sport, profile: profile,
                hrMax: profile.maxHR, restingHR: restingHR)
            let matchesLiveSummary = (row.distanceM ?? 0) > 0 && LegacyWorkoutEnergy.looksComputed(
                stored: stored, averageHR: row.avgHr, durationSeconds: row.durationS,
                profile: profile, hrMax: profile.maxHR, restingHR: restingHR)
            guard matchesOffloaded || matchesLiveSummary else { continue }
            if try await store.correctLegacyWorkoutEnergy(for: key, matching: stored, to: kcal) {
                earliest = min(earliest ?? row.startTs, row.startTs)
            }
        }
        return earliest
    }
}
