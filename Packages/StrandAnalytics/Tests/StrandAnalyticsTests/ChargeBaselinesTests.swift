import XCTest
@testable import StrandAnalytics
import WhoopStore

/// Which nights the Charge baselines are folded from (#2525, AI-35).
///
/// The defects these pin: the imported vendor history was folded in full while the wearer's own nights
/// entered only from the scan window, so the import kept about a third of the weight however long NOOP had
/// been worn (#2525); and one baseline folded from the nights ending TODAY scored every day, so a day's
/// Charge read its own night and every later one (AI-35). Byte-identical twin: Kotlin `ChargeBaselinesTest`
/// (same cases, same oracle literal).
final class ChargeBaselinesTests: XCTestCase {

    private let hrvCfg = Baselines.hrvCfg
    private let rhrCfg = Baselines.restingHRCfg

    /// `yyyy-MM-dd` for a day count from 1970-01-01 (Howard Hinnant's civil-from-days), so the cases need no
    /// calendar or time zone. The Kotlin twin uses `LocalDate.ofEpochDay`, which yields the same keys.
    private static func dayKey(_ epochDay: Int) -> String {
        let z = epochDay + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// 2026-09-30 as a day count from 1970-01-01.
    private static let anchorEpochDay = 20_726

    /// `count` consecutive nights ending `endBack` days before the anchor, all at `value`.
    private static func run(_ count: Int, endBack: Int, value: Double?) -> [(day: String, value: Double?)] {
        (0..<count).map { i in (day: dayKey(anchorEpochDay - endBack - (count - 1 - i)), value: value) }
    }

    private static let anchor = dayKey(anchorEpochDay)

    // MARK: - The window

    func testTheAnchorIsTheDayItClaims() {
        XCTAssertEqual(Self.anchor, "2026-09-30")
    }

    /// The window holds the anchor and the 89 days before it; the 90th day back and any later day are out.
    func testTheWindowKeepsNinetyCalendarDaysEndingOnTheAnchor() {
        XCTAssertEqual(ChargeBaselines.windowDays, 90)
        let own: [(day: String, value: Double?)] = [
            (day: Self.dayKey(Self.anchorEpochDay - 90), value: 50),
            (day: Self.dayKey(Self.anchorEpochDay - 89), value: 51),
            (day: Self.anchor, value: 52),
            (day: Self.dayKey(Self.anchorEpochDay + 1), value: 53),
        ]
        let h = ChargeBaselines.history(imported: [], own: own, anchorDay: Self.anchor, cfg: hrvCfg, baselineEpoch: 0)
        XCTAssertEqual(h.dayKeys, ["2026-07-03", "2026-09-30"])
        XCTAssertEqual(h.values, [51, 52])
    }

    // MARK: - The scored day (AI-35)

    /// A day's Charge is scored against the day BEFORE it, so its own night and later nights stay out.
    func testTheAnchorOfAScoredDayIsTheDayBefore() {
        XCTAssertEqual(ChargeBaselines.anchorDay(forScoredDay: "2026-10-01"), "2026-09-30")
        XCTAssertEqual(ChargeBaselines.anchorDay(forScoredDay: "2026-03-01"), "2026-02-28")
        XCTAssertNil(ChargeBaselines.anchorDay(forScoredDay: "not-a-day"))
    }

    private static func row(_ back: Int, hrv: Double, rhr: Int) -> DailyMetric {
        DailyMetric(day: dayKey(anchorEpochDay - back), totalSleepMin: nil, efficiency: nil,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: rhr,
                    avgHrv: hrv, recovery: nil, strain: nil, exerciseCount: nil)
    }

    /// The scored night itself does not enter its own baseline: a very low night cannot pull its own normal
    /// down and so soften its own score.
    func testAScoredNightIsNotPartOfItsOwnBaseline() {
        let earlier = (1...20).map { Self.row($0, hrv: 50, rhr: 55) }
        let withLowNight = earlier + [Self.row(0, hrv: 20, rhr: 70)]
        let r = ChargeBaselines.resolve(imported: [], own: withLowNight, scoredDay: Self.anchor,
                                        hrvEpoch: 0, recoveryEpoch: 0)
        let without = ChargeBaselines.resolve(imported: [], own: earlier, scoredDay: Self.anchor,
                                              hrvEpoch: 0, recoveryEpoch: 0)
        XCTAssertEqual(r, without)
        XCTAssertEqual(r.hrv.nValid, 20)
        XCTAssertEqual(r.hrv.baseline, 50, accuracy: 1e-9)
    }

    /// Nights after the scored day change nothing: a past day keeps the baseline it was scored with when
    /// later nights arrive (before AI-35 a rebuild scored every day against today's baseline).
    func testLaterNightsDoNotMoveAnEarlierDaysBaseline() {
        let history = (0..<30).map { Self.row($0 + 10, hrv: 40 + Double($0 % 7), rhr: 60 - $0 % 5) }
        let later = (0..<10).map { Self.row($0, hrv: 90, rhr: 45) }
        let scored = Self.dayKey(Self.anchorEpochDay - 9)   // the first day after `history`
        let before = ChargeBaselines.resolve(imported: [], own: history, scoredDay: scored, hrvEpoch: 0,
                                             recoveryEpoch: 0)
        let after = ChargeBaselines.resolve(imported: [], own: history + later, scoredDay: scored, hrvEpoch: 0,
                                            recoveryEpoch: 0)
        XCTAssertEqual(before, after)
    }

    /// The Charge configs are the shared ones plus the early spread half-life; nothing else differs.
    func testTheChargeConfigsAddOnlyTheEarlySpreadHalfLife() {
        for (charge, shared) in [(ChargeBaselines.hrvCfg, Baselines.hrvCfg),
                                 (ChargeBaselines.restingHRCfg, Baselines.restingHRCfg),
                                 (ChargeBaselines.respCfg, Baselines.respCfg)] {
            XCTAssertEqual(charge.earlyHalfLifeS, ChargeBaselines.earlySpreadHalfLife)
            XCTAssertNil(shared.earlyHalfLifeS)
            XCTAssertEqual(MetricCfg(minVal: charge.minVal, maxVal: charge.maxVal, floorSpread: charge.floorSpread,
                                     halfLifeB: charge.halfLifeB, halfLifeS: charge.halfLifeS), shared)
        }
    }

    /// An import that ended before the window has nothing left to seed with, however few own nights exist.
    func testAnImportOlderThanTheWindowDoesNotSeed() {
        let imported = Self.run(300, endBack: 95, value: 40)
        let own = Self.run(3, endBack: 0, value: 60)
        let h = ChargeBaselines.history(imported: imported, own: own, anchorDay: Self.anchor, cfg: hrvCfg,
                                        baselineEpoch: 0)
        XCTAssertFalse(h.seededByImport)
        XCTAssertEqual(h.values, [60, 60, 60])
        XCTAssertEqual(h.importedNights, 0)
    }

    // MARK: - The handoff

    /// Thirteen valid own nights are not yet a trusted baseline, so the import still seeds; the fourteenth
    /// hands over and the import drops out entirely.
    func testImportSeedsUntilTheOwnNightsAloneAreTrusted() {
        let imported = Self.run(7, endBack: 14, value: 40)
        let seeding = ChargeBaselines.history(imported: imported, own: Self.run(13, endBack: 0, value: 60),
                                              anchorDay: Self.anchor, cfg: hrvCfg, baselineEpoch: 0)
        XCTAssertTrue(seeding.seededByImport)
        XCTAssertEqual(seeding.ownValidNights, 13)
        XCTAssertEqual(seeding.importedNights, 7)
        XCTAssertEqual(seeding.dayKeys.count, 20)

        let handedOff = ChargeBaselines.history(imported: imported, own: Self.run(14, endBack: 0, value: 60),
                                                anchorDay: Self.anchor, cfg: hrvCfg, baselineEpoch: 0)
        XCTAssertFalse(handedOff.seededByImport)
        XCTAssertEqual(handedOff.ownValidNights, 14)
        XCTAssertEqual(handedOff.importedNights, 0)
        XCTAssertEqual(handedOff.values, Array(repeating: 60, count: 14))
    }

    /// Own nights without a value exist but are not valid, so they do not bring the handoff forward.
    func testOwnNightsWithoutAValueDoNotCountTowardTheHandoff() {
        let own = Self.run(13, endBack: 1, value: 60) + Self.run(1, endBack: 0, value: nil)
        let h = ChargeBaselines.history(imported: Self.run(6, endBack: 14, value: 40), own: own,
                                        anchorDay: Self.anchor, cfg: hrvCfg, baselineEpoch: 0)
        XCTAssertTrue(h.seededByImport)
        XCTAssertEqual(h.ownValidNights, 13)
    }

    /// Own nights before the recalibration epoch are dropped by the fold, so they must not count here either.
    func testOwnNightsBeforeTheEpochDoNotCountTowardTheHandoff() {
        let own = Self.run(30, endBack: 0, value: 60)
        let epoch = Double(Self.anchorEpochDay - 9) * 86_400   // the last ten own nights survive
        let h = ChargeBaselines.history(imported: Self.run(3, endBack: 18, value: 40), own: own,
                                        anchorDay: Self.anchor, cfg: hrvCfg, baselineEpoch: epoch)
        XCTAssertEqual(h.ownValidNights, 10)
        XCTAssertTrue(h.seededByImport)
    }

    // MARK: - Seeding precedence (carried over from the pre-#2525 `mergeNightlyIntoHistory` pins)

    private func seed(imported: [(day: String, value: Double?)],
                      own: [(day: String, value: Double?)]) -> ChargeBaselines.History {
        ChargeBaselines.history(imported: imported, own: own, anchorDay: Self.anchor, cfg: hrvCfg, baselineEpoch: 0)
    }

    /// An imported value wins a day the own nights also cover (import users keep their seed).
    func testWhileSeedingAnImportedValueWinsASharedDay() {
        let h = seed(imported: [(day: Self.anchor, value: 62)], own: [(day: Self.anchor, value: 48)])
        XCTAssertTrue(h.seededByImport)
        XCTAssertEqual(h.values, [62])
    }

    /// An own night fills a day the import does not cover.
    func testWhileSeedingAnOwnNightFillsADayTheImportLacks() {
        let yesterday = Self.dayKey(Self.anchorEpochDay - 1)
        let h = seed(imported: [(day: yesterday, value: 62)], own: [(day: Self.anchor, value: 48)])
        XCTAssertEqual(h.dayKeys, [yesterday, Self.anchor])
        XCTAssertEqual(h.values, [62, 48])
    }

    /// A blank imported row must not shadow a night the strap measured, or an import whose rows are blank
    /// for a metric blankets every strap night and the baseline never seeds ("Needs the strap").
    func testWhileSeedingABlankImportedRowIsFilledByTheOwnNight() {
        let h = seed(imported: [(day: Self.anchor, value: nil)], own: [(day: Self.anchor, value: 48)])
        XCTAssertEqual(h.values, [48])
    }

    /// A blank imported row with no own night stays a missing night (an honest gap).
    func testWhileSeedingABlankImportedRowWithNoOwnNightStaysMissing() {
        let yesterday = Self.dayKey(Self.anchorEpochDay - 1)
        let h = seed(imported: [(day: yesterday, value: nil), (day: Self.anchor, value: 62)], own: [])
        XCTAssertTrue(h.seededByImport)
        XCTAssertEqual(h.dayKeys, [yesterday, Self.anchor])
        XCTAssertEqual(h.values, [nil, 62])
    }

    /// An own night without a value neither overwrites an imported value nor removes a blank imported day.
    func testWhileSeedingABlankOwnNightDisturbsNothing() {
        let d1 = Self.dayKey(Self.anchorEpochDay - 2), d2 = Self.dayKey(Self.anchorEpochDay - 1)
        let h = seed(imported: [(day: d1, value: 62), (day: d2, value: nil)],
                     own: [(day: d1, value: nil), (day: d2, value: nil), (day: Self.anchor, value: nil)])
        XCTAssertEqual(h.dayKeys, [d1, d2, Self.anchor])
        XCTAssertEqual(h.values, [62, nil, nil])
    }

    /// The starvation report's shape: a week of imported rows, all blank for HRV, over nights the strap
    /// scored. The seven measured nights must reach the fold so the baseline can seed.
    func testWhileSeedingAWeekOfBlankImportedRowsStillSeedsFromTheStrap() {
        let imported = Self.run(7, endBack: 0, value: nil)
        let own = (0..<7).map { i in (day: Self.dayKey(Self.anchorEpochDay - 6 + i), value: Optional(50.0 + Double(i))) }
        let h = seed(imported: imported, own: own)
        XCTAssertEqual(h.values.compactMap { $0 }.count, 7)
        let folded = Baselines.foldHistory(h.values, dayKeys: h.dayKeys, cfg: hrvCfg, baselineEpoch: 0)
        XCTAssertGreaterThanOrEqual(folded.nValid, Baselines.minNightsSeed)
    }

    /// Nothing that cannot be placed on the calendar is folded.
    func testUnparseableKeysAreDroppedAndAnUnparseableAnchorYieldsNothing() {
        let own: [(day: String, value: Double?)] = [(day: "garbage", value: 50), (day: Self.anchor, value: 51)]
        let h = ChargeBaselines.history(imported: [], own: own, anchorDay: Self.anchor, cfg: hrvCfg, baselineEpoch: 0)
        XCTAssertEqual(h.dayKeys, [Self.anchor])
        let none = ChargeBaselines.history(imported: [], own: own, anchorDay: "not-a-day", cfg: hrvCfg,
                                           baselineEpoch: 0)
        XCTAssertEqual(none.dayKeys, [])
        XCTAssertFalse(none.seededByImport)
    }

    // MARK: - The defect (#2525)

    /// A wearer whose resting HR fell from 58 during their vendor subscription to 52 since. Under the old
    /// rule (the whole import plus the last 21 own nights) the baseline stays about a third of the way back
    /// towards 58 however long NOOP has been worn; under this rule it follows the wearer to 52.
    func testTheBaselineFollowsTheWearerInsteadOfTheImport() {
        let imported = Self.run(700, endBack: 181, value: 58)
        let own = Self.run(180, endBack: 0, value: 52)
        let oldRule = Baselines.foldHistory(imported.map(\.value) + own.suffix(21).map(\.value), cfg: rhrCfg)
        XCTAssertEqual(oldRule.baseline, 54.1, accuracy: 0.2,
                       "the pinned third: 52 + 6 x 0.5^(21/14) is about 54.1")

        let h = ChargeBaselines.history(imported: imported, own: own, anchorDay: Self.anchor, cfg: rhrCfg,
                                        baselineEpoch: 0)
        let folded = Baselines.foldHistory(h.values, dayKeys: h.dayKeys, cfg: rhrCfg, baselineEpoch: 0)
        XCTAssertEqual(folded.baseline, 52, accuracy: 1e-9)
    }

    /// Once the own nights have taken over, the import has no weight at all: moving every imported value
    /// leaves the baseline exactly where it was.
    func testOnceHandedOffTheImportCarriesNoWeight() {
        let own = Self.run(60, endBack: 0, value: 52)
        let base = ChargeBaselines.history(imported: Self.run(200, endBack: 10, value: 58), own: own,
                                           anchorDay: Self.anchor, cfg: rhrCfg, baselineEpoch: 0)
        let shifted = ChargeBaselines.history(imported: Self.run(200, endBack: 10, value: 68), own: own,
                                              anchorDay: Self.anchor, cfg: rhrCfg, baselineEpoch: 0)
        XCTAssertEqual(base, shifted)
    }

    /// The own nights of a varied 60-night history, as a full-history repair pass would score them.
    private static func variedOwnNights() -> [(day: String, value: Double?)] {
        (0..<60).map { i in
            (day: dayKey(anchorEpochDay - 59 + i), value: i % 9 == 0 ? nil : 45 + Double((i * 7) % 13))
        }
    }

    /// Without an import the history is exactly the own nights of the window, in day order.
    func testWithoutAnImportTheHistoryIsTheWindowsOwnNights() {
        let nights = Self.variedOwnNights()
        let h = ChargeBaselines.history(imported: [], own: nights.shuffled(), anchorDay: Self.anchor, cfg: hrvCfg,
                                        baselineEpoch: 0)
        XCTAssertEqual(h.dayKeys, nights.map(\.day))
        XCTAssertEqual(h.values, nights.map(\.value))
    }

    /// A full-history repair pass and a short pass give a day the same history: nights older than the window
    /// fall out, so the baseline no longer depends on which pass ran last.
    func testARepairPassFoldsTheSameWindowAsAShortPass() {
        let all = (0..<200).map { i in
            (day: Self.dayKey(Self.anchorEpochDay - 199 + i), value: Optional(45 + Double((i * 7) % 13)))
        }
        let repair = ChargeBaselines.history(imported: [], own: all, anchorDay: Self.anchor, cfg: hrvCfg,
                                             baselineEpoch: 0)
        let tick = ChargeBaselines.history(imported: [], own: Array(all.suffix(ChargeBaselines.windowDays)),
                                           anchorDay: Self.anchor, cfg: hrvCfg, baselineEpoch: 0)
        XCTAssertEqual(repair, tick)
    }

    // MARK: - Resolved (the dashboard's view)

    /// Resting HR follows the Charge-wide recalibration epoch in the dashboard as it does in the engine.
    func testResolveFoldsRestingHROnTheRecoveryEpoch() {
        func row(_ back: Int, rhr: Int) -> DailyMetric {
            DailyMetric(day: Self.dayKey(Self.anchorEpochDay - back), totalSleepMin: nil, efficiency: nil,
                        deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: rhr,
                        avgHrv: 50, recovery: nil, strain: nil, exerciseCount: nil)
        }
        let own = (0..<20).map { row($0, rhr: $0 < 5 ? 50 : 60) }
        let epoch = Double(Self.anchorEpochDay - 4) * 86_400
        // Scored the day after the anchor, so the anchor's night is the newest the baseline reads.
        let r = ChargeBaselines.resolve(imported: [], own: own, scoredDay: Self.dayKey(Self.anchorEpochDay + 1),
                                        hrvEpoch: 0, recoveryEpoch: epoch)
        XCTAssertEqual(r.restingHR.nValid, 5)
        XCTAssertEqual(r.restingHR.baseline, 50, accuracy: 1e-9)
        XCTAssertEqual(r.hrv.nValid, 20)
    }

    // MARK: - Diagnostic line

    func testLogLineNamesEachMetricsComposition() {
        let seeded = ChargeBaselines.History(dayKeys: [], values: [], seededByImport: true,
                                             ownValidNights: 9, importedNights: 40)
        let own = ChargeBaselines.History(dayKeys: [], values: [], seededByImport: false,
                                          ownValidNights: 45, importedNights: 0)
        XCTAssertEqual(ChargeBaselines.logLine(anchorDay: "2026-09-30", hrv: own, restingHR: seeded,
                                               resp: own, skin: own),
                       "charge baseline anchor=2026-09-30 window=90d hrv=own/45 rhr=seed/9+40 resp=own/45 skin=own/45")
    }

    // MARK: - Oracle (shared with Kotlin)

    /// A deterministic spread of imported/own histories, anchors and epochs. The same generator runs in the
    /// Kotlin twin and both assert the same literal, so either side drifting fails its own suite.
    static func oracleLines() -> [String] {
        var s: UInt64 = 2525
        func next() -> Int {
            s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(s >> 33)
        }
        var lines: [String] = []
        for c in 0..<40 {
            let anchorDay = 20_089 + next() % 400
            var imported: [(day: String, value: Double?)] = []
            let nImported = next() % 120
            let importEndBack = next() % 40
            for i in 0..<nImported {
                let value: Double? = next() % 10 == 0 ? nil : 40 + Double(next() % 60) / 2
                imported.append((day: dayKey(anchorDay - importEndBack - (nImported - 1 - i)), value: value))
            }
            var own: [(day: String, value: Double?)] = []
            let nOwn = next() % 30
            let ownEndBack = next() % 10
            for i in 0..<nOwn {
                let value: Double? = next() % 8 == 0 ? nil : 35 + Double(next() % 80) / 2
                own.append((day: dayKey(anchorDay - ownEndBack - (nOwn - 1 - i)), value: value))
            }
            if next() % 7 == 0 { own.append((day: dayKey(anchorDay + 1), value: 50)) }
            let epoch = next() % 5 == 0 ? Double(anchorDay - next() % 60) * 86_400 : 0
            let h = ChargeBaselines.history(imported: imported, own: own, anchorDay: dayKey(anchorDay),
                                            cfg: Baselines.hrvCfg, baselineEpoch: epoch)
            let present = h.values.compactMap { $0 }
            lines.append("c=\(c) anchor=\(dayKey(anchorDay)) n=\(h.dayKeys.count) " +
                         "first=\(h.dayKeys.first ?? "-") last=\(h.dayKeys.last ?? "-") " +
                         "seeded=\(h.seededByImport ? 1 : 0) own=\(h.ownValidNights) imp=\(h.importedNights) " +
                         "nils=\(h.values.count - present.count) sum=\(String(format: "%.1f", present.reduce(0, +)))")
        }
        return lines
    }

    func testOracleSpread() {
        XCTAssertEqual(Self.oracleLines().joined(separator: "\n"), Self.oracleLiteral)
    }

    static let oracleLiteral = """
    c=0 anchor=2026-01-25 n=12 first=2025-12-18 last=2026-01-16 seeded=1 own=7 imp=5 nils=0 sum=668.5
    c=1 anchor=2025-07-07 n=54 first=2025-05-01 last=2025-07-07 seeded=1 own=2 imp=52 nils=5 sum=2672.0
    c=2 anchor=2025-12-01 n=82 first=2025-09-03 last=2025-11-25 seeded=1 own=9 imp=72 nils=11 sum=4011.5
    c=3 anchor=2025-06-15 n=59 first=2025-04-05 last=2025-06-15 seeded=1 own=2 imp=57 nils=6 sum=2860.0
    c=4 anchor=2025-08-01 n=70 first=2025-05-15 last=2025-07-27 seeded=1 own=13 imp=55 nils=8 sum=3361.0
    c=5 anchor=2025-11-29 n=80 first=2025-09-01 last=2025-11-27 seeded=1 own=11 imp=66 nils=10 sum=3987.0
    c=6 anchor=2025-05-06 n=81 first=2025-02-06 last=2025-04-30 seeded=1 own=11 imp=69 nils=13 sum=3776.0
    c=7 anchor=2025-10-16 n=68 first=2025-07-19 last=2025-10-14 seeded=1 own=13 imp=54 nils=5 sum=3339.5
    c=8 anchor=2026-01-27 n=29 first=2025-12-04 last=2026-01-18 seeded=1 own=10 imp=17 nils=3 sum=1394.5
    c=9 anchor=2026-02-02 n=74 first=2025-11-10 last=2026-01-28 seeded=1 own=3 imp=71 nils=5 sum=3649.5
    c=10 anchor=2025-02-01 n=83 first=2024-11-04 last=2025-01-28 seeded=1 own=5 imp=75 nils=8 sum=4020.5
    c=11 anchor=2025-12-06 n=13 first=2025-11-22 last=2025-12-04 seeded=1 own=13 imp=2 nils=0 sum=687.0
    c=12 anchor=2025-07-27 n=20 first=2025-06-30 last=2025-07-19 seeded=0 own=18 imp=0 nils=2 sum=980.0
    c=13 anchor=2025-04-30 n=71 first=2025-02-02 last=2025-04-25 seeded=1 own=8 imp=62 nils=8 sum=3431.5
    c=14 anchor=2025-05-17 n=21 first=2025-04-18 last=2025-05-08 seeded=0 own=21 imp=0 nils=0 sum=1134.0
    c=15 anchor=2025-06-17 n=19 first=2025-05-30 last=2025-06-17 seeded=0 own=16 imp=0 nils=3 sum=929.0
    c=16 anchor=2025-11-04 n=69 first=2025-08-07 last=2025-10-29 seeded=1 own=11 imp=55 nils=8 sum=3376.5
    c=17 anchor=2025-07-22 n=47 first=2025-05-26 last=2025-07-19 seeded=1 own=8 imp=37 nils=3 sum=2403.5
    c=18 anchor=2025-08-09 n=16 first=2025-07-13 last=2025-07-28 seeded=1 own=0 imp=16 nils=1 sum=762.5
    c=19 anchor=2025-01-01 n=17 first=2024-12-12 last=2024-12-28 seeded=0 own=16 imp=0 nils=1 sum=873.0
    c=20 anchor=2025-09-06 n=68 first=2025-06-09 last=2025-09-01 seeded=1 own=13 imp=54 nils=4 sum=3502.0
    c=21 anchor=2025-02-05 n=60 first=2024-11-08 last=2025-01-27 seeded=1 own=2 imp=58 nils=5 sum=3012.0
    c=22 anchor=2025-09-03 n=73 first=2025-06-17 last=2025-08-28 seeded=1 own=5 imp=68 nils=12 sum=3454.0
    c=23 anchor=2025-11-14 n=83 first=2025-08-17 last=2025-11-07 seeded=1 own=3 imp=82 nils=9 sum=4184.5
    c=24 anchor=2025-02-26 n=25 first=2025-02-01 last=2025-02-25 seeded=0 own=23 imp=0 nils=2 sum=1272.0
    c=25 anchor=2025-01-27 n=24 first=2024-12-29 last=2025-01-21 seeded=0 own=22 imp=0 nils=2 sum=1166.0
    c=26 anchor=2025-07-12 n=24 first=2025-06-12 last=2025-07-05 seeded=0 own=21 imp=0 nils=3 sum=1119.5
    c=27 anchor=2025-12-20 n=22 first=2025-11-20 last=2025-12-11 seeded=0 own=20 imp=0 nils=2 sum=1107.5
    c=28 anchor=2025-06-07 n=20 first=2025-05-14 last=2025-06-02 seeded=0 own=17 imp=0 nils=3 sum=952.0
    c=29 anchor=2025-05-29 n=23 first=2025-05-04 last=2025-05-26 seeded=0 own=19 imp=0 nils=4 sum=1097.0
    c=30 anchor=2025-06-16 n=82 first=2025-03-19 last=2025-06-08 seeded=1 own=12 imp=79 nils=7 sum=4093.0
    c=31 anchor=2025-08-10 n=66 first=2025-05-31 last=2025-08-04 seeded=1 own=9 imp=61 nils=9 sum=3186.0
    c=32 anchor=2026-01-17 n=20 first=2025-12-22 last=2026-01-10 seeded=0 own=18 imp=0 nils=2 sum=1027.0
    c=33 anchor=2026-01-10 n=20 first=2025-12-15 last=2026-01-03 seeded=0 own=18 imp=0 nils=2 sum=1040.0
    c=34 anchor=2025-08-30 n=66 first=2025-06-02 last=2025-08-30 seeded=1 own=4 imp=60 nils=3 sum=3438.0
    c=35 anchor=2026-01-31 n=57 first=2025-11-28 last=2026-01-31 seeded=1 own=4 imp=53 nils=7 sum=2873.0
    c=36 anchor=2025-06-22 n=52 first=2025-04-12 last=2025-06-19 seeded=1 own=5 imp=47 nils=4 sum=2674.5
    c=37 anchor=2026-01-28 n=87 first=2025-10-31 last=2026-01-25 seeded=1 own=12 imp=80 nils=7 sum=4351.0
    c=38 anchor=2025-05-08 n=18 first=2025-04-16 last=2025-05-03 seeded=0 own=14 imp=0 nils=4 sum=810.0
    c=39 anchor=2025-10-01 n=22 first=2025-09-03 last=2025-09-24 seeded=0 own=19 imp=0 nils=3 sum=1075.0
    """
}
