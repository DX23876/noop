import XCTest
@testable import StrandAnalytics

/// Pins the basal formulas and the dated log that selects between them.
///
/// The log's whole purpose is that a switch made today cannot change what yesterday showed. Most of
/// these tests are about that boundary rather than about arithmetic.
final class BasalFormulaTests: XCTestCase {

    private let weightKg = 80.0
    private let heightCm = 180.0
    private let age = 35.0

    // MARK: - The formulas

    /// Harris–Benedict comes from `Calories` rather than a second copy living here.
    func testHarrisBenedictMatchesTheOneCaloriesOwns() throws {
        let value = try XCTUnwrap(BasalRate.kcalPerDay(.revisedHarrisBenedict, weightKg: weightKg,
                                                       heightCm: heightCm, age: age, sex: "male"))
        XCTAssertEqual(value, 1825.247, accuracy: 0.001)
        let viaCalories = try XCTUnwrap(Calories.bmrKcalPerDay(
            profile: .init(weightKg: weightKg, heightCm: heightCm, age: age, sex: "male")))
        XCTAssertEqual(value, viaCalories, accuracy: 1e-9)
    }

    /// Mifflin-St Jeor at its published form.
    func testMifflinStJeorMatchesItsPublishedForm() throws {
        let male = try XCTUnwrap(BasalRate.kcalPerDay(.mifflinStJeor, weightKg: weightKg,
                                                      heightCm: heightCm, age: age, sex: "male"))
        XCTAssertEqual(male, 1755, accuracy: 0.001)
        let female = try XCTUnwrap(BasalRate.kcalPerDay(.mifflinStJeor, weightKg: weightKg,
                                                        heightCm: heightCm, age: age, sex: "female"))
        XCTAssertEqual(female, 1589, accuracy: 0.001)
        // Nonbinary takes the midpoint, the convention `Calories` already uses.
        let nonbinary = try XCTUnwrap(BasalRate.kcalPerDay(.mifflinStJeor, weightKg: weightKg,
                                                           heightCm: heightCm, age: age,
                                                           sex: "nonbinary"))
        XCTAssertEqual(nonbinary, (male + female) / 2, accuracy: 0.001)
    }

    /// Katch-McArdle works from lean mass and is therefore sex-independent — the same lean kilogram
    /// costs the same on any body.
    func testKatchMcArdleWorksFromLeanMassAndIgnoresSex() throws {
        let male = try XCTUnwrap(BasalRate.kcalPerDay(.katchMcArdle, weightKg: weightKg,
                                                      heightCm: heightCm, age: age, sex: "male",
                                                      bodyFatPercent: 18))
        XCTAssertEqual(male, 1786.96, accuracy: 0.001)
        let female = try XCTUnwrap(BasalRate.kcalPerDay(.katchMcArdle, weightKg: weightKg,
                                                        heightCm: heightCm, age: age, sex: "female",
                                                        bodyFatPercent: 18))
        XCTAssertEqual(male, female, accuracy: 1e-9)
    }

    /// More fat at equal weight means less lean mass, so a lower basal rate.
    func testMoreFatAtEqualWeightLowersTheRate() throws {
        let lean = try XCTUnwrap(BasalRate.kcalPerDay(.katchMcArdle, weightKg: weightKg,
                                                      heightCm: heightCm, age: age, sex: "male",
                                                      bodyFatPercent: 12))
        let fatter = try XCTUnwrap(BasalRate.kcalPerDay(.katchMcArdle, weightKg: weightKg,
                                                        heightCm: heightCm, age: age, sex: "male",
                                                        bodyFatPercent: 30))
        XCTAssertGreaterThan(lean, fatter)
    }

    /// Katch-McArdle says nothing without a body-fat figure instead of falling through to another
    /// formula — a silent substitution would put an unexplained step in the curve.
    func testKatchMcArdleRefusesWithoutBodyFat() {
        XCTAssertNil(BasalRate.kcalPerDay(.katchMcArdle, weightKg: weightKg, heightCm: heightCm,
                                          age: age, sex: "male"))
        XCTAssertNil(BasalRate.kcalPerDay(.katchMcArdle, weightKg: weightKg, heightCm: heightCm,
                                          age: age, sex: "male", bodyFatPercent: 95))
        XCTAssertTrue(BasalFormula.katchMcArdle.needsBodyFat)
        XCTAssertFalse(BasalFormula.revisedHarrisBenedict.needsBodyFat)
    }

    /// Absent body data produces nothing, for every formula.
    func testAbsentBodyDataProducesNothing() {
        for formula in BasalFormula.allCases {
            XCTAssertNil(BasalRate.kcalPerDay(formula, weightKg: 0, heightCm: heightCm,
                                              age: age, sex: "male", bodyFatPercent: 18))
            XCTAssertNil(BasalRate.kcalPerDay(formula, weightKg: weightKg, heightCm: 0,
                                              age: age, sex: "male", bodyFatPercent: 18))
            XCTAssertNil(BasalRate.kcalPerDay(formula, weightKg: weightKg, heightCm: heightCm,
                                              age: 0, sex: "male", bodyFatPercent: 18))
        }
    }

    /// The switch delta is what the provenance sheet states, signed toward the new formula.
    func testTheSwitchDeltaIsSignedTowardTheNewFormula() throws {
        let delta = try XCTUnwrap(BasalRate.switchDelta(
            from: .revisedHarrisBenedict, to: .katchMcArdle, weightKg: weightKg,
            heightCm: heightCm, age: age, sex: "male", bodyFatPercent: 18))
        XCTAssertEqual(delta, 1786.96 - 1825.247, accuracy: 0.001)
        XCTAssertLessThan(delta, 0)
    }

    // MARK: - The dated log

    /// An untouched install is Harris–Benedict for all of time, so nothing changes for anyone who
    /// never switches.
    func testAnUntouchedLogIsHarrisBenedictForever() {
        let log = BmrFormulaLog.seeded
        XCTAssertEqual(log.formula(onDay: "1970-01-01"), .revisedHarrisBenedict)
        XCTAssertEqual(log.formula(onDay: "2026-09-10"), .revisedHarrisBenedict)
        XCTAssertNil(log.lastSwitchDay)
    }

    /// An empty list is seeded rather than left empty — no caller may be handed a log with no answer.
    func testAnEmptyLogIsSeeded() {
        XCTAssertEqual(BmrFormulaLog(epochs: []), .seeded)
    }

    /// THE guarantee: a switch applies from its own day forward and leaves every earlier day alone.
    func testASwitchAppliesForwardAndLeavesHistoryAlone() {
        let log = BmrFormulaLog.seeded.appending(.katchMcArdle, effectiveFrom: "2026-09-10")
        XCTAssertEqual(log.formula(onDay: "2026-09-09"), .revisedHarrisBenedict)
        XCTAssertEqual(log.formula(onDay: "2026-09-10"), .katchMcArdle)
        XCTAssertEqual(log.formula(onDay: "2026-12-31"), .katchMcArdle)
        XCTAssertEqual(log.lastSwitchDay, "2026-09-10")
    }

    /// Switching repeatedly appends; nothing is edited away, and each period keeps its own formula.
    func testRepeatedSwitchesEachKeepTheirOwnPeriod() {
        let log = BmrFormulaLog.seeded
            .appending(.mifflinStJeor, effectiveFrom: "2026-03-01")
            .appending(.katchMcArdle, effectiveFrom: "2026-09-10")
        XCTAssertEqual(log.formula(onDay: "2026-02-28"), .revisedHarrisBenedict)
        XCTAssertEqual(log.formula(onDay: "2026-03-01"), .mifflinStJeor)
        XCTAssertEqual(log.formula(onDay: "2026-09-09"), .mifflinStJeor)
        XCTAssertEqual(log.formula(onDay: "2026-09-10"), .katchMcArdle)
        XCTAssertEqual(log.epochs.count, 3)
    }

    /// A backdated switch cannot rewrite history: it is carried forward to the newest entry instead.
    /// This is the clock-moved-backwards / restored-future-log case.
    func testABackdatedSwitchIsCarriedForwardRatherThanRewritingHistory() {
        let log = BmrFormulaLog.seeded
            .appending(.mifflinStJeor, effectiveFrom: "2026-09-10")
            .appending(.katchMcArdle, effectiveFrom: "2026-01-01")
        XCTAssertEqual(log.formula(onDay: "2026-06-01"), .revisedHarrisBenedict)
        XCTAssertEqual(log.formula(onDay: "2026-09-10"), .katchMcArdle)
    }

    /// Two switches on one day: the later append wins, and the earlier is still on the record.
    func testTheLaterAppendOnOneDayWins() {
        let log = BmrFormulaLog.seeded
            .appending(.mifflinStJeor, effectiveFrom: "2026-09-10")
            .appending(.katchMcArdle, effectiveFrom: "2026-09-10")
        XCTAssertEqual(log.formula(onDay: "2026-09-10"), .katchMcArdle)
        XCTAssertEqual(log.epochs.count, 3)
    }

    /// The log survives a backup round trip. Without this a restore reverts to Harris–Benedict and the
    /// curve steps a second time with nobody having changed anything.
    func testTheLogSurvivesABackupRoundTrip() {
        let log = BmrFormulaLog.seeded
            .appending(.mifflinStJeor, effectiveFrom: "2026-03-01")
            .appending(.katchMcArdle, effectiveFrom: "2026-09-10")
        XCTAssertEqual(BmrFormulaLog.decode(log.encodedJSON()), log)
    }

    /// A corrupt or empty backup field seeds rather than leaving the energy path with no formula.
    func testACorruptBackupFieldSeeds() {
        XCTAssertEqual(BmrFormulaLog.decode(""), .seeded)
        XCTAssertEqual(BmrFormulaLog.decode("not json"), .seeded)
        XCTAssertEqual(BmrFormulaLog.decode("{\"unexpected\":1}"), .seeded)
    }
}
