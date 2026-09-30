import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// WorkoutHeartRateFillSeries.swift — average, peak and Effort for Apple Health workouts.
//
// Health hands NOOP a workout's sport, duration, energy and distance, never its heart rate. The heart rate
// is at hand all the same: the band's trace for the window, or the minute-averaged samples Health keeps
// with the workout (`workoutHeartRateBucket`, read with the workout and without NOOP's own write-back).
// `WorkoutHeartRateFill` decides which one describes a session; this file reads the inputs, stores the
// answer beside the row (`workoutHeartRateFill`, WhoopStore v73) and lays it over the row when the list is
// read. Never into the row: its columns belong to Health and are rewritten on every sync.
//
// Workouts the WHOOP app copied into Health are left as they arrived: their heart rate is WHOOP's, already
// in its own export, and they would otherwise pass for Watch recordings.
extension Repository {

    /// Whether a Health workout was written by the WHOOP app rather than recorded by the Watch or another
    /// app. Those copies keep their empty heart-rate fields.
    nonisolated static func isWhoopAuthored(bundleId: String?) -> Bool {
        bundleId?.lowercased().contains("whoop") == true
    }

    /// Computes and stores the heart rate of every Apple Health workout starting in `[from, to]` that came
    /// without one, and removes fills whose heart rate no longer covers their session. Returns the number of
    /// workouts filled.
    ///
    /// Throws when a stored read fails, so the recipe that runs it (AI-16) stays pending instead of marking
    /// a partial pass done. The band trace is read through the ordinary facade, which reads an unreachable
    /// strap as empty; its raw history spans only the recent weeks, which every sync fills again.
    @discardableResult
    func fillAppleWorkoutHeartRate(from: Int, to: Int) async throws -> Int {
        guard let store = await storeHandle() else { return 0 }
        var rows: [WorkoutRow] = []
        var offset = 0
        while true {
            let page = try await store.workouts(deviceId: Self.appleHealthSource, from: from, to: to,
                                                limit: 500, offset: offset)
            rows += page
            if page.count < 500 { break }
            offset += page.count
        }
        let candidates = rows.filter {
            WorkoutSource.isAppleHealth($0.source) && $0.avgHr == nil && $0.endTs > $0.startTs
        }
        guard let first = candidates.map(\.startTs).min(),
              let last = candidates.map(\.startTs).max() else { return 0 }

        var metadata: [String: WorkoutSourceMetadataRow] = [:]
        for row in try await store.workoutSourceMetadata(from: from, to: to)
        where WorkoutSource.isAppleHealth(row.source) {
            metadata["\(row.startTs)|\(row.sport)"] = row
        }
        let firstDay = WeeklyDigestEngine.addDays(Self.localDayKey(Date(timeIntervalSince1970: TimeInterval(first))),
                                                  -WorkoutHeartRateFill.appleRestingWindowDays)
        let lastDay = WeeklyDigestEngine.addDays(Self.localDayKey(Date(timeIntervalSince1970: TimeInterval(last))),
                                                 WorkoutHeartRateFill.appleRestingWindowDays)
        let own = await restingHrByDay(fromDay: firstDay, toDay: lastDay)
        var apple: [String: Double] = [:]
        for metric in try await store.dailyMetrics(deviceId: Self.appleHealthSource, from: firstDay, to: lastDay) {
            if let value = metric.restingHr, value > 0 { apple[metric.day] = Double(value) }
        }
        let maxHR = Self.cardioLoadMaxHR(strainProfile)
        let sex = strainProfile?.sex ?? ""
        let method = PuffinExperiment.effortMethod
        let now = Int(Date().timeIntervalSince1970)

        var keys: [WorkoutKey] = []
        var fills: [WorkoutHeartRateFillRow] = []
        for row in candidates {
            // Without the source metadata NOOP cannot tell a Watch recording from a WHOOP copy; the
            // history backfill writes it for every workout, and until then the row is left as it is.
            guard let meta = metadata["\(row.startTs)|\(row.sport)"] else { continue }
            let key = WorkoutKey(deviceId: Self.appleHealthSource, startTs: row.startTs, sport: row.sport)
            keys.append(key)
            guard !Self.isWhoopAuthored(bundleId: meta.sourceBundleId) else { continue }
            let band = await hrSamples(from: row.startTs, to: row.endTs, limit: 20_000)
            let minutes = try await store.workoutHeartRateBuckets(componentKey: meta.componentKey)
                .map { (start: $0.bucketStart, bpm: $0.bpm) }
            let day = Self.localDayKey(Date(timeIntervalSince1970: TimeInterval(row.startTs)))
            let resting = WorkoutHeartRateFill.restingHR(on: day, own: own, apple: apple)
            guard let result = WorkoutHeartRateFill.resolve(
                band: band, watchMinutes: minutes, start: row.startTs, end: row.endTs,
                maxHR: maxHR, restingHR: resting, method: method, sex: sex) else { continue }
            fills.append(WorkoutHeartRateFillRow(
                key: key, avgHr: result.averageHR, maxHr: result.maxHR, strain: result.strain,
                hrSource: result.source.rawValue, restingHrUsed: result.restingHR,
                coveredMinutes: result.coveredMinutes, possibleMinutes: result.possibleMinutes,
                updatedAtTs: now))
        }
        guard !keys.isEmpty else { return 0 }
        try await store.replaceWorkoutHeartRateFills(fills, keys: keys)
        // A session the cardio load priced before its Watch trace arrived was priced without one, and a
        // ledger row older than a week is never computed again on its own. Free exactly those.
        for fill in fills where fill.hrSource == WorkoutHeartRateFill.Source.watch.rawValue {
            try await store.dropUntracedTrainingSessionLoads(from: fill.key.startTs - 600,
                                                             to: fill.key.startTs + 600)
        }
        noteWorkoutAnnotationsChanged()
        return fills.count
    }

    /// Lays stored fills and Health step counts over Apple Health rows that came without them. Runs after
    /// twins are resolved, so a filled value never decides which twin stands for a session.
    func overlayWorkoutFills(_ rows: [WorkoutRow], store: WhoopStore) async -> [WorkoutRow] {
        let apple = rows.filter { WorkoutSource.isAppleHealth($0.source) }
        guard let lo = apple.map(\.startTs).min(), let hi = apple.map(\.startTs).max() else { return rows }
        let fills = (try? await store.workoutHeartRateFills(deviceId: Self.appleHealthSource,
                                                            from: lo, to: hi)) ?? [:]
        var steps: [String: Int] = [:]
        for meta in (try? await store.workoutSourceMetadata(from: lo, to: hi)) ?? []
        where WorkoutSource.isAppleHealth(meta.source) {
            if let value = meta.steps, value > 0 { steps["\(meta.startTs)|\(meta.sport)"] = value }
        }
        guard !fills.isEmpty || !steps.isEmpty else { return rows }
        return rows.map { row in
            guard WorkoutSource.isAppleHealth(row.source) else { return row }
            let fill = fills[WorkoutKey(deviceId: Self.appleHealthSource, startTs: row.startTs, sport: row.sport)]
            let healthSteps = steps["\(row.startTs)|\(row.sport)"]
            guard fill != nil || healthSteps != nil else { return row }
            return WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: row.sport, source: row.source,
                              durationS: row.durationS, energyKcal: row.energyKcal,
                              avgHr: row.avgHr ?? fill?.avgHr, maxHr: row.maxHr ?? fill?.maxHr,
                              strain: row.strain ?? fill?.strain, distanceM: row.distanceM,
                              zonesJSON: row.zonesJSON, notes: row.notes, steps: row.steps ?? healthSteps)
        }
    }

    /// The stored fill of one Apple Health row, for the detail screen's heart-rate source line.
    func workoutHeartRateFill(for row: WorkoutRow) async -> WorkoutHeartRateFillRow? {
        guard WorkoutSource.isAppleHealth(row.source), let store = await storeHandle() else { return nil }
        let key = WorkoutKey(deviceId: Self.appleHealthSource, startTs: row.startTs, sport: row.sport)
        return (try? await store.workoutHeartRateFills(deviceId: Self.appleHealthSource,
                                                       from: row.startTs, to: row.startTs))?[key]
    }

    func noteWorkoutAnnotationsChanged() { workoutAnnotationRevision &+= 1 }
}
