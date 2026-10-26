import Foundation
import StrandAnalytics
import StrandTraining
import WhoopProtocol
import WhoopStore

/// Reads over the union of source ids one wearer's history lives under (Android plan B3 step 4, moved from
/// `Repository`). The active strap comes first so its live, measured rows win a day; every other registered
/// WHOOP follows in registry order; the canonical import namespace ("my-whoop") is the final fallback. A
/// single-device install reads one id and gets exactly the rows it always did.
///
/// The app keeps the registry snapshot (`Repository.registeredWhoopIds`) and builds one of these per read.
public struct StoreReader: Sendable {
    public let store: WhoopStore
    /// The strap the app is connected to now.
    public let activeDeviceId: String
    /// Every registered WHOOP, in registry order.
    public let registeredWhoopIds: [String]

    public init(store: WhoopStore, activeDeviceId: String, registeredWhoopIds: [String]) {
        self.store = store
        self.activeDeviceId = activeDeviceId
        self.registeredWhoopIds = registeredWhoopIds
    }

    /// The distinct IMPORTED/MEASURED source ids to union for a dashboard read: the active strap (live raw,
    /// #814) and the canonical imported id. Active strap FIRST so per-day dedup lets the measured/live row
    /// win over the imported one. Deduped, so a single-device install (active id == canonical) reads one id.
    public static func importedReadIds(activeDeviceId: String) -> [String] {
        let canonical = MetricResolver.whoopSource
        return activeDeviceId == canonical ? [activeDeviceId] : [activeDeviceId, canonical]
    }
    /// The distinct COMPUTED ("-noop") source ids to union: the active strap's computed sibling and the
    /// canonical computed sibling. Same dedup rule as `importedReadIds`.
    public static func computedReadIds(activeDeviceId: String) -> [String] {
        let computed = activeDeviceId + "-noop", canonical = MetricResolver.whoopSource + "-noop"
        return computed == canonical ? [computed] : [computed, canonical]
    }
    /// `yyyy-MM-dd` in the device's local zone, matching how `DailyMetric.day` is stored.
    public static func localDayKey(_ date: Date) -> String { dayKeyFormatter.string(from: date) }
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    public var importedReadIds: [String] { Self.importedReadIds(activeDeviceId: activeDeviceId) }
    public var computedReadIds: [String] { Self.computedReadIds(activeDeviceId: activeDeviceId) }
    /// Raw physiological streams are a worn timeline, not a property of whichever strap is active now:
    /// every registered physical WHOOP, active first, the canonical import namespace last. Archived devices
    /// remain, since archive means "stop connecting, keep data".
    public var rawPhysiologyReadIds: [String] {
        Self.rawWhoopSourceIds(activeDeviceId: activeDeviceId, registeredWhoopIds: registeredWhoopIds)
    }
    /// The computed ("-noop") siblings of `rawPhysiologyReadIds`.
    public var rawComputedReadIds: [String] {
        rawPhysiologyReadIds.map { $0.hasSuffix("-noop") ? $0 : $0 + "-noop" }
    }

    /// Pure ordering contract shared with Android's parity guard: current active source first, every other
    /// registered WHOOP in stable registry order, canonical history last; duplicates collapse.
    public static func rawWhoopSourceIds(activeDeviceId: String,
                                         registeredWhoopIds: [String]) -> [String] {
        let canonical = MetricResolver.whoopSource
        let middle = registeredWhoopIds.filter { $0 != activeDeviceId && $0 != canonical }
        return ([activeDeviceId] + middle + [canonical]).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
    }

    /// The subset of [workoutNamespaces] a DELETE may touch: the strap namespaces only.
    ///
    /// Imported history is read-only, and that is enforced everywhere else: the row menu offers only
    /// "Duplicate as manual…" for an imported row, `bulkDeleteWorkouts` skips those classes outright, and
    /// `mergeWorkouts` refuses them with "never rewrite imported history". A delete that swept the import
    /// namespaces would reach underneath all three guards and destroy a wearer's imported Apple Health,
    /// Hevy/Liftosaur or FIT/GPX/TCX row, which nothing in the UI ever offers to remove.
    ///
    /// That a cross-source twin is COLLAPSED into one row at display time does not license deleting the
    /// imported half of the pair: the dedup is a presentation decision, and the surviving import is
    /// exactly the history this repository promises not to rewrite.
    ///
    /// A `.manual` row, the only class the delete button is offered for, is written under a strap id, so
    /// this set is what a delete actually needs.
    public static func deletableWorkoutNamespaces(rawIds: [String]) -> [String] {
        (rawIds + rawIds.map { $0.hasSuffix("-noop") ? $0 : $0 + "-noop" })
            .reduce(into: [String]()) { acc, id in
                if !acc.contains(id) { acc.append(id) }
            }
    }

    /// Every namespace the Workouts list reads a row out of, in read order, duplicates collapsed.
    ///
    /// Why this exists: the list unions many device ids while `deleteWorkout` deleted from exactly ONE,
    /// the active strap. A row banked under any other namespace (a retained strap, a computed `-noop`
    /// sibling, Apple Health, an imported lifting session or activity file) was therefore VISIBLE BUT
    /// UNDELETABLE: the delete reported nothing, the reload re-read the row from the namespace the delete
    /// never touched, and it came straight back. Reported as workouts that ignore the delete button
    /// (#2278).
    ///
    /// Deriving both sides from one function is the point. Spelling the union out twice is what let them
    /// disagree, and a future namespace added to the read alone would reintroduce exactly this bug.
    public static func workoutNamespaces(rawIds: [String]) -> [String] {
        deletableWorkoutNamespaces(rawIds: rawIds)
            + [WorkoutSource.appleHealthSource, "lifting", WorkoutSource.hevySource, "activity-file",
               WorkoutSource.ouraSource]
    }

    /// Daily-metric rows across the imported union for a day range, DEDUPED per day with the ACTIVE STRAP
    /// winning over the canonical import (a live/measured row beats an imported one for the same day). The
    /// single returned row per day feeds the existing imported-vs-computed `mergeDaily` unchanged.
    public func unionDailyMetrics(from: String, to: String) async -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for id in importedReadIds {   // active strap FIRST → it claims each column, canonical fills its gaps
            for m in (try? await store.dailyMetrics(deviceId: id, from: from, to: to)) ?? [] {
                byDay[m.day] = byDay[m.day].map { Self.coalesceDay($0, m) } ?? m
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Computed ("-noop") daily-metric rows across the computed union, DEDUPED per day (active strap's
    /// computed sibling wins over the canonical computed sibling).
    public func unionComputedDailyMetrics(from: String, to: String) async -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for id in computedReadIds {
            for m in (try? await store.dailyMetrics(deviceId: id, from: from, to: to)) ?? [] {
                byDay[m.day] = byDay[m.day].map { Self.coalesceDay($0, m) } ?? m
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// metricSeries points across the imported union for a key + day range, DEDUPED per day with the active
    /// strap winning (same precedence as `unionDailyMetrics`).
    public func unionMetricSeries(key: String, from: String, to: String) async -> [MetricPoint] {
        var byDay: [String: MetricPoint] = [:]
        for id in importedReadIds {
            for p in (try? await store.metricSeries(deviceId: id, key: key, from: from, to: to)) ?? [] where byDay[p.day] == nil {
                byDay[p.day] = p
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Daily series for any metric key from a given source. When `source` is the canonical WHOOP id, the active
    /// strap is unioned in so a series stored under a re-added strap's id still surfaces beside the canonical
    /// history (deduped per day, active strap wins); other sources read verbatim. A wake-day in
    /// `suppressedSleepWakeDays` (an explicit sleep deletion) hides its sleep values.
    public func series(key: String, source: String, from: String, to: String,
                       suppressedSleepWakeDays: Set<String>) async -> [(day: String, value: Double)] {
        let pts: [MetricPoint]
        if source == MetricResolver.whoopSource {
            pts = await unionMetricSeries(key: key, from: from, to: to)
        } else {
            pts = (try? await store.metricSeries(deviceId: source, key: key, from: from, to: to)) ?? []
        }
        let suppressed = MetricResolver.isSleepDayMetricKey(key) ? suppressedSleepWakeDays : Set<String>()
        return pts.filter { !suppressed.contains($0.day) }.map { ($0.day, $0.value) }
    }

    /// Sleep sessions across every registered WHOOP source for a ts range, keeping ALL sessions per day (a nap + a main
    /// night both survive) and collapsing near-identical nights recorded under different union ids.
    /// The downstream `mergeSleep`/`userEditedDays` do the per-day collapse, exactly as before.
    public func unionSleepSessions(from: Int, to: Int, limit: Int = 4000) async -> [CachedSleepSession] {
        Self.dedupBlocks(await unionRawSleepBlocks(ids: rawPhysiologyReadIds, from: from, to: to, limit: limit))
    }

    /// Computed ("-noop") sleep sessions across every registered WHOOP source, keeping ALL sessions per day
    /// and collapsing near-identical nights recorded under different computed siblings.
    public func unionComputedSleepSessions(from: Int, to: Int, limit: Int = 4000) async -> [CachedSleepSession] {
        Self.dedupBlocks(await unionRawSleepBlocks(ids: rawComputedReadIds, from: from, to: to, limit: limit))
    }

    /// Every sleep block the Sleep screens browse between `from` and `to` (unix seconds), oldest to newest by
    /// onset: imported blocks of the whole union, then computed blocks for the days no import covers, each layer
    /// with near-identical cross-source copies collapsed. All blocks of a day stay (a split night and a nap
    /// both), and days the wearer deleted (`suppressedWakeDays`, local end-day keys) are left out.
    public func allSleepSessions(from: Int, to: Int, suppressedWakeDays: Set<String> = []) async -> [CachedSleepSession] {
        func endDayKey(_ s: CachedSleepSession) -> String {
            let offsetSec = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            return AnalyticsEngine.dayString(s.endTs, offsetSec: offsetSec)
        }
        let imported = Self.dedupBlocks(await unionRawSleepBlocks(ids: rawPhysiologyReadIds, from: from, to: to))
            .filter { !suppressedWakeDays.contains(endDayKey($0)) }
        let computed = Self.dedupBlocks(await unionRawSleepBlocks(ids: rawComputedReadIds, from: from, to: to))
            .filter { !suppressedWakeDays.contains(endDayKey($0)) }
        let cal = Calendar.current
        func endDay(_ s: CachedSleepSession) -> Date {
            cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
        }
        let importedDays = Set(imported.map(endDay))
        let computedKept = computed.filter { !importedDays.contains(endDay($0)) }
        return (imported + computedKept).sorted { $0.effectiveStartTs < $1.effectiveStartTs }
    }

    /// The wearer's learned habitual midsleep (local seconds of the day) from the sleep blocks between `from`
    /// and `to`, the imported and computed unions each de-duplicated, keyed by the local day of each block's
    /// midpoint (`SleepStageTotals.habitualMidsleepSec`). nil during the cold start. (#547)
    public func habitualMidsleepSec(from: Int, to: Int, offsetSec: Int) async -> Int? {
        SleepStageTotals.habitualMidsleepSec(await sleepHistoryBlocks(from: from, to: to, offsetSec: offsetSec),
                                             offsetSec: offsetSec)
    }

    /// The sleep history the habitual learners read, as `HistoryBlock`s keyed by the local day of each block's
    /// midpoint: the imported and the computed union, each de-duplicated.
    public func sleepHistoryBlocks(from: Int, to: Int, offsetSec: Int) async -> [SleepStageTotals.HistoryBlock] {
        let imported = Self.dedupBlocks(await unionRawSleepBlocks(ids: rawPhysiologyReadIds, from: from, to: to))
        let computed = Self.dedupBlocks(await unionRawSleepBlocks(ids: rawComputedReadIds, from: from, to: to))
        return (imported + computed).compactMap { s -> SleepStageTotals.HistoryBlock? in
            let start = s.effectiveStartTs, end = s.endTs
            guard end > start else { return nil }
            let mid = start + (end - start) / 2
            return SleepStageTotals.HistoryBlock(start: start, end: end,
                                                 dayKey: AnalyticsEngine.dayString(mid, offsetSec: offsetSec))
        }
    }

    /// ALL sleep blocks across `ids` for a ts range, concatenated (NOT collapsed to one per day, used by
    /// `allSleepSessions`, which expands split sleeps). Active strap first.
    public func unionRawSleepBlocks(ids: [String], from: Int, to: Int, limit: Int = 4000) async -> [CachedSleepSession] {
        var blocks: [CachedSleepSession] = []
        for id in ids {
            blocks += (try? await store.sleepSessions(deviceId: id, from: from, to: to, limit: limit)) ?? []
        }
        return blocks
    }

    /// Latest HR-sample ts across the imported union, or nil. The auto-land Today anchor (#597) uses this,
    /// so a re-added strap's live raw AND the canonical history both count toward "the most recent data day".
    public func unionLatestHRSampleTs() async -> Int? {
        var latest: Int?
        for id in importedReadIds {
            if let ts = (try? await store.latestHRSampleTs(deviceId: id)) ?? nil {
                latest = max(latest ?? ts, ts)
            }
        }
        return latest
    }

    /// Resting heart rate per local day, for pricing a session whose energy nobody recorded.
    ///
    /// Per DAY rather than "the current one", for the reason `CausalWeightResolver` exists: a session
    /// last August belongs to the body that did it. And it is not a nicety — the resting rate sets
    /// the activity gate the Keytel estimate is measured against, so the same 77-minute session at an
    /// average of 103 bpm prices at 649 kcal against a resting rate of 45 and at 99 kcal against 70,
    /// where the average falls below the gate entirely. A default would not be an approximation.
    ///
    /// The rate is the one the dashboard shows for the day: imported rows first, NOOP's computed rows
    /// filling the days they lack (`mergeDaily`). Reading the imported rows alone left every day after
    /// the last WHOOP export without a resting rate, so sessions were priced with none at all.
    public func restingHrByDay(fromDay: String, toDay: String) async -> [String: Double] {
        let imported = await unionDailyMetrics(from: fromDay, to: toDay)
        let computed = await unionComputedDailyMetrics(from: fromDay, to: toDay)
        var byDay: [String: Double] = [:]
        for metric in Self.mergeDaily(imported: imported, computed: computed) {
            if let resting = metric.restingHr, resting > 0 { byDay[metric.day] = Double(resting) }
        }
        return byDay
    }

    /// #856: the same dedup over an EXPLICIT id list, so a workout's zone minutes bin the rows its own
    /// recording strap banked rather than the day-level active ∪ canonical. Order is precedence.
    public func hrSamples(deviceIds: [String], from: Int, to: Int, limit: Int = 8000) async -> [HRSample] {
        guard !deviceIds.isEmpty else { return [] }
        guard deviceIds.count > 1 else {
            return (try? await store.hrSamples(deviceId: deviceIds[0], from: from, to: to,
                                               limit: limit)) ?? []
        }
        var byTs: [Int: HRSample] = [:]
        for id in deviceIds {
            for s in (try? await store.hrSamples(deviceId: id, from: from, to: to,
                                                 limit: limit)) ?? [] where byTs[s.ts] == nil {
                byTs[s.ts] = s
            }
        }
        return byTs.values.sorted { $0.ts < $1.ts }
    }

    public func hrSamples(from: Int, to: Int, limit: Int = 8000) async -> [HRSample] {
        // UNION the active strap + canonical so the HR trend renders whether the landed day's raw sits under
        // the re-added strap (live) or the canonical history. Deduped by ts (active strap wins) so an overlap
        // never double-counts; sorted ascending. Single-device install reads one id (byte-identical).
        let ids = rawPhysiologyReadIds
        guard ids.count != 1 else {
            return (try? await store.hrSamples(deviceId: activeDeviceId, from: from, to: to, limit: limit)) ?? []
        }
        var byTs: [Int: HRSample] = [:]
        for id in ids {
            for s in (try? await store.hrSamples(deviceId: id, from: from, to: to, limit: limit)) ?? [] where byTs[s.ts] == nil {
                byTs[s.ts] = s
            }
        }
        return byTs.values.sorted { $0.ts < $1.ts }
    }

    public func hrBuckets(deviceIds: [String], from: Int, to: Int, bucketSeconds: Int = 300) async -> [HRBucket] {
        guard !deviceIds.isEmpty else { return [] }
        guard deviceIds.count > 1 else {
            return (try? await store.hrBuckets(deviceId: deviceIds[0], from: from, to: to,
                                               bucketSeconds: bucketSeconds)) ?? []
        }
        var byStart: [Int: HRBucket] = [:]
        for id in deviceIds {
            for b in (try? await store.hrBuckets(deviceId: id, from: from, to: to,
                                                 bucketSeconds: bucketSeconds)) ?? [] where byStart[b.ts] == nil {
                byStart[b.ts] = b
            }
        }
        return byStart.values.sorted { $0.ts < $1.ts }
    }

    public func hrBuckets(from: Int, to: Int, bucketSeconds: Int = 300) async -> [HRBucket] {
        // UNION all registered WHOOP straps + canonical for the trend chart. Per bucket-start the active strap wins; a
        // raw HR window almost never overlaps between the two namespaces (different time periods), so the
        // per-bucket mean stays faithful. Single-device install reads one id (byte-identical).
        return await hrBuckets(deviceIds: rawPhysiologyReadIds, from: from, to: to,
                               bucketSeconds: bucketSeconds)
    }

    /// The same source-preserving read over an EXPLICIT window. A screen that needs the canonical
    /// session for ONE workout fuses the hours around it instead of the whole library: the fusion is
    /// quadratic in the rows it is handed, so "which session is this?" must not cost a full-history pass.
    public func rawWorkoutRows(from lo: Int, to hi: Int,
                               dismissedDetectedSpans: [String]) async -> [WorkoutRow] {
        // UNION every registered WHOOP + canonical (and computed siblings) so workouts banked before a
        // re-add remain visible alongside every retained strap's live workouts.
        // De-dup identical same-source rows that appear under both union ids by natural key (the cross-SOURCE
        // dedup below only collapses strap-vs-Apple twins, not a row present in two strap namespaces).
        var rows: [WorkoutRow] = []
        // Every namespace in one list, shared with `deleteWorkout` so the two cannot disagree about where a
        // row lives (#2278). File-imported lifting sessions (Hevy / Liftosaur exports) live under "lifting";
        // API-synced Hevy sessions deliberately use their own source so an export and its API twin can be
        // fused instead of one silently overwriting the other. #29: imported activity FILES (FIT / GPX /
        // TCX) live under "activity-file", or a successful file import never appears here at all.
        for id in Self.workoutNamespaces(rawIds: rawPhysiologyReadIds) {
            let page = await pagedWorkoutRows(deviceId: id, from: lo, to: hi)
            rows += id == WorkoutSource.ouraSource ? page.map(WorkoutSource.normalizedOuraRow) : page
        }
        // Native sessions remain normalized in the training tables. Their read-time envelope makes
        // them visible to Workouts and session fusion without persisting a duplicate workout row.
        let native = await pagedNativeWorkoutRows(from: lo, to: hi)
        rows += native.map(NativeTrainingProjection.workoutRow)
        rows = Self.dedupWorkoutsByNaturalKey(rows)
        let lifecycleLinks = ((try? await store.trainingSessionLinks()) ?? []).filter { $0.origin == "native-lifecycle" }
        rows = Self.hidingLegacyStrengthRecordings(rows, links: lifecycleLinks)
        let spans = WorkoutSource.parseDismissedSpans(dismissedDetectedSpans)
        let filtered = rows.filter { !WorkoutSource.isDismissed($0, spans: spans) }
        return filtered.sorted { $0.startTs > $1.startTs }
    }

    private func pagedWorkoutRows(deviceId: String, from: Int, to: Int) async -> [WorkoutRow] {
        let pageSize = 500
        var offset = 0
        var values: [WorkoutRow] = []
        while true {
            let page = (try? await store.workouts(deviceId: deviceId, from: from, to: to,
                                                  limit: pageSize, offset: offset)) ?? []
            values.append(contentsOf: page)
            guard page.count == pageSize else { break }
            offset += pageSize
        }
        return values
    }

    private func pagedNativeWorkoutRows(from: Int, to: Int) async -> [NativeWorkout] {
        let pageSize = 500
        var offset = 0
        var values: [NativeWorkout] = []
        while true {
            let page = (try? await store.nativeWorkouts(from: from, to: to,
                                                        limit: pageSize, offset: offset)) ?? []
            values.append(contentsOf: page)
            guard page.count == pageSize else { break }
            offset += pageSize
        }
        return values
    }

    /// Before the single active session, a native strength workout could be accompanied by a second,
    /// manually recorded "Strength Training" row of the same session. Both are kept in storage; the list
    /// shows the session once. A recording is hidden only when it is that twin: a strength row that is not
    /// itself native, overlapping at least half of a native row that the lifecycle linked to a session.
    public static func hidingLegacyStrengthRecordings(_ rows: [WorkoutRow],
                                                           links: [TrainingSessionLinkRow]) -> [WorkoutRow] {
        guard !links.isEmpty else { return rows }
        let linkedKeys = Set(links.map(\.componentKey))
        let strength = WorkoutSource.sportKey("Strength Training")
        let natives = rows.filter { row in
            row.source.hasPrefix("native-training")
                && linkedKeys.contains("\(row.source)|\(row.startTs)|\(WorkoutSource.sportKey(row.sport))")
        }
        guard !natives.isEmpty else { return rows }
        return rows.filter { row in
            guard !row.source.hasPrefix("native-training"),
                  WorkoutSource.sportKey(row.sport) == strength else { return true }
            return !natives.contains { isLegacyStrengthTwin(row, of: $0) }
        }
    }

    /// True when `recording` is the legacy manual twin of `native`: the two overlap by at least half of
    /// the shorter one. A ZERO-LENGTH side (a start/stop inside the same second, listed as "0m") has no
    /// half to overlap, so it counts as a twin when its instant falls inside the other span. Without that
    /// fallback the twin of an accidental start was never hidden, the list showed the session twice, and
    /// deleting one copy left the other on screen (#2278). Sport is the caller's check.
    public static func isLegacyStrengthTwin(_ recording: WorkoutRow, of native: WorkoutRow) -> Bool {
        let overlap = min(recording.endTs, native.endTs) - max(recording.startTs, native.startTs)
        let shorter = min(recording.endTs - recording.startTs, native.endTs - native.startTs)
        if shorter > 0 { return overlap * 2 >= shorter }
        return overlap >= 0
    }

    /// One day held by two source ids in the SAME bucket, folded into `winner`'s row: `winner` keeps every
    /// column it carries (NON-nil — a measured zero is a reading) and `filler` supplies only the ones it
    /// left nil. Whole-row first-wins let a hollow row (steps and nothing else) discard a complete one, and
    /// nothing downstream healed it — `mergeDaily` only bridges imported/computed/phone, never two straps.
    /// Columns that only mean something together move as a GROUP, whole and from one row, so a sleep total
    /// never sits beside another strap's stage minutes: the sleep block, and the raw red/IR PPG pair.
    /// Across-bucket precedence (`mergeDaily`) is untouched. Ported from tanarchytan/noop @de370b85, reduced
    /// to the columns this DailyMetric carries. Byte-identical twin of Kotlin WhoopRepository.coalesceDay.
    public static func coalesceDay(_ winner: DailyMetric, _ filler: DailyMetric) -> DailyMetric {
        let sleepFromFiller = winner.totalSleepMin == nil && winner.efficiency == nil &&
            winner.deepMin == nil && winner.remMin == nil && winner.lightMin == nil &&
            winner.disturbances == nil
        let rawSpo2FromFiller = winner.spo2Red == nil && winner.spo2Ir == nil
        return DailyMetric(
            day: winner.day,
            totalSleepMin: sleepFromFiller ? filler.totalSleepMin : winner.totalSleepMin,
            efficiency: sleepFromFiller ? filler.efficiency : winner.efficiency,
            deepMin: sleepFromFiller ? filler.deepMin : winner.deepMin,
            remMin: sleepFromFiller ? filler.remMin : winner.remMin,
            lightMin: sleepFromFiller ? filler.lightMin : winner.lightMin,
            disturbances: sleepFromFiller ? filler.disturbances : winner.disturbances,
            restingHr: winner.restingHr ?? filler.restingHr,
            avgHrv: winner.avgHrv ?? filler.avgHrv,
            recovery: winner.recovery ?? filler.recovery,
            strain: winner.strain ?? filler.strain,
            exerciseCount: winner.exerciseCount ?? filler.exerciseCount,
            spo2Pct: winner.spo2Pct ?? filler.spo2Pct,
            skinTempDevC: winner.skinTempDevC ?? filler.skinTempDevC,
            respRateBpm: winner.respRateBpm ?? filler.respRateBpm,
            steps: winner.steps ?? filler.steps,
            activeKcalEst: winner.activeKcalEst ?? filler.activeKcalEst,
            spo2Red: rawSpo2FromFiller ? filler.spo2Red : winner.spo2Red,
            spo2Ir: rawSpo2FromFiller ? filler.spo2Ir : winner.spo2Ir,
            // Strap-only, like raw SpO2: an imported winner carries no absolute skin temp, so take the
            // filler's rather than let the union blank a value the strap did record (#1636).
            skinTempC: winner.skinTempC ?? filler.skinTempC,
            // Part of the SLEEP GROUP, not an independent column (#1801): it describes how the stage
            // figures above were derived, so it has to come from whichever row supplied them. A plain
            // `winner ?? filler` would caption the winner's own hypnogram with the filler's staging.
            sleepHrOnly: sleepFromFiller ? filler.sleepHrOnly : winner.sleepHrOnly
        )
    }

    /// Imported daily values win field-by-field; computed rows fill only nil imported fields.
    /// This preserves official export/import values while allowing fresh local analysis to populate
    /// Charge, skin temperature deviation, activity totals, or other fields missing from that row.
    ///
    /// H5 (#509): a day in `userEditedDays` is one the user hand-edited the sleep of (a corrected
    /// bed/wake time, an added nap, a deleted night). For those days the COMPUTED row's SLEEP fields
    /// take precedence over the import , otherwise a re-imported WHOOP/Apple night would silently mask
    /// the user's correction. Non-sleep fields (recovery/strain/HRV/RHR/activity…) still follow the
    /// normal imports-win merge, and every NON-edited day is unchanged.
    public static func mergeDaily(imported: [DailyMetric], computed: [DailyMetric],
                                       userEditedDays: Set<String> = []) -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for d in computed { byDay[d.day] = d }
        for d in imported {
            if let existing = byDay[d.day] {
                let merged = d.fillingNilFields(from: existing)
                byDay[d.day] = userEditedDays.contains(d.day)
                    ? merged.takingSleepFields(from: existing)   // edited night: computed sleep wins
                    : merged
            } else {
                byDay[d.day] = d
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Same precedence for sleep sessions, keyed by the day the night ends on.
    /// Keys through `AnalyticsEngine.dayString(_:offsetSec:)` , the canonical LOCAL-day keyer
    /// `analyzeDay` attributes sessions with , NOT the unzoned `Repository.dayFormatter`, which formats
    /// in whatever the live device zone is and so disagreed with the engine's cached-offset attribution
    /// across a midnight boundary for non-UTC users (the Swift half of #406; mirrors the Android #304 fix
    /// pinned by MergeSleepLocalDayTest).
    public static func mergeSleep(imported: [CachedSleepSession], computed: [CachedSleepSession]) -> [CachedSleepSession] {
        func endDay(_ s: CachedSleepSession) -> String {
            let offsetSec = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            return AnalyticsEngine.dayString(s.endTs, offsetSec: offsetSec)
        }
        // #715, preserve EVERY session (a day with a main night + a nap must keep both); imported still
        // wins per end-day. Shared, unit-tested grouping (WhoopStore.SleepMerge / SleepMergeTests) replaces
        // the old per-day dictionary that silently dropped a second same-day session.
        return SleepMerge.merge(imported: imported, computed: computed, endDay: endDay)
    }

    /// Keep the active source's copy of a night when another source recorded nearly the same interval.
    /// Require a majority of BOTH intervals to overlap so a short nap inside a long night survives.
    /// Separate blocks from one source remain distinct, including split sleeps.
    public static func dedupBlocks(_ blocks: [CachedSleepSession]) -> [CachedSleepSession] {
        var seen = Set<[Int]>()
        var out: [CachedSleepSession] = []
        for b in blocks {
            let key = [b.startTs, b.endTs]
            guard seen.insert(key).inserted else { continue }
            let overlapsOtherSource = out.contains { kept in
                guard let source = b.deviceId, let keptSource = kept.deviceId,
                      source != keptSource else { return false }
                let start = max(b.effectiveStartTs, kept.effectiveStartTs)
                let end = min(b.endTs, kept.endTs)
                let bDuration = b.endTs - b.effectiveStartTs
                let keptDuration = kept.endTs - kept.effectiveStartTs
                let overlap = end - start
                return bDuration > 0 && keptDuration > 0 &&
                    overlap > bDuration / 2 && overlap > keptDuration / 2
            }
            if !overlapsOtherSource { out.append(b) }
        }
        return out
    }

    /// Drop workout rows that share a (startTs, endTs, sport, source) key, the same session recorded under
    /// both union device ids, keeping the first (active strap). Distinct sessions are preserved; the
    /// downstream `dedupCrossSource` still collapses strap-vs-Apple twins by time.
    public static func dedupWorkoutsByNaturalKey(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        var seen = Set<String>()
        var out: [WorkoutRow] = []
        for r in rows {
            let key = "\(r.startTs)-\(r.endTs)-\(r.sport)-\(r.source)"
            if seen.insert(key).inserted { out.append(r) }
        }
        return out
    }

    /// Merge gravity lists into one time-ordered stream, deduped by timestamp with the FIRST list (the
    /// active strap) winning a tie. A single-id read is returned UNCHANGED, so a single-device install
    /// performs exactly the read it did before the union existed.
    ///
    /// Byte-identical rule to Kotlin `mergeGravityByTs`. Pure + static so the dedup is unit-tested
    /// without a store — the property that actually matters here is "active wins, nothing double-counts".
    public static func mergeGravityByTs(_ lists: [[GravitySample]]) -> [GravitySample] {
        if lists.count == 1 { return lists[0] }
        var byTs: [Int: GravitySample] = [:]
        for list in lists {
            for s in list where byTs[s.ts] == nil { byTs[s.ts] = s }
        }
        return byTs.values.sorted { $0.ts < $1.ts }
    }

    /// Merge R-R reads without treating a timestamp as a beat identity. Several real beats can share a
    /// one-second timestamp; only the complete storage identity `(ts, rrMs, seq)` is a duplicate across
    /// namespaces. The first list is the active strap and therefore wins exact duplicates.
    public static func mergeRRByIdentity(_ lists: [[RRInterval]]) -> [RRInterval] {
        if lists.count == 1 { return lists[0] }
        struct BeatKey: Hashable { let ts: Int; let rrMs: Int; let seq: Int }
        var seen = Set<BeatKey>()
        var out: [RRInterval] = []
        for list in lists {
            for beat in list where seen.insert(BeatKey(ts: beat.ts, rrMs: beat.rrMs, seq: beat.seq)).inserted {
                out.append(beat)
            }
        }
        if out.contains(where: { $0.srcChannel?.isWhoop5Transport == true || $0.srcChannel == .whoop4Historical }) {
            // Retain the selected stream's emission order within a second. Value sorting corrupts
            // successive differences; original offsets also keep owner precedence deterministic.
            return out.enumerated().sorted {
                $0.element.ts != $1.element.ts ? $0.element.ts < $1.element.ts : $0.offset < $1.offset
            }.map(\.element)
        }
        return out.sorted {
            if $0.ts != $1.ts { return $0.ts < $1.ts }
            if $0.seq != $1.seq { return $0.seq < $1.seq }
            if $0.rrMs != $1.rrMs { return $0.rrMs < $1.rrMs }
            return ($0.ord ?? Int.min) < ($1.ord ?? Int.min)
        }
    }
}

public extension DailyMetric {
    /// A copy of self where every nil field is backfilled from `fallback`. Used by the field-by-field
    /// daily merge so an imported export keeps its own values while a computed row fills the gaps it
    /// doesn't carry (e.g. on-device Charge / skin-temp deviation / activity totals).
    func fillingNilFields(from fallback: DailyMetric) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: totalSleepMin ?? fallback.totalSleepMin,
            efficiency: efficiency ?? fallback.efficiency,
            deepMin: deepMin ?? fallback.deepMin,
            remMin: remMin ?? fallback.remMin,
            lightMin: lightMin ?? fallback.lightMin,
            disturbances: disturbances ?? fallback.disturbances,
            restingHr: restingHr ?? fallback.restingHr,
            avgHrv: avgHrv ?? fallback.avgHrv,
            recovery: recovery ?? fallback.recovery,
            strain: strain ?? fallback.strain,
            exerciseCount: exerciseCount ?? fallback.exerciseCount,
            spo2Pct: spo2Pct ?? fallback.spo2Pct,
            skinTempDevC: skinTempDevC ?? fallback.skinTempDevC,
            respRateBpm: respRateBpm ?? fallback.respRateBpm,
            steps: steps ?? fallback.steps,
            activeKcalEst: activeKcalEst ?? fallback.activeKcalEst,
            // Raw SpO2 is on-device only (imports never carry it), so the imported row's nil is
            // backfilled from the computed fallback — otherwise the nightly means would be lost. (#93)
            spo2Red: spo2Red ?? fallback.spo2Red,
            spo2Ir: spo2Ir ?? fallback.spo2Ir,
            avgSdnn: avgSdnn ?? fallback.avgSdnn,
            energyCoverageSeconds: energyCoverageSeconds ?? fallback.energyCoverageSeconds,
            // On-device only (imports never carry it), so an imported row's nil is backfilled from the
            // computed fallback — otherwise the night's absolute would be lost. (#1636)
            skinTempC: skinTempC ?? fallback.skinTempC,
            // Same shape, same reason (#1801): only a scoring pass knows how the night was staged, so an
            // imported row's nil takes the computed answer rather than erasing it.
            sleepHrOnly: sleepHrOnly ?? fallback.sleepHrOnly
        )
    }

    /// A copy of self where the SLEEP fields are overridden by `source` , used by the H5 edit-merge so a
    /// hand-edited night's computed sleep figures win over the import for that day (#509). Only the sleep
    /// columns move; every other field (recovery/strain/HRV/RHR/activity/in-sleep vitals) is left as-is, so
    /// the import still wins for non-sleep metrics on the edited day.
    func takingSleepFields(from source: DailyMetric) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: source.totalSleepMin,
            efficiency: source.efficiency,
            deepMin: source.deepMin,
            remMin: source.remMin,
            lightMin: source.lightMin,
            disturbances: source.disturbances,
            restingHr: restingHr,
            avgHrv: avgHrv,
            recovery: recovery,
            strain: strain,
            exerciseCount: exerciseCount,
            spo2Pct: spo2Pct,
            skinTempDevC: skinTempDevC,
            respRateBpm: respRateBpm,
            steps: steps,
            activeKcalEst: activeKcalEst,
            spo2Red: spo2Red,   // non-sleep field: preserved as-is (#93)
            spo2Ir: spo2Ir,
            avgSdnn: avgSdnn,   // non-sleep (HRV) field: preserved as-is
            energyCoverageSeconds: energyCoverageSeconds,
            skinTempC: skinTempC, // non-sleep (thermal) field: preserved as-is (#1636)
            // MOVES with the sleep columns, unlike the others here: it describes how the very stage
            // figures being taken were derived, so leaving `self`'s behind would caption the source's
            // hypnogram with the import's staging — and an import's is always nil. (#1801)
            sleepHrOnly: source.sleepHrOnly
        )
    }

    /// Applies the stage totals re-derived from a user-edited session while retaining fields that stages
    /// cannot truthfully recompute, such as disturbances and overnight vitals.
    func takingEditedSleepFields(from source: SleepStageTotals.DailySleep) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: source.totalSleepMin,
            efficiency: source.efficiency,
            deepMin: source.deepMin,
            remMin: source.remMin,
            lightMin: source.lightMin,
            disturbances: disturbances,
            restingHr: restingHr,
            avgHrv: avgHrv,
            recovery: recovery,
            strain: strain,
            exerciseCount: exerciseCount,
            spo2Pct: spo2Pct,
            skinTempDevC: skinTempDevC,
            respRateBpm: respRateBpm,
            steps: steps,
            activeKcalEst: activeKcalEst,
            spo2Red: spo2Red,
            spo2Ir: spo2Ir,
            avgSdnn: avgSdnn,
            energyCoverageSeconds: energyCoverageSeconds,
            skinTempC: skinTempC,
            // Explicitly nil, not carried (#1801): these stage figures came from `SleepStageTotals`, which
            // records no derivation, and the night they describe was hand-edited. Keeping `self`'s flag
            // would caption the user's own hypnogram with how the SUPERSEDED one was staged — a claim
            // nothing here can attribute. Nil is what the caption already reads as "not known".
            sleepHrOnly: nil
        )
    }

    /// Preserve non-sleep outcomes while making an explicitly deleted wake-day absent from sleep-facing
    /// cards and series.
    func clearingSleepFields() -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: nil,
            efficiency: nil,
            deepMin: nil,
            remMin: nil,
            lightMin: nil,
            disturbances: nil,
            restingHr: restingHr,
            avgHrv: avgHrv,
            recovery: recovery,
            strain: strain,
            exerciseCount: exerciseCount,
            spo2Pct: spo2Pct,
            skinTempDevC: skinTempDevC,
            respRateBpm: respRateBpm,
            steps: steps,
            activeKcalEst: activeKcalEst,
            spo2Red: spo2Red,
            spo2Ir: spo2Ir,
            avgSdnn: avgSdnn,
            energyCoverageSeconds: energyCoverageSeconds,
            skinTempC: skinTempC, // non-sleep (thermal) field: preserved as-is (#1636)
            // Goes with the sleep columns it describes: with no stages left there is no staging to
            // caption. (#1801)
            sleepHrOnly: nil
        )
    }
}
