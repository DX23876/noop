import Foundation
import StrandTraining
import WhoopStore

/// A complete, self-contained demo account, written once into the store so every screen and every tile has
/// something to show without a strap and without an import.
///
/// Why it lives here (owner, 2026-11-18): Android has had a seeder like this since its Demo flavour began,
/// the iPhone never did, so checking a tile on both phones meant comparing a filled card against an empty
/// one. That is not a comparison of design, it is a comparison of data, and it hid a real fault for an
/// evening: a weight tile on Android was not ugly, it was EMPTY. One dataset, described once, seeded by
/// both, removes that whole class of confusion.
///
/// Deterministic by construction: a fixed seed and a generator written out here rather than the platform's,
/// so the same day's figures come out identical on an iPhone and on an emulator, and identical again
/// tomorrow. Synthetic throughout; nothing here is anybody's biometric data. The values are physiologically
/// plausible and correlated the way the real ones are (recovery follows HRV, sleep and resting heart rate;
/// effort follows the workouts; fitness drifts slowly upward), so trends, ranges and insights read like an
/// account rather than like noise.
///
/// The caller gates it to a debug build. It refuses to run when the device already holds days, so it can
/// never overwrite a real account.
///
/// Analysis migration required: no. Seeded rows are ordinary stored inputs; the usual analysis reads them.
public enum DemoDataset {

    public static let deviceId = "my-whoop"
    /// Where the engine writes its derived weekly scores, and so where the demo must write them too, or the
    /// fitness age, VO₂max, vitality and body age tiles read empty while everything around them is full.
    public static let computedDeviceId = "my-whoop-noop"
    static let appleId = "apple-health"
    /// 120 days: long enough for a thirty-day curve to have a shape, a ninety-day change to exist, and the
    /// weekly derived scores to have eight stamps.
    public static let days = 120

    static let sports = ["Running", "Cycling", "Strength Training", "Walking", "Rowing", "Swimming", "Yoga"]
    /// Effort is stored on the 0 to 100 axis; the generator thinks in the old 0 to 21 and rescales.
    static let strainScale = 100.0 / 21.0

    /// Seed the store unless it already holds days for the demo device.
    ///
    /// - Returns: true when it wrote, false when it found an account already there and left it alone.
    @discardableResult
    public static func seedIfEmpty(store: WhoopStore, today: Date = Date()) async throws -> Bool {
        let last = try await store.dailyMetrics(deviceId: deviceId, from: "0000-01-01", to: "9999-12-31")
        guard last.isEmpty else { return false }
        try await seed(store: store, today: today)
        return true
    }

    static func seed(store: WhoopStore, today: Date) async throws {
        let plan = build(today: today)
        _ = try await store.upsertDailyMetrics(plan.daily, deviceId: deviceId)
        _ = try await store.upsertBodyWeights(plan.weights)
        _ = try await store.upsertSleepSessions(plan.sleeps, deviceId: deviceId)
        _ = try await store.upsertMetricSeries(plan.series, deviceId: deviceId)
        _ = try await store.upsertMetricSeries(plan.computedSeries, deviceId: computedDeviceId)
        _ = try await store.upsertMetricSeries(plan.hydration, deviceId: "hydration")
        _ = try await store.upsertAppleDaily(plan.apple, deviceId: appleId)
        if !plan.whoopWorkouts.isEmpty { _ = try await store.upsertWorkouts(plan.whoopWorkouts, deviceId: deviceId) }
        if !plan.appleWorkouts.isEmpty { _ = try await store.upsertWorkouts(plan.appleWorkouts, deviceId: appleId) }
        if !plan.cycle.isEmpty { _ = try await store.upsertMetricSeries(plan.cycle, deviceId: CycleTrackingStore.sourceId) }
        // The plan last: its week references its routines, and `upsertTrainingPlan` is the call that
        // writes them in that order.
        //
        // The test is NOT whether a plan exists. Every fresh store already carries one, written by the
        // migration that gave routines a plan to belong to: no title, no week, active. So "is there a
        // plan" is false on a brand-new store and the demo plan was silently skipped (2026-11-19). The
        // honest test is whether anybody has set one up, which is a title or a week; the untouched plan
        // from the migration has neither, and it is taken away with the same breath, or Training would
        // show the demo's plan beside a nameless empty one.
        let existing = (try? await store.trainingPrograms()) ?? []
        if existing.allSatisfy({ $0.title.isEmpty && $0.schedule.isEmpty }) {
            let p = program(today: today)
            try await store.upsertTrainingPlan(p.program, routines: p.routines)
            for blank in existing where blank.id != p.program.id {
                try? await store.deleteTrainingProgram(id: blank.id)
            }
        }
    }

    /// Everything the seed writes, built without touching a store, so a test can read the figures.
    public struct Plan {
        public let daily: [DailyMetric]
        /// The weigh-ins themselves, in the store the weight tile and the body page actually read. Without
        /// them the tile said "No data yet" on a phone whose every other tile was full, which is precisely
        /// the kind of hole this dataset exists to close.
        public let weights: [BodyWeightRow]
        public let sleeps: [CachedSleepSession]
        public let series: [MetricPoint]
        public let computedSeries: [MetricPoint]
        /// The day's water, where the hydration tile and its page read it (`HydrationRead`).
        public let hydration: [MetricPoint]
        public let apple: [AppleDaily]
        public let whoopWorkouts: [WorkoutRow]
        public let appleWorkouts: [WorkoutRow]
        /// What the wearer noted about their cycle, under its own isolated source
        /// (`CycleTrackingStore`): period starts, the flow of the first days, and a few symptoms and
        /// moods. Awareness only, as the cycle page is; none of it reaches a score.
        ///
        /// Seeded whatever the demo person's cycle looks like, because the card appears to anybody who has
        /// logged a start (`!starts.isEmpty`), and a page nobody can reach in the demo is a page nobody
        /// checks. The physiology is NOT shaped to a cycle here: that is what `--demo-cycle` does on the
        /// Apple side, where the whole dataset is rebuilt around one.
        public let cycle: [MetricPoint]
    }

    /// The demo's training plan with its two routines, so Training has a week and Today has a session to
    /// name. Written through `upsertTrainingPlan`, which writes the routines before the week that
    /// references them.
    ///
    /// The exercises are the shipped catalogue's own ids. `DemoDatasetTests` holds every one of them
    /// against that catalogue, so a catalogue change cannot leave the demo plan pointing at nothing — the
    /// plan would still write, and its days would simply be blank.
    /// The demo's long-term goals, so the goals page, the Today goal card and the coach's goal reads have
    /// something true to stand on.
    ///
    /// Three, all measurable from what this dataset already wrote, and all template-free kinds: a weight
    /// goal whose baseline IS the dataset's last weigh-in, four sessions a week, and seven and a half
    /// hours of sleep. A goal whose baseline disagreed with the history behind it would make every
    /// progress reading in the app wrong at once, which is the opposite of what a demo account is for.
    static func goals(today: Date = Date()) -> [CoachGoal] {
        let weight = build(today: today).weights.last?.weightKg ?? 79.5
        let created = today.addingTimeInterval(-42 * 86_400)
        return [
            CoachGoal(id: UUID(uuidString: "D0000000-0000-4000-B000-000000000001")!, kind: .weight,
                      title: "Down to \(Int((weight - 4).rounded())) kg", baseline: weight,
                      target: (weight - 4).rounded(), targetDate: today.addingTimeInterval(84 * 86_400),
                      motivation: "Lighter on the hills.", createdAt: created),
            CoachGoal(id: UUID(uuidString: "D0000000-0000-4000-B000-000000000002")!, kind: .consistency,
                      title: "Train four times a week", baseline: 3, target: 4,
                      targetDate: today.addingTimeInterval(56 * 86_400),
                      motivation: "Keep the habit through the winter.", createdAt: created),
            CoachGoal(id: UUID(uuidString: "D0000000-0000-4000-B000-000000000003")!, kind: .sleep,
                      title: "Seven and a half hours a night", baseline: 7.1, target: 7.5,
                      targetDate: today.addingTimeInterval(70 * 86_400), createdAt: created),
        ]
    }

    /// Writes those goals through the one goal store both platforms read, unless the wearer has goals of
    /// their own. Apple calls it on the demo launch; the Android core calls it inside the host that holds
    /// the persisted goal image, which is the only place on that phone where this store is the real one.
    @MainActor
    @discardableResult
    public static func seedGoalsIfEmpty(today: Date = Date()) -> Bool {
        guard CoachGoalStore.shared.goals.isEmpty else { return false }
        CoachGoalStore.shared.goals = goals(today: today)
        return true
    }

    public static func program(today: Date = Date()) -> (program: TrainingProgram, routines: [TrainingRoutine]) {
        func sets(_ count: Int, _ low: Int, _ high: Int, kg: Double) -> [RoutineSetPlan] {
            (0..<count).map { _ in RoutineSetPlan(targetWeightKg: kg, repsMin: low, repsMax: high) }
        }
        let push = TrainingRoutine(
            id: UUID(uuidString: "D0000000-0000-4000-A000-000000000001")!, title: "Push",
            exercises: [
                RoutineExercise(exerciseId: "exdb:0025", sets: sets(4, 5, 8, kg: 72.5), restSeconds: 180),
                RoutineExercise(exerciseId: "exdb:0091", sets: sets(3, 8, 10, kg: 42.5), restSeconds: 150),
                RoutineExercise(exerciseId: "exdb:0334", sets: sets(3, 12, 15, kg: 12), restSeconds: 90),
                RoutineExercise(exerciseId: "exdb:0201", sets: sets(3, 10, 12, kg: 30), restSeconds: 90),
            ])
        let pull = TrainingRoutine(
            id: UUID(uuidString: "D0000000-0000-4000-A000-000000000002")!, title: "Pull and legs",
            exercises: [
                RoutineExercise(exerciseId: "exdb:0043", sets: sets(4, 5, 8, kg: 95), restSeconds: 210),
                RoutineExercise(exerciseId: "exdb:0085", sets: sets(3, 6, 8, kg: 85), restSeconds: 180),
                RoutineExercise(exerciseId: "exdb:0027", sets: sets(3, 8, 10, kg: 60), restSeconds: 150),
                RoutineExercise(exerciseId: "exdb:0017", sets: sets(3, 6, 10, kg: 0), restSeconds: 120),
            ])
        let program = TrainingProgram(
            id: UUID(uuidString: "D0000000-0000-4000-A000-00000000000F")!, title: "Upper and lower, twice a week",
            kind: .strength, notes: "The demo account's plan.",
            schedule: [.monday: [push.id], .tuesday: [pull.id], .thursday: [push.id], .friday: [pull.id]],
            isActive: true, createdAt: Int(today.timeIntervalSince1970) - 60 * 86_400,
            updatedAt: Int(today.timeIntervalSince1970) - 7 * 86_400)
        return (program, [push, pull])
    }

    /// The demo wearer's own facts, which live in the profile rather than in the store.
    ///
    /// Without them the demo account has a history and no body, and every screen that needs one reads
    /// empty while everything around it is full: the calorie goal (its formula burn needs a weight, a
    /// height, years and a cohort), the heart-rate zones, the body composition, AgeLess. That is how the
    /// Nutrition tile came to say "– left today" over seven logged days, on both phones at once
    /// (2026-11-19). Synthetic throughout; nobody's figures.
    ///
    /// The weight is NOT a figure of its own: it is the last weigh-in this dataset wrote. A profile weight
    /// that disagreed with the scale would be precisely the fault this dataset exists to expose.
    public struct Person: Equatable, Sendable, Codable {
        public let ageYears: Int
        /// "male" or "female", as the profile stores it.
        public let sex: String
        public let heightCm: Double
        public let waistCm: Double
        public let weightKg: Double
    }

    public static func person(today: Date = Date()) -> Person {
        Person(ageYears: 34, sex: "male", heightCm: 182, waistCm: 86,
               weightKg: build(today: today).weights.last?.weightKg ?? 79.5)
    }

    public static func build(today: Date = Date()) -> Plan {
        var rng = Generator(seed: 0xC0FFEE)
        var daily: [DailyMetric] = [], sleeps: [CachedSleepSession] = [], weights: [BodyWeightRow] = []
        var cycle: [MetricPoint] = []
        var series: [MetricPoint] = [], computed: [MetricPoint] = [], hydration: [MetricPoint] = []
        var apple: [AppleDaily] = [], whoopWorkouts: [WorkoutRow] = [], appleWorkouts: [WorkoutRow] = []

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.startOfDay(for: today).addingTimeInterval(-Double(days - 1) * 86_400)

        var weight = 79.5
        var fitness = 0.0

        for i in 0..<days {
            let date = start.addingTimeInterval(Double(i) * 86_400)
            let day = dayKey(date)
            let weekday = calendar.component(.weekday, from: date)   // 1 = Sunday
            let weekend = weekday == 1 || weekday == 7
            fitness += 0.012

            let trains = rng.next() < (weekend ? 0.40 : 0.62)
            let workoutCount = !trains ? 0 : (rng.next() < 0.22 ? 2 : 1)

            let totalSleep = clamp(rng.gauss(430, 35), 300, 540)
            let efficiency = clamp(rng.gauss(89, 4), 72, 98)
            let deep = clamp(totalSleep * rng.gauss(0.20, 0.03), 35, 130)
            let rem = clamp(totalSleep * rng.gauss(0.23, 0.03), 45, 150)
            let light = max(totalSleep - deep - rem, 60)
            let disturbances = Int(clamp(rng.gauss(6, 3), 0, 18))

            let hrv = clamp(rng.gauss(78 + fitness * 1.5, 12) + (weekend ? 6 : 0) - Double(workoutCount) * 4, 28, 150)
            let rhr = Int(clamp(rng.gauss(56 - fitness * 0.4, 3) + Double(workoutCount) * 1.2, 42, 70))
            let spo2 = clamp(rng.gauss(96.5, 0.8), 93, 100)
            // Both skin-temperature numbers, from one draw: the deviation the live pipeline computes and
            // the wrist temperature it is a deviation FROM. A demo with the deviation alone made every
            // tile say "+0.1 Δ°C", which is the thing the real app only falls back to (#1844).
            let skinTemp = clamp(rng.gauss(0, 0.25), -1.2, 1.4)
            let skinAbs = round2(33.6 + skinTemp)
            let resp = clamp(rng.gauss(14.6, 0.9), 11, 19)

            let recovery = clamp(40 + (hrv - 70) * 0.55 + (efficiency - 85) * 0.6 + (totalSleep - 420) * 0.03
                                 - Double(rhr - 55) * 1.4 - Double(disturbances) * 0.8 + rng.gauss(0, 5), 8, 99)
            let strain = clamp((workoutCount == 0 ? rng.gauss(7.5, 1.8)
                                : rng.gauss(13.5, 2.4) + Double(workoutCount - 1) * 2.5) * strainScale,
                               3 * strainScale, 100)

            daily.append(DailyMetric(day: day, totalSleepMin: round1(totalSleep), efficiency: round1(efficiency),
                                     deepMin: round1(deep), remMin: round1(rem), lightMin: round1(light),
                                     disturbances: disturbances, restingHr: rhr, avgHrv: round1(hrv),
                                     recovery: round1(recovery), strain: round1(strain),
                                     exerciseCount: workoutCount, spo2Pct: round1(spo2),
                                     skinTempDevC: round2(skinTemp), respRateBpm: round1(resp),
                                     skinTempC: skinAbs))

            // The night before this day, about 23:10, drifting half an hour either way.
            let bedtime = calendar.date(bySettingHour: 23, minute: 10, second: 0,
                                        of: date.addingTimeInterval(-86_400)) ?? date
            let onset = Int(bedtime.timeIntervalSince1970) + Int(rng.next() * 3600 - 1800)
            let inBed = Int((totalSleep + totalSleep * (100 - efficiency) / 100) * 60)
            sleeps.append(CachedSleepSession(startTs: onset, endTs: onset + inBed, efficiency: round1(efficiency),
                                             restingHr: rhr, avgHrv: round1(hrv),
                                             stagesJSON: stagesJSON(deep: deep, rem: rem, light: light,
                                                                    awake: disturbances)))

            weight += rng.gauss(-0.02, 0.18)
            series.append(MetricPoint(day: day, key: "weightKg", value: round2(weight)))
            // Not every day: a wearer steps on the scales now and then, and "last weighed two days ago" is
            // one of the facts the wider tile is supposed to be able to say.
            if i % 3 != 1 {
                let at = Int(date.timeIntervalSince1970) + 7 * 3600
                weights.append(BodyWeightRow(id: "demo-\(day)", deviceId: "noop-weight", day: day, takenAt: at,
                                             weightKg: round2(weight), source: "noop-weight"))
            }
            series.append(MetricPoint(day: day, key: "bodyFatPct",
                                      value: round1(clamp(18 - fitness * 0.2 + rng.gauss(0, 0.4), 10, 24))))
            let need = clamp(totalSleep + rng.gauss(25, 20), 420, 560)
            series.append(MetricPoint(day: day, key: "sleep_performance",
                                      value: round1(min(totalSleep / need * 100, 100))))
            series.append(MetricPoint(day: day, key: "sleep_consistency",
                                      value: round1(clamp(rng.gauss(80, 8), 40, 100))))
            series.append(MetricPoint(day: day, key: "sleep_need_min", value: round1(need)))
            series.append(MetricPoint(day: day, key: "sleep_debt_min", value: round1(max(need - totalSleep, 0))))

            // Water, in millilitres: most days near the goal, some well short, because a tile that always
            // reads "done" says nothing about the day it is on.
            hydration.append(MetricPoint(day: day, key: "hydration",
                                         value: (clamp(rng.gauss(2300, 700), 400, 4200) / 50).rounded() * 50))

            let steps = Int(clamp(rng.gauss(8500, 2600), 1200, 19000))
            apple.append(AppleDaily(day: day, steps: steps,
                                    activeKcal: round1(clamp(Double(steps) * 0.045 + Double(workoutCount) * 220,
                                                             120, 1400)),
                                    basalKcal: round1(rng.gauss(1650, 40)),
                                    vo2max: round1(clamp(46 + fitness * 0.3 + rng.gauss(0, 0.5), 38, 56)),
                                    avgHr: Int(rng.gauss(72, 5)), maxHr: Int(rng.gauss(150, 12)),
                                    walkingHr: Int(rng.gauss(108, 6)), weightKg: round2(weight)))

            for k in 0..<workoutCount {
                let sport = sports[Int(rng.next() * Double(sports.count)) % sports.count]
                let duration = clamp(rng.gauss(48, 16), 18, 110) * 60
                let hour = weekend ? 9 : 18
                let begin = (calendar.date(bySettingHour: hour, minute: Int(rng.next() * 50), second: 0, of: date)
                             ?? date).timeIntervalSince1970 + Double(k) * 3600
                let avg = Int(rng.gauss(138, 12))
                let fromStrap = rng.next() < 0.7
                let distanceSports: Set<String> = ["Running", "Cycling", "Walking", "Swimming", "Rowing"]
                let zones = (0..<5).map { _ in clamp(rng.gauss(20, 8), 0, 100) }
                let row = WorkoutRow(startTs: Int(begin), endTs: Int(begin + duration), sport: sport,
                                     source: fromStrap ? deviceId : appleId,
                                     durationS: round1(duration),
                                     energyKcal: round1(duration / 60 * rng.gauss(9, 2)),
                                     avgHr: avg, maxHr: avg + Int(rng.gauss(22, 6)),
                                     strain: round1(clamp(strain * rng.gauss(0.6, 0.1), 4 * strainScale, 100)),
                                     distanceM: distanceSports.contains(sport)
                                        ? round1(max(rng.gauss(6500, 2500), 500)) : nil,
                                     // Only strap rows carry zones, as real imports do: an Apple row never
                                     // has them, and the demo should exercise both shapes.
                                     zonesJSON: fromStrap ? zonesJSON(zones) : nil, notes: nil, steps: nil)
                if fromStrap { whoopWorkouts.append(row) } else { appleWorkouts.append(row) }
            }
        }

        // The weekly derived scores, stamped on Saturdays where the engine stamps them. Fitness age and body
        // age fall, VO₂max and vitality climb, so a year's tile has a direction rather than a flat line.
        var fitnessAge = 42.0, vo2 = 44.0, vitality = 55.0, bodyAge = 40.0
        for i in 0..<days {
            let date = start.addingTimeInterval(Double(i) * 86_400)
            guard calendar.component(.weekday, from: date) == 7 else { continue }
            let day = dayKey(date)
            computed.append(MetricPoint(day: day, key: "fitness_age",
                                        value: round1(clamp(fitnessAge + rng.gauss(0, 0.3), 34, 44))))
            computed.append(MetricPoint(day: day, key: "vo2max_est",
                                        value: round1(clamp(vo2 + rng.gauss(0, 0.4), 42, 52))))
            computed.append(MetricPoint(day: day, key: "vitality",
                                        value: round1(clamp(vitality + rng.gauss(0, 1), 40, 80))))
            computed.append(MetricPoint(day: day, key: "body_age",
                                        value: round1(clamp(bodyAge + rng.gauss(0, 0.3), 30, 45))))
            fitnessAge -= 0.75; vo2 += 0.75; vitality += 2; bodyAge -= 0.6
        }

        // Day stress exactly as a real import derives it, so the stress tile and its day read like an
        // imported account rather than like a second method.
        let rhrAll = daily.compactMap { $0.restingHr.map(Double.init) }
        let hrvAll = daily.compactMap(\.avgHrv)
        let (rMean, rSd) = meanStd(rhrAll), (hMean, hSd) = meanStd(hrvAll)
        if rSd > 0, hSd > 0 {
            for d in daily {
                guard let rhr = d.restingHr.map(Double.init), let hrv = d.avgHrv else { continue }
                let z = 0.6 * ((rhr - rMean) / rSd) - 0.6 * ((hrv - hMean) / hSd)
                series.append(MetricPoint(day: d.day, key: "stress", value: round2(clamp(1.5 + z, 0, 3))))
            }
        }

        // The cycle log: a 28-day cycle with today on day 12, so the page has a start behind it and a next
        // one ahead of it. Flow on the first four days of every cycle, and symptoms and moods on the most
        // recent one only, which is how a log actually reads: the near past is noted, the far past is not.
        for i in 0..<days {
            let date = start.addingTimeInterval(Double(i) * 86_400)
            let cycleDay = ((11 + i - (days - 1)) % 28 + 28) % 28 + 1
            let day = dayKey(date)
            if cycleDay == 1 {
                cycle.append(MetricPoint(day: day, key: CycleTrackingStore.periodStartKey,
                                         value: CycleTrackingStore.loggedValue))
            }
            if cycleDay <= 4 {
                cycle.append(MetricPoint(day: day, key: CycleLog.flowKey, value: Double([3, 4, 3, 2][cycleDay - 1])))
            }
            guard i > days - 29 else { continue }
            if cycleDay <= 3 {
                for id in ["cramps", "tired"] {
                    cycle.append(MetricPoint(day: day, key: CycleLog.symptomPrefix + id, value: 1))
                }
                cycle.append(MetricPoint(day: day, key: CycleLog.moodPrefix + "low", value: 1))
            } else if cycleDay == 13 {
                cycle.append(MetricPoint(day: day, key: CycleLog.ovulationTestKey, value: 1))
                cycle.append(MetricPoint(day: day, key: CycleLog.moodPrefix + "happy", value: 1))
            } else if cycleDay >= 25 {
                cycle.append(MetricPoint(day: day, key: CycleLog.symptomPrefix + "bloating", value: 1))
                cycle.append(MetricPoint(day: day, key: CycleLog.moodPrefix + "irritable", value: 1))
            }
        }

        return Plan(daily: daily, weights: weights, sleeps: sleeps, series: series, computedSeries: computed,
                    hydration: hydration, apple: apple, whoopWorkouts: whoopWorkouts, appleWorkouts: appleWorkouts,
                    cycle: cycle)
    }

    // MARK: - Shaping

    static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(max(value, low), high) }
    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
    static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func meanStd(_ values: [Double]) -> (Double, Double) {
        guard values.count > 1 else { return (values.first ?? 0, 0) }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return (mean, variance.squareRoot())
    }

    static func stagesJSON(deep: Double, rem: Double, light: Double, awake: Int) -> String {
        """
        {"deep":\(round1(deep)),"rem":\(round1(rem)),"light":\(round1(light)),"awake":\(awake)}
        """
    }

    static func zonesJSON(_ z: [Double]) -> String {
        """
        {"zone1":\(round1(z[0])),"zone2":\(round1(z[1])),"zone3":\(round1(z[2])),"zone4":\(round1(z[3])),"zone5":\(round1(z[4]))}
        """
    }

    /// A small xorshift, written out rather than taken from the platform.
    ///
    /// `SystemRandomNumberGenerator` is not reproducible and Kotlin's `Random` is a different algorithm, so
    /// either would give the two phones different demo accounts and make a side-by-side comparison
    /// meaningless again. This one is the same arithmetic everywhere, today and next month.
    struct Generator {
        private var state: UInt64

        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

        /// The next value in [0, 1).
        mutating func next() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state >> 11) / Double(1 << 53)
        }

        /// Box–Muller, as the Kotlin seeder draws it.
        mutating func gauss(_ mean: Double, _ sd: Double) -> Double {
            let u1 = max(next(), 1e-9), u2 = next()
            return mean + sd * (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * Double.pi * u2)
        }
    }
}
