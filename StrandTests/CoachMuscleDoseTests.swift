import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// The weekly per-muscle volume line the Coach reads beside its 28-day set counts.
final class CoachMuscleDoseTests: XCTestCase {

    func testTwentyEightDaysBecomeFractionalSetsPerWeekNewestHeaviestFirst() {
        let lines = CoachMuscleDose.lines(primary: [.chest: 16, .lats: 8], secondary: [.triceps: 8, .chest: 4],
                                          days: 28)
        XCTAssertEqual(lines.count, 2)
        // chest 16 + 4 × 0.5 = 18 over 4 weeks = 4.5; lats 8 / 4 = 2; triceps 8 × 0.5 / 4 = 1
        XCTAssertTrue(lines[0].hasSuffix(": \(HevyMuscleGroup.chest.label) 4.5, \(HevyMuscleGroup.lats.label) 2.0, "
                                         + "\(HevyMuscleGroup.triceps.label) 1.0."), lines[0])
        XCTAssertTrue(lines[1].contains("below about 4 sets per week"), lines[1])
        XCTAssertTrue(lines[1].contains("not a prescription"), lines[1])
    }

    func testNothingAttributedSaysNothing() {
        XCTAssertEqual(CoachMuscleDose.lines(primary: [:], secondary: [:], days: 28), [])
        XCTAssertEqual(CoachMuscleDose.lines(primary: [.other: 6], secondary: [:], days: 28), [])
        XCTAssertEqual(CoachMuscleDose.lines(primary: [.chest: 6], secondary: [:], days: 0), [])
    }
}
