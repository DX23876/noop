import XCTest
@testable import WhoopProtocol

/// The asymmetry between the two directions of the sharing switch, pinned.
///
/// The cases below are the ones that were wrong in the field: an OFF that also took the standard
/// heart-rate service down with it, a remembered wish fired at the wrong strap, and a readout that
/// reported a strap nobody had asked as "off".
final class StrapSharingTests: XCTestCase {

    func testOnWritesBothSettings() {
        let plan = StrapSharing.plan(on: true)
        XCTAssertTrue(plan.writesService)
        XCTAssertTrue(plan.writesAdvertising)
    }

    /// The whole reason this type exists. NOOP's own live heart rate, its R-R intervals and its link
    /// liveness watchdog all ride the standard heart-rate service, so an OFF that switched it off took
    /// those away from a wearer who had only asked to stop broadcasting.
    func testOffNeverTouchesTheService() {
        let plan = StrapSharing.plan(on: false)
        XCTAssertFalse(plan.writesService, "stopping the broadcast must not switch off the service NOOP reads")
        XCTAssertTrue(plan.writesAdvertising)
    }

    func testPendingWishAppliesOnlyToTheStrapItWasMadeFor() {
        XCTAssertTrue(StrapSharing.pendingApplies(pendingDeviceId: "my-whoop", activeDeviceId: "my-whoop"))
        XCTAssertFalse(StrapSharing.pendingApplies(pendingDeviceId: "my-whoop", activeDeviceId: "spare-whoop"))
    }

    /// An unattributable write is never sent: nothing here may fall back to "the strap in front of us".
    func testPendingWishNeedsBothIds() {
        XCTAssertFalse(StrapSharing.pendingApplies(pendingDeviceId: nil, activeDeviceId: "my-whoop"))
        XCTAssertFalse(StrapSharing.pendingApplies(pendingDeviceId: "my-whoop", activeDeviceId: nil))
        XCTAssertFalse(StrapSharing.pendingApplies(pendingDeviceId: "", activeDeviceId: "my-whoop"))
        XCTAssertFalse(StrapSharing.pendingApplies(pendingDeviceId: "my-whoop", activeDeviceId: ""))
        XCTAssertFalse(StrapSharing.pendingApplies(pendingDeviceId: nil, activeDeviceId: nil))
    }

    /// Three states, never two. A strap nobody has read is UNKNOWN, and saying "off" there is the readout
    /// that made a stranded strap undiagnosable.
    func testHeaderLineKeepsUnknownApart() {
        XCTAssertEqual(StrapSharing.headerLine(stateOn: nil, age: nil),
                       "Sharing:     unknown (never read from this strap)")
        XCTAssertEqual(StrapSharing.headerLine(stateOn: nil, age: "5m ago"),
                       "Sharing:     unknown (never read from this strap)")
    }

    func testHeaderLineReportsWhatWasRead() {
        XCTAssertEqual(StrapSharing.headerLine(stateOn: true, age: "5m ago"),
                       "Sharing:     ON — the strap broadcasts its heart rate continuously · read 5m ago")
        XCTAssertEqual(StrapSharing.headerLine(stateOn: false, age: "5m ago"),
                       "Sharing:     off · read 5m ago")
        XCTAssertEqual(StrapSharing.headerLine(stateOn: false, age: nil), "Sharing:     off")
    }

    /// The label is padded to the same 13 columns as "Model:", "Firmware:" and "Last sync:", so the block
    /// still reads as a column rather than as a ragged list.
    func testHeaderLabelMatchesItsNeighbours() {
        for state in [nil, true, false] as [Bool?] {
            let line = StrapSharing.headerLine(stateOn: state, age: nil)
            XCTAssertEqual(line.prefix(13), "Sharing:     ")
            XCTAssertEqual("Model:       ".count, 13)
        }
    }
}
