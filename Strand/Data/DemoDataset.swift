import Foundation
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
        _ = try await store.upsertSleepSessions(plan.sleeps, deviceId: deviceId)
        _ = try await store.upsertMetricSeries(plan.series, deviceId: deviceId)
        _ = try await store.upsertMetricSeries(plan.computedSeries, deviceId: computedDeviceId)
        _ = try await store.upsertAppleDaily(plan.apple, deviceId: appleId)
        if !plan.whoopWorkouts.isEmpty { _ = try await store.upsertWorkouts(plan.whoopWorkouts, deviceId: deviceId) }
        if !plan.appleWorkouts.isEmpty { _ = try await store.upsertWorkouts(plan.appleWorkouts, deviceId: appleId) }
    }

    /// Everything the seed writes, built without touching a store, so a test can read the figures.
    public struct Plan {
        public let daily: [DailyMetric]
        public let sleeps: [CachedSleepSession]
        public let series: [MetricPoint]
        public let computedSeries: [MetricPoint]
        public let apple: [AppleDaily]
        public let whoopWorkouts: [WorkoutRow]
        public let appleWorkouts: [WorkoutRow]
    }

    public static func build(today: Date = Date()) -> Plan {
        var rng = Generator(seed: 0xC0FFEE)
        var daily: [DailyMetric] = [], sleeps: [CachedSleepSession] = []
        var series: [MetricPoint] = [], computed: [MetricPoint] = []
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
            let skinTemp = clamp(rng.gauss(0, 0.25), -1.2, 1.4)
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
                                     skinTempDevC: round2(skinTemp), respRateBpm: round1(resp)))

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
            series.append(MetricPoint(day: day, key: "bodyFatPct",
                                      value: round1(clamp(18 - fitness * 0.2 + rng.gauss(0, 0.4), 10, 24))))
            let need = clamp(totalSleep + rng.gauss(25, 20), 420, 560)
            series.append(MetricPoint(day: day, key: "sleep_performance",
                                      value: round1(min(totalSleep / need * 100, 100))))
            series.append(MetricPoint(day: day, key: "sleep_consistency",
                                      value: round1(clamp(rng.gauss(80, 8), 40, 100))))
            series.append(MetricPoint(day: day, key: "sleep_need_min", value: round1(need)))
            series.append(MetricPoint(day: day, key: "sleep_debt_min", value: round1(max(need - totalSleep, 0))))

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

        return Plan(daily: daily, sleeps: sleeps, series: series, computedSeries: computed, apple: apple,
                    whoopWorkouts: whoopWorkouts, appleWorkouts: appleWorkouts)
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
