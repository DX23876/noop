import XCTest
@testable import Strand

/// Pins `Repository.resolveWeightKg`'s three-tier fallback (imported Apple Health reading → 90-day series
/// fallback → profile weight) — the shared selector classic Today, Liquid Today, and Heute all now call,
/// so the three screens can't disagree about which weight to show for the same day.
final class RepositoryWeightResolutionTests: XCTestCase {

    func testPrefersLatestAppleWeightWhenRealistic() {
        let resolved = Repository.resolveWeightKg(latestAppleWeightKg: 82.4, seriesFallbackKg: 80.0,
                                                   profileWeightKg: 75.0)
        XCTAssertEqual(resolved.kg, 82.4)
        XCTAssertFalse(resolved.isFromProfile)
    }

    func testFallsBackToSeriesWhenNoLatestReading() {
        let resolved = Repository.resolveWeightKg(latestAppleWeightKg: nil, seriesFallbackKg: 79.1,
                                                   profileWeightKg: 75.0)
        XCTAssertEqual(resolved.kg, 79.1)
        XCTAssertFalse(resolved.isFromProfile)
    }

    func testFallsBackToProfileWhenNothingRealisticExists() {
        let resolved = Repository.resolveWeightKg(latestAppleWeightKg: nil, seriesFallbackKg: nil,
                                                   profileWeightKg: 75.0)
        XCTAssertEqual(resolved.kg, 75.0)
        XCTAssertTrue(resolved.isFromProfile)
    }

    /// A stray 0/garbage sample (< 10 kg) must not win over a good series value or the profile — the same
    /// guard classic Today's original `weightTile` applied inline.
    func testIgnoresUnrealisticLatestReading() {
        let resolved = Repository.resolveWeightKg(latestAppleWeightKg: 0.4, seriesFallbackKg: 78.0,
                                                   profileWeightKg: 75.0)
        XCTAssertEqual(resolved.kg, 78.0)
        XCTAssertFalse(resolved.isFromProfile)
    }

    func testIgnoresUnrealisticSeriesFallback() {
        let resolved = Repository.resolveWeightKg(latestAppleWeightKg: nil, seriesFallbackKg: 2.0,
                                                   profileWeightKg: 75.0)
        XCTAssertEqual(resolved.kg, 75.0)
        XCTAssertTrue(resolved.isFromProfile)
    }
}
