import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

// IntelligenceEngine+Healthspan.swift — fork feature (backlog plan HEALTHSPAN_AGE_PLAN, spec S5): the weekly
// healthspan age and Pace of Aging, kept in its own file so the shared analysis pass gains one call only.
//
// Two steps per pass. (1) Zone minutes need raw HR, which the store keeps for about five weeks, so they are
// banked per day for the pass window. (2) Every weekly row is re-derived from banked and permanent per-day
// values (daily rows, sleep sessions, workouts, series), so a row can never go stale. Weeks follow the
// Fitness Age convention: keyed to the Saturday on or before, refining until the week ends.

/// Experimental and off by default until the Healthspan card ships (spec S6).
enum HealthspanFeature {
    static let defaultsKey = "noopHealthspanAge"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}

extension IntelligenceEngine {

    static let healthspanAgeKey = "healthspan_age"
    static let healthspanPaceKey = "healthspan_pace"
    static let healthspanCoveredDaysKey = "healthspan_covered_days"
    static let healthspanZone13Key = "hs_zone13_min"
    static let healthspanZone45Key = "hs_zone45_min"
    /// A day's training-based VO₂max (median of its walks and runs), banked while the band's trace exists.
    static let healthspanTrainingVO2Key = "hs_vo2_training"
    /// Which `HealthspanVO2.Source` a week's VO₂max came from.
    static let healthspanVO2SourceKey = "hs_vo2_source"
    /// The window input behind a week's age, so the card's breakdown is computed from the same numbers.
    nonisolated static func healthspanInputKey(_ c: HealthspanEngine.Component) -> String { "hs_in_" + c.rawValue }
    /// The last-30-days input behind a week's pace, for the detail screen's second marker.
    nonisolated static func healthspanRecentInputKey(_ c: HealthspanEngine.Component) -> String {
        "hs_in30_" + c.rawValue
    }

    /// Every key a weekly row writes, so a rewrite can clear what a week no longer has.
    nonisolated static var healthspanWeeklyKeys: [String] {
        [healthspanAgeKey, healthspanPaceKey, healthspanCoveredDaysKey, healthspanVO2SourceKey]
            + HealthspanEngine.Component.allCases.flatMap { [healthspanInputKey($0), healthspanRecentInputKey($0)] }
    }

    /// Banks zone minutes and training-based VO₂max for `[oldestDay, newestDay]`, then rewrites the weekly rows
    /// of the weeks that window touches; on the first run, every week back to the first sleep data. Writes
    /// nothing for a profile sex the paper has no targets for. `manualVO2max` is the value the wearer entered
    /// with the day it was measured; `bodyFat` every body-fat reading, entered or from Apple Health.
    nonisolated static func runHealthspanPass(store: WhoopStore, strapId: String, computedId: String, age: Int,
                                              sex: String, hrMaxOverride: Int, oldestDay: String,
                                              newestDay: String, tzOffset: Int,
                                              manualVO2max: (day: String, value: Double)? = nil,
                                              bodyFat: [(day: String, value: Double)] = []) async {
        guard age > 0, let sex = HealthspanEngine.Sex(profileValue: sex),
              let windowStart = midnightForDayKey(oldestDay, offsetSec: tzOffset),
              let windowEndDay = midnightForDayKey(newestDay, offsetSec: tzOffset) else { return }
        let windowEnd = windowEndDay + 86_400
        let maxHR = hrMaxOverride > 0 ? Double(hrMaxOverride) : StrainScorer.tanakaHRmax(age: Double(age))

        // (1) Bank zone minutes while raw HR exists. A day counts as worn when it has a computed daily row.
        let recentWorkouts = await healthspanWorkouts(store: store, strapId: strapId, computedId: computedId,
                                                      from: windowStart - 86_400, to: windowEnd)
        let worn = Set(((try? await store.dailyMetrics(deviceId: computedId, from: oldestDay, to: newestDay)) ?? [])
            .map(\.day))
        let sleepHR = Dictionary(((try? await store.metricSeries(deviceId: computedId, key: "rhr_primary_session",
                                                                 from: oldestDay, to: newestDay)) ?? [])
            .map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
        let fallbackRHR = sleepHR.isEmpty ? nil : sleepHR.values.reduce(0, +) / Double(sleepHR.count)
        var banked: [MetricPoint] = []
        var day = oldestDay
        while day <= newestDay {
            defer { day = HealthspanWindow.dayKey(day, plus: 1) }
            guard worn.contains(day), let restingHR = sleepHR[day] ?? fallbackRHR,
                  let dayStart = midnightForDayKey(day, offsetSec: tzOffset) else { continue }
            var zone13 = 0.0, zone45 = 0.0
            for w in recentWorkouts where w.end > dayStart && w.start < dayStart + 86_400 {
                let s = max(w.start, dayStart), e = min(w.end, dayStart + 86_400)
                let hr = (try? await store.hrSamples(deviceId: strapId, from: s, to: e - 1, limit: Int.max)) ?? []
                guard let m = HealthspanEngine.zoneMinutes(hr: hr, restingHR: restingHR, maxHR: maxHR) else { continue }
                zone13 += m.zone13; zone45 += m.zone45
            }
            banked += [MetricPoint(day: day, key: healthspanZone13Key, value: zone13),
                       MetricPoint(day: day, key: healthspanZone45Key, value: zone45)]
        }
        banked += await healthspanTrainingVO2(store: store, strapId: strapId, computedId: computedId,
                                              from: windowStart, to: windowEnd, sleepHR: sleepHR,
                                              fallbackRHR: fallbackRHR, maxHR: maxHR, tzOffset: tzOffset)
        if !banked.isEmpty { _ = try? await store.upsertMetricSeries(banked, deviceId: computedId) }

        // (2) Weekly rows. First run: every week back to the first computed day; afterwards: the pass window.
        let currentSaturday = saturdayKey(onOrBefore: newestDay)
        let hasHistory = !(((try? await store.metricSeries(deviceId: computedId, key: healthspanAgeKey,
                                                           from: HealthspanWindow.dayKey(newestDay, plus: -400),
                                                           to: newestDay)) ?? []).isEmpty)
        var firstSaturday = saturdayKey(onOrBefore: oldestDay)
        if !hasHistory,
           let firstDay = ((try? await store.dailyMetrics(deviceId: computedId,
                                                          from: HealthspanWindow.dayKey(newestDay, plus: -365),
                                                          to: newestDay)) ?? []).map(\.day).min() {
            firstSaturday = min(firstSaturday, saturdayKey(onOrBefore: firstDay))
        }
        let readFrom = HealthspanWindow.dayKey(firstSaturday, plus: -(HealthspanWindow.ageWindowDays - 1))
        let days = await healthspanDays(store: store, strapId: strapId, computedId: computedId,
                                        from: readFrom, to: newestDay, tzOffset: tzOffset)
        func series(_ deviceId: String, _ key: String) async -> [(day: String, value: Double)] {
            ((try? await store.metricSeries(deviceId: deviceId, key: key, from: readFrom, to: newestDay)) ?? [])
                .map { (day: $0.day, value: $0.value) }
        }
        let appleVO2 = await series(Repository.appleHealthSource, "vo2max")
        let trainingVO2 = await series(computedId, healthspanTrainingVO2Key)
        var weekly: [MetricPoint] = []
        var saturday = firstSaturday
        while saturday <= currentSaturday {
            defer { saturday = HealthspanWindow.dayKey(saturday, plus: 7) }
            let end = min(HealthspanWindow.dayKey(saturday, plus: 6), newestDay)
            let vo2 = HealthspanVO2.resolve(manual: manualVO2max, appleHealth: appleVO2, training: trainingVO2,
                                            endingOn: end)
            guard let w = HealthspanWindow.weekly(
                days: days, endingOn: end, age: Double(age), sex: sex, vo2max: vo2?.window,
                recentVO2max: vo2?.recent, leanMassPct: HealthspanVO2.leanMassPct(bodyFat: bodyFat, endingOn: end))
            else { continue }
            weekly.append(MetricPoint(day: saturday, key: healthspanAgeKey, value: w.result.healthspanAge))
            if let vo2 {
                weekly.append(MetricPoint(day: saturday, key: healthspanVO2SourceKey, value: Double(vo2.source.rawValue)))
            }
            weekly.append(MetricPoint(day: saturday, key: healthspanCoveredDaysKey, value: Double(w.coveredDays)))
            if let pace = w.pace { weekly.append(MetricPoint(day: saturday, key: healthspanPaceKey, value: pace)) }
            for c in HealthspanEngine.Component.allCases {
                if let v = w.inputs.value(c) {
                    weekly.append(MetricPoint(day: saturday, key: healthspanInputKey(c), value: v))
                }
                if let v = w.recentInputs?.value(c) {
                    weekly.append(MetricPoint(day: saturday, key: healthspanRecentInputKey(c), value: v))
                }
            }
        }
        // Replace the whole span, so a week that lost a measure (or its age) keeps no stale row.
        _ = try? await store.replaceMetricSeriesWindow(weekly, deviceId: computedId, keys: healthspanWeeklyKeys,
                                                       from: firstSaturday, to: currentSaturday)
    }

    /// Training-based VO₂max per day for walks and runs starting in `[from, to)`: the session's average heart
    /// rate from the band's trace (or, for an Apple Health session, the watch's own measured average) through
    /// `ExerciseVO2max`, the day's median banked under `healthspanTrainingVO2Key`. A session logged by two
    /// sources yields two estimates of the same day, which the median absorbs.
    nonisolated static func healthspanTrainingVO2(store: WhoopStore, strapId: String, computedId: String,
                                                  from: Int, to: Int, sleepHR: [String: Double],
                                                  fallbackRHR: Double?, maxHR: Double,
                                                  tzOffset: Int) async -> [MetricPoint] {
        var byDay: [String: [Double]] = [:]
        for source in Set([strapId, computedId, Repository.appleHealthSource]) {
            for row in (try? await store.workouts(deviceId: source, from: from, to: to, limit: 100_000)) ?? [] {
                let m = CardioSession.metrics(for: row, tzOffsetSeconds: tzOffset)
                guard m.modality == .foot, let seconds = m.durationS, let restingHR = sleepHR[m.day] ?? fallbackRHR
                else { continue }
                let trace = (try? await store.hrSamples(deviceId: strapId, from: row.startTs, to: row.endTs - 1,
                                                        limit: Int.max)) ?? []
                let averageHR = HealthspanVO2.bandAverageHR(trace, sessionSeconds: seconds)
                    ?? (row.source == WorkoutSource.appleHealthSource ? m.avgHr.map(Double.init) : nil)
                let input = ExerciseVO2max.SessionInput(
                    day: m.day, startTs: m.startTs, modality: m.modality, distanceM: m.distanceM, durationS: seconds,
                    averageHR: averageHR, heartRateMeasured: averageHR != nil, restingHR: restingHR, maxHR: maxHR)
                if case let .estimate(e) = ExerciseVO2max.estimate(input) { byDay[m.day, default: []].append(e.vo2max) }
            }
        }
        return byDay.compactMap { day, xs in
            HealthspanVO2.median(xs).map { MetricPoint(day: day, key: healthspanTrainingVO2Key, value: $0) }
        }
    }

    /// Per-day healthspan values from NOOP's own computed data: daily rows (sleep, steps), the sleep-mean HR,
    /// banked zone minutes, timing consistency from sleep sessions, and strength minutes from workouts.
    nonisolated static func healthspanDays(store: WhoopStore, strapId: String, computedId: String,
                                           from: String, to: String, tzOffset: Int) async -> [HealthspanDay] {
        guard let fromTs = midnightForDayKey(from, offsetSec: tzOffset),
              let toTs = midnightForDayKey(to, offsetSec: tzOffset).map({ $0 + 86_400 }) else { return [] }
        func series(_ key: String) async -> [String: Double] {
            Dictionary(((try? await store.metricSeries(deviceId: computedId, key: key, from: from, to: to)) ?? [])
                .map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        var byDay: [String: HealthspanDay] = [:]
        func edit(_ day: String, _ f: (inout HealthspanDay) -> Void) {
            var d = byDay[day] ?? HealthspanDay(day: day); f(&d); byDay[day] = d
        }
        for d in (try? await store.dailyMetrics(deviceId: computedId, from: from, to: to)) ?? [] {
            edit(d.day) {
                $0.sleepHours = d.totalSleepMin.flatMap { $0 > 0 ? $0 / 60 : nil }
                $0.steps = d.steps.flatMap { $0 > 0 ? Double($0) : nil }
            }
        }
        for (day, v) in await series("rhr_primary_session") { edit(day) { $0.sleepMeanHR = v } }
        for (day, v) in await series(healthspanZone13Key) { edit(day) { $0.zone13Min = v } }
        for (day, v) in await series(healthspanZone45Key) { edit(day) { $0.zone45Min = v } }

        // Consistency for each night: the longest session ending that day is the main sleep; naps count too.
        let sessions = ((try? await store.sleepSessions(deviceId: computedId, from: fromTs - 5 * 86_400,
                                                        to: toTs, limit: 100_000)) ?? [])
            .map { SleepTimingConsistency.Interval(start: $0.effectiveStartTs, end: $0.endTs) }
        var mainByDay: [String: SleepTimingConsistency.Interval] = [:]
        for s in sessions where s.end >= fromTs && s.end < toTs {
            let day = AnalyticsEngine.dayString(s.end, offsetSec: tzOffset)
            if let m = mainByDay[day], m.end - m.start >= s.end - s.start { continue }
            mainByDay[day] = s
        }
        for (day, main) in mainByDay {
            // An unrecorded day would read as awake all day; score only nights with all four prior nights.
            guard (1...SleepTimingConsistency.priorDays).allSatisfy({
                mainByDay[HealthspanWindow.dayKey(day, plus: -$0)] != nil
            }) else { continue }
            let near = sessions.filter { $0.end > main.end - 5 * 86_400 && $0.start < main.end }
            if let c = SleepTimingConsistency.score(sleeps: near, wakeAt: main.end) {
                edit(day) { $0.sleepConsistencyPct = c }
            }
        }

        // Strength minutes by local start day; overlapping rows from several sources count once.
        var strengthByDay: [String: Double] = [:]
        let workouts = await healthspanWorkouts(store: store, strapId: strapId, computedId: computedId,
                                                from: fromTs, to: toTs, strengthOnly: true)
        for w in workouts { strengthByDay[AnalyticsEngine.dayString(w.start, offsetSec: tzOffset), default: 0] += Double(w.end - w.start) / 60 }
        for day in byDay.keys { edit(day) { $0.strengthMin = strengthByDay[day] ?? 0 } }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Weekly rows for `--demo-seed`: habits improving week by week, run through the real engine so the card
    /// renders under the demo exactly as it would on a wearer's data. Each week's pace compares its window
    /// with a slightly better last 30 days, as an improving wearer's would. `--demo-ageless-older` seeds the
    /// other story instead: habits slipping, an age above the actual one and a pace above the calendar.
    nonisolated static func healthspanDemoRows(saturdays: [String],
                                               older: Bool = CommandLine.arguments.contains("--demo-ageless-older"))
        -> [MetricPoint] {
        func inputs(_ t: Double) -> HealthspanEngine.Inputs {
            func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * min(1.25, t) }
            if older {
                return HealthspanEngine.Inputs(age: 35, sex: .male, sleepHours: lerp(6.9, 6.0),
                                               sleepConsistencyPct: lerp(62, 45), dailySteps: lerp(6500, 4000),
                                               zone13MinPerWeek: lerp(90, 25), zone45MinPerWeek: lerp(8, 0),
                                               strengthMinPerWeek: lerp(30, 0), vo2max: lerp(40, 35),
                                               restingHR: lerp(62, 71), leanMassPct: lerp(74, 70))
            }
            return HealthspanEngine.Inputs(age: 35, sex: .male, sleepHours: lerp(6.8, 7.4),
                                           sleepConsistencyPct: lerp(60, 76), dailySteps: lerp(6800, 9400),
                                           zone13MinPerWeek: lerp(70, 170), zone45MinPerWeek: lerp(3, 18),
                                           strengthMinPerWeek: lerp(15, 55), vo2max: lerp(44, 50),
                                           restingHR: lerp(63, 57), leanMassPct: lerp(76, 79))
        }
        var out: [MetricPoint] = []
        let last = Double(max(1, saturdays.count - 1))
        for (i, day) in saturdays.enumerated() {
            let window = inputs(Double(i) / last), recent = inputs((Double(i) + 2) / last)
            guard let r = HealthspanEngine.compute(window) else { continue }
            out.append(MetricPoint(day: day, key: healthspanAgeKey, value: r.healthspanAge))
            out.append(MetricPoint(day: day, key: healthspanVO2SourceKey,
                                   value: Double(HealthspanVO2.Source.training.rawValue)))
            out.append(MetricPoint(day: day, key: healthspanCoveredDaysKey, value: Double(min(182, 30 + 7 * i))))
            if let pace = HealthspanEngine.paceOfAging(window: window, last30Days: recent) {
                out.append(MetricPoint(day: day, key: healthspanPaceKey, value: pace))
            }
            for c in HealthspanEngine.Component.allCases {
                if let v = window.value(c) { out.append(MetricPoint(day: day, key: healthspanInputKey(c), value: v)) }
                if let v = recent.value(c) { out.append(MetricPoint(day: day, key: healthspanRecentInputKey(c), value: v)) }
            }
        }
        return out
    }

    /// Workouts from every source the analysis reads (strap imports and manual rows, detected bouts, Apple
    /// Health, Hevy), merged into non-overlapping intervals so a session logged twice counts once.
    nonisolated static func healthspanWorkouts(store: WhoopStore, strapId: String, computedId: String,
                                               from: Int, to: Int,
                                               strengthOnly: Bool = false) async -> [(start: Int, end: Int)] {
        var rows: [WorkoutRow] = []
        for source in Set([strapId, computedId, "apple-health", "hevy"]) {
            rows += (try? await store.workouts(deviceId: source, from: from, to: to, limit: 100_000)) ?? []
        }
        let intervals = rows
            .filter { $0.endTs > $0.startTs && (!strengthOnly || HealthspanWindow.countsAsStrength(storedName: $0.sport)) }
            .map { (start: $0.startTs, end: $0.endTs) }
            .sorted { $0.start < $1.start }
        var merged: [(start: Int, end: Int)] = []
        for i in intervals {
            if let last = merged.last, i.start <= last.end {
                merged[merged.count - 1].end = max(last.end, i.end)
            } else {
                merged.append(i)
            }
        }
        return merged
    }
}
