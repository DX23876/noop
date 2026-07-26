import XCTest
@testable import Strand
import WhoopStore

final class CoachDataCatalogTests: XCTestCase {
    func testCatalogGroupsCoverageAndNeverLeaksOpaqueSourceIdentifier() {
        let report = CoachDataCatalog.report(entries: [
            .init(source: "watch-4F2A-serial", key: "weight", pointCount: 2,
                  earliestDay: "2023-01-05", latestDay: "2023-01-12"),
            .init(source: "apple-health", key: "weight", pointCount: 4,
                  earliestDay: "2022-12-01", latestDay: "2024-04-01")
        ])

        XCTAssertTrue(report.contains("weight: 6 points, 2022-12-01 → 2024-04-01"), report)
        XCTAssertTrue(report.contains("Apple Health"), report)
        XCTAssertTrue(report.contains("Another local import"), report)
        XCTAssertFalse(report.contains("watch-4F2A-serial"), report)
        XCTAssertFalse(report.contains("value"), report)
    }

    func testCatalogCapsKeysAndExplainsThatMoreExist() {
        let report = CoachDataCatalog.report(entries: [
            .init(source: "apple-health", key: "alpha", pointCount: 1,
                  earliestDay: "2026-01-01", latestDay: "2026-01-01"),
            .init(source: "apple-health", key: "beta", pointCount: 1,
                  earliestDay: "2026-01-01", latestDay: "2026-01-01")
        ], limit: 1)

        XCTAssertTrue(report.contains("alpha:"), report)
        XCTAssertFalse(report.contains("beta:"), report)
        XCTAssertTrue(report.contains("1 further metric keys"), report)
    }

    func testKnownLabBookProjectionGetsHelpfulButNonClinicalSourceLabel() {
        let report = CoachDataCatalog.report(entries: [
            .init(source: WhoopStore.labBookSourceId, key: "ferritin", pointCount: 3,
                  earliestDay: "2025-01-01", latestDay: "2026-01-01")
        ])

        XCTAssertTrue(report.contains("sources: Lab Book"), report)
        XCTAssertFalse(report.localizedCaseInsensitiveContains("normal"), report)
    }

    func testFocusedSearchKeepsUnrelatedCatalogMetadataOnDevice() {
        let entries: [MetricCatalogEntry] = [
            .init(source: "apple-health", key: "weight", pointCount: 20,
                  earliestDay: "2024-01-01", latestDay: "2026-01-01"),
            .init(source: "lab-book", key: "ferritin", pointCount: 4,
                  earliestDay: "2024-01-01", latestDay: "2026-01-01"),
            .init(source: "my-whoop", key: "sleep_total_min", pointCount: 100,
                  earliestDay: "2024-01-01", latestDay: "2026-01-01")
        ]

        let report = CoachDataCatalog.report(entries: entries, query: "my weight over years")
        XCTAssertTrue(report.contains("weight:"), report)
        XCTAssertFalse(report.contains("ferritin:"), report)
        XCTAssertFalse(report.contains("sleep_total_min:"), report)
    }

    func testFocusedSearchDoesNotFallBackToFullInventoryOnNoMatch() {
        let report = CoachDataCatalog.report(entries: [
            .init(source: "apple-health", key: "weight", pointCount: 2,
                  earliestDay: "2025-01-01", latestDay: "2026-01-01")
        ], query: "unrelated topic")
        XCTAssertTrue(report.contains("No locally stored metric key matched"), report)
        XCTAssertFalse(report.contains("weight:"), report)
    }

    func testLocalKeyMatchingCanFindAnImportedLabMarkerWithoutEmittingTheCatalog() {
        let key = CoachDataCatalog.bestMatchingKey(entries: [
            .init(source: "lab-book", key: "vitamin_d", pointCount: 4,
                  earliestDay: "2024-01-01", latestDay: "2026-01-01"),
            .init(source: "apple-health", key: "weight", pointCount: 20,
                  earliestDay: "2024-01-01", latestDay: "2026-01-01")
        ], query: "How has my vitamin D changed over 2 years?")

        XCTAssertEqual(key, "vitamin_d")
    }

    func testLabBookProjectionIsHiddenWithoutTheSeparateLogsGrant() {
        let entries: [MetricCatalogEntry] = [
            .init(source: "lab-book", key: "ferritin", pointCount: 4,
                  earliestDay: "2024-01-01", latestDay: "2026-01-01"),
            .init(source: "apple-health", key: "weight", pointCount: 20,
                  earliestDay: "2024-01-01", latestDay: "2026-01-01")
        ]

        let hidden = CoachDataCatalog.entriesVisibleToCoach(entries, includesLabBook: false)
        XCTAssertEqual(hidden.map(\.key), ["weight"])
        XCTAssertEqual(CoachDataCatalog.entriesVisibleToCoach(entries, includesLabBook: true).count, 2)
    }

    func testCatalogCanExposeOnlyConsentFilteredStoreMetadataWithoutEntries() {
        let report = CoachDataCatalog.report(entries: [], areas: [
            .init(name: "Workout history", summary: "12 recorded sessions"),
            .init(name: "Coach memory", summary: "3 saved facts, 5 local conversations")
        ])

        XCTAssertTrue(report.contains("OTHER GRANTED LOCAL DATA"), report)
        XCTAssertTrue(report.contains("Workout history: 12 recorded sessions"), report)
        XCTAssertFalse(report.contains("No granted local data inventory"), report)
    }

    func testFocusedMetricMissStillKeepsGrantedNonMetricStoreMetadata() {
        let report = CoachDataCatalog.report(entries: [
            .init(source: "apple-health", key: "weight", pointCount: 20,
                  earliestDay: "2024-01-01", latestDay: "2026-01-01")
        ], areas: [.init(name: "Workout history", summary: "12 recorded sessions")], query: "workouts")

        XCTAssertTrue(report.contains("No locally stored metric key matched"), report)
        XCTAssertTrue(report.contains("Workout history: 12 recorded sessions"), report)
        XCTAssertFalse(report.contains("weight:"), report)
    }
}
