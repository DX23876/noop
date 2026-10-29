import Foundation
import XCTest
import WhoopStore
@testable import NoopCore

/// #1853 on Android (parity plan 1.2): the Test Centre's skin-temp backfill runs the shared walker on the core's
/// store and reports the same line Apple logs.
final class CoreSkinTempBackfillTests: XCTestCase {
    func testAnEmptyStoreFillsNothingAndSaysSo() async throws {
        let store = try await WhoopStore.inMemory()
        let result = await SkinTempBackfillWalker(store: store).runBackfill()
        XCTAssertEqual(result.filledCount, 0)
        XCTAssertTrue(result.summary.hasPrefix("skin-temp backfill (#1853): filled 0, declined 0, no raw data 0"),
                      result.summary)
    }
}
