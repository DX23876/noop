import XCTest
import StrandAnalytics
import WhoopStore
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

    private func restoredMethod(legacyV2: Bool? = nil, explicit: SleepStager.Method? = nil) throws
        -> SleepStager.Method {
        let sourceSuite = "SleepStagerBackupSource-\(UUID().uuidString)"
        let destinationSuite = "SleepStagerBackupDestination-\(UUID().uuidString)"
        let source = try XCTUnwrap(UserDefaults(suiteName: sourceSuite))
        let destination = try XCTUnwrap(UserDefaults(suiteName: destinationSuite))
        defer {
            source.removePersistentDomain(forName: sourceSuite)
            destination.removePersistentDomain(forName: destinationSuite)
        }
        if let legacyV2 { source.set(legacyV2, forKey: PuffinExperiment.experimentalSleepV2Key) }
        if let explicit { source.set(explicit.rawValue, forKey: PuffinExperiment.sleepStagerMethodKey) }

        let payload = try XCTUnwrap(DataBackup.currentSettingsJSON(defaults: source))
        let decoded = BackupSettings.decode(payload)
        XCTAssertEqual(decoded["sleep.stagerMethod"] as? String,
                       PuffinExperiment.sleepStagerMethod(in: source).rawValue)
        BackupSettings.apply(decoded, to: destination)
        return PuffinExperiment.sleepStagerMethod(in: destination)
    }

    func testBackupPreservesClassicFromAnUnmigratedLegacyPreference() throws {
        XCTAssertEqual(try restoredMethod(legacyV2: false), .v1)
    }

    func testBackupMaterializesTheFreshInstallV3Default() throws {
        XCTAssertEqual(try restoredMethod(), .v3)
    }

    func testBackupPreservesTheExplicitV2FallbackOverLegacyClassic() throws {
        XCTAssertEqual(try restoredMethod(legacyV2: false, explicit: .v2), .v2)
    }
}
