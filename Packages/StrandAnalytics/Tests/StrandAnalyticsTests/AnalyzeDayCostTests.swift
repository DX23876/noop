import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// What one day of scoring costs, and how that cost grows with the data.
///
/// On a real 2.9 GB library the device reports 242 seconds for a SINGLE day:
///
///     day=2026-09-06 total=321.73s rawRead=26.33s analysisPipeline=242.63s other=52.76s
///                    hr=172694 rr=234783 grav=163019
///
/// `analysisPipeline` is exactly one `AnalyticsEngine.analyzeDay` call. 242 s for ~570 000 samples is
/// 0.42 ms per sample - on the order of a million cycles to fold one measurement. No fold, no
/// smoothing and no stager costs that; a number of that shape comes from walking something whole once
/// per sample.
///
/// `AnalyticsEngine` is pure and `StrandAnalytics` builds on its own, so this reproduces the cost away
/// from the phone. Running the same measurement at four densities answers the question that decides
/// everything after it: a constant factor (about x2 per doubling) or an algorithm (about x4).
///
/// ## The fixture has to produce a NIGHT
///
/// The first attempt did not, and it looked wonderful for it: 0.035 s at full device scale, growing
/// perfectly linearly. It was measuring almost nothing - `sleepSessions` came back empty, so staging,
/// the HRV windows and the recovery scorer never ran. Gravity carried movement through the night, so
/// the stager never found a still stretch to call sleep. Even a few thousandths of jitter was enough.
///
/// Every measurement below therefore asserts a night was detected. A benchmark that silently times an
/// early exit is worse than none, because it produces a number people believe.
final class AnalyzeDayCostTests: XCTestCase {

    private static let dayKey = "2026-09-06"
    private static let windowHours = 54      // StreamReadCap: 30 h back, 24 h forward

    private static var dayMidnight: Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return Int(f.date(from: dayKey)!.timeIntervalSince1970)
    }

    private static let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")

    /// A 54-hour window holding one still, low-HR night, sampled at `hz` per stream.
    ///
    /// The night's shape is taken from the fixture the existing sleep tests already rely on: perfectly
    /// still gravity, a flat 50 bpm, and R-R oscillating by +/-5 ms (a completely flat R-R stream is
    /// rejected as ectopic and yields no HRV). Around it sits a waking day with movement, so the
    /// stager has to FIND the night rather than being handed a window that is nothing else.
    private static func window(hz: Double)
        -> (hr: [HRSample], rr: [RRInterval], grav: [GravitySample], steps: [StepSample]) {
        let nightEnd = dayMidnight + 6 * 3_600
        let nightStart = nightEnd - 7 * 3_600
        let from = nightEnd - 30 * 3_600
        let to = from + windowHours * 3_600
        let step = max(1, Int((1.0 / hz).rounded()))

        var hr: [HRSample] = [], grav: [GravitySample] = [], steps: [StepSample] = []
        var counter = 0
        var t = from
        while t < to {
            if t >= nightStart && t < nightEnd {
                hr.append(HRSample(ts: t, bpm: 50))
                grav.append(GravitySample(ts: t, x: 0, y: 0, z: 1))     // exactly still
            } else {
                hr.append(HRSample(ts: t, bpm: 74 + (t / 97) % 9))
                // Moving on EVERY daytime sample, not in bursts. With movement only one minute in six
                // and near-stillness between, the whole 54-hour window read as still and the stager
                // found no night at all — the day has to look unmistakably unlike the night.
                let wobble = Double((t &* 2_654_435_761) % 1_000) / 1_000.0
                grav.append(GravitySample(ts: t, x: 0.35 * wobble, y: 0.30 * (1 - wobble),
                                          z: 0.80 + 0.15 * wobble))
                if (t / 60) % 6 == 0 { counter += 3 }
            }
            steps.append(StepSample(ts: t, counter: counter))
            t += step
        }

        var rr: [RRInterval] = []
        let rrStep = max(1, Int((1.0 / (hz * 1.2)).rounded()))
        var toggle = false
        var r = from
        while r < to {
            let asleep = r >= nightStart && r < nightEnd
            rr.append(RRInterval(ts: r, rrMs: asleep ? (toggle ? 1_205 : 1_195)
                                                     : (toggle ? 805 : 795)))
            toggle.toggle()
            r += rrStep
        }
        return (hr, rr, grav, steps)
    }

    private static func score(_ d: (hr: [HRSample], rr: [RRInterval],
                                   grav: [GravitySample], steps: [StepSample]))
        -> AnalyticsEngine.DayResult {
        AnalyticsEngine.analyzeDay(day: dayKey, hr: d.hr, rr: d.rr, gravity: d.grav,
                                   steps: d.steps, profile: profile)
    }

    /// With REAL baselines, so the recovery path actually runs.
    ///
    /// Every measurement above came back `recovery=nil`, because the benchmark passed empty
    /// `ProfileBaselines`. A day with no baseline scores no Charge — and therefore never enters the
    /// HRV-window work, the charge drivers or the skin-temp comparison that a real day goes through.
    /// Measuring a path the app does not take is measuring nothing, and this is the last large
    /// difference between the fixture and the device's call.
    func testCostWithBaselines() throws {
        let base = Self.window(hz: 1.0)
        let trusted = { (b: Double, s: Double) in
            BaselineState(baseline: b, spread: s, nValid: 30,
                                          nightsSinceUpdate: 1, status: .trusted)
        }
        let baselines = AnalyticsEngine.ProfileBaselines(
            hrv: trusted(65, 12), restingHR: trusted(52, 4),
            resp: trusted(14.5, 1.2), skinTemp: trusted(33.5, 0.6))

        for (label, bl) in [("empty", AnalyticsEngine.ProfileBaselines()),
                            ("trusted", baselines)] {
            let started = Date()
            let r = AnalyticsEngine.analyzeDay(day: Self.dayKey, hr: base.hr, rr: base.rr,
                                               gravity: base.grav, steps: base.steps,
                                               profile: Self.profile, baselines: bl)
            print(String(format: "[BASE] %-8@ %7.3fs  nights=%d recovery=%@",
                         label as NSString, Date().timeIntervalSince(started),
                         r.sleepSessions.count,
                         r.recovery.map { String(format: "%.1f", $0) } ?? "nil" as NSString as String))
        }
    }

    /// What a MESSY day costs, against the tidy one.
    ///
    /// The tidy fixture has a perfectly still night, a uniformly restless day, and produces zero
    /// workouts. Real data is neither: the night fragments into several runs the stager has to
    /// evaluate and re-join, and the day carries bouts of raised heart rate the workout detector has
    /// to consider. That matters because several functions on both paths take a slice of the FULL
    /// stream per candidate — `WorkoutDetector` filters `hrSeg` inside its candidate loops — so their
    /// cost is candidates x samples, and a fixture with one night and no bouts never pays it.
    ///
    /// If this is much dearer than the tidy day, the shape of the data is the cost, not its size.
    func testMessyDayCost() throws {
        let base = Self.window(hz: 1.0)
        let from = base.hr.first!.ts, to = base.hr.last!.ts
        let midnight = Self.dayMidnight
        let nightEnd = midnight + 6 * 3_600, nightStart = nightEnd - 7 * 3_600

        // Six exercise bouts across the waking hours, plus a night broken by five awakenings.
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        var t = from
        var i = 0
        while t < to {
            let inNight = t >= nightStart && t < nightEnd
            // An awakening every ~70 minutes, twelve minutes long.
            let awake = inNight && ((t - nightStart) / 60) % 70 < 12
            let boutIndex = (t - midnight) / 3_600
            let inBout = !inNight && (6...11).contains(boutIndex % 13) && ((t / 60) % 60) < 35
            let wobble = Double((t &* 2_654_435_761) % 1_000) / 1_000.0
            if inNight && !awake {
                hr.append(HRSample(ts: t, bpm: 50))
                grav.append(GravitySample(ts: t, x: 0, y: 0, z: 1))
            } else if inNight {
                hr.append(HRSample(ts: t, bpm: 62 + Int(6 * wobble)))
                grav.append(GravitySample(ts: t, x: 0.2 * wobble, y: 0.1, z: 0.95))
            } else if inBout {
                hr.append(HRSample(ts: t, bpm: 138 + Int(20 * wobble)))
                grav.append(GravitySample(ts: t, x: 0.6 * wobble, y: 0.5 * (1 - wobble),
                                          z: 0.7 + 0.2 * wobble))
            } else {
                hr.append(HRSample(ts: t, bpm: 74 + Int(9 * wobble)))
                grav.append(GravitySample(ts: t, x: 0.35 * wobble, y: 0.30 * (1 - wobble),
                                          z: 0.80 + 0.15 * wobble))
            }
            t += 1
            i += 1
        }

        func run(_ label: String, hr: [HRSample], grav: [GravitySample]) {
            let started = Date()
            let r = AnalyticsEngine.analyzeDay(day: Self.dayKey, hr: hr, rr: base.rr,
                                               gravity: grav, steps: base.steps,
                                               profile: Self.profile)
            print(String(format: "[MESSY] %-8@ %7.3fs  nights=%d workouts=%d",
                         label as NSString, Date().timeIntervalSince(started),
                         r.sleepSessions.count, r.workouts.count))
        }
        run("tidy", hr: base.hr, grav: base.grav)
        run("messy", hr: hr, grav: grav)
    }

    /// Which of the streams the first benchmark LEFT OUT is the expensive one.
    ///
    /// The four-stream fixture costs 2.4 s in a debug build on a Mac. The device reported 242 s for a
    /// real day. A phone is a few times slower than this machine, not fifty, so the gap has to come
    /// from inputs this benchmark was not passing: the real call also hands over `resp`, `skinTemp`,
    /// `spo2`, the band's own sleep state, and a second copy of the day's HR/steps/gravity.
    ///
    /// Measured in DEBUG on purpose. The device build is a debug build — `NOOP Staging.debug.dylib` —
    /// and debug alone is a 45x multiplier here (0.053 s release against 2.370 s debug), so a release
    /// measurement would be comparing against the wrong thing.
    func testWhichExtraStreamCosts() throws {
        let base = Self.window(hz: 1.0)
        let from = base.hr.first!.ts, to = base.hr.last!.ts

        func ramp<T>(_ every: Int, _ make: (Int, Int) -> T) -> [T] {
            var out: [T] = []
            var t = from, i = 0
            while t < to { out.append(make(t, i)); t += every; i += 1 }
            return out
        }
        // Densities in the same order of magnitude as the day the device logged.
        let resp = ramp(1) { t, i in RespSample(ts: t, raw: 2_000 + (i % 400)) }
        let skin = ramp(1) { t, i in SkinTempSample(ts: t, raw: 30_000 + (i % 900)) }
        let spo2 = ramp(1) { t, i in SpO2Sample(ts: t, red: 100_000 + (i % 5_000),
                                                ir: 120_000 + (i % 5_000)) }
        let band: [(ts: Int, state: Int)] = ramp(30) { t, i in (ts: t, state: i % 4) }

        func timed(_ label: String, _ body: () -> AnalyticsEngine.DayResult) {
            let started = Date()
            let r = body()
            print(String(format: "[EXTRA] %-16@ %7.3fs  nights=%d",
                         label as NSString, Date().timeIntervalSince(started), r.sleepSessions.count))
        }

        timed("baseline") { Self.score(base) }
        timed("+resp") {
            AnalyticsEngine.analyzeDay(day: Self.dayKey, hr: base.hr, rr: base.rr, resp: resp,
                                       gravity: base.grav, steps: base.steps, profile: Self.profile)
        }
        timed("+skinTemp") {
            AnalyticsEngine.analyzeDay(day: Self.dayKey, hr: base.hr, rr: base.rr,
                                       gravity: base.grav, steps: base.steps, skinTemp: skin,
                                       profile: Self.profile)
        }
        timed("+spo2") {
            AnalyticsEngine.analyzeDay(day: Self.dayKey, hr: base.hr, rr: base.rr,
                                       gravity: base.grav, steps: base.steps, spo2: spo2,
                                       profile: Self.profile)
        }
        timed("+bandState") {
            AnalyticsEngine.analyzeDay(day: Self.dayKey, hr: base.hr, rr: base.rr,
                                       gravity: base.grav, steps: base.steps,
                                       profile: Self.profile, bandSleepState: band)
        }
        timed("+dayCopies") {
            AnalyticsEngine.analyzeDay(day: Self.dayKey, hr: base.hr, rr: base.rr,
                                       gravity: base.grav, steps: base.steps,
                                       dayHr: base.hr, daySteps: base.steps, dayGravity: base.grav,
                                       profile: Self.profile)
        }
        timed("everything") {
            AnalyticsEngine.analyzeDay(day: Self.dayKey, hr: base.hr, rr: base.rr, resp: resp,
                                       gravity: base.grav, steps: base.steps,
                                       dayHr: base.hr, daySteps: base.steps, dayGravity: base.grav,
                                       skinTemp: skin, spo2: spo2,
                                       profile: Self.profile, bandSleepState: band)
        }
    }

    /// One `analyzeDay` at four densities, with the night asserted at each.
    ///
    /// The densities are sampling RATES, not window lengths: the window stays 54 hours so the epoch
    /// count is identical across all four. That isolates cost-against-sample-count from the thing that
    /// would otherwise move with it.
    func testScalingCurve() throws {
        var previous: Double?
        for hz in [0.125, 0.25, 0.5, 1.0] {
            let input = Self.window(hz: hz)
            let started = Date()
            let result = Self.score(input)
            let seconds = Date().timeIntervalSince(started)
            let growth = previous.map { String(format: "%.2fx", seconds / max($0, 1e-9)) } ?? "-"
            print(String(format: "[COST] %5.3f Hz  hr=%6d rr=%6d grav=%6d  %8.3fs  vsPrev=%@  nights=%d",
                         hz, input.hr.count, input.rr.count, input.grav.count,
                         seconds, growth, result.sleepSessions.count))
            XCTAssertFalse(result.sleepSessions.isEmpty,
                           "no night at \(hz) Hz - that row would time the early exit")
            previous = seconds
        }
        print("[COST] the data doubles each row: ~2x is linear, ~4x is quadratic")
    }

    /// The gate, and the predicate `git bisect run` uses. Deliberately generous: the point is not to
    /// police a few hundred milliseconds, it is to separate "a day costs about a second" from "a day
    /// costs four minutes".
    func testFullScaleDay() throws {
        let input = Self.window(hz: 1.0)
        let started = Date()
        let result = Self.score(input)
        let seconds = Date().timeIntervalSince(started)
        let recovery = result.daily.recovery.map { String(format: "%.1f", $0) } ?? "nil"
        print(String(format: "[COST] FULL %.3fs  nights=%d recovery=%@ sleepMin=%@ workouts=%d",
                     seconds, result.sleepSessions.count, recovery,
                     String(describing: result.daily.totalSleepMin), result.workouts.count))
        XCTAssertFalse(result.sleepSessions.isEmpty,
                       "the synthetic night must be detected, or this times the early exit")
        XCTAssertLessThan(seconds, 20, "one day of scoring took \(String(format: "%.1f", seconds))s")
    }
}

// MARK: - Which argument costs the 242 seconds

extension AnalyzeDayCostTests {

    /// The benchmark above scores a full device-sized day in ~50 ms, while the device reports 242 s.
    /// Sample volume therefore is not the explanation, and the difference has to be in what production
    /// passes that the benchmark leaves at its default: the experimental stager, the motion-aware wake
    /// pass, the skin-temp stream, or the extra calendar-day streams.
    ///
    /// This times them one at a time. Whichever line explodes is the answer, and it is a much cheaper
    /// answer than reading four thousand lines hoping to spot it.
    func testWhichArgumentIsExpensive() throws {
        let d = Self.window(hz: 1.0)
        let nightEnd = Self.dayMidnight + 6 * 3_600
        let from = nightEnd - 30 * 3_600

        // Skin temp at the same cadence as the other streams: the library holds 3.8 M of these rows,
        // and production reads them for every day.
        var skin: [SkinTempSample] = []
        var t = from
        while t < from + Self.windowHours * 3_600 {
            skin.append(SkinTempSample(ts: t, raw: 2_100 + (t / 211) % 40))
            t += 1
        }

        // The calendar-day streams production also passes (dayHr / daySteps / dayGravity).
        let dayStart = Self.dayMidnight
        let dayOnly = d.hr.filter { $0.ts >= dayStart && $0.ts < dayStart + 86_400 }
        let dayGrav = d.grav.filter { $0.ts >= dayStart && $0.ts < dayStart + 86_400 }
        let daySteps = d.steps.filter { $0.ts >= dayStart && $0.ts < dayStart + 86_400 }

        func time(_ label: String, _ body: () -> AnalyticsEngine.DayResult) {
            let started = Date()
            let r = body()
            let seconds = Date().timeIntervalSince(started)
            print(String(format: "[COST] %-22@ %8.3fs  nights=%d", label as NSString,
                         seconds, r.sleepSessions.count))
        }

        time("baseline") {
            AnalyticsEngine.analyzeDay(day: Self.dayKey, hr: d.hr, rr: d.rr, gravity: d.grav,
                                       steps: d.steps, profile: Self.profile)
        }
        time("+ sleepStagerV2") {
            AnalyticsEngine.analyzeDay(day: Self.dayKey, hr: d.hr, rr: d.rr, gravity: d.grav,
                                       steps: d.steps, profile: Self.profile,
                                       useSleepStagerV2: true)
        }
        time("+ motionAwareWake") {
            AnalyticsEngine.analyzeDay(day: Self.dayKey, hr: d.hr, rr: d.rr, gravity: d.grav,
                                       steps: d.steps, profile: Self.profile,
                                       useMotionAwareWake: true)
        }
        time("+ skinTemp") {
            AnalyticsEngine.analyzeDay(day: Self.dayKey, hr: d.hr, rr: d.rr, gravity: d.grav,
                                       steps: d.steps, skinTemp: skin, profile: Self.profile)
        }
        time("+ calendar-day streams") {
            AnalyticsEngine.analyzeDay(day: Self.dayKey, hr: d.hr, rr: d.rr, gravity: d.grav,
                                       steps: d.steps, dayHr: dayOnly, daySteps: daySteps,
                                       dayGravity: dayGrav, profile: Self.profile)
        }
        time("+ hrvWindowDetail") {
            AnalyticsEngine.analyzeDay(day: Self.dayKey, hr: d.hr, rr: d.rr, gravity: d.grav,
                                       steps: d.steps, profile: Self.profile,
                                       hrvWindowDetail: true)
        }
        time("+ deepHrvWindow") {
            AnalyticsEngine.analyzeDay(day: Self.dayKey, hr: d.hr, rr: d.rr, gravity: d.grav,
                                       steps: d.steps, profile: Self.profile,
                                       deepHrvWindow: true)
        }
    }
}

extension AnalyzeDayCostTests {

    /// Same number of rows, fewer distinct seconds.
    ///
    /// The synthetic streams above put one row on each second, which is the friendliest possible shape.
    /// The real store does not: `rrInterval` carries an `ord` column precisely because a second can
    /// hold many beats, and this library holds 6.3 M R-R rows. Anything that groups by timestamp and
    /// then walks the group per element turns that clustering into quadratic work, and it would be
    /// invisible to every test that samples one row per second.
    ///
    /// If this line explodes while the evenly-spread one does not, the shape of the data is the bug.
    func testClusteredTimestamps() throws {
        let d = Self.window(hz: 1.0)
        let nightEnd = Self.dayMidnight + 6 * 3_600
        let from = nightEnd - 30 * 3_600

        func clustered(rowsPerSecond: Int) -> [RRInterval] {
            var out: [RRInterval] = []
            out.reserveCapacity(d.rr.count)
            let seconds = max(1, d.rr.count / rowsPerSecond)
            let nightStart = nightEnd - 7 * 3_600
            for i in 0..<d.rr.count {
                // Same total rows, packed onto `seconds` distinct timestamps.
                let ts = from + (i / rowsPerSecond) * (Self.windowHours * 3_600 / seconds)
                let asleep = ts >= nightStart && ts < nightEnd
                out.append(RRInterval(ts: ts, rrMs: asleep ? (i % 2 == 0 ? 1_205 : 1_195)
                                                           : (i % 2 == 0 ? 805 : 795),
                                      ord: i % rowsPerSecond))
            }
            return out
        }

        for rowsPerSecond in [1, 4, 16, 64] {
            let rr = clustered(rowsPerSecond: rowsPerSecond)
            let distinct = Set(rr.map(\.ts)).count
            let started = Date()
            let r = AnalyticsEngine.analyzeDay(day: Self.dayKey, hr: d.hr, rr: rr, gravity: d.grav,
                                               steps: d.steps, profile: Self.profile)
            let seconds = Date().timeIntervalSince(started)
            print(String(format: "[COST] rr rows=%d over %d distinct seconds (%d/s)  %8.3fs  nights=%d",
                         rr.count, distinct, rowsPerSecond, seconds, r.sleepSessions.count))
        }
    }
}

extension AnalyzeDayCostTests {

    /// The same gap that made the first fixture worthless, one level down: every run above reported
    /// `recovery=nil`, which means the recovery scorer never ran. Without baselines there is nothing to
    /// score a night against, so that whole half of the pipeline was being timed at zero.
    func testWithBaselinesSoRecoveryActuallyRuns() throws {
        let d = Self.window(hz: 1.0)
        let baselines = AnalyticsEngine.ProfileBaselines(
            hrv: BaselineState(baseline: 55, spread: 12, nValid: 30,
                               nightsSinceUpdate: 0, status: .trusted),
            restingHR: BaselineState(baseline: 52, spread: 4, nValid: 30,
                                     nightsSinceUpdate: 0, status: .trusted),
            resp: BaselineState(baseline: 14, spread: 1.5, nValid: 30,
                                nightsSinceUpdate: 0, status: .trusted),
            skinTemp: BaselineState(baseline: 33, spread: 0.6, nValid: 30,
                                    nightsSinceUpdate: 0, status: .trusted))

        for v2 in [false, true] {
            let started = Date()
            let r = AnalyticsEngine.analyzeDay(day: Self.dayKey, hr: d.hr, rr: d.rr, gravity: d.grav,
                                               steps: d.steps, profile: Self.profile,
                                               baselines: baselines, useSleepStagerV2: v2)
            let seconds = Date().timeIntervalSince(started)
            let recovery = r.daily.recovery.map { String(format: "%.1f", $0) } ?? "nil"
            print(String(format: "[COST] baselines v2=%@  %8.3fs  nights=%d recovery=%@",
                         (v2 ? "yes" : "no ") as NSString, seconds,
                         r.sleepSessions.count, recovery as NSString))
        }
    }
}
