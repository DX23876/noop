#if DEBUG
import Foundation
import StrandImport
import WhoopStore

// MARK: - DEBUG-only demo seed (Apple parity with Android's DemoSeeder)
// Seeds a comprehensive, self-contained synthetic dataset so a DEBUG build can walk every screen —
// Today, Sleep, Trends, Workouts, Health, Stress, Insights, Explore — with no strap and no import.
// This is the Apple twin of `android/.../data/DemoSeeder.kt` (same RNG seed, same physiology, same
// 120-day window) and exists so we can render iOS + macOS for verification and marketing screenshots.
//
// Gating: the whole file is `#if DEBUG`, so it is stripped from every Release build (the shipped
// app). At runtime it only seeds when launched with `--demo-seed` AND the store has no daily rows,
// so it runs at most once and never clobbers real data. Everything here is SYNTHETIC and
// DETERMINISTIC (fixed seed) — nothing is real biometric data. Values are physiologically plausible
// and internally correlated (recovery ↔ HRV ↔ resting-HR ↔ sleep; strain ↔ workouts; a slow fitness
// drift) so the charts, trends and insights all read like a real account.
enum AppleDemoSeeder {

    static let whoop = "my-whoop"
    static let apple = "apple-health"
    private static let DAYS = 120
    /// Effort rescale factor: the old 0–21 strain scale → the new 0–100 Effort scale.
    private static let STRAIN_SCALE = 100.0 / 21.0

    /// Conditioning as an elite strength athlete actually does it — weighted toward the low-intensity
    /// work that supports recovery without competing with the lifting for it. No marathon volume: a
    /// 21 km run in the same week as a 210 kg squat block is a demo nobody at this level recognises.
    /// The repeats are the weighting; `Cycling` and `Walking` come up most, `Running` rarely.
    private static let SPORTS = [
        "Cycling", "Cycling", "Cycling", "Walking", "Walking", "Walking",
        "Rowing", "Rowing", "HIIT", "Running", "Yoga",
    ]
    /// Typical conditioning distance per sport, in metres, and how much it varies. Kept per sport
    /// because one shared 6.5 km draw produced a 6.5 km "walk" and a 6.5 km "row" — the row roughly a
    /// world-class 2 k eight times over, and the kind of number that makes every derived pace absurd.
    private static func conditioningDistanceM(_ sport: String, _ rng: inout SplitMix64) -> Double? {
        switch sport {
        case "Cycling": return round1(gauss(&rng, 22_000, 6_000).atLeast(6_000))
        case "Walking": return round1(gauss(&rng, 4_200, 1_200).atLeast(1_500))
        case "Rowing":  return round1(gauss(&rng, 5_000, 1_500).atLeast(2_000))
        case "Running": return round1(gauss(&rng, 6_500, 1_800).atLeast(2_500))
        default:        return nil
        }
    }

    /// True when the process was launched asking for the demo seed (Xcode scheme arg or `simctl
    /// launch … --demo-seed`).
    static var requested: Bool { CommandLine.arguments.contains("--demo-seed") }

    /// Seed only if requested AND the store is empty. Safe to call on every launch.
    static func seedIfRequested(into store: WhoopStore) async {
        guard requested else { return }
        seedDemoDeviceIfNeeded(into: store)
        await seedDemoGoalIfNeeded()
        let existing = (try? await store.dailyMetrics(deviceId: whoop, from: "0000-00-00", to: "9999-99-99")) ?? []
        guard existing.isEmpty else { return }
        do { try await seed(into: store) }
        catch { NSLog("AppleDemoSeeder: seed failed — \(error)") }
    }

    /// DEBUG/demo-only: a weight goal with runway behind it, so the goal screens have something to
    /// render under `--demo-seed`.
    ///
    /// This exists because the goal UI was, until now, unverifiable anywhere but a real device: the
    /// seeder filled workouts, sleep and weight but never a goal, so every goal screen sat on its
    /// empty state and a visual check was impossible. Dates are relative, so the route always has
    /// waypoints in the past AND ahead, and the course reading has enough history to fit a rate.
    /// No-op once any goal exists — it never touches a real one.
    @MainActor
    private static func seedDemoGoalIfNeeded() async {
        // Momentum's step countdown needs a target the user chose; there is deliberately no default, so
        // without this the flagship "steps to go" message could never appear in a demo capture at all.
        // Only ever set when unset, so a real value on a dev device is never overwritten.
        if UserDefaults.standard.integer(forKey: "momentum.stepGoal") == 0 {
            UserDefaults.standard.set(10_000, forKey: "momentum.stepGoal")
        }

        let store = CoachGoalStore.shared
        guard store.goals.isEmpty else { return }
        let now = Date()
        // Two KINDS on purpose, not two goals: the Today tile draws a different strip per kind
        // (a route under a weight goal, the week's days under a consistency one), and with a single
        // goal that difference — the whole point of the tile — cannot be seen.
        store.goals = [
            CoachGoal(kind: .weight,
                      title: "Leichter werden",
                      baseline: 100,
                      target: 70,
                      targetDate: now.addingTimeInterval(120 * 86_400),
                      createdAt: now.addingTimeInterval(-60 * 86_400)),
            CoachGoal(kind: .consistency,
                      title: "Dreimal pro Woche",
                      baseline: 1,
                      target: 3,
                      targetDate: now.addingTimeInterval(90 * 86_400),
                      createdAt: now.addingTimeInterval(-40 * 86_400))
        ]
    }

    /// DEBUG/demo-only: so the Devices screen renders with content under `--demo-seed`, pair a second
    /// (non-WHOOP) strap alongside the seeded WHOOP. If the registry only holds the WHOOP, add a
    /// `.paired` "Polar H10" — the screenshot then shows the WHOOP (Active) plus a paired strap. Status
    /// `.paired` (not `.active`) keeps the WHOOP active, so the SourceCoordinator stays dormant and the
    /// existing WHOOP path is untouched. No-op once a second device already exists.
    private static func seedDemoDeviceIfNeeded(into store: WhoopStore) {
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        guard let devices = try? registry.all() else { return }
        guard devices.allSatisfy({ $0.id == whoop }) else { return }  // only the seeded WHOOP present
        let now = Int(Date().timeIntervalSince1970)
        let polar = PairedDevice(
            id: "polar-h10-demo", brand: "Polar", model: "H10", nickname: nil,
            sourceKind: .liveBLE, capabilities: [.hr, .hrv], status: .paired,
            addedAt: now - 86_400, lastSeenAt: now - 3_600)
        try? registry.add(polar)
    }

    private static func seed(into store: WhoopStore) async throws {
        var rng = SplitMix64(seed: 0xC0FFEE)
        let cal = Calendar.current
        let zone = TimeZone.current
        let startDay = cal.date(byAdding: .day, value: -(DAYS - 1), to: cal.startOfDay(for: Date()))!

        try? await store.upsertDevice(id: whoop, mac: nil, name: "WHOOP (demo)")

        var daily: [DailyMetric] = []
        var sleeps: [CachedSleepSession] = []
        var series: [MetricPoint] = []
        /// Long-format series stored under the APPLE source, for the metrics whose readers ask for
        /// `source: "apple-health"` (body weight above all).
        var appleSeries: [MetricPoint] = []
        var appleRows: [AppleDaily] = []
        var workouts: [WorkoutRow] = []
        var journal: [JournalEntry] = []

        // An elite strength athlete's frame: ~98 kg at 181 cm, in a slow accumulation phase rather
        // than a cut. The seeded body has to agree with the loads below — a 210 kg squat on a 79 kg
        // frame is not a demo, it is a bug report waiting to be filed.
        var weight = 97.5
        var fitness = 0.0  // slow upward drift: HRV rises, resting-HR falls, VO2max climbs

        let isoFmt = DateFormatter()
        isoFmt.locale = Locale(identifier: "en_US_POSIX")
        isoFmt.timeZone = zone
        isoFmt.dateFormat = "yyyy-MM-dd"

        for i in 0..<DAYS {
            let date = cal.date(byAdding: .day, value: i, to: startDay)!
            let day = isoFmt.string(from: date)
            let weekday = cal.component(.weekday, from: date)  // 1=Sun … 7=Sat
            let weekend = (weekday == 1 || weekday == 7)
            fitness += 0.012

            // --- training load for the day ---
            let trains = weekend ? rng.nextDouble() < 0.40 : rng.nextDouble() < 0.62
            let nWorkouts = !trains ? 0 : (rng.nextDouble() < 0.22 ? 2 : 1)

            // --- sleep architecture ---
            let totalSleep = gauss(&rng, 430.0, 35.0).clamped(300.0, 540.0)
            let efficiency = gauss(&rng, 89.0, 4.0).clamped(72.0, 98.0)
            let deep = (totalSleep * gauss(&rng, 0.20, 0.03)).clamped(35.0, 130.0)
            let rem = (totalSleep * gauss(&rng, 0.23, 0.03)).clamped(45.0, 150.0)
            let light = (totalSleep - deep - rem).atLeast(60.0)
            let disturbances = Int(gauss(&rng, 6.0, 3.0).clamped(0.0, 18.0))

            // --- autonomic markers ---
            let hrv = (gauss(&rng, 78.0 + fitness * 1.5, 12.0) + (weekend ? 6 : 0) - Double(nWorkouts) * 4)
                .clamped(28.0, 150.0)
            let rhr = Int((gauss(&rng, 56.0 - fitness * 0.4, 3.0) + Double(nWorkouts) * 1.2).clamped(42.0, 70.0))
            let spo2 = gauss(&rng, 96.5, 0.8).clamped(93.0, 100.0)
            let skinTempDev = gauss(&rng, 0.0, 0.25).clamped(-1.2, 1.4)
            let resp = gauss(&rng, 14.6, 0.9).clamped(11.0, 19.0)

            // --- recovery: a function of HRV, sleep quality and resting-HR ---
            let recovery = (
                40 + (hrv - 70) * 0.55 + (efficiency - 85) * 0.6 + (totalSleep - 420) * 0.03 -
                    (Double(rhr) - 55) * 1.4 - Double(disturbances) * 0.8 + gauss(&rng, 0.0, 5.0)
            ).clamped(8.0, 99.0)

            // --- strain (Effort): workout-driven, rescaled 0–21 → 0–100 ---
            let strain = (
                (nWorkouts == 0 ? gauss(&rng, 7.5, 1.8)
                 : gauss(&rng, 13.5, 2.4) + Double(nWorkouts - 1) * 2.5) * STRAIN_SCALE
            ).clamped(3.0 * STRAIN_SCALE, 100.0)

            daily.append(DailyMetric(
                day: day, totalSleepMin: round1(totalSleep), efficiency: round1(efficiency),
                deepMin: round1(deep), remMin: round1(rem), lightMin: round1(light),
                disturbances: disturbances, restingHr: rhr, avgHrv: round1(hrv),
                recovery: round1(recovery), strain: round1(strain), exerciseCount: nWorkouts,
                spo2Pct: round1(spo2), skinTempDevC: round2(skinTempDev), respRateBpm: round1(resp)))

            // --- sleep session: previous night ~23:10 → wake, with a REAL stage timeline so the
            //     hypnogram renders the computed segment path (not just the proportional bar). ---
            let onsetBase = cal.date(byAdding: .day, value: -1, to: date)!
            let onsetDay = cal.startOfDay(for: onsetBase)
            let onset = Int(onsetDay.timeIntervalSince1970) + 23 * 3600 + 10 * 60 + rng.nextInt(-1800, 1800)
            let inBedSec = Int((totalSleep + totalSleep * (100 - efficiency) / 100) * 60)
            sleeps.append(CachedSleepSession(
                startTs: onset, endTs: onset + inBedSec,
                efficiency: round1(efficiency), restingHr: rhr, avgHrv: round1(hrv),
                stagesJSON: segmentsJSON(onset: onset, deep: deep, rem: rem, light: light,
                                         awakeMin: Double(disturbances) * 1.6)))

            // --- long-format extras (body composition) under my-whoop ---
            weight += gauss(&rng, -0.02, 0.18)
            series.append(MetricPoint(day: day, key: "weightKg", value: round2(weight)))
            // The SAME weight under the key everything actually reads. "weightKg" is the AppleDaily
            // COLUMN name, not a series key: `series(key: "weight", source: "apple-health")` is what
            // Today's weight tile, Apple Health, Compare and the goal engine all ask for, so under
            // `--demo-seed` the weight series was empty for every one of them — which is why the
            // seeded weight GOAL could never be measured and the Today tile said it had no reading.
            appleSeries.append(MetricPoint(day: day, key: "weight", value: round2(weight)))
            series.append(MetricPoint(day: day, key: "bodyFatPct",
                value: round1((18.0 - fitness * 0.2 + gauss(&rng, 0.0, 0.4)).clamped(10.0, 24.0))))
            // Export-verbatim sleep figures (same metricSeries keys the importers write), so the demo
            // Sleep tiles exercise the prefer-imported path.
            let demoNeedMin = (totalSleep + gauss(&rng, 25.0, 20.0)).clamped(420.0, 560.0)
            series.append(MetricPoint(day: day, key: "sleep_performance",
                value: round1(min(totalSleep / demoNeedMin * 100.0, 100.0))))
            series.append(MetricPoint(day: day, key: "sleep_consistency",
                value: round1(gauss(&rng, 80.0, 8.0).clamped(40.0, 100.0))))
            series.append(MetricPoint(day: day, key: "sleep_need_min", value: round1(demoNeedMin)))
            series.append(MetricPoint(day: day, key: "sleep_debt_min",
                value: round1((demoNeedMin - totalSleep).atLeast(0.0))))

            // --- Apple Health daily aggregate ---
            let steps = Int(gauss(&rng, 8500.0, 2600.0).clamped(1200.0, 19000.0))
            appleRows.append(AppleDaily(
                day: day, steps: steps,
                activeKcal: round1((Double(steps) * 0.045 + Double(nWorkouts) * 220).clamped(120.0, 1400.0)),
                basalKcal: round1(gauss(&rng, 1650.0, 40.0)),
                vo2max: round1((46 + fitness * 0.3 + gauss(&rng, 0.0, 0.5)).clamped(38.0, 56.0)),
                avgHr: Int(gauss(&rng, 72.0, 5.0)), maxHr: Int(gauss(&rng, 150.0, 12.0)),
                walkingHr: Int(gauss(&rng, 108.0, 6.0)), weightKg: round2(weight)))

            // --- workouts on training days ---
            for k in 0..<nWorkouts {
                let sport = SPORTS[rng.nextInt(0, SPORTS.count)]
                // Conditioning sessions, not endurance training: 25–60 minutes, sitting alongside six
                // lifting days rather than competing with them.
                let durSec = gauss(&rng, 38.0, 11.0).clamped(20.0, 65.0) * 60
                let hour = weekend ? 9 : 18
                let dayStart = cal.startOfDay(for: date)
                let start = Int(dayStart.timeIntervalSince1970) + hour * 3600 + rng.nextInt(0, 50) * 60 + k * 3600
                // Mostly zone 2. A lifter's conditioning is deliberately easy — the hard work is under
                // a bar — so the average heart rate sits well below a runner's tempo session.
                let avg = Int(gauss(&rng, 124.0, 11.0))
                let src = rng.nextDouble() < 0.7 ? whoop : apple
                let zonesJSON: String? = src == whoop ? {
                    // Weighted toward zones 1–2, which is what "conditioning that supports lifting"
                    // looks like in a zone split.
                    let z = [gauss(&rng, 24.0, 6.0), gauss(&rng, 44.0, 9.0), gauss(&rng, 20.0, 7.0),
                             gauss(&rng, 8.0, 4.0), gauss(&rng, 3.0, 2.0)].map { $0.clamped(0.0, 100.0) }
                    return "{\"zone1\":\(round1(z[0])),\"zone2\":\(round1(z[1])),\"zone3\":\(round1(z[2])),\"zone4\":\(round1(z[3])),\"zone5\":\(round1(z[4]))}"
                }() : nil
                workouts.append(WorkoutRow(
                    startTs: start, endTs: start + Int(durSec), sport: sport, source: src,
                    durationS: round1(durSec),
                    energyKcal: round1((durSec / 60) * gauss(&rng, 11.5, 2.0)),
                    avgHr: avg, maxHr: avg + Int(gauss(&rng, 22.0, 6.0)),
                    strain: round1((strain * gauss(&rng, 0.6, 0.1)).clamped(4.0 * STRAIN_SCALE, 100.0)),
                    distanceM: conditioningDistanceM(sport, &rng),
                    zonesJSON: zonesJSON, notes: nil, steps: nil))
            }

            // --- journal answers for the recent 40 days (real catalog strings → Insights light up) ---
            if i >= DAYS - 40 {
                journal.append(JournalEntry(day: day, question: "Did you drink any alcohol?", answeredYes: rng.nextDouble() < 0.18, notes: nil))
                journal.append(JournalEntry(day: day, question: "Did you have caffeine late in the day?", answeredYes: rng.nextDouble() < 0.30, notes: nil))
                journal.append(JournalEntry(day: day, question: "Did you feel stressed?", answeredYes: rng.nextDouble() < 0.28, notes: nil))
            }
        }

        // --- weekly Fitness Age + VO2max estimate (the engine stamps these on each week's
        //     Saturday; mirror that here so the Fitness Age screen renders under --demo-seed).
        //     Trends from ~42 → ~36 (younger) as the demo "fitness" drift climbs; vo2max ~44 → ~50.
        var fitnessAge = 42.0
        var vo2 = 44.0
        var vitality = 55.0      // weekly Vitality (0–100) trending up as the demo habits improve
        var bodyAgeDemo = 40.0   // Body Age (years) trending down (younger)
        for i in 0..<DAYS {
            let date = cal.date(byAdding: .day, value: i, to: startDay)!
            guard cal.component(.weekday, from: date) == 7 else { continue }  // 7 = Saturday
            let day = isoFmt.string(from: date)
            series.append(MetricPoint(day: day, key: "fitness_age",
                value: round1((fitnessAge + gauss(&rng, 0.0, 0.3)).clamped(34.0, 44.0))))
            series.append(MetricPoint(day: day, key: "vo2max_est",
                value: round1((vo2 + gauss(&rng, 0.0, 0.4)).clamped(42.0, 52.0))))
            series.append(MetricPoint(day: day, key: "vitality",
                value: round1((vitality + gauss(&rng, 0.0, 1.0)).clamped(40.0, 80.0))))
            series.append(MetricPoint(day: day, key: "body_age",
                value: round1((bodyAgeDemo + gauss(&rng, 0.0, 0.3)).clamped(30.0, 45.0))))
            fitnessAge -= 0.75  // ~6 yr younger across the 8 seeded Saturdays
            vo2 += 0.75
            vitality += 2.0
            bodyAgeDemo -= 0.6
        }

        _ = try await store.upsertDailyMetrics(daily, deviceId: whoop)
        _ = try await store.upsertSleepSessions(sleeps, deviceId: whoop)
        _ = try await store.upsertMetricSeries(series, deviceId: whoop)
        _ = try await store.upsertMetricSeries(appleSeries, deviceId: apple)
        _ = try await store.upsertAppleDaily(appleRows, deviceId: apple)
        if !workouts.isEmpty { _ = try await store.upsertWorkouts(workouts, deviceId: whoop) }
        if !journal.isEmpty { _ = try await store.upsertJournal(journal, deviceId: whoop) }
        let lifts = try await seedStrength(into: store, startDay: startDay, cal: cal, isoFmt: isoFmt)
        let body = try await seedBody(into: store, startDay: startDay, cal: cal, isoFmt: isoFmt)
        NSLog("AppleDemoSeeder: seeded \(daily.count) days, \(workouts.count) workouts, \(lifts) lifting sessions, \(body) body readings.")
    }

    // MARK: - The body & energy lane
    //
    // The same gap the strength lane above was added to close, one screen over: without seeded tape
    // measurements, body-fat readings and logged intake, the Body page shows nothing but its empty
    // state and the Energy page can never reach its balance tier — so neither the charts, the
    // same-site progress comparison, the Navy estimate nor the three-way corridor could be looked at without a
    // real account and months of logging.
    //
    // Its own RNG, for the reason `seedStrength` documents: drawing from the shared one would shift
    // every later draw and silently change the whole demo dataset.
    //
    // The programme is a slow recomposition — waist down, body fat down, arms and thighs slightly up
    // against a nearly flat weight. That is the case the comparison chart exists for ("am I losing fat
    // or water?"), and a flat series would leave every trend rendering its "not enough to say" state.
    private static func seedBody(into store: WhoopStore, startDay: Date,
                                 cal: Calendar, isoFmt: DateFormatter) async throws -> Int {
        var rng = SplitMix64(seed: 0xB0D_1E5)
        var rows: [LabMarkerRow] = []
        var intake: [MetricPoint] = []

        // Height is a single standing reading; everything else moves.
        if let date = cal.date(byAdding: .day, value: 0, to: startDay) {
            rows.append(marker("height", 181, on: date, isoFmt: isoFmt, source: "manual"))
        }

        // Tape measurements every 7 days, which is the cadence the reminder suggests and the spread the
        // method actually supports.
        for week in stride(from: 0, through: DAYS - 1, by: 7) {
            guard let date = cal.date(byAdding: .day, value: week, to: startDay) else { continue }
            let t = Double(week) / Double(max(1, DAYS - 1))   // 0 → 1 across the window
            let sites: [(String, Double)] = [
                ("neck", 43.5 + 0.3 * t + gauss(&rng, 0, 0.15)),
                ("shoulders", 133.0 + 2.2 * t + gauss(&rng, 0, 0.4)),
                ("chest", 118.0 + 1.8 * t + gauss(&rng, 0, 0.35)),
                // A gaining phase, so the waist creeps UP a little while everything trained goes up
                // more. That is the honest shape of an accumulation block, and it gives the
                // development card both directions to report instead of a one-way story.
                ("waist", 86.0 + 1.2 * t + gauss(&rng, 0, 0.4)),
                ("abdomen", 89.0 + 1.4 * t + gauss(&rng, 0, 0.45)),
                ("hips", 107.0 + 0.8 * t + gauss(&rng, 0, 0.3)),
                // Keep both measurement sites believable. The UI treats each as its own timeline; it
                // never frames the current left and right values as the point of the feature.
                ("biceps_l", 43.4 + 1.1 * t + gauss(&rng, 0, 0.2)),
                ("biceps_r", 44.3 + 1.2 * t + gauss(&rng, 0, 0.2)),
                ("forearm_l", 33.8 + 0.4 * t + gauss(&rng, 0, 0.15)),
                ("forearm_r", 34.4 + 0.4 * t + gauss(&rng, 0, 0.15)),
                ("thigh_l", 68.5 + 1.6 * t + gauss(&rng, 0, 0.3)),
                ("thigh_r", 69.0 + 1.6 * t + gauss(&rng, 0, 0.3)),
                ("calf_l", 43.2 + 0.5 * t + gauss(&rng, 0, 0.2)),
                ("calf_r", 43.5 + 0.5 * t + gauss(&rng, 0, 0.2)),
            ]
            for (key, value) in sites {
                rows.append(marker(key, round1(value), on: date, isoFmt: isoFmt, source: "manual"))
            }
        }

        // Body fat from two DIFFERENT methods on purpose. A DEXA scan at each end and a monthly caliper
        // reading between them is exactly the case the chart must keep on separate series — averaging a
        // scan and a pinch into one line would report a number nobody measured.
        for (offset, value, source) in [(2, 19.4, "dexa"), (30, 18.6, "caliper"),
                                        (60, 17.9, "caliper"), (90, 17.2, "caliper"),
                                        (DAYS - 3, 16.4, "dexa")] {
            guard let date = cal.date(byAdding: .day, value: offset, to: startDay) else { continue }
            rows.append(marker("body_fat", value, on: date, isoFmt: isoFmt, source: source))
        }

        // Intake for the last 40 days only, so the Energy page shows a balance tier that has genuinely
        // just become answerable rather than one that has always been there.
        for offset in stride(from: max(0, DAYS - 40), through: DAYS - 1, by: 1) {
            guard let date = cal.date(byAdding: .day, value: offset, to: startDay) else { continue }
            // A mild deficit with ordinary day-to-day scatter and the occasional big day.
            let base = 2_250.0 + gauss(&rng, 0, 180)
            let feast = (rng.next() % 9 == 0) ? 600.0 : 0
            intake.append(MetricPoint(day: isoFmt.string(from: date),
                                      key: "calories_in", value: (base + feast).rounded()))
        }

        if !rows.isEmpty { _ = try await store.upsertLabMarkers(rows) }
        if !intake.isEmpty {
            _ = try await store.upsertMetricSeries(intake, deviceId: EnergyPlanStore.manualIntakeSource)
        }
        return rows.count + intake.count
    }

    /// One dated body reading, in the shape the Body page reads.
    private static func marker(_ key: String, _ value: Double, on date: Date,
                               isoFmt: DateFormatter, source: String) -> LabMarkerRow {
        let day = isoFmt.string(from: date)
        return LabMarkerRow(
            id: "demo-\(key)-\(day)", deviceId: apple, markerKey: key,
            category: "bodyMeasurement", day: day,
            takenAt: Int(date.timeIntervalSince1970) + 27_000,   // 07:30, before the day's food and water
            value: value, valueText: nil,
            unit: MarkerCatalog.definition(for: key)?.canonicalUnit ?? "cm",
            source: source, note: nil, referenceText: nil)
    }

    // MARK: - The strength lane
    //
    // Without this the Strength screen was unverifiable anywhere but a real account with Hevy connected:
    // the seeder filled workouts, sleep and weight but never a lifting session, so every strength
    // surface — the muscle map, the per-exercise trend, records, balance, the session breakdown — sat on
    // its empty state and a visual check was impossible. The same gap the goal seed above was added to
    // close, one lane over.
    //
    // A SEPARATE RNG, seeded independently. Drawing from the shared one would shift every subsequent
    // draw and silently change the whole demo dataset — the sleep, the workouts, the journal — which is
    // exactly what a fixed seed exists to prevent.
    //
    // The programme is a deliberate push / pull / legs split on Mon-Wed-Fri, with weights that climb
    // slowly. That is not decoration: a flat programme would leave the trend line, the records and the
    // balance card each rendering the "not enough to say" state they are designed to fall back to, and
    // none of them would be verifiable.
    private static func seedStrength(into store: WhoopStore, startDay: Date,
                                     cal: Calendar, isoFmt: DateFormatter) async throws -> Int {
        var rng = SplitMix64(seed: 0x5E7_5E7)
        let templates = strengthTemplates
        _ = try await store.upsertHevyExerciseTemplates(templates)

        /// templateId → the working weight this block starts at. Bodyweight and timed movements carry
        /// nil, so the seeded data exercises the "no weight logged" paths too.
        // Elite working weights. A competitive raw lifter at ~98 kg: a 145 kg bench, a 210 kg squat,
        // a 180 kg Romanian deadlift. The weighted dip and pull-up carry real added load, which is
        // also what makes the bodyweight-plus-load path worth exercising in the demo.
        let openingWeight: [String: Double?] = [
            "demo-bench": 145.0, "demo-ohp": 85.0, "demo-pushdown": 65.0, "demo-dip": 55.0,
            "demo-pullup": nil, "demo-row": 130.0, "demo-curl": 35.0,
            "demo-squat": 210.0, "demo-rdl": 180.0, "demo-legpress": 420.0, "demo-plank": nil,
        ]
        // Push / Pull / Legs run TWICE a week — six training days, which is the frequency and weekly
        // volume an advanced lifter actually accumulates. The second rotation is the lighter one, so
        // the week has a heavy and a volume day per movement rather than six identical sessions.
        let split: [Int: (title: String, plan: [(String, Int)])] = [
            2: ("Push (heavy)", [("demo-bench", 5), ("demo-ohp", 4), ("demo-dip", 4), ("demo-pushdown", 3)]),
            3: ("Pull (heavy)", [("demo-row", 5), ("demo-pullup", 4), ("demo-curl", 3), ("demo-plank", 2)]),
            4: ("Legs (heavy)", [("demo-squat", 5), ("demo-rdl", 4), ("demo-legpress", 4), ("demo-plank", 2)]),
            6: ("Push (volume)", [("demo-bench", 4), ("demo-ohp", 4), ("demo-dip", 3), ("demo-pushdown", 4)]),
            7: ("Pull (volume)", [("demo-row", 4), ("demo-pullup", 4), ("demo-curl", 4), ("demo-plank", 2)]),
            1: ("Legs (volume)", [("demo-squat", 4), ("demo-rdl", 4), ("demo-legpress", 4), ("demo-plank", 2)]),
        ]
        /// Days that run the lighter rotation, at a fraction of the day's top weight.
        let volumeDays: Set<Int> = [6, 7, 1]

        var sessions: [HevyWorkout] = []
        var mirrored: [WorkoutRow] = []

        for i in 0..<DAYS {
            let date = cal.date(byAdding: .day, value: i, to: startDay)!
            let weekday = cal.component(.weekday, from: date)   // 1=Sun … 7=Sat
            guard let day = split[weekday] else { continue }
            // One missed session in twenty. An athlete at this level trains through most weeks, and the
            // weekly bands still get a range from the heavy/volume alternation rather than from gaps.
            guard rng.nextDouble() > 0.05 else { continue }

            let weeks = Double(i) / 7.0
            let start = Int(cal.startOfDay(for: date).timeIntervalSince1970) + 18 * 3600 + rng.nextInt(0, 40) * 60
            var exercises: [HevyExercise] = []

            for (index, entry) in day.plan.enumerated() {
                let (templateId, workingSets) = entry
                let template = templates.first { $0.id == templateId }
                var sets: [HevySet] = []
                var setIndex = 0

                // Progressive overload at an ADVANCED rate: ~0.12 % a week. A novice adds 2.5 kg to the
                // bar every session; someone benching 145 kg fights for a couple of kilos a month, and
                // seeding a beginner's slope onto elite numbers would draw a curve nobody at this level
                // recognises. The volume rotation runs at 82 % of the day's top weight.
                let dayFactor = volumeDays.contains(weekday) ? 0.82 : 1.0
                let base = (openingWeight[templateId] ?? nil)
                    .map { $0 * (1 + 0.0012 * weeks) * dayFactor }

                // A warmup on the first movement of the day — the one the detail view dims and every
                // figure excludes.
                if index == 0, let base {
                    sets.append(HevySet(index: setIndex, type: .warmup,
                                        weightKg: round1(base * 0.55), reps: 8,
                                        distanceM: nil, durationS: nil, rpe: nil, customMetric: nil))
                    setIndex += 1
                }

                for setNumber in 0..<workingSets {
                    // RPE on roughly two sets in three: the map's rated-share caption only says
                    // something when the coverage is partial.
                    let rpe: Double? = rng.nextDouble() < 0.66
                        ? (7.5 + Double(setNumber) * 0.4 + (rng.nextDouble() < 0.35 ? 0.5 : 0)).clamped(6.5, 10.0)
                        : nil
                    if templateId == "demo-plank" {
                        sets.append(HevySet(index: setIndex, type: .normal, weightKg: nil, reps: nil,
                                            distanceM: nil, durationS: 45 + Double(rng.nextInt(0, 30)),
                                            rpe: rpe, customMetric: nil))
                    } else if let base {
                        // Heavy days sit at 3–5, volume days at 8–12 — the two rep worlds an advanced
                        // programme actually alternates between, and what gives the rep-band records
                        // (1–3, 4–6, 7–12) something to fill on both ends.
                        let reps = volumeDays.contains(weekday) ? 8 + rng.nextInt(0, 5)
                                                                : 3 + rng.nextInt(0, 3)
                        let weight = round1(base * (1 - Double(setNumber) * 0.025) + gauss(&rng, 0, 1.2))
                        sets.append(HevySet(index: setIndex, type: setNumber == workingSets - 1 && rng.nextDouble() < 0.15 ? .failure : .normal,
                                            weightKg: weight, reps: reps,
                                            distanceM: nil, durationS: nil, rpe: rpe, customMetric: nil))
                    } else {
                        // Bodyweight reps — no weight logged, which is exactly the case the bodyweight
                        // volume figure exists for.
                        sets.append(HevySet(index: setIndex, type: .normal, weightKg: nil,
                                            reps: 6 + rng.nextInt(0, 5),
                                            distanceM: nil, durationS: nil, rpe: rpe, customMetric: nil))
                    }
                    setIndex += 1
                }

                exercises.append(HevyExercise(
                    index: index, title: template?.title ?? templateId, templateId: templateId,
                    // The last two movements of each day are supersetted, so the detail view's grouping
                    // has something to group.
                    supersetId: index >= day.plan.count - 2 ? 1 : nil,
                    notes: nil, sets: sets))
            }

            // 75–105 minutes. Five heavy compound sets with real rest do not fit in an hour.
            let duration = 4500 + rng.nextInt(0, 1800)
            sessions.append(HevyWorkout(
                id: "demo-\(isoFmt.string(from: date))", title: day.title, routineId: nil,
                notes: nil, startTs: start, endTs: start + duration,
                updatedAtTs: start, createdAtTs: start, exercises: exercises,
                source: .hevyAPI))
            // The mirror the sync coordinator would write, so the session also appears in the Workouts
            // list and the Strength screen can pair it with what the strap recorded.
            mirrored.append(WorkoutRow(
                startTs: start, endTs: start + duration, sport: "Strength Training", source: "hevy",
                durationS: Double(duration), energyKcal: nil, avgHr: nil, maxHr: nil,
                strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil))
        }

        guard !sessions.isEmpty else { return 0 }
        _ = try await store.upsertStrengthWorkouts(sessions)
        _ = try await store.upsertWorkouts(mirrored, deviceId: "hevy")
        // Whole-session RPE is a separate observation from the set ratings above. Seed most, not all,
        // so the Training Load screen demonstrates both a real sRPE×duration series and honest missing
        // coverage. These rows use the same sidecar the detail screen writes.
        let sessionRatings = sessions.enumerated().compactMap { index, workout -> LabMarkerRow? in
            guard !index.isMultiple(of: 5) else { return nil }
            let rpe = workout.title.contains("heavy") ? 8.5 : 7.5
            return LabMarkerRow(
                id: "session-rpe-\(workout.startTs)", deviceId: Repository.sessionRPEDeviceId,
                markerKey: Repository.sessionRPEMarkerKey, category: Repository.sessionRPECategory,
                day: isoFmt.string(from: Date(timeIntervalSince1970: TimeInterval(workout.startTs))),
                takenAt: workout.startTs, value: rpe, valueText: nil, unit: "RPE",
                source: Repository.sessionRPESource, note: workout.title, referenceText: nil)
        }
        _ = try await store.upsertLabMarkers(sessionRatings)
        return sessions.count
    }

    /// The demo exercise catalogue.
    ///
    /// Deliberately spans every movement SHAPE the strength lane handles — weight-and-reps, bodyweight
    /// reps, weighted bodyweight, and a timed hold — because each takes a different path through the
    /// e1RM estimate and the bodyweight pricing, and a catalogue of barbell lifts alone would leave
    /// three of those four paths unrendered.
    private static var strengthTemplates: [HevyExerciseTemplate] {
        func t(_ id: String, _ title: String, _ type: String, _ primary: HevyMuscleGroup,
               _ secondary: [HevyMuscleGroup], _ equipment: HevyEquipment) -> HevyExerciseTemplate {
            HevyExerciseTemplate(id: id, title: title, type: type, primaryMuscleGroup: primary,
                                 secondaryMuscleGroups: secondary, equipment: equipment,
                                 isCustom: false)
        }
        return [
            t("demo-bench", "Bench Press (Barbell)", "weight_reps", .chest, [.triceps, .shoulders], .barbell),
            t("demo-ohp", "Overhead Press (Barbell)", "weight_reps", .shoulders, [.triceps], .barbell),
            t("demo-pushdown", "Triceps Pushdown", "weight_reps", .triceps, [], .machine),
            t("demo-dip", "Dip (Weighted)", "weighted_bodyweight", .chest, [.triceps], .none),
            t("demo-pullup", "Pull Up", "bodyweight_reps", .lats, [.biceps], .none),
            t("demo-row", "Bent Over Row (Barbell)", "weight_reps", .upperBack, [.biceps, .lats], .barbell),
            t("demo-curl", "Biceps Curl (Dumbbell)", "weight_reps", .biceps, [.forearms], .dumbbell),
            t("demo-squat", "Back Squat (Barbell)", "weight_reps", .quadriceps, [.glutes, .lowerBack], .barbell),
            t("demo-rdl", "Romanian Deadlift", "weight_reps", .hamstrings, [.glutes, .lowerBack], .barbell),
            t("demo-legpress", "Leg Press", "weight_reps", .quadriceps, [.glutes], .machine),
            t("demo-plank", "Plank", "duration", .abdominals, [], .none),
        ]
    }

    // MARK: - helpers

    private static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
    private static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    /// Box–Muller normal sample, matching DemoSeeder.gauss exactly.
    private static func gauss(_ rng: inout SplitMix64, _ mean: Double, _ sd: Double) -> Double {
        let u1 = rng.nextDouble().clamped(1e-9, 1.0)
        let u2 = rng.nextDouble()
        return mean + sd * (Foundation.sqrt(-2.0 * Foundation.log(u1)) * Foundation.cos(2.0 * Double.pi * u2))
    }

    /// A plausible light→deep→rem cycle as the COMPUTED segment array
    /// [{"start":epoch,"end":epoch,"stage":"light"|"deep"|"rem"|"wake"}] that SleepView.decodeSegments
    /// reads, laid end-to-end from `onset`.
    private static func segmentsJSON(onset: Int, deep: Double, rem: Double, light: Double, awakeMin: Double) -> String {
        var t = onset
        var parts: [String] = []
        func seg(_ stage: String, _ minutes: Double) {
            let secs = Int(minutes * 60)
            guard secs > 0 else { return }
            parts.append("{\"start\":\(t),\"end\":\(t + secs),\"stage\":\"\(stage)\"}")
            t += secs
        }
        seg("light", light * 0.35); seg("deep", deep * 0.6); seg("light", light * 0.30)
        seg("rem", rem * 0.6); seg("deep", deep * 0.4); seg("light", light * 0.35)
        seg("rem", rem * 0.4); seg("wake", awakeMin)
        return "[" + parts.joined(separator: ",") + "]"
    }
}

/// Deterministic SplitMix64 PRNG — gives a fixed, reproducible demo dataset across runs (the Apple
/// counterpart of Kotlin's `Random(0xC0FFEE)`). Not for any security use.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func nextDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)  // 2^53
    }

    /// Uniform Int in [lower, upper).
    mutating func nextInt(_ lower: Int, _ upper: Int) -> Int {
        guard upper > lower else { return lower }
        let span = UInt64(upper - lower)
        return lower + Int(next() % span)
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
    func atLeast(_ lo: Double) -> Double { Swift.max(self, lo) }
}
#endif
