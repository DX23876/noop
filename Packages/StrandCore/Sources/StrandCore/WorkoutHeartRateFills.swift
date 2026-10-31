import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// Average, peak and Effort for Apple Health workouts.
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
//
// Moved from `Repository` (Android plan B3 step 4); the app passes the wearer's maximum heart rate, sex and
// Effort method and tells its screens when fills changed.
public enum WorkoutHeartRateFills {
    /// What a fill pass did: how many workouts it filled, and whether it wrote at all (a pass that only
    /// removed stale fills writes without filling).
    public struct Outcome: Equatable, Sendable {
        public let filled: Int
        public let wrote: Bool
        public init(filled: Int, wrote: Bool) { self.filled = filled; self.wrote = wrote }
        public static let untouched = Outcome(filled: 0, wrote: false)
    }

    /// Whether a Health workout was written by the WHOOP app rather than recorded by the Watch or another
    /// app. Those copies keep their empty heart-rate fields.
    public static func isWhoopAuthored(bundleId: String?) -> Bool {
        bundleId?.lowercased().contains("whoop") == true
    }

    /// Computes and stores the heart rate of every Apple Health workout starting in `[from, to]` that came
    /// without one, and removes fills whose heart rate no longer covers their session, and says what it did.
    ///
    /// Throws when a stored read fails, so the recipe that runs it (AI-16) stays pending instead of marking
    /// a partial pass done. The band trace is read through the ordinary facade, which reads an unreachable
    /// strap as empty; its raw history spans only the recent weeks, which every sync fills again.
    public static func fillApple(reader: StoreReader, from: Int, to: Int, maxHR: Double,
                                 sex: String) async throws -> Outcome {
        let store = reader.store
        var rows: [WorkoutRow] = []
        var offset = 0
        while true {
            let page = try await store.workouts(deviceId: MetricResolver.appleHealthSource, from: from, to: to,
                                                limit: 500, offset: offset)
            rows += page
            if page.count < 500 { break }
            offset += page.count
        }
        let candidates = rows.filter {
            WorkoutSource.isAppleHealth($0.source) && $0.avgHr == nil && $0.endTs > $0.startTs
        }
        guard let first = candidates.map(\.startTs).min(),
              let last = candidates.map(\.startTs).max() else { return .untouched }

        var metadata: [String: WorkoutSourceMetadataRow] = [:]
        for row in try await store.workoutSourceMetadata(from: from, to: to)
        where WorkoutSource.isAppleHealth(row.source) {
            metadata["\(row.startTs)|\(row.sport)"] = row
        }
        let firstDay = WeeklyDigestEngine.addDays(StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(first))),
                                                  -WorkoutHeartRateFill.appleRestingWindowDays)
        let lastDay = WeeklyDigestEngine.addDays(StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(last))),
                                                 WorkoutHeartRateFill.appleRestingWindowDays)
        let own = await reader.restingHrByDay(fromDay: firstDay, toDay: lastDay)
        var apple: [String: Double] = [:]
        for metric in try await store.dailyMetrics(deviceId: MetricResolver.appleHealthSource, from: firstDay, to: lastDay) {
            if let value = metric.restingHr, value > 0 { apple[metric.day] = Double(value) }
        }
        let now = Int(Date().timeIntervalSince1970)

        var keys: [WorkoutKey] = []
        var fills: [WorkoutHeartRateFillRow] = []
        for row in candidates {
            // Without the source metadata NOOP cannot tell a Watch recording from a WHOOP copy; the
            // history backfill writes it for every workout, and until then the row is left as it is.
            guard let meta = metadata["\(row.startTs)|\(row.sport)"] else { continue }
            let key = WorkoutKey(deviceId: MetricResolver.appleHealthSource, startTs: row.startTs, sport: row.sport)
            keys.append(key)
            guard !Self.isWhoopAuthored(bundleId: meta.sourceBundleId) else { continue }
            let band = await reader.hrSamples(from: row.startTs, to: row.endTs, limit: 20_000)
            let minutes = try await store.workoutHeartRateBuckets(componentKey: meta.componentKey)
                .map { (start: $0.bucketStart, bpm: $0.bpm) }
            let day = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(row.startTs)))
            let resting = WorkoutHeartRateFill.restingHR(on: day, own: own, apple: apple)
            guard let result = WorkoutHeartRateFill.resolve(
                band: band, watchMinutes: minutes, start: row.startTs, end: row.endTs,
                maxHR: maxHR, restingHR: resting) else { continue }
            fills.append(WorkoutHeartRateFillRow(
                key: key, avgHr: result.averageHR, maxHr: result.maxHR, strain: result.strain,
                hrSource: result.source.rawValue, restingHrUsed: result.restingHR,
                coveredMinutes: result.coveredMinutes, possibleMinutes: result.possibleMinutes,
                updatedAtTs: now))
        }
        guard !keys.isEmpty else { return .untouched }
        try await store.replaceWorkoutHeartRateFills(fills, keys: keys)
        // A session the cardio load priced before its Watch trace arrived was priced without one, and a
        // ledger row older than a week is never computed again on its own. Free exactly those.
        for fill in fills where fill.hrSource == WorkoutHeartRateFill.Source.watch.rawValue {
            try await store.dropUntracedTrainingSessionLoads(from: fill.key.startTs - 600,
                                                             to: fill.key.startTs + 600)
        }
        return Outcome(filled: fills.count, wrote: true)
    }

    /// Fill namespace of workouts NOOP recorded itself or the wearer entered (`WorkoutSource.manual`). Their
    /// rows carry no device id, so one namespace keyed by start and sport stands for all of them.
    public static let recordedWorkoutFillNamespace = "noop-recorded"

    /// Computes and stores the heart rate of every recorded or entered workout starting in `[from, to]` that
    /// was saved without one, from the band's own trace, and removes fills whose trace no longer covers their
    /// session. A live recording takes its heart rate from the stream; with the link down while it ran it is
    /// saved empty, though the strap kept the trace and hands it over at the next sync. Says what it did.
    public static func fillRecorded(reader: StoreReader, from: Int, to: Int, maxHR: Double,
                                    sex: String) async throws -> Outcome {
        let store = reader.store
        var rows: [WorkoutRow] = []
        for id in StoreReader.rawWhoopSourceIds(activeDeviceId: reader.activeDeviceId, registeredWhoopIds: []) {
            var offset = 0
            while true {
                let page = try await store.workouts(deviceId: id, from: from, to: to, limit: 500, offset: offset)
                rows += page
                if page.count < 500 { break }
                offset += page.count
            }
        }
        let candidates = rows.filter {
            WorkoutSource.classify($0.source).isWearerLogged && $0.avgHr == nil && $0.endTs > $0.startTs
        }
        guard let first = candidates.map(\.startTs).min(),
              let last = candidates.map(\.startTs).max() else { return .untouched }
        let own = await reader.restingHrByDay(fromDay: StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(first))),
                                              toDay: StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(last))))
        let now = Int(Date().timeIntervalSince1970)
        var keys: [WorkoutKey] = []
        var fills: [WorkoutHeartRateFillRow] = []
        for row in candidates {
            let key = WorkoutKey(deviceId: Self.recordedWorkoutFillNamespace, startTs: row.startTs, sport: row.sport)
            keys.append(key)
            let band = await reader.hrSamples(from: row.startTs, to: row.endTs, limit: 20_000)
            let day = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(row.startTs)))
            let resting = WorkoutHeartRateFill.restingHR(on: day, own: own, apple: [:])
            guard let result = WorkoutHeartRateFill.resolve(
                band: band, watchMinutes: [], start: row.startTs, end: row.endTs,
                maxHR: maxHR, restingHR: resting) else { continue }
            fills.append(WorkoutHeartRateFillRow(
                key: key, avgHr: result.averageHR, maxHr: result.maxHR, strain: result.strain,
                hrSource: result.source.rawValue, restingHrUsed: result.restingHR,
                coveredMinutes: result.coveredMinutes, possibleMinutes: result.possibleMinutes,
                updatedAtTs: now))
        }
        guard !keys.isEmpty else { return .untouched }
        try await store.replaceWorkoutHeartRateFills(fills, keys: keys)
        return Outcome(filled: fills.count, wrote: true)
    }

    /// The fill namespace a row's stored fill lives in, or nil for a source that is never filled.
    public static func fillNamespace(for row: WorkoutRow) -> String? {
        if WorkoutSource.isAppleHealth(row.source) { return MetricResolver.appleHealthSource }
        if WorkoutSource.classify(row.source).isWearerLogged { return recordedWorkoutFillNamespace }
        return nil
    }

    /// Lays stored fills over Apple Health rows and recorded or entered workouts that came without heart rate,
    /// and Health step counts over Apple Health rows. Runs after twins are resolved, so a filled value never
    /// decides which twin stands for a session.
    public static func overlay(_ rows: [WorkoutRow], store: WhoopStore) async -> [WorkoutRow] {
        let apple = rows.filter { WorkoutSource.isAppleHealth($0.source) }
        let fillable = rows.filter { Self.fillNamespace(for: $0) != nil }
        guard let lo = fillable.map(\.startTs).min(), let hi = fillable.map(\.startTs).max() else { return rows }
        var fills = (try? await store.workoutHeartRateFills(deviceId: MetricResolver.appleHealthSource,
                                                            from: lo, to: hi)) ?? [:]
        for (key, fill) in (try? await store.workoutHeartRateFills(deviceId: Self.recordedWorkoutFillNamespace,
                                                                   from: lo, to: hi)) ?? [:] {
            fills[key] = fill
        }
        var steps: [String: Int] = [:]
        for meta in apple.isEmpty ? [] : ((try? await store.workoutSourceMetadata(from: lo, to: hi)) ?? [])
        where WorkoutSource.isAppleHealth(meta.source) {
            if let value = meta.steps, value > 0 { steps["\(meta.startTs)|\(meta.sport)"] = value }
        }
        guard !fills.isEmpty || !steps.isEmpty else { return rows }
        return rows.map { row in
            guard let namespace = Self.fillNamespace(for: row) else { return row }
            let fill = fills[WorkoutKey(deviceId: namespace, startTs: row.startTs, sport: row.sport)]
            let healthSteps = steps["\(row.startTs)|\(row.sport)"]
            guard fill != nil || healthSteps != nil else { return row }
            return WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: row.sport, source: row.source,
                              durationS: row.durationS, energyKcal: row.energyKcal,
                              avgHr: row.avgHr ?? fill?.avgHr, maxHr: row.maxHr ?? fill?.maxHr,
                              strain: row.strain ?? fill?.strain, distanceM: row.distanceM,
                              zonesJSON: row.zonesJSON, notes: row.notes, steps: row.steps ?? healthSteps)
        }
    }
}
