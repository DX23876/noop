import XCTest
@testable import NoopCore

/// The Android Settings pages reach the core's UserDefaults only through `CorePrefs`: known keys, Apple's ranges.
final class CorePrefsTests: XCTestCase {
    private let keys = ["goals.limit.longTerm", "training.restWeekdays", "goals.motivation.enabled", "training.weightUnit"]

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    func testWritesKnownKeysWithinTheirRanges() async {
        let ok = await CoreCall.run("prefs.write", #"{"key":"goals.limit.longTerm","value":7}"#)
        XCTAssertEqual(ok, #"{"ok":true}"#)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "goals.limit.longTerm"), 7)
        _ = await CoreCall.run("prefs.write", #"{"key":"training.restWeekdays","value":[7,2,2,9]}"#)
        XCTAssertEqual(UserDefaults.standard.array(forKey: "training.restWeekdays") as? [Int], [2, 7])
        _ = await CoreCall.run("prefs.write", #"{"key":"goals.motivation.enabled","value":false}"#)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "goals.motivation.enabled") as? Bool, false)
        let read = await CoreCall.run("prefs.read", "{}")
        XCTAssertTrue(read.contains("\"goals.limit.longTerm\":7"), read)
    }

    func testRefusesUnknownKeysAndOutOfRangeValues() async {
        let unknown = await CoreCall.run("prefs.write", #"{"key":"coach.apiKey","value":"x"}"#)
        XCTAssertEqual(unknown, #"{"ok":false}"#)
        let tooMany = await CoreCall.run("prefs.write", #"{"key":"goals.limit.longTerm","value":11}"#)
        XCTAssertEqual(tooMany, #"{"ok":false}"#)
        let unit = await CoreCall.run("prefs.write", #"{"key":"training.weightUnit","value":"stone"}"#)
        XCTAssertEqual(unit, #"{"ok":false}"#)
        XCTAssertNil(UserDefaults.standard.object(forKey: "goals.limit.longTerm"))
    }
}
