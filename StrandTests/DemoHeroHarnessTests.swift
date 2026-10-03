#if DEBUG
import XCTest
@testable import Strand

final class DemoHeroHarnessTests: XCTestCase {
    func testParsesThreeValuesWithDashForMissing() {
        XCTAssertEqual(DemoHeroHarness.parse(["app", "--demo-hero", "94, 40,-"]),
                       DemoHeroFixture(charge: 94, effort: 40, rest: nil))
    }

    func testClampsAndIgnoresMalformedFlags() {
        XCTAssertEqual(DemoHeroHarness.parse(["--demo-hero", "120,-5,nan"]),
                       DemoHeroFixture(charge: 100, effort: 0, rest: nil))
        XCTAssertNil(DemoHeroHarness.parse(["--demo-hero", "1,2"]))
        XCTAssertNil(DemoHeroHarness.parse(["--demo-hero"]))
        XCTAssertNil(DemoHeroHarness.parse(["--demo-seed"]))
    }
}
#endif
