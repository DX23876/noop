import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

// MARK: - The cycle, shared by iOS and the Android core
//
// Everything the cycle page knows, in one place both platforms compile: the iPhone app builds this file, and the
// Android core links it through `Packages/NoopCoreJNI/Sources/NoopCore/Shared`. What a wearer logs is stored here
// (period starts and the day log under the isolated `noop-cycle` source), the nights are read into the phase engine
// here, and the page's snapshot, the fertile-days estimate and the training pattern are worked out here. The screens
// only word and draw it. Awareness only; none of it changes a score. Analysis migration required: no.

/// Where a logged period start lives: one value-1 metricSeries point under the dedicated local source.
enum CycleTrackingStore {
    static let sourceId = "noop-cycle"
    static let periodStartKey = "period_start"
    static let loggedValue = 1.0
    static let earliestDay = "0000-01-01"
    static let latestDay = "9999-12-31"

    /// Logged period-start days, oldest first. The value gate keeps reads forward-compatible.
    static func periodStarts(store: WhoopStore, from: String = earliestDay, to: String = latestDay) async -> [String] {
        let rows = (try? await store.metricSeries(deviceId: sourceId, key: periodStartKey, from: from, to: to)) ?? []
        return rows.filter { $0.value >= loggedValue }.map(\.day)
    }

    /// Log (or idempotently re-log) one local calendar day as cycle day 1.
    static func logPeriodStart(store: WhoopStore, day: String) async {
        _ = try? await store.upsertMetricSeries([MetricPoint(day: day, key: periodStartKey, value: loggedValue)],
                                                deviceId: sourceId)
    }
}

/// What a wearer notes about a cycle day beside the period start: one metricSeries row per fact under the same
/// source. Flow is one row keyed `flow` with the level as its value; each symptom and mood is its own value-1 row
/// (`symptom.cramps`, `mood.irritable`), and clearing one is a real row delete. None of it feeds the cycle estimate.
enum CycleLog {
    static let flowKey = "flow"
    static let symptomPrefix = "symptom."
    static let moodPrefix = "mood."
    /// A positive ovulation (LH) test on that day.
    static let ovulationTestKey = "ovulation_test"

    enum Flow: Int, CaseIterable, Identifiable, Sendable {
        case spotting = 1, light, medium, heavy
        var id: Int { rawValue }
    }

    /// Stable ids (they are storage keys), in the order the log sheet shows them.
    static let symptomIds = ["cramps", "headache", "bloating", "tender_breasts", "back_pain", "acne", "tired", "cravings"]
    static let moodIds = ["calm", "happy", "irritable", "low", "anxious", "sensitive"]

    /// One day's notes.
    struct Day: Equatable, Sendable {
        var flow: Flow?
        var symptoms: Set<String> = []
        var moods: Set<String> = []
        var ovulationTest = false
        var isEmpty: Bool { flow == nil && symptoms.isEmpty && moods.isEmpty && !ovulationTest }
    }

    /// Every logged cycle day in the range, by "yyyy-MM-dd".
    static func read(store: WhoopStore, from: String, to: String) async -> [String: Day] {
        let keys = ((try? await store.metricKeys(deviceId: CycleTrackingStore.sourceId)) ?? [])
            .filter { $0 == flowKey || $0 == ovulationTestKey || $0.hasPrefix(symptomPrefix) || $0.hasPrefix(moodPrefix) }
        var out: [String: Day] = [:]
        for key in keys {
            let rows = (try? await store.metricSeries(deviceId: CycleTrackingStore.sourceId, key: key, from: from, to: to)) ?? []
            for row in rows {
                var day = out[row.day] ?? Day()
                if key == flowKey {
                    day.flow = Flow(rawValue: Int(row.value.rounded()))
                } else if key == ovulationTestKey {
                    day.ovulationTest = row.value >= 1
                } else if key.hasPrefix(symptomPrefix), row.value >= 1 {
                    day.symptoms.insert(String(key.dropFirst(symptomPrefix.count)))
                } else if key.hasPrefix(moodPrefix), row.value >= 1 {
                    day.moods.insert(String(key.dropFirst(moodPrefix.count)))
                }
                out[row.day] = day
            }
        }
        return out
    }

    /// Replace one day's notes with `log`: rows no longer set are deleted, not zeroed.
    static func save(store: WhoopStore, day: String, _ log: Day, previous: Day) async {
        let source = CycleTrackingStore.sourceId
        var upserts: [MetricPoint] = []
        var deletes: [String] = []
        if let flow = log.flow {
            upserts.append(MetricPoint(day: day, key: flowKey, value: Double(flow.rawValue)))
        } else if previous.flow != nil {
            deletes.append(flowKey)
        }
        if log.ovulationTest {
            upserts.append(MetricPoint(day: day, key: ovulationTestKey, value: 1))
        } else if previous.ovulationTest {
            deletes.append(ovulationTestKey)
        }
        for id in log.symptoms { upserts.append(MetricPoint(day: day, key: symptomPrefix + id, value: 1)) }
        for id in previous.symptoms.subtracting(log.symptoms) { deletes.append(symptomPrefix + id) }
        for id in log.moods { upserts.append(MetricPoint(day: day, key: moodPrefix + id, value: 1)) }
        for id in previous.moods.subtracting(log.moods) { deletes.append(moodPrefix + id) }
        if !upserts.isEmpty { _ = try? await store.upsertMetricSeries(upserts, deviceId: source) }
        for key in deletes { _ = try? await store.deleteMetricSeriesPoint(deviceId: source, day: day, key: key) }
    }

    /// Saves today's notes and, when flow is logged with no period start in the last ten days, logs `day` as cycle
    /// day 1, since that is what a new period means. True when a start was logged.
    @discardableResult
    static func saveLoggingStart(store: WhoopStore, day: String, _ log: Day, previous: Day, starts: [String]) async -> Bool {
        await save(store: store, day: day, log, previous: previous)
        guard log.flow != nil, previous.flow == nil else { return false }
        let recent = starts.contains { start in CycleSnapshot.days(from: start, to: day).map { abs($0) < 10 } ?? false }
        if recent { return false }
        await CycleTrackingStore.logPeriodStart(store: store, day: day)
        return true
    }
}

/// The cycle phase from the nights: each night's skin-temperature deviation, resting heart rate and HRV z-scored
/// against the personal baseline, then `CyclePhaseEngine.classify` reads the run with the logged starts.
enum CyclePhaseReading {
    struct Output: Sendable {
        let result: CyclePhaseEngine.Result
        /// The fused nightly index, oldest first, for the history chart.
        let curve: [Double]
    }

    static func classify(days: [DailyMetric], loggedPeriodStarts: [String]) -> Output? {
        // The deviation's own bounds: the absolute skin_temp cfg (20 to 42 °C) rejected every night, so the baseline
        // never became usable and the engine stayed on "learning" for everyone.
        let tempCfg = Baselines.skinTempDeviationCfg
        guard let rhrCfg = Baselines.metricCfg["resting_hr"], let hrvCfg = Baselines.metricCfg["hrv"] else { return nil }
        // The nightly deviation is z-scored against its own folded spread, a zero-centred personal baseline; RHR and
        // HRV z-score their raw columns. Oldest to newest.
        let sorted = days.sorted { $0.day < $1.day }
        let skinState = Baselines.foldHistory(sorted.map { $0.skinTempDevC }, cfg: tempCfg)
        let rhrState = Baselines.foldHistory(sorted.map { $0.restingHr.map(Double.init) }, cfg: rhrCfg)
        let hrvState = Baselines.foldHistory(sorted.map { $0.avgHrv }, cfg: hrvCfg)
        var nights: [CyclePhaseEngine.Night] = []
        var curve: [Double] = []
        for d in sorted {
            let tempZ = d.skinTempDevC.map { skinState.usable ? Baselines.deviation($0, state: skinState).z : $0 / 0.3 }
            let rhrZ = rhrState.usable ? d.restingHr.map { Baselines.deviation(Double($0), state: rhrState).z } : nil
            let hrvZ = hrvState.usable ? d.avgHrv.map { Baselines.deviation($0, state: hrvState).z } : nil
            nights.append(CyclePhaseEngine.Night(day: d.day, tempZ: tempZ, rhrZ: rhrZ, hrvZ: hrvZ))
            if let fused = CyclePhaseEngine.fusedIndex(tempZ: tempZ, rhrZ: rhrZ, hrvZ: hrvZ) { curve.append(fused) }
        }
        // The pure engine cross-validates the logged starts against the temperature shift rather than trusting a
        // mistimed log blindly.
        return Output(result: CyclePhaseEngine.classify(nights, baselineUsable: skinState.usable,
                                                         loggedPeriodStarts: loggedPeriodStarts),
                      curve: curve)
    }
}

/// The phase a cycle day is drawn in on the page.
enum CyclePagePhase: String, CaseIterable, Sendable {
    case period, follicular, shift, luteal

    /// `CycleTrainingPattern.Phase`; the shift has none.
    var patternPhase: CycleTrainingPattern.Phase? {
        switch self {
        case .period: return .period
        case .follicular: return .follicular
        case .luteal: return .luteal
        case .shift: return nil
        }
    }
}

/// Everything the cycle page draws, worked out once from the engine's result, the logged starts and days, and the
/// nights. Nothing here is a new estimate: it reads the engine's phase, shift and window and counts days. Days are
/// "yyyy-MM-dd" keys counted on the calendar, so the result is the same on every platform and time zone.
struct CycleSnapshot: Sendable {
    var cycleDay: Int?
    var dayRange: ClosedRange<Int>?
    var length: Int
    var phase: CyclePagePhase?
    var shiftDay: Int?
    var periodLength: Int
    /// The likely next-period window, in days from today.
    var nextWindow: ClosedRange<Int>?
    var temps: [(day: Int, value: Double)] = []
    /// The first day of this cycle.
    var startDay: String?
    var periodDays: Set<String> = []
    var compare: Compare?
    var cyclesSeen: Int
    var engineConfidence: CyclePhaseEngine.Confidence?
    var moodsThisPhase: [String: Int] = [:]
    /// The rough fertile-days estimate of this cycle, when it may be shown.
    var fertile: FertileWindow.Estimate?
    /// Day keys of this cycle's likely fertile days, for the calendar.
    var fertileDays: Set<String> = []

    /// This cycle's luteal nights against its first half, for the Body, Exercise and Mind cards.
    struct Compare: Sendable {
        var tempDelta: Double?
        var rhrDelta: Double?
        var hrvDelta: Double?
        var chargeNow: Double?
        var chargeBefore: Double?
        var wakeNow: Double?
        var wakeBefore: Double?
    }

    var fertileStatus: FertileWindow.Status? {
        guard let fertile, let cycleDay else { return nil }
        return FertileWindow.status(fertile, cycleDay: cycleDay)
    }

    /// The first likely fertile day while it still lies ahead; what the reminder arms.
    var fertileStartDayAhead: String? {
        guard case .before? = fertileStatus, let fertile, let startDay else { return nil }
        return Self.add(fertile.firstDay - 1, to: startDay)
    }

    func isFertile(day d: Int) -> Bool {
        guard let fertile else { return false }
        return (fertile.firstDay...fertile.lastDay).contains(d)
    }

    var wheelDays: Int { min(45, max(length, cycleDay ?? 0, (cycleDay ?? 0) + (nextWindow?.upperBound ?? 0))) }
    var todayOnWheel: Int? { cycleDay ?? dayRange.map { ($0.lowerBound + $0.upperBound) / 2 } }
    var tempFloor: Double { min(-0.4, (temps.map(\.value).min() ?? 0) - 0.1) }
    var tempCeiling: Double { max(0.5, (temps.map(\.value).max() ?? 0) + 0.1) }

    /// The phase colour of one day of this cycle on the dial.
    func phase(onDay d: Int) -> CyclePagePhase? {
        if d <= periodLength, cycleDay != nil { return .period }
        guard let shift = shiftDay else { return (todayOnWheel.map { d <= $0 } ?? false) ? .follicular : nil }
        if d < shift - 1 { return .follicular }
        if d <= shift + 1 { return .shift }
        return .luteal
    }

    static func make(result: CyclePhaseEngine.Result?, starts: [String], log: [String: CycleLog.Day],
                     days: [DailyMetric], today: String, showFertile: Bool = false) -> CycleSnapshot {
        // The current cycle runs from the newest logged start, if it is recent enough to still be this cycle.
        let lastStart = starts.filter { $0 <= today }.max()
        let current = lastStart.flatMap { s in (diff(s, today) ?? 99) <= 45 ? s : nil }
        let cycleDay = current.flatMap { diff($0, today).map { $0 + 1 } }

        // The usual length: the engine's, else the median gap between logged starts, else the default.
        let sortedStarts = starts.sorted()
        let gaps = zip(sortedStarts, sortedStarts.dropFirst()).compactMap { diff($0, $1) }.filter { (21...40).contains($0) }.sorted()
        let length = result?.cycleLengthDays ?? (gaps.isEmpty ? CyclePhaseEngine.defaultCycleDays : gaps[gaps.count / 2])

        // Period days: from each start, the days with flow logged, else the first five.
        func window(_ s: String) -> [String] { (0..<10).compactMap { add($0, to: s) } }
        var periodDays = Set<String>()
        for s in sortedStarts {
            let w = window(s)
            let flowed = w.enumerated().filter { log[$0.element]?.flow != nil }.map(\.offset)
            let n = max(flowed.max().map { $0 + 1 } ?? 5, 1)
            w.prefix(n).forEach { periodDays.insert($0) }
        }
        for (k, d) in log where d.flow != nil { periodDays.insert(k) }
        var periodLength = 5
        if let current, let last = window(current).enumerated().filter({ log[$0.element]?.flow != nil }).map(\.offset).max() {
            periodLength = last + 1
        }

        // The engine's shift marker inside this cycle, as a cycle day.
        let shiftDay: Int? = current.flatMap { start in
            result?.shiftMarkers.map(\.day).filter { $0 > start && $0 <= today }.max().flatMap { diff(start, $0).map { $0 + 1 } }
        }

        // The phase: the logged period first (the wearer's own fact), then this cycle's rise, then the engine.
        var phase: CyclePagePhase?
        if let cycleDay, cycleDay <= periodLength {
            phase = .period
        } else if let cycleDay, let shiftDay {
            phase = cycleDay < shiftDay - 1 ? .follicular : (cycleDay <= shiftDay + 1 ? .shift : .luteal)
        } else if let result {
            switch result.phase {
            case .follicular: phase = .follicular
            case .periOvulatory: phase = .shift
            case .luteal: phase = .luteal
            case .unknown, .learning: phase = nil
            }
        }

        let nextWindow: ClosedRange<Int>? = result?.nextPeriodWindow.flatMap { w in
            guard let lo = diff(today, w.earliestDay), let hi = diff(today, w.latestDay), hi >= lo else { return nil }
            return lo...hi
        }

        var snap = CycleSnapshot(cycleDay: cycleDay,
                                 dayRange: (result?.cycleDayLow).flatMap { lo in result?.cycleDayHigh.map { lo...max(lo, $0) } },
                                 length: length, phase: phase, shiftDay: shiftDay, periodLength: periodLength,
                                 nextWindow: nextWindow, startDay: current, periodDays: periodDays,
                                 cyclesSeen: starts.count, engineConfidence: result?.confidence)

        // The nights of this cycle, by cycle day.
        if let current {
            let byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
            var nights: [(day: Int, metric: DailyMetric)] = []
            for offset in 0..<(cycleDay ?? 0) {
                guard let key = add(offset, to: current), let m = byDay[key] else { continue }
                nights.append((offset + 1, m))
            }
            snap.temps = nights.compactMap { n in n.metric.skinTempDevC.map { (n.day, $0) } }
            if let shiftDay, phase == .luteal {
                let before = nights.filter { $0.day > periodLength && $0.day < shiftDay - 1 }.map(\.metric)
                let after = nights.filter { $0.day > shiftDay + 1 }.map(\.metric)
                func mean(_ xs: [Double]) -> Double? { xs.count >= 3 ? xs.reduce(0, +) / Double(xs.count) : nil }
                func delta(_ f: (DailyMetric) -> Double?) -> Double? {
                    guard let a = mean(after.compactMap(f)), let b = mean(before.compactMap(f)) else { return nil }
                    return a - b
                }
                snap.compare = Compare(tempDelta: delta { $0.skinTempDevC },
                                       rhrDelta: delta { $0.restingHr.map(Double.init) },
                                       hrvDelta: delta { $0.avgHrv },
                                       chargeNow: mean(after.compactMap(\.recovery)),
                                       chargeBefore: mean(before.compactMap(\.recovery)),
                                       wakeNow: mean(after.compactMap { $0.disturbances.map(Double.init) }),
                                       wakeBefore: mean(before.compactMap { $0.disturbances.map(Double.init) }))
                for n in nights where n.day > shiftDay + 1 {
                    for m in log[n.metric.day]?.moods ?? [] { snap.moodsThisPhase[m, default: 0] += 1 }
                }
            }
        }
        if showFertile, let current, let cycleDay {
            // The rise days of completed past cycles, newest first, then this cycle's own rise or test.
            let all = cycles(starts: starts, log: log, result: result).sorted { $0.start > $1.start }
            let pastRises: [Int] = all.dropFirst().compactMap { c in
                guard let shift = c.shift else { return nil }
                return diff(c.start, shift).map { $0 + 1 }
            }
            let testDay = (0..<cycleDay).first { offset in
                add(offset, to: current).map { log[$0]?.ovulationTest == true } ?? false
            }.map { $0 + 1 }
            if let estimate = FertileWindow.estimate(pastRiseDays: pastRises, currentRiseDay: shiftDay, positiveTestDay: testDay) {
                snap.fertile = estimate
                for d in estimate.firstDay...estimate.lastDay {
                    if let key = add(d - 1, to: current) { snap.fertileDays.insert(key) }
                }
            }
        }
        return snap
    }

    /// Every logged cycle with the temperature rise the engine found inside it, for the training pattern.
    static func cycles(starts: [String], log: [String: CycleLog.Day], result: CyclePhaseEngine.Result?) -> [CycleTrainingPattern.Cycle] {
        let sorted = starts.sorted()
        let shifts = (result?.shiftMarkers ?? []).map(\.day).sorted()
        return sorted.enumerated().map { i, start in
            let end = i + 1 < sorted.count ? sorted[i + 1] : CycleTrackingStore.latestDay
            let shift = shifts.first { $0 > start && $0 < end }
            let flowed = (0..<10).filter { offset in add(offset, to: start).map { log[$0]?.flow != nil } ?? false }.max()
            return CycleTrainingPattern.Cycle(start: start, shift: shift, periodDays: flowed.map { $0 + 1 } ?? 5)
        }
    }

    // MARK: Day keys

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Calendar days from `a` to `b`.
    static func days(from a: String, to b: String) -> Int? {
        guard let x = date(a), let y = date(b) else { return nil }
        return utc.dateComponents([.day], from: x, to: y).day
    }

    private static func diff(_ a: String, _ b: String) -> Int? { days(from: a, to: b) }

    /// The key `n` days after `key`.
    static func add(_ n: Int, to key: String) -> String? {
        guard let d = date(key), let r = utc.date(byAdding: .day, value: n, to: d) else { return nil }
        let c = utc.dateComponents([.year, .month, .day], from: r)
        guard let y = c.year, let m = c.month, let dd = c.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, dd)
    }
}

/// Whether this wearer's training feels harder in one part of the cycle (`CycleTrainingPattern`), learned from a
/// year of strength sessions, each with its whole-session rating where one lies within half an hour, else the mean
/// set RPE; ratings with no strength session count on their own.
enum CyclePatternReading {
    static func learn(reader: StoreReader, cycles: [CycleTrainingPattern.Cycle], dismissedWorkouts: [String],
                      now: Int = Int(Date().timeIntervalSince1970)) async -> CycleTrainingPattern.Result {
        let days = 365
        let fusion = await TrainingSessionResolver.read(reader: reader, from: now - days * 86_400, to: now + 86_400,
                                                        dismissedDetectedSpans: dismissedWorkouts)
        let history = await StrengthHistoryReader.read(store: reader.store, days: days, now: now) { fusion }
        let summaries = history.workouts.map { StrengthSession.summarize($0, templates: history.templates) }
        let rated = await SessionRPEEntry.read(store: reader.store, from: now - 400 * 86_400, to: now)
        func day(_ ts: Int) -> String { StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(ts))) }
        var used = Set<String>()
        var sessions: [CycleTrainingPattern.Session] = []
        for s in summaries {
            let match = rated.first { abs($0.startTs - s.startTs) <= 1_800 }
            if let match { used.insert(match.id) }
            sessions.append(.init(day: day(s.startTs), rpe: match?.rpe ?? s.meanRpe,
                                  volumeKg: s.volumeLoadKg > 0 ? s.volumeLoadKg : nil, kind: s.title))
        }
        for r in rated where !used.contains(r.id) { sessions.append(.init(day: day(r.startTs), rpe: r.rpe)) }
        return CycleTrainingPattern.analyse(sessions: sessions, cycles: cycles)
    }
}
