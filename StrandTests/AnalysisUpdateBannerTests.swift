import XCTest
@testable import Strand

/// The Today card shows only while an analysis migration runs, and states an outcome only for a pass
/// it was showing. The gate is the pure `kind(of:)`; these pin which engine phases open it.
final class AnalysisUpdateBannerTests: XCTestCase {

    func testOnlyAnAnalysisMigrationShowsTheCard() {
        XCTAssertEqual(AnalysisUpdateBanner.kind(of: .migrating(from: 20, to: 26)), .running)
        // The manual 21-day recalculation shows its progress in Settings, where it was started.
        XCTAssertEqual(AnalysisUpdateBanner.kind(of: .manualRecent), .quiet)
        // A launch check, a refresh of today's activity and idle are routine, not a migration.
        XCTAssertEqual(AnalysisUpdateBanner.kind(of: .checking), .quiet)
        XCTAssertEqual(AnalysisUpdateBanner.kind(of: .refreshingToday), .quiet)
        XCTAssertEqual(AnalysisUpdateBanner.kind(of: .idle), .quiet)
    }

    func testEndingsCarryTheirOutcome() {
        XCTAssertEqual(AnalysisUpdateBanner.kind(of: .completed(Date())), .ended(.finished))
        XCTAssertEqual(AnalysisUpdateBanner.kind(of: .failed("disk full")), .ended(.failed("disk full")))
    }
}
