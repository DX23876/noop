import XCTest
import StrandAnalytics
@testable import Strand

@MainActor
final class SleepStagerPreferenceTests: XCTestCase {
    func testDefaultAndLegacyChoicesAndExplicitV2Fallback() throws {
        let suite = "SleepStagerPreferenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PuffinExperiment.sleepStagerMethod(in: defaults), .v3)
        defaults.set(false, forKey: PuffinExperiment.experimentalSleepV2Key)
        XCTAssertEqual(PuffinExperiment.sleepStagerMethod(in: defaults), .v1)
        defaults.set(true, forKey: PuffinExperiment.experimentalSleepV2Key)
        XCTAssertEqual(PuffinExperiment.sleepStagerMethod(in: defaults), .v3)
        defaults.set("v2", forKey: PuffinExperiment.sleepStagerMethodKey)
        XCTAssertEqual(PuffinExperiment.sleepStagerMethod(in: defaults), .v2)
        XCTAssertEqual(AppAnalysisHost(defaults: defaults).analysisSettings().sleepStagerMethod, .v2)
    }
}
