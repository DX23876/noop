import XCTest
@testable import StrandAnalytics

final class PersonalNormalTests: XCTestCase {
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
