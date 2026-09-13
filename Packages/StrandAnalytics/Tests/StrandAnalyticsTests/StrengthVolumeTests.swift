import XCTest
import WhoopStore
@testable import StrandAnalytics

/// The weekly set range is the one EXTERNAL reference on a screen that otherwise compares the wearer
/// with themselves. These tests pin what it may and may not say: it judges muscles that were trained,
/// it never turns an untrained muscle into a shortfall, and it never scores a filing category.
final class StrengthVolumeTests: XCTestCase {

    func testTheBandBoundariesAreInclusive() {
        XCTAssertEqual(StrengthVolume.verdict(sets: 9), .below)
        XCTAssertEqual(StrengthVolume.verdict(sets: 10), .inside)
        XCTAssertEqual(StrengthVolume.verdict(sets: 20), .inside)
        XCTAssertEqual(StrengthVolume.verdict(sets: 21), .above)
    }

    /// A muscle nobody trained this week is not underdosed — it is untrained, which is a different
    /// statement and one the balance readings already make. Reporting it here would leave every
    /// lifter's neck and forearms permanently in the red.
    func testAnUntrainedMuscleIsNotAShortfall() {
        let readings = StrengthVolume.readings(setsByMuscle: [.chest: 12, .neck: 0])
        XCTAssertEqual(readings.map(\.group), [.chest])
        XCTAssertEqual(StrengthVolume.summary(setsByMuscle: [.chest: 12, .neck: 0]).below, 0)
    }

    /// `cardio`, `fullBody` and `other` are catalogue buckets, not body parts. A weekly set range for
    /// them would put a verdict on a filing decision.
    func testFilingCategoriesAreNeverJudged() {
        let sets: [HevyMuscleGroup: Int] = [.cardio: 30, .fullBody: 4, .other: 2, .quadriceps: 14]
        XCTAssertEqual(StrengthVolume.readings(setsByMuscle: sets).map(\.group), [.quadriceps])
        XCTAssertEqual(StrengthVolume.summary(setsByMuscle: sets).trained, 1)
    }

    /// Busiest first, and ties broken by name so the list never depends on dictionary order.
    func testReadingsAreOrderedAndCounted() {
        let sets: [HevyMuscleGroup: Int] = [.chest: 14, .biceps: 6, .quadriceps: 24, .lats: 14]
        let readings = StrengthVolume.readings(setsByMuscle: sets)
        XCTAssertEqual(readings.map(\.sets), [24, 14, 14, 6])
        XCTAssertEqual(readings.first?.verdict, .above)
        XCTAssertEqual(readings.last?.verdict, .below)

        let summary = StrengthVolume.summary(setsByMuscle: sets)
        XCTAssertEqual(summary.trained, 4)
        XCTAssertEqual(summary.inside, 2)
        XCTAssertEqual(summary.below, 1)
        XCTAssertEqual(summary.above, 1)
    }
}
