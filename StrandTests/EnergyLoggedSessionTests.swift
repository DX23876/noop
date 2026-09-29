import XCTest
import SwiftUI
import StrandAnalytics
import WhoopStore
@testable import Strand

/// The app-side half of "does the Energy screen count my workouts?": how a stored `WorkoutRow` becomes
/// something the engine can price, and what the card is allowed to claim when nothing measured a day.
///
/// The arithmetic itself lives in `StrandAnalytics` and is tested there, where CI runs it. What is
/// tested here is the mapping and the wording — both app-target, both easy to get quietly wrong.
final class EnergyLoggedSessionTests: XCTestCase {
    private let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")

    private func row(sport: String = "Strength", source: String = "manual",
                     kcal: Double? = nil, avgHr: Int? = nil,
                     minutes: Int = 60) -> WorkoutRow {
        WorkoutRow(startTs: 1_756_000_000, endTs: 1_756_000_000 + minutes * 60, sport: sport,
                   source: source, durationS: Double(minutes * 60), energyKcal: kcal, avgHr: avgHr,
                   maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    // MARK: - Which lane a row arrived through

    func testEveryWorkoutSourceMapsToALaneWithAStatedEnergyConvention() {
        XCTAssertEqual(Repository.contributionSource("apple-health"), .apple)
        XCTAssertEqual(Repository.contributionSource("apple_health"), .apple)
        XCTAssertEqual(Repository.contributionSource("whoop"), .whoop)
        XCTAssertEqual(Repository.contributionSource("manual"), .manual)
        XCTAssertEqual(Repository.contributionSource("native-training-1"), .manual)
        XCTAssertEqual(Repository.contributionSource("my-whoop-noop"), .detected)
        XCTAssertEqual(Repository.contributionSource("lifting"), .lifting)
        XCTAssertEqual(Repository.contributionSource("activity-file"), .activityFile)
        XCTAssertEqual(Repository.contributionSource("oura-api"), .oura)
        // Apple (and Oura, which writes the same figure into Apple Health) report energy ABOVE resting;
        // every other lane's figure still contains the bout's own resting energy. Getting this backwards
        // would quietly double-count an hour of basal.
        XCTAssertFalse(ActivityContribution.Source.apple.includesRestingEnergy)
        XCTAssertFalse(ActivityContribution.Source.oura.includesRestingEnergy)
        for source in ActivityContribution.Source.allCases where source != .apple && source != .oura {
            XCTAssertTrue(source.includesRestingEnergy, "\(source)")
        }
    }

    // MARK: - Precedence: recorded, then heart rate, then the table

    func testARecordedFigureIsUsedAsRecorded() {
        let contribution = Repository.activityContribution(
            row(kcal: 420, avgHr: 140), profile: profile, hrMax: 190, restingHR: 55)
        XCTAssertEqual(contribution?.kcal ?? 0, 420, accuracy: 0.001)
        XCTAssertEqual(contribution?.isEstimated, false)
    }

    /// With the day's aerobic ceiling a session's average heart rate prices it; without one (a day no
    /// strap covered) the table does, above the wearer's own basal rate.
    func testAnAverageHeartRateIsUsedBeforeTheTable() throws {
        let fromHR = Repository.activityContribution(
            row(avgHr: 150), profile: profile, hrMax: 190, restingHR: 55, peakMET: 10)
        let fromTable = Repository.activityContribution(
            row(), profile: profile, hrMax: 190, restingHR: 55, peakMET: 10)
        XCTAssertEqual(fromHR?.isEstimated, true)
        XCTAssertEqual(fromTable?.isEstimated, true)
        // A hard hour must not be priced the same as the table's idea of an average one.
        XCTAssertNotEqual(fromHR?.kcal ?? 0, fromTable?.kcal ?? 0, accuracy: 1)
        let basal = try XCTUnwrap(Calories.bmrKcalPerDay(profile: profile)) / 24
        let active: Double = (ActivityMETCatalog.met(forSport: "Strength") - 1) * 3.5 * 80 / 200 * 60
        XCTAssertEqual(fromTable?.kcal ?? 0, basal + active, accuracy: 0.001)
        // No ceiling: the heart rate cannot be read, and the table answers.
        let noCeiling = Repository.activityContribution(
            row(avgHr: 150), profile: profile, hrMax: 190, restingHR: 55)
        XCTAssertEqual(noCeiling?.kcal ?? 0, basal + active, accuracy: 0.001)
    }

    func testASessionThatCannotBePricedAtAllIsDroppedRatherThanZeroed() {
        let noBodyMass = UserProfile(weightKg: 0, heightCm: 0, age: 0, sex: "nonbinary")
        XCTAssertNil(Repository.activityContribution(row(), profile: noBodyMass,
                                                     hrMax: nil, restingHR: nil))
    }

    // MARK: - What the card may claim

    func testTheCardOnlyBlamesAMissingDeviceWhenThereIsNoStrap() {
        let base: LocalizedStringKey = "Estimated from steps: no device recorded energy today."
        let now = Date()
        let today = Repository.localDayKey(now)
        let yesterday = Repository.localDayKey(now.addingTimeInterval(-86_400))
        let notSynced: LocalizedStringKey =
            "Your strap hasn't synced today yet — this is an estimate until it does."

        // No strap paired: the original sentence is true, and stays.
        XCTAssertEqual(EnergyCard.unmeasuredNote(base: base, strapPaired: false, lastStrapSync: nil,
                                                 day: today, now: now), base)
        // A paired strap that has not synced today: NOOP cannot claim the strap recorded nothing.
        XCTAssertEqual(EnergyCard.unmeasuredNote(base: base, strapPaired: true, lastStrapSync: nil,
                                                 day: today, now: now), notSynced)
        XCTAssertEqual(EnergyCard.unmeasuredNote(base: base, strapPaired: true,
                                                 lastStrapSync: now.addingTimeInterval(-86_400),
                                                 day: today, now: now), notSynced)
        // Synced today and still nothing: that IS attributable.
        XCTAssertEqual(EnergyCard.unmeasuredNote(base: base, strapPaired: true, lastStrapSync: now,
                                                 day: today, now: now), base)
        // A past day is finished being measured; no sync is going to change it.
        XCTAssertEqual(EnergyCard.unmeasuredNote(base: base, strapPaired: true, lastStrapSync: nil,
                                                 day: yesterday, now: now), base)
    }
}
