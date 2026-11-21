import XCTest
import OuraProtocol
import StrandAnalytics
import WhoopStore
@testable import Strand

/// #2075: the Live Console must read out the ACTIVE device, not whichever field happens to be populated.
///
/// `LiveState` is one object every live source writes into, so a bonded WHOOP sitting beside a streaming
/// Oura ring leaves every WHOOP-only field truthful-looking while the console is naming the ring. The
/// report was a ring on 93% displaying the strap's 72% under "Oura Ring 5", with a WHOOP pairing pill.
///
/// Mirrors Android `LiveConsoleReadoutTest` case-for-case.
final class LiveConsoleReadoutTests: XCTestCase {

    private func device(_ id: String, _ brand: String) -> PairedDevice {
        PairedDevice(id: id, brand: brand, model: "m", nickname: nil, peripheralId: nil,
                     sourceKind: .liveBLE, capabilities: [.hr],
                     status: .active, addedAt: 1000, lastSeenAt: 1000)
    }

    // MARK: - activeIsWhoop

    func testAnOuraActiveDeviceIsNotAWhoop() {
        let rows = [device("my-whoop", "WHOOP"), device("oura-123", "Oura")]
        XCTAssertFalse(LiveConsoleReadout.activeIsWhoop(devices: rows, activeId: "oura-123"))
        XCTAssertTrue(LiveConsoleReadout.activeIsWhoop(devices: rows, activeId: "my-whoop"))
    }

    func testTheLegacySeededRowIsAWhoopWhateverItsBrandSays() {
        // SourceIdentity's rule: the seeded id counts even if the brand column is blank.
        XCTAssertTrue(LiveConsoleReadout.activeIsWhoop(devices: [device("my-whoop", "")], activeId: "my-whoop"))
    }

    func testAnUnresolvableActiveDeviceStaysWhoopFirst() {
        // Before the registry opens, the console already names "WHOOP"; the gate must agree rather than
        // blanking a working strap's readouts on a cold start.
        XCTAssertTrue(LiveConsoleReadout.activeIsWhoop(devices: [], activeId: nil))
        XCTAssertTrue(LiveConsoleReadout.activeIsWhoop(devices: [], activeId: "oura-123"))
    }

    func testBrandMatchingIsCaseInsensitive() {
        XCTAssertTrue(LiveConsoleReadout.activeIsWhoop(devices: [device("w1", "whoop")], activeId: "w1"))
        XCTAssertFalse(LiveConsoleReadout.activeIsWhoop(devices: [device("o1", "OURA")], activeId: "o1"))
    }

    // MARK: - activeIsOura (#2305)

    func testAnOuraActiveDeviceIsARing() {
        let rows = [device("my-whoop", "WHOOP"), device("oura-123", "Oura")]
        XCTAssertTrue(LiveConsoleReadout.activeIsOura(devices: rows, activeId: "oura-123"))
        XCTAssertFalse(LiveConsoleReadout.activeIsOura(devices: rows, activeId: "my-whoop"))
    }

    func testAnUnresolvableActiveDeviceIsNotARing() {
        // The opposite default to activeIsWhoop: a ring-only affordance must not appear for a device the
        // registry cannot name — there would be nothing for "Reconnect ring" to reach.
        XCTAssertFalse(LiveConsoleReadout.activeIsOura(devices: [], activeId: nil))
        XCTAssertFalse(LiveConsoleReadout.activeIsOura(devices: [], activeId: "oura-123"))
    }

    func testAThirdBrandIsNeitherWhoopNorRing() {
        let rows = [device("polar-1", "Polar")]
        XCTAssertFalse(LiveConsoleReadout.activeIsWhoop(devices: rows, activeId: "polar-1"))
        XCTAssertFalse(LiveConsoleReadout.activeIsOura(devices: rows, activeId: "polar-1"))
    }

    func testRingBrandMatchingIsCaseInsensitive() {
        XCTAssertTrue(LiveConsoleReadout.activeIsOura(devices: [device("o1", "OURA")], activeId: "o1"))
        XCTAssertTrue(LiveConsoleReadout.activeIsOura(devices: [device("o2", "oura")], activeId: "o2"))
    }

    // MARK: - batteryPercent

    func testAWhoopActiveDeviceShowsTheStrapCharge() {
        XCTAssertEqual(
            LiveConsoleReadout.batteryPercent(activeIsWhoop: true, whoopPct: 72.4, ringPct: 93), 72)
    }

    /// ROUNDS, it does not truncate. The surfaces this seam replaced disagreed: Devices and the widget
    /// rounded, the Live Console truncated. Folding them onto a truncating seam would have quietly moved
    /// five readouts down by a point, which is the kind of change nobody reports and everyone notices.
    func testTheChargeIsRoundedNotTruncated() {
        XCTAssertEqual(LiveConsoleReadout.batteryPercent(activeIsWhoop: true, whoopPct: 72.6, ringPct: nil), 73)
        XCTAssertEqual(LiveConsoleReadout.batteryPercent(activeIsWhoop: true, whoopPct: 72.4, ringPct: nil), 72)
        // The exact half goes up, matching Kotlin's Math.round over a positive percentage.
        XCTAssertEqual(LiveConsoleReadout.batteryPercent(activeIsWhoop: true, whoopPct: 72.5, ringPct: nil), 73)
        XCTAssertEqual(LiveConsoleReadout.batteryPercent(activeIsWhoop: true, whoopPct: 99.7, ringPct: nil), 100)
    }

    func testARingActiveDeviceShowsTheRingCharge() {
        // The reported numbers exactly: ring 93, strap 72.40, console showed 72.
        XCTAssertEqual(
            LiveConsoleReadout.batteryPercent(activeIsWhoop: false, whoopPct: 72.4, ringPct: 93), 93)
    }

    func testARingActiveDeviceNeverFallsBackToTheStrapCharge() {
        // The heart of it. Nothing is the honest answer; the strap's number under the ring's name is a
        // confident lie, and is the bug.
        XCTAssertNil(
            LiveConsoleReadout.batteryPercent(activeIsWhoop: false, whoopPct: 72.4, ringPct: nil))
    }

    /// The Devices list asks this PER ROW rather than of the active
    /// device, which is the stronger question there because the row itself is in hand. Composed here so
    /// the two halves are pinned together the way the screen actually uses them.
    /// Calls `SourceIdentity.isWhoop` directly, where the screens call `SourceCoordinator.isWhoop`.
    /// That wrapper is main-actor isolated, so a synchronous test cannot reach it, and it delegates to
    /// this verbatim with no logic of its own — so the behaviour under test is the same one.
    func testARingRowShowsTheRingChargeEvenWhenTheStrapReportedOne() {
        let ring = device("oura-123", "Oura")
        let strap = device("my-whoop", "WHOOP")
        XCTAssertEqual(
            LiveConsoleReadout.batteryPercent(activeIsWhoop: SourceIdentity.isWhoop(ring),
                                              whoopPct: 72.4, ringPct: 93), 93)
        XCTAssertEqual(
            LiveConsoleReadout.batteryPercent(activeIsWhoop: SourceIdentity.isWhoop(strap),
                                              whoopPct: 72.4, ringPct: 93), 72)
    }

    func testAWhoopActiveDeviceIgnoresAnyRingCharge() {
        // Symmetry: a ring that reported earlier must not leak into a strap's readout either.
        XCTAssertNil(
            LiveConsoleReadout.batteryPercent(activeIsWhoop: true, whoopPct: nil, ringPct: 93))
    }
    // MARK: - rollingRMSSD

    /// The console states this figure on the live page and the old console states it beside the R-R
    /// trace. One resolver, or the two can drift apart without anyone noticing.
    func testTheRollingRMSSDIsTheTaskForceFigureOverTheLastIntervals() {
        // Successive differences of 20 ms throughout: RMSSD is 20 whatever the window holds.
        let steady = (0..<20).map { 800 + ($0 % 2) * 20 }
        XCTAssertEqual(LiveConsoleReadout.rollingRMSSD(steady) ?? 0, 20, accuracy: 1e-9)
        // And it agrees with the package the whole app measures HRV with, over the same window.
        let window = steady.suffix(LiveConsoleReadout.rmssdWindow).map(Double.init)
        XCTAssertEqual(LiveConsoleReadout.rollingRMSSD(steady) ?? 0,
                       HRVAnalyzer.rmssdRaw(Array(window)) ?? -1, accuracy: 1e-9)
    }

    func testTheRollingRMSSDOnlyReadsTheRecentWindowAndWaitsForEnoughIntervals() {
        // Older intervals outside the window cannot move it: a wild prefix, a calm window.
        let calmWindow = [200, 1400, 200] + Array(repeating: 800, count: LiveConsoleReadout.rmssdWindow)
        XCTAssertEqual(LiveConsoleReadout.rollingRMSSD(calmWindow) ?? -1, 0, accuracy: 1e-9)
        XCTAssertNil(LiveConsoleReadout.rollingRMSSD([]))
        XCTAssertNil(LiveConsoleReadout.rollingRMSSD([800, 820]), "two intervals are one difference")
        XCTAssertNotNil(LiveConsoleReadout.rollingRMSSD([800, 820, 800]))
    }

    // MARK: - isLiveLink / isWorn

    /// #218: a ring streams live HR WITHOUT a WHOOP bond, so `activeConnection` is false for it by
    /// construction and every surface that forgot the second half read "—" mid-stream.
    func testARingStreamingWithoutABondIsStillALiveLink() {
        XCTAssertTrue(LiveConsoleReadout.isLiveLink(activeConnection: false, connected: true,
                                                    streamingLiveHR: true))
        XCTAssertTrue(LiveConsoleReadout.isLiveLink(activeConnection: true, connected: false,
                                                    streamingLiveHR: false), "a bonded strap is a link")
        XCTAssertFalse(LiveConsoleReadout.isLiveLink(activeConnection: false, connected: false,
                                                     streamingLiveHR: true),
                       "a stream flag that outlived its connection is not a link")
        XCTAssertFalse(LiveConsoleReadout.isLiveLink(activeConnection: false, connected: true,
                                                     streamingLiveHR: false))
    }

    func testTheRingsOwnWearStateWinsAndAStaleWristOffDoesNotSurviveAStream() {
        XCTAssertFalse(LiveConsoleReadout.isWorn(ouraWearState: .off, worn: true, connected: true,
                                                 streamingLiveHR: true),
                       "the ring says it is off the finger, and it knows better than a strap's flag")
        XCTAssertTrue(LiveConsoleReadout.isWorn(ouraWearState: .worn, worn: false, connected: false,
                                                streamingLiveHR: false))
        XCTAssertTrue(LiveConsoleReadout.isWorn(ouraWearState: nil, worn: false, connected: true,
                                                streamingLiveHR: true),
                      "a live stream is itself the wear signal when nothing else reports it")
        XCTAssertFalse(LiveConsoleReadout.isWorn(ouraWearState: nil, worn: false, connected: false,
                                                 streamingLiveHR: true))
        XCTAssertTrue(LiveConsoleReadout.isWorn(ouraWearState: nil, worn: true, connected: false,
                                                streamingLiveHR: false))
    }
}
