import XCTest
@testable import StrandAnalytics

final class PersonalNormalTests: XCTestCase {
    /// The reported case: a recalibrated HRV baseline of 78 ms and a night of 82 ms reads as above the
    /// baseline, not as the "-6" a mean over the nights before the reset gave.
    func testABaselineComparisonReadsAgainstTheFittedBaseline() throws {
        let state = BaselineState(baseline: 78, spread: 4, nValid: 6, nightsSinceUpdate: 0, status: .provisional)
        let c = try XCTUnwrap(PersonalNormal.compare(today: 82, baseline: state, polarity: .higherIsBetter))
        XCTAssertEqual(c.normal, 78, accuracy: 1e-9)
        XCTAssertEqual(c.delta, 4, accuracy: 1e-9)
        XCTAssertEqual(c.tone, .ordinary, "4 ms is inside one robust sigma (1.253 x 4)")
        XCTAssertEqual(try XCTUnwrap(PersonalNormal.compare(today: 90, baseline: state,
                                                            polarity: .higherIsBetter)).tone, .favourable)
    }

    func testACalibratingBaselineGivesNoComparison() {
        let state = BaselineState(baseline: 78, spread: 4, nValid: 2, nightsSinceUpdate: 0, status: .calibrating)
        XCTAssertNil(PersonalNormal.compare(today: 82, baseline: state, polarity: .higherIsBetter))
        XCTAssertNil(PersonalNormal.compare(today: 82, baseline: nil, polarity: .higherIsBetter))
    }

    func testNoComparisonBeforeEnoughPriorValues() {
        XCTAssertNil(PersonalNormal.compare(today: 60, prior: [55, 56, 57], polarity: .higherIsBetter))
    }

    func testOrdinaryWobbleIsReportedButNotColoured() throws {
        let c = try XCTUnwrap(PersonalNormal.compare(today: 61, prior: [58, 62, 60, 59, 61, 60],
                                                     polarity: .higherIsBetter))
        XCTAssertEqual(c.normal, 60, accuracy: 1e-9)
        XCTAssertEqual(c.delta, 1, accuracy: 1e-9)
        XCTAssertEqual(c.tone, .ordinary)
    }

    func testNotableChangeFollowsPolarity() throws {
        let prior: [Double] = [58, 62, 60, 59, 61, 60]
        XCTAssertEqual(try XCTUnwrap(PersonalNormal.compare(today: 70, prior: prior, polarity: .higherIsBetter)).tone,
                       .favourable)
        XCTAssertEqual(try XCTUnwrap(PersonalNormal.compare(today: 70, prior: prior, polarity: .lowerIsBetter)).tone,
                       .unfavourable)
        XCTAssertEqual(try XCTUnwrap(PersonalNormal.compare(today: 70, prior: prior, polarity: .neutral)).tone,
                       .ordinary)
    }

    func testOnlyTheMostRecentWindowCounts() throws {
        let old = Array(repeating: 100.0, count: 40)
        let recent = Array(repeating: 50.0, count: PersonalNormal.window)
        let c = try XCTUnwrap(PersonalNormal.compare(today: 50, prior: old + recent, polarity: .neutral))
        XCTAssertEqual(c.normal, 50, accuracy: 1e-9)
    }

    func testSignedText() {
        XCTAssertEqual(PersonalNormal.signedText(4.4), "+4")
        XCTAssertEqual(PersonalNormal.signedText(-1.5), "-2")
        XCTAssertEqual(PersonalNormal.signedText(0.2), "±0")
        XCTAssertEqual(PersonalNormal.signedText(0.64, decimals: 1), "+0.6")
    }
}
