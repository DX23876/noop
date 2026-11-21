import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// What the Android screens read from the core's store (Android plan E-2), as small JSON documents. The reads go
/// through `StoreReader` and resolve as the Apple screens' `Repository` does: imported values win field by field,
/// the core's computed ("-noop") rows fill the rest, and the active strap wins over the canonical import. Values
/// the store does not have stay null.
public enum CoreRead {
    /// One optional number for a read whose answer may be absent (`read.habitualMidsleep`): `{"value": null}` then.
    public struct OptionalValue: Encodable {
        public var value: Int?
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(value, forKey: .value)
        }
        enum CodingKeys: String, CodingKey { case value }
    }

    /// One day as the Today screen shows it.
    public struct Day: Codable, Equatable, Sendable {
        public var day: String
        public var charge: Double?, effort: Double?, rest: Double?
        public var sleepMinutes: Double?, deepMinutes: Double?, remMinutes: Double?, lightMinutes: Double?
        public var efficiency: Double?, restingHr: Int?, hrv: Double?, respRate: Double?, spo2: Double?
        public var skinTempDev: Double?, steps: Int?
        /// The night's ABSOLUTE wrist temperature (`DailyMetric.skinTempC`), beside the deviation rather
        /// than instead of it: a tile leads with the temperature where the night measured one and falls
        /// back to the ±baseline where it did not (`SkinTempDisplay.leadReading`). Android could not show
        /// a temperature at all while this was missing, and printed "+0.1 Δ°C" where iOS printed "33.8 °C".
        public var skinTempAbs: Double? = nil
        /// Who supplied the Charge, Effort and Rest inputs, as the hero names them (`ScoreProvenance.heroLabels`):
        /// a name as is, or "#workoutFiles", "#nutrition" or "#cached" for the words each platform translates.
        public var heroSource: [String] = []
    }

    /// One night with its stages: `stages` is the timeline (empty for an imported night that stores totals only),
    /// `minutes` the stage totals the Sleep screen states, summed over the night's blocks as on iOS.
    public struct Night: Codable, Equatable, Sendable {
        public struct Stage: Codable, Equatable, Sendable {
            public var stage: String, start: Int, end: Int
        }
        public struct Minutes: Codable, Equatable, Sendable {
            public var wake: Double, light: Double, deep: Double, rem: Double
        }
        /// One stored block this night was built from, by the key that identifies its row.
        ///
        /// A night is assembled here from BOTH sleep lanes, the imported and the computed one
        /// (`StoreReader.allSleepSessions`). A caller that wants to correct or delete the night it is
        /// looking at must act on exactly these rows, and anything that derives the group a second time
        /// from a time window can disagree with what was drawn: Android's edit re-derived it from the
        /// imported lane alone, so a night NOOP had computed itself was silently unchangeable
        /// (tester report 2026-11-21). The night therefore names its own blocks.
        ///
        /// `deviceId` is the namespace the row was read from, nil only when the read did not know it;
        /// `startTs` is the immutable detected key the store writes under, `effectiveStartTs` the onset
        /// as drawn (a hand-corrected night moves the latter, never the former).
        public struct Block: Codable, Equatable, Sendable {
            public var deviceId: String?
            public var startTs: Int, endTs: Int, effectiveStartTs: Int
            public init(deviceId: String?, startTs: Int, endTs: Int, effectiveStartTs: Int) {
                self.deviceId = deviceId
                self.startTs = startTs
                self.endTs = endTs
                self.effectiveStartTs = effectiveStartTs
            }
        }
        public var startTs: Int, endTs: Int, efficiency: Double?, restingHr: Int?, hrv: Double?, edited: Bool
        public var stages: [Stage]
        public var minutes: Minutes?
        /// The stored rows behind this night, oldest first. Empty only when the night carries none.
        public var blocks: [Block] = []
    }

    /// A sleep block off a day's main night (`SleepNight.naps`), with its asleep minutes.
    public struct Nap: Codable, Equatable, Sendable {
        public var startTs: Int, endTs: Int, asleepMinutes: Double
        /// The stored row this nap IS, by the key that identifies it, for the same reason a night names
        /// its blocks (see `Night.Block`): deleting a nap must act on the row that was drawn, not on
        /// whatever a second search through one lane happens to return.
        public var block: Night.Block?
    }

    /// One value of a metric on one day.
    public struct Point: Codable, Equatable, Sendable {
        public var day: String, value: Double
        public init(day: String, value: Double) { self.day = day; self.value = value }
    }

    /// The mean heart rate of one five-minute stretch; `ts` is its start in unix seconds.
    public struct HeartPoint: Codable, Equatable, Sendable {
        public var ts: Int, bpm: Double
        public init(ts: Int, bpm: Double) { self.ts = ts; self.bpm = bpm }
    }

    /// The metrics a trend screen can chart.
    public enum Metric: String, CaseIterable, Sendable {
        case charge, effort, rest, hrv, restingHr, sleepMinutes, respRate
        /// The day rows' own SpO2, steps and skin-temperature deviation, as Today's detailed tiles draw them
        /// (`LiquidTodayView` `kSparks` "spo2", "steps", "skin_temp").
        case spo2, steps, skinTemp
        /// The nightly absolute, charted on its own scale; mixing it into `skinTemp` would average two
        /// different scales into one plausible-looking line (`SkinTempDisplay.dominantKind`).
        case skinTempAbs
    }

    public static func day(_ day: String, reader: StoreReader) async -> Day? {
        guard let row = await merged(from: day, to: day, reader: reader).first(where: { $0.day == day }) else {
            return nil
        }
        let rest = await restSeries(from: day, to: day, reader: reader).last?.value
        // The day's steps from the one steps resolver and the source the wearer chose (`StepsSource`), as the
        // iPhone reads them; SpO2 the strap measured none for comes from the phone's health store.
        let steps = await MetricResolver.resolvedSteps(store: reader.store, actualWhoopSource: reader.activeDeviceId,
                                                        from: day, to: day).points.first { $0.day == day }
            .map { Int($0.value.rounded()) }
        var spo2 = row.spo2Pct
        if spo2 == nil {
            for source in [MetricResolver.appleHealthSource, MetricResolver.healthConnectSource] {
                if let v = ((try? await reader.store.metricSeries(deviceId: source, key: "spo2", from: day, to: day)) ?? [])
                    .last?.value {
                    spo2 = v; break
                }
            }
        }
        return Day(day: row.day, charge: row.recovery, effort: row.strain, rest: rest,
                   sleepMinutes: row.totalSleepMin, deepMinutes: row.deepMin, remMinutes: row.remMin,
                   lightMinutes: row.lightMin, efficiency: row.efficiency, restingHr: row.restingHr,
                   hrv: row.avgHrv, respRate: row.respRateBpm, spo2: spo2, skinTempDev: row.skinTempDevC,
                   steps: steps, skinTempAbs: row.skinTempC,
                   heroSource: await ScoreProvenance.heroLabels(day: day, reader: reader).map(token))
    }

    /// The main night of every day between `from` and `to` (unix seconds), oldest first, as the Apple Sleep tab
    /// shows them (`SleepNight`): a night split into blocks reads as one, a nap is not a night, and a sleepless
    /// lead stub does not move the bedtime. The stages are absolute, with the gaps between blocks as "wake".
    public static func nights(from: Int, to: Int, reader: StoreReader,
                              offsetSec: Int = TimeZone.current.secondsFromGMT()) async -> [Night] {
        let sessions = await reader.allSleepSessions(from: from, to: to)
        // The learner reads the whole history, as `Repository.habitualMidsleepSec()` does, not just the window.
        let now = Int(Date().timeIntervalSince1970)
        let habitual = await reader.habitualMidsleepSec(from: now - 4000 * 86_400, to: now + 86_400,
                                                        offsetSec: offsetSec)
        return SleepNight.days(sessions).compactMap { day -> Night? in
            guard let main = SleepNight.main(day, offsetSec: offsetSec, habitualMidsleepSec: habitual) else {
                return nil
            }
            let longest = main.group.max { ($0.endTs - $0.effectiveStartTs) < ($1.endTs - $1.effectiveStartTs) }
            let stages = main.intervals.map {
                Night.Stage(stage: $0.stage == "awake" ? "wake" : $0.stage,
                            start: main.onset + Int($0.start), end: main.onset + Int($0.end))
            }
            return Night(startTs: main.onset, endTs: main.wake,
                         efficiency: main.efficiency,
                         restingHr: longest?.restingHr, hrv: longest?.avgHrv,
                         edited: main.group.contains { $0.userEdited }, stages: stages,
                         minutes: Night.Minutes(wake: main.minutes.awake, light: main.minutes.light,
                                                deep: main.minutes.deep, rem: main.minutes.rem),
                         // The group this night was drawn from, so a correction acts on these rows and
                         // never on a second, differently derived set (see `Night.Block`).
                         blocks: main.group
                             .sorted { $0.effectiveStartTs < $1.effectiveStartTs }
                             .map { Night.Block(deviceId: $0.deviceId, startTs: $0.startTs,
                                                endTs: $0.endTs, effectiveStartTs: $0.effectiveStartTs) })
        }.sorted { $0.startTs < $1.startTs }
    }

    /// The naps between `from` and `to` (unix seconds), oldest first: every day's blocks outside the main night
    /// `nights` picks, by the one rule the Apple timeline reads too (`SleepNight.naps`).
    public static func naps(from: Int, to: Int, reader: StoreReader,
                            offsetSec: Int = TimeZone.current.secondsFromGMT()) async -> [Nap] {
        let sessions = await reader.allSleepSessions(from: from, to: to)
        let now = Int(Date().timeIntervalSince1970)
        let habitual = await reader.habitualMidsleepSec(from: now - 4000 * 86_400, to: now + 86_400,
                                                        offsetSec: offsetSec)
        return SleepNight.days(sessions).flatMap { day -> [Nap] in
            let group = SleepNight.mainGroup(day, offsetSec: offsetSec, habitualMidsleepSec: habitual)
            return SleepNight.naps(day, mainGroup: group).map {
                Nap(startTs: $0.effectiveStartTs, endTs: $0.endTs,
                    asleepMinutes: SleepNight.asleepMinutes($0.stagesJSON, effectiveStartTs: $0.effectiveStartTs),
                    block: Night.Block(deviceId: $0.deviceId, startTs: $0.startTs, endTs: $0.endTs,
                                       effectiveStartTs: $0.effectiveStartTs))
            }
        }.sorted { $0.startTs < $1.startTs }
    }

    public static func series(_ metric: Metric, from: String, to: String, reader: StoreReader) async -> [Point] {
        if metric == .rest { return await restSeries(from: from, to: to, reader: reader) }
        if metric == .steps {
            // The one steps resolver, from the source the wearer chose (`StepsSource`), as the iPhone's tile reads.
            return await MetricResolver.resolvedSteps(store: reader.store, actualWhoopSource: reader.activeDeviceId,
                                                      from: from, to: to).points.map { Point(day: $0.day, value: $0.value) }
        }
        let own = await strapSeries(metric, from: from, to: to, reader: reader)
        guard metric == .spo2 else { return own }
        // SpO2 a day's row lacks comes from the phone's health store: Apple Health first, then Health Connect.
        var byDay = Dictionary(own.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        for source in [MetricResolver.appleHealthSource, MetricResolver.healthConnectSource] {
            for p in (try? await reader.store.metricSeries(deviceId: source, key: "spo2", from: from, to: to)) ?? []
            where byDay[p.day] == nil {
                byDay[p.day] = Point(day: p.day, value: p.value)
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    private static func strapSeries(_ metric: Metric, from: String, to: String, reader: StoreReader) async -> [Point] {
        await merged(from: from, to: to, reader: reader).compactMap { row in
            let value: Double? = switch metric {
            case .charge: row.recovery
            case .effort: row.strain
            case .hrv: row.avgHrv
            case .restingHr: row.restingHr.map(Double.init)
            case .sleepMinutes: row.totalSleepMin
            case .respRate: row.respRateBpm
            case .spo2: row.spo2Pct
            case .steps: row.steps.map(Double.init)
            case .skinTemp: row.skinTempDevC
            case .skinTempAbs: row.skinTempC
            case .rest: nil
            }
            return value.map { Point(day: row.day, value: $0) }
        }.sorted { $0.day < $1.day }
    }

    /// The heart rate between `from` and `to` (unix seconds) in five-minute means, across every strap the wearer
    /// has, as the Apple Today screen's banked trace reads it (`StoreReader.hrBuckets`).
    public static func heartRate(from: Int, to: Int, reader: StoreReader) async -> [HeartPoint] {
        await reader.hrBuckets(from: from, to: to, bucketSeconds: 300).map { HeartPoint(ts: $0.ts, bpm: $0.bpm) }
    }

    /// A resolved metric series in Android's shape (`WhoopRepository.MetricSeriesResolution`).
    public struct ResolvedSeries: Encodable {
        struct Candidate: Encodable { var source: String, key: String }
        struct Point: Encodable { var day: String, value: Double, source: String, sourceKey: String }
        var requestedSource: String
        var candidates: [Candidate]
        var points: [Point]

        init(_ r: MetricSeriesResolution) {
            requestedSource = r.requestedSource
            candidates = r.candidates.map { Candidate(source: $0.source, key: $0.key) }
            points = r.points.map { Point(day: $0.day, value: $0.value, source: $0.source, sourceKey: $0.sourceKey) }
        }
    }

    /// The workout list as the iPhone's `Repository.workoutRows` builds it, without its display-only heart-rate
    /// reconcile: every source's rows with native sessions and dismissed detections applied, cross-source twins
    /// collapsed, recorded heart-rate fills laid over, newest first. What Android's Workouts screen reads instead of
    /// Room's own assembly (parity plan 1.3).
    public static func workouts(days: Int, dismissed: [String], reader: StoreReader) async -> [WorkoutRow] {
        let now = Int(Date().timeIntervalSince1970)
        let raw = await reader.rawWorkoutRows(from: now - days * 86_400, to: now + 86_400, dismissedDetectedSpans: dismissed)
        let deduped = WorkoutSource.dedupCrossSource(raw)
        return await WorkoutHeartRateFills.overlay(deduped.sorted { $0.startTs > $1.startTs }, store: reader.store)
    }

    /// Today's Effort as a Today screen must show it: the live score where there is enough heart rate to
    /// take one, floored at the stored row so the figure can never visibly drop (`effectiveEffort`).
    ///
    /// The Apple screens have read Effort this way since #402; the Android Forge screen showed the stored
    /// row raw, which only moves when the nightly pass runs. The same wearer therefore saw two different
    /// Efforts depending only on which Today they had open, and the lower one lagged by hours (#41). The
    /// rules are `LiveEffortScore`'s, so neither platform can drift from the other.
    ///
    /// [restingHr] is the shown day's own resting rate and [storedEffort] its stored Effort; both come
    /// from the day the caller is showing, so this never reads a different day than the screen does.
    public static func liveEffort(reader: StoreReader, hrMaxOverride: Int, age: Int,
                                  restingHr: Int?, storedEffort: Double?, mode: DayCycleMode,
                                  now: Date = Date()) async -> Double? {
        // The day in progress is the cycle the pass scores, not the calendar day (`CycleDayWindow`).
        let nowTs = Int(now.timeIntervalSince1970)
        let offsetSec = TimeZone.current.secondsFromGMT(for: now)
        let cycle = await CycleDayWindow.current(reader: reader, now: nowTs, offsetSec: offsetSec)
        let (from, to) = LiveEffortScore.window(now: now, mode: mode, cycle: cycle)
        let workout = LiveEffortScore.workoutWindow(forWindow: (from, to))
        // The override, then the level the last pass measured, then the formula — resolved by the pass's
        // own resolver (`CoreAnalysis.passHRmax`), so the live score is taken against the same yardstick
        // as the stored day. Resolving it here instead read the measured level out of `UserDefaults`,
        // which on this platform nothing writes: a wearer whose measured maximum sits above the age
        // formula had today scored against the formula while the stored row was scored against the
        // measurement, and `effectiveEffort` takes the larger of the two.
        let maxHR = await CoreAnalysis.passHRmax(overrideBpm: hrMaxOverride, age: age).bpm
        let hr = await reader.hrSamples(from: from, to: to, limit: LiveEffortScore.hrLimit)
        let rows = await reader.rawWorkoutRows(from: workout.from, to: workout.to, dismissedDetectedSpans: [])
        let live = LiveEffortScore.score(hr: hr, workoutRows: rows, maxHR: maxHR, restingHr: restingHr)
        return StrainScorer.effectiveEffort(live: live, stored: storedEffort)
    }

    /// Whether this install holds ANY day at all: the first-run question both Today screens ask before they
    /// offer to connect a wearable. iOS reads `repo.days.isEmpty`, which is this same merge held in memory,
    /// so the answer is defined as `dailyRows` being non-empty rather than as a second rule — Android used to
    /// ask whether a Rest or Charge SCORE existed and therefore kept offering to pair for days after the
    /// strap had been streaming, because a day with heart rate but no scored night has neither.
    ///
    /// Ten years back, which is how far the Android screens look for anything else; a wearer with an older
    /// import than that has plenty of newer days too. Cheap exactly where it is asked: an install with no day
    /// merges nothing, and a caller stops asking once the answer is yes.
    public static func hasAnyDay(reader: StoreReader) async -> Bool {
        let today = Date()
        let from = Calendar(identifier: .gregorian).date(byAdding: .year, value: -10, to: today) ?? today
        return await !dailyRows(from: LogicalDay.key(from), to: LogicalDay.key(today), reader: reader).isEmpty
    }

    /// The daily rows as the iPhone's `Repository.days` holds them: imports win a day, the core's own rows fill it, a
    /// hand-edited night's sleep comes from the edit, and an activity file supplies steps a day lacks. What
    /// Android's classic screens read instead of Room's merge (parity plan 1.3).
    public static func dailyRows(from: String, to: String, reader: StoreReader) async -> [DailyMetric] {
        let start = Int(WeightSeries.date(forDay: from)?.timeIntervalSince1970 ?? 0) - 86_400
        let end = Int(WeightSeries.date(forDay: to)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) + 2 * 86_400
        let sessions = await reader.allSleepSessions(from: start, to: end)
        let merged = StoreReader.applyingEditedSleepSessions(sessions, to: StoreReader.mergeDaily(
            imported: await reader.unionDailyMetrics(from: from, to: to),
            computed: await reader.unionComputedDailyMetrics(from: from, to: to),
            userEditedDays: StoreReader.userEditedDays(sessions)))
        let activityFile = (try? await reader.store.dailyMetrics(deviceId: ScoreProvenance.activityFileSource,
                                                                 from: from, to: to)) ?? []
        return StoreReader.mergeActivityFileSteps(into: merged, activityFile)
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

    /// A provider label as the Android parser reads it.
    static func token(_ label: ScoreProvenance.Label) -> String {
        switch label {
        case .name(let name): return name
        case .workoutFiles: return "#workoutFiles"
        case .nutrition: return "#nutrition"
        case .cached: return "#cached"
        }
    }

    /// Compact JSON with sorted keys, so the same answer is the same text.
    public static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}
