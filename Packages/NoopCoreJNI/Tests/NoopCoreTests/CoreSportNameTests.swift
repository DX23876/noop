import XCTest
@testable import NoopCore

final class CoreSportNameTests: XCTestCase {
    override func tearDown() { CoreLocalization.load(nil, language: nil) }

    func testASportReadsInTheLoadedLanguage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sport-de-\(UUID().uuidString).l10n")
        try Data(#"{"Strength Training":"Krafttraining","sport.running":"Laufen","Running":"Läuft","sport.football":"Fußball"}"#.utf8)
            .write(to: url)
        CoreLocalization.load(url, language: "de")
        XCTAssertEqual(CoreSportName.name("StrengthTraining"), "Krafttraining")
        XCTAssertEqual(CoreSportName.name("Running"), "Laufen", "the sport, not the state word")
        XCTAssertEqual(CoreSportName.name("Football"), "Fußball")
        XCTAssertEqual(CoreSportName.name("Push day"), "Push day", "a name the wearer typed passes through")
    }

    func testEnglishShipsNoTable() {
        CoreLocalization.load(nil, language: nil)
        XCTAssertEqual(CoreSportName.name("TraditionalStrengthTraining"), "Traditional Strength Training")
        XCTAssertEqual(CoreSportName.name("Running"), "Running")
        XCTAssertEqual(CoreSportName.name("detected"), "Activity")
    }
}
