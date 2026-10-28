import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

// DailyAnalysis+Healthspan.swift — fork feature (backlog plan HEALTHSPAN_AGE_PLAN, spec S5): the weekly
// healthspan age and Pace of Aging, kept in its own file so the shared analysis pass gains one call only.
//
// Two steps per pass. (1) Zone minutes need raw HR, which the store keeps for about five weeks, so they are
// banked per day for the pass window (on the first run, for every day the raw HR still covers). (2) Every weekly row is re-derived from banked and permanent per-day
// values (daily rows, sleep sessions, workouts, series), so a row can never go stale. Weeks follow the
// Fitness Age convention: keyed to the Saturday on or before, refining until the week ends.


extension DailyAnalysis {

    public static let healthspanAgeKey = "healthspan_age"
    public static let healthspanPaceKey = "healthspan_pace"
    public static let healthspanCoveredDaysKey = "healthspan_covered_days"
    public static let healthspanZone13Key = "hs_zone13_min"
    public static let healthspanZone45Key = "hs_zone45_min"
    /// Training VO₂max days AI-21 banked before the estimator moved to Training Load's; AI-22 deletes them.
    public static let healthspanLegacyTrainingVO2Key = "hs_vo2_training"
    /// Which `HealthspanVO2.Source` a week's VO₂max came from.
    public static let healthspanVO2SourceKey = "hs_vo2_source"
    /// The window input behind a week's age, so the card's breakdown is computed from the same numbers.
    public nonisolated static func healthspanInputKey(_ c: HealthspanEngine.Component) -> String { "hs_in_" + c.rawValue }
    /// The last-30-days input behind a week's pace, for the detail screen's second marker.
    public nonisolated static func healthspanRecentInputKey(_ c: HealthspanEngine.Component) -> String {
        "hs_in30_" + c.rawValue
    }
    /// What a week's input stands on (`HealthspanBasis.counts`; for VO₂max, its readings), since AI-23.
    public nonisolated static func healthspanCountKey(_ c: HealthspanEngine.Component) -> String { "hs_n_" + c.rawValue }
    /// The day of the newest VO₂max reading behind a week, as `HealthspanBasis.dayNumber`.
    public static let healthspanVO2DayKey = "hs_vo2_day"
    /// The least VO₂max the week's long walks and runs allow (`HealthspanVO2.enduranceFloor`), since AI-26. A
    /// plausibility bound shown beside the measure, never its value.
    public static let healthspanVO2FloorKey = "hs_vo2_floor"
    /// The day of the body-fat reading behind a week's lean mass, as `HealthspanBasis.dayNumber`.
    public static let healthspanBodyFatDayKey = "hs_fat_day"
    /// For the current week only, when it has no age: its nights of sleep data and the core measures it lacks
    /// (`HealthspanWindow.Gap`), since AI-29, so the screen says what is missing.
    public static let healthspanGapNightsKey = "hs_gap_nights"
    public static let healthspanGapMissingKey = "hs_gap_missing"

    /// Every key a weekly row writes, so a rewrite can clear what a week no longer has.
    public nonisolated static var healthspanWeeklyKeys: [String] {
        [healthspanAgeKey, healthspanPaceKey, healthspanCoveredDaysKey, healthspanVO2SourceKey, healthspanVO2DayKey,
         healthspanBodyFatDayKey, healthspanVO2FloorKey, healthspanGapNightsKey, healthspanGapMissingKey]
            + HealthspanEngine.Component.allCases.flatMap {
                [healthspanInputKey($0), healthspanRecentInputKey($0), healthspanCountKey($0)]
            }
    }

    /// Banks zone minutes for `[oldestDay, newestDay]`, then rewrites the weekly rows of the weeks that window
    /// touches. On the first run (no stored week) it banks every day the band's raw heart rate still covers
    /// (`HealthspanWindow.rawRetentionDays`) and writes every week back to the first sleep data. Writes nothing
    /// for a profile sex without targets, and nothing at all when a read fails: a failed read is
    /// not an empty history, and replacing the weeks with it would erase them.
    ///
    /// `manualVO2max` is the value the wearer entered with its day; `longSessions` the walks and runs of an hour
    /// or more with their oxygen cost, for the endurance floor (`Repository.agelessLongSessions`); `bodyFat` every
    /// body-fat reading, entered or from Apple Health. Since AI-26 no estimate from walks or runs is a VO₂max source.
    /// `steps` is the day's count from the app's one step resolver (`Repository.resolvedSteps`: the strap's count,
    /// then the phone's, then the estimate from motion), since AI-29; a day missing from it falls back to the
    /// strap's own daily row.
    public nonisolated static func runHealthspanPass(store: WhoopStore, strapId: String, computedId: String, age: Int,
                                              sex: String, hrMaxOverride: Int, oldestDay: String,
                                              newestDay: String, tzOffset: Int,
                                              manualVO2max: (day: String, value: Double)? = nil,
                                              longSessions: [HealthspanVO2.LongSession] = [],
                                              bodyFat: [(day: String, value: Double)] = [],
                                              steps: [String: Double] = [:]) async {
        guard age > 0, let sex = HealthspanEngine.Sex(profileValue: sex) else { return }
        do {
            try await healthspanPass(store: store, strapId: strapId, computedId: computedId, age: age, sex: sex,
                                     hrMaxOverride: hrMaxOverride, oldestDay: oldestDay, newestDay: newestDay,
                                     tzOffset: tzOffset, manualVO2max: manualVO2max,
                                     longSessions: longSessions, bodyFat: bodyFat, steps: steps)
        } catch {
            // Leave every stored row as it was; the next pass tries again.
        }
    }

    /// The AI-21/AI-22 rebuild: deletes every AgeLess week and the training VO₂max days AI-21 banked, under both
    /// computed owners, so the next pass finds no history and rebuilds. Banked zone minutes are kept: their raw
    /// heart rate may be gone.
    public nonisolated static func deleteHealthspanWeeks(store: WhoopStore, deviceId: String) async throws {
        for owner in Set([deviceId + "-noop", MetricResolver.whoopSource + "-noop"]) {
            for key in healthspanWeeklyKeys + [healthspanLegacyTrainingVO2Key] {
                try await store.deleteMetricSeries(deviceId: owner, key: key)
            }
        }
    }

    /// Whether any AgeLess week is stored in the last 400 days; none means the next pass is a first run.
    public nonisolated static func healthspanHasHistory(store: WhoopStore, computedId: String, newestDay: String) async throws -> Bool {
        !(try await store.metricSeries(deviceId: computedId, key: healthspanAgeKey,
                                       from: HealthspanWindow.dayKey(newestDay, plus: -400), to: newestDay)).isEmpty
    }

    private nonisolated static func healthspanPass(store: WhoopStore, strapId: String, computedId: String, age: Int,
                                                   sex: HealthspanEngine.Sex, hrMaxOverride: Int, oldestDay: String,
                                                   newestDay: String, tzOffset: Int,
                                                   manualVO2max: (day: String, value: Double)?,
                                                   longSessions: [HealthspanVO2.LongSession],
                                                   bodyFat: [(day: String, value: Double)],
                                                   steps: [String: Double]) async throws {
        let hasHistory = try await healthspanHasHistory(store: store, computedId: computedId, newestDay: newestDay)
        let bankFrom = hasHistory ? oldestDay
            : min(oldestDay, HealthspanWindow.dayKey(newestDay, plus: -(HealthspanWindow.rawRetentionDays - 1)))
        guard let windowStart = midnightForDayKey(bankFrom, offsetSec: tzOffset),
              let windowEndDay = midnightForDayKey(newestDay, offsetSec: tzOffset) else { return }
        let windowEnd = windowEndDay + 86_400
        let maxHR = MaxHeartRate.resolve(overrideBpm: hrMaxOverride, age: Double(age)).bpm ?? 0

        // (1) Bank zone minutes while raw HR exists. A day counts as worn when it has a computed daily row; a
        // worn day whose raw HR is already gone keeps the value banked while it still existed.
        let recentWorkouts = try await healthspanWorkouts(store: store, strapId: strapId, computedId: computedId,
                                                          from: windowStart - 86_400, to: windowEnd)
        let worn = Set(try await store.dailyMetrics(deviceId: computedId, from: bankFrom, to: newestDay).map(\.day))
        let sleepHR = Dictionary(try await store.metricSeries(deviceId: computedId, key: "rhr_primary_session",
                                                              from: bankFrom, to: newestDay)
            .map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
        let fallbackRHR = sleepHR.isEmpty ? nil : sleepHR.values.reduce(0, +) / Double(sleepHR.count)
        var banked: [MetricPoint] = []
        var day = bankFrom
        while day <= newestDay {
            defer { day = HealthspanWindow.dayKey(day, plus: 1) }
            guard worn.contains(day), let restingHR = sleepHR[day] ?? fallbackRHR,
                  let dayStart = midnightForDayKey(day, offsetSec: tzOffset),
                  !(try await store.hrSamples(deviceId: strapId, from: dayStart, to: dayStart + 86_399, limit: 1)).isEmpty
            else { continue }
            var zone13 = 0.0, zone45 = 0.0
            for w in recentWorkouts where w.end > dayStart && w.start < dayStart + 86_400 {
                let s = max(w.start, dayStart), e = min(w.end, dayStart + 86_400)
                let hr = try await store.hrSamples(deviceId: strapId, from: s, to: e - 1, limit: Int.max)
                guard let m = HealthspanEngine.zoneMinutes(hr: hr, restingHR: restingHR, maxHR: maxHR) else { continue }
                zone13 += m.zone13; zone45 += m.zone45
            }
            banked += [MetricPoint(day: day, key: healthspanZone13Key, value: zone13),
                       MetricPoint(day: day, key: healthspanZone45Key, value: zone45)]
        }

        // (2) Weekly rows. First run: every week back to the first computed day; afterwards: the pass window.
        let currentSaturday = saturdayKey(onOrBefore: newestDay)
        var firstSaturday = saturdayKey(onOrBefore: oldestDay)
        if !hasHistory,
           let firstDay = try await store.dailyMetrics(deviceId: computedId,
                                                       from: HealthspanWindow.dayKey(newestDay, plus: -365),
                                                       to: newestDay).map(\.day).min() {
            firstSaturday = min(firstSaturday, saturdayKey(onOrBefore: firstDay))
        }
        let readFrom = HealthspanWindow.dayKey(firstSaturday, plus: -(HealthspanWindow.ageWindowDays - 1))
        // Banked first, so the weeks below read today's zone minutes.
        if !banked.isEmpty { _ = try await store.upsertMetricSeries(banked, deviceId: computedId) }
        let days = try await healthspanDays(store: store, strapId: strapId, computedId: computedId,
                                            from: readFrom, to: newestDay, tzOffset: tzOffset, steps: steps)
        let appleVO2 = try await store.metricSeries(deviceId: MetricResolver.appleHealthSource, key: "vo2max",
                                                    from: readFrom, to: newestDay).map { (day: $0.day, value: $0.value) }
        var weekly: [MetricPoint] = []
        var saturday = firstSaturday
        while saturday <= currentSaturday {
            defer { saturday = HealthspanWindow.dayKey(saturday, plus: 7) }
            let end = min(HealthspanWindow.dayKey(saturday, plus: 6), newestDay)
            let vo2 = HealthspanVO2.resolve(manual: manualVO2max, appleHealth: appleVO2, endingOn: end)
            let vo2Floor = HealthspanVO2.enduranceFloor(longSessions, endingOn: end)
            let fat = HealthspanVO2.latestBodyFat(bodyFat, endingOn: end)
            guard let w = HealthspanWindow.weekly(
                days: days, endingOn: end, age: Double(age), sex: sex, vo2max: vo2?.window,
                recentVO2max: vo2?.recent, leanMassPct: fat.map { 100 - $0.value })
            else {
                // Only the current week says why, for the screen that has no age to show.
                if saturday == currentSaturday {
                    let gap = HealthspanWindow.gap(days: days, endingOn: end)
                    weekly += [MetricPoint(day: saturday, key: healthspanGapNightsKey, value: Double(gap.nights)),
                               MetricPoint(day: saturday, key: healthspanGapMissingKey, value: gap.missingMask)]
                }
                continue
            }
            weekly.append(MetricPoint(day: saturday, key: healthspanAgeKey, value: w.result.healthspanAge))
            if let vo2 {
                weekly.append(MetricPoint(day: saturday, key: healthspanVO2SourceKey, value: Double(vo2.source.rawValue)))
                weekly.append(MetricPoint(day: saturday, key: healthspanCountKey(.vo2max), value: Double(vo2.readings)))
                if let d = HealthspanBasis.dayNumber(vo2.latestDay) {
                    weekly.append(MetricPoint(day: saturday, key: healthspanVO2DayKey, value: d))
                }
            }
            if let d = fat.flatMap({ HealthspanBasis.dayNumber($0.day) }) {
                weekly.append(MetricPoint(day: saturday, key: healthspanBodyFatDayKey, value: d))
            }
            if let vo2Floor { weekly.append(MetricPoint(day: saturday, key: healthspanVO2FloorKey, value: vo2Floor)) }
            for (c, n) in w.counts {
                weekly.append(MetricPoint(day: saturday, key: healthspanCountKey(c), value: Double(n)))
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
        // Every read above succeeded, so replacing the whole span cannot erase weeks on a failed read; a week
        // that lost a measure (or its age) keeps no stale row.
        _ = try await store.replaceMetricSeriesWindow(weekly, deviceId: computedId, keys: healthspanWeeklyKeys,
                                                      from: firstSaturday, to: currentSaturday)
    }

    /// Per-day healthspan values from NOOP's own computed data: daily rows (sleep, steps), the sleep-mean HR,
    /// banked zone minutes, timing consistency from sleep sessions, and strength minutes from workouts. A day is
    /// one the band covered (it has a computed daily row); its steps come from `steps` (the app's step resolver)
    /// where that has the day, so a strap without a step counter still has them.
    public nonisolated static func healthspanDays(store: WhoopStore, strapId: String, computedId: String,
                                           from: String, to: String, tzOffset: Int,
                                           steps: [String: Double] = [:]) async throws -> [HealthspanDay] {
        guard let fromTs = midnightForDayKey(from, offsetSec: tzOffset),
              let toTs = midnightForDayKey(to, offsetSec: tzOffset).map({ $0 + 86_400 }) else { return [] }
        func series(_ key: String) async throws -> [String: Double] {
            Dictionary(try await store.metricSeries(deviceId: computedId, key: key, from: from, to: to)
                .map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        var byDay: [String: HealthspanDay] = [:]
        func edit(_ day: String, _ f: (inout HealthspanDay) -> Void) {
            var d = byDay[day] ?? HealthspanDay(day: day); f(&d); byDay[day] = d
        }
        for d in try await store.dailyMetrics(deviceId: computedId, from: from, to: to) {
            edit(d.day) {
                $0.sleepHours = d.totalSleepMin.flatMap { $0 > 0 ? $0 / 60 : nil }
                $0.steps = (steps[d.day] ?? d.steps.map(Double.init)).flatMap { $0 > 0 ? $0 : nil }
            }
        }
        for (day, v) in try await series("rhr_primary_session") { edit(day) { $0.sleepMeanHR = v } }
        for (day, v) in try await series(healthspanZone13Key) { edit(day) { $0.zone13Min = v } }
        for (day, v) in try await series(healthspanZone45Key) { edit(day) { $0.zone45Min = v } }

        // Consistency for each night: the longest session ending that day is the main sleep; naps count too.
        let sessions = try await store.sleepSessions(deviceId: computedId, from: fromTs - 5 * 86_400,
                                                     to: toTs, limit: 100_000)
            .map { SleepTimingConsistency.Interval(start: $0.effectiveStartTs, end: $0.endTs) }
        let consistency = SleepTimingConsistency.scoresByDay(sessions: sessions, from: fromTs, to: toTs) {
            AnalyticsEngine.dayString($0, offsetSec: tzOffset)
        }
        for (day, c) in consistency { edit(day) { $0.sleepConsistencyPct = c } }

        // Strength minutes and sessions by local start day; overlapping rows from several sources count once.
        var strengthByDay: [String: Double] = [:]
        var sessionsByDay: [String: Int] = [:]
        let workouts = try await healthspanWorkouts(store: store, strapId: strapId, computedId: computedId,
                                                    from: fromTs, to: toTs, strengthOnly: true)
        for w in workouts {
            let day = AnalyticsEngine.dayString(w.start, offsetSec: tzOffset)
            strengthByDay[day, default: 0] += Double(w.end - w.start) / 60
            sessionsByDay[day, default: 0] += 1
        }
        for day in byDay.keys {
            edit(day) { $0.strengthMin = strengthByDay[day] ?? 0; $0.strengthSessions = sessionsByDay[day] ?? 0 }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Weekly rows for `--demo-seed`: habits improving week by week, run through the real engine so the card
    /// renders under the demo exactly as it would on a wearer's data. Each week's pace compares its window
    /// with a slightly better last 30 days, as an improving wearer's would. `--demo-ageless-older` seeds the
    /// other story instead: habits slipping, an age above the actual one and a pace above the calendar.
    public nonisolated static func healthspanDemoRows(saturdays: [String],
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
                                   value: Double(HealthspanVO2.Source.appleHealth.rawValue)))
            let covered = min(182, 30 + 7 * i)
            out.append(MetricPoint(day: day, key: healthspanCoveredDaysKey, value: Double(covered)))
            // The basis lines: nearly every night worn, a few step-less days, a month of zone minutes at most, one
            // strength session a week, a walk or run every five days and a body-fat reading a month back.
            let counts: [HealthspanEngine.Component: Int] = [
                .sleepDuration: covered - covered / 20, .sleepConsistency: covered - covered / 12,
                .dailySteps: covered - covered / 10, .restingHR: covered - covered / 20,
                .zone13: min(covered, 35), .zone45: min(covered, 35), .strength: covered / 7, .vo2max: covered / 5]
            for (c, n) in counts { out.append(MetricPoint(day: day, key: healthspanCountKey(c), value: Double(n))) }
            for (key, back) in [(healthspanVO2DayKey, 3), (healthspanBodyFatDayKey, 30)] {
                if let d = HealthspanBasis.dayNumber(HealthspanWindow.dayKey(day, plus: -back)) {
                    out.append(MetricPoint(day: day, key: key, value: d))
                }
            }
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
    public nonisolated static func healthspanWorkouts(store: WhoopStore, strapId: String, computedId: String,
                                               from: Int, to: Int,
                                               strengthOnly: Bool = false) async throws -> [(start: Int, end: Int)] {
        var rows: [WorkoutRow] = []
        for source in Set([strapId, computedId, "apple-health", "hevy"]) {
            rows += try await store.workouts(deviceId: source, from: from, to: to, limit: 100_000)
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
