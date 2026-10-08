import XCTest
@testable import WhoopProtocol

final class EcgReadingCompletionTests: XCTestCase {
    func testStopDuringSaveWaitsForBothOperations() {
        var state = EcgReadingCompletion()
        let run = state.begin()
        state.beginSave()
        XCTAssertTrue(state.requestFinish())
        XCTAssertFalse(state.requestFinish())
        state.cleanedUp(run, success: true)
        XCTAssertFalse(state.canPublish)
        XCTAssertTrue(state.saved(run))
        XCTAssertTrue(state.canPublish)
    }

    func testLateSaveCannotChangeANewRun() {
        var state = EcgReadingCompletion()
        let old = state.begin()
        let current = state.begin()
        state.beginSave()
        XCTAssertFalse(state.saved(old))
        state.cleanedUp(old, success: true)
        XCTAssertTrue(state.saving)
        XCTAssertNil(state.cleanupSucceeded)
        XCTAssertTrue(state.isCurrent(current))
    }

    func testUnconfirmedCleanupCanFinishWithoutClaimingSuccess() {
        var state = EcgReadingCompletion()
        let run = state.begin()
        state.requestFinish()
        state.cleanedUp(run, success: false)
        XCTAssertTrue(state.canPublish)
        XCTAssertEqual(state.cleanupSucceeded, false)
    }
}
