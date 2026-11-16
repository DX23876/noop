import XCTest
@testable import Strand

/// "Disconnected and removed every synced session" is a sentence about the store, said by someone who
/// did not look. `deleteAllHevyData` was called with `try?` and the line printed either way, so a
/// deletion the store refused was reported as done — to the one person who asked for no trace left.
@MainActor
final class HevyForgetReportTests: XCTestCase {

    func testARefusedDeletionIsNotReportedAsRemoved() async {
        let model = HevyConnectModel()
        await model.forgetEverything(delete: { false }, refresh: {})

        XCTAssertTrue(model.failed, "the card tints it, because something is still here")
        XCTAssertEqual(model.message?.contains("could not"), true)
        XCTAssertFalse(model.isConnected, "the key is gone either way, which is the half that worked")
    }

    func testARemovalThatHappenedIsReportedPlainly() async {
        let model = HevyConnectModel()
        await model.forgetEverything(delete: { true }, refresh: {})

        XCTAssertFalse(model.failed)
        XCTAssertEqual(model.message?.contains("removed"), true)
        XCTAssertFalse(model.isConnected)
    }
}
