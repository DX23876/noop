import XCTest
@testable import Strand

/// The Charge drivers keep fixed English read-outs for the coach and the analytics tests; the new design's
/// pages print them in the reader's language.
final class ForgeTodayDriverTextTests: XCTestCase {
    private let german = Locale(identifier: "de_DE")
    private let english = Locale(identifier: "en_US")

    func testDecimalMarkFollowsTheLocale() {
        XCTAssertEqual(ForgeToday.driverValue("15.3 br/min", locale: german), "15,3 /min")
        XCTAssertEqual(ForgeToday.driverValue("15.3 br/min", locale: english), "15.3 /min")
    }

    func testWholeNumbersAreUntouched() {
        XCTAssertEqual(ForgeToday.driverValue("96 ms", locale: german), "96 ms")
    }

    func testDeviationDropsTheEnglishSuffix() {
        let text = ForgeToday.driverValue("-0.2 C vs baseline", locale: german, temperatureUnit: .celsius)
        XCTAssertFalse(text.contains("baseline"))
        XCTAssertTrue(text.contains("-0,2 °C"))
    }

    /// A difference converts by 9/5 with no +32 offset: +0.5 °C is +0.9 °F.
    func testDeviationFollowsTheReadersUnit() {
        let text = ForgeToday.driverValue("+0.5 C vs baseline", locale: english, temperatureUnit: .fahrenheit)
        XCTAssertTrue(text.contains("+0.9 °F"), text)
        XCTAssertFalse(text.contains("°C"))
    }

    func testUsualDropsTheWordBaseline() {
        let text = ForgeToday.driverUsual("15.0 br/min baseline", locale: german)
        XCTAssertFalse(text.contains("baseline"))
        XCTAssertTrue(text.contains("15,0 /min"))
    }
}
