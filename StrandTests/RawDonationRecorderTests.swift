import XCTest
@testable import Strand
@testable import StrandCore

/// The recording mechanics of the raw-motion donation, driven without a strap and without waiting out
/// a workout: the clock, the strap and the stored bytes are all injected.
///
/// This does NOT answer the open hardware question (whether a 100 Hz stream during a workout disturbs
/// live heart rate or the history offload). Nothing on this machine can. What it does answer is the
/// half that would otherwise also be unknown until someone wore a strap: that the windows open and
/// close where the plan says, that a lost strap ends a window instead of leaving the producer armed,
/// and that nothing becomes a donation unless something was really recorded.
@MainActor
final class RawDonationRecorderTests: XCTestCase {

    private func environment(sports: [String] = [], keepCopy: Bool = false)
        -> (recorder: RawDonationRecorder, started: Box<[String]>, stopped: Box<Int>, clock: Clock) {
        let suite = UUID().uuidString
        let settings = RawDonationSettings(defaults: UserDefaults(suiteName: suite)!)
        for sport in sports { settings.set(sport, on: true) }
        settings.keepsLocalCopy = keepCopy
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("donation-\(suite)", isDirectory: true)
        let recorder = RawDonationRecorder(settings: settings, store: DonationStore(directory: directory))
        let started = Box<[String]>([])
        let stopped = Box(0)
        let clock = Clock()
        recorder.now = { clock.value }
        recorder.startCapture = { id in started.value.append(id); return true }
        recorder.stopCapture = { stopped.value += 1 }
        recorder.strapFamily = { (family: "whoop5", firmware: "3") }
        recorder.collectPayload = { _, _, _ in Data(repeating: 1, count: 16) }
        return (recorder, started, stopped, clock)
    }

    // MARK: Nothing without a tick

    func testAnUntickedSportNeverTouchesTheStrap() {
        let (recorder, started, _, _) = environment()
        recorder.begin(sport: "Cycling", expected: 3600)
        for second in stride(from: 0.0, through: 1800, by: 30) {
            recorder.tick(elapsed: second, strapConnected: true)
        }
        XCTAssertTrue(started.value.isEmpty, "an app nobody configured must never stream raw data")
        XCTAssertFalse(recorder.isRecordingWindow)
    }

    // MARK: The windows

    func testAWindowOpensInsideThePlanAndClosesAfterIt() async {
        let (recorder, started, stopped, _) = environment(sports: ["Cycling"])
        recorder.begin(sport: "Cycling", expected: 3600)
        let windows = RawDonationPlan.windows(expected: 3600)
        let first = try! XCTUnwrap(windows.first)

        recorder.tick(elapsed: first.startOffset - 5, strapConnected: true)
        XCTAssertFalse(recorder.isRecordingWindow, "nothing before the window")
        XCTAssertTrue(started.value.isEmpty)

        recorder.tick(elapsed: first.startOffset + 1, strapConnected: true)
        XCTAssertTrue(recorder.isRecordingWindow)
        XCTAssertEqual(started.value.count, 1)

        recorder.tick(elapsed: first.endOffset + 1, strapConnected: true)
        XCTAssertFalse(recorder.isRecordingWindow, "the window closes on its own")
        await recorder.pendingStop?.value
        XCTAssertEqual(stopped.value, 1)
    }

    func testTheStrapGoingAwayEndsTheWindowRatherThanLeavingItArmed() async {
        let (recorder, _, stopped, _) = environment(sports: ["Running"])
        recorder.begin(sport: "Running", expected: 3600)
        let first = RawDonationPlan.windows(expected: 3600)[0]
        recorder.tick(elapsed: first.startOffset + 1, strapConnected: true)
        XCTAssertTrue(recorder.isRecordingWindow)
        recorder.tick(elapsed: first.startOffset + 2, strapConnected: false)
        XCTAssertFalse(recorder.isRecordingWindow)
        await recorder.pendingStop?.value
        XCTAssertEqual(stopped.value, 1)
    }

    // MARK: What a finished workout leaves

    func testAWorkoutThatRecordedNothingLeavesNoDonation() async {
        let (recorder, _, _, _) = environment(sports: ["Cycling"])
        recorder.begin(sport: "Cycling", expected: 3600)
        await recorder.finish()
        XCTAssertTrue(recorder.pending.isEmpty)
    }

    func testAFewSecondsAreNotWorthADonation() async {
        let (recorder, _, _, clock) = environment(sports: ["Cycling"])
        recorder.begin(sport: "Cycling", expected: 3600)
        let first = RawDonationPlan.windows(expected: 3600)[0]
        recorder.tick(elapsed: first.startOffset + 1, strapConnected: true)
        clock.advance(10)
        recorder.tick(elapsed: first.endOffset + 1, strapConnected: true)
        await recorder.finish()
        XCTAssertTrue(recorder.pending.isEmpty, "ten seconds teaches a detector nothing")
    }

    func testARecordedWindowBecomesOnePendingDonationWithACode() async {
        let (recorder, _, _, clock) = environment(sports: ["Cycling"])
        recorder.begin(sport: "Cycling", expected: 3600)
        let windows = RawDonationPlan.windows(expected: 3600)
        for window in windows {
            recorder.tick(elapsed: window.startOffset + 1, strapConnected: true)
            clock.advance(window.duration)
            recorder.tick(elapsed: window.endOffset + 1, strapConnected: true)
        }
        await recorder.finish()

        XCTAssertEqual(recorder.pending.count, 1)
        let donation = try! XCTUnwrap(recorder.pending.first)
        XCTAssertEqual(donation.sport, "Cycling")
        XCTAssertEqual(donation.strapFamily, "whoop5")
        XCTAssertTrue(RawDonationCode.isValid(donation.code))
        XCTAssertGreaterThanOrEqual(donation.recordedSeconds, Int(RawDonationPlan.windowSeconds) * 3)
        XCTAssertNil(donation.sentAt, "a finished recording is not a sent one")
    }

    func testNothingLeavesByItself() async {
        // The recorder has no upload path at all: the only way out is the page's send button, and that
        // one is hidden without a service address. The absence is the assertion.
        let (recorder, _, _, clock) = environment(sports: ["Walking"])
        recorder.begin(sport: "Walking", expected: 600)
        let window = RawDonationPlan.windows(expected: 600)[0]
        recorder.tick(elapsed: window.startOffset + 1, strapConnected: true)
        clock.advance(window.duration)
        await recorder.finish()
        XCTAssertEqual(recorder.pending.count, 1)
        XCTAssertNil(recorder.pending.first?.sentAt)
    }

    // MARK: After sending

    func testTheLocalCopyGoesUnlessTheWearerAskedToKeepIt() async {
        for keep in [false, true] {
            let (recorder, _, _, clock) = environment(sports: ["Hiking"], keepCopy: keep)
            recorder.begin(sport: "Hiking", expected: 600)
            let window = RawDonationPlan.windows(expected: 600)[0]
            recorder.tick(elapsed: window.startOffset + 1, strapConnected: true)
            clock.advance(window.duration)
            await recorder.finish()
            let donation = try! XCTUnwrap(recorder.pending.first)

            recorder.markSent(donation)
            if keep {
                XCTAssertEqual(recorder.pending.count, 1)
                XCTAssertNotNil(recorder.pending.first?.sentAt)
            } else {
                XCTAssertTrue(recorder.pending.isEmpty, "raw motion is the heaviest thing NOOP stores")
            }
        }
    }

    func testDeletingARecordingRemovesIt() async {
        let (recorder, _, _, clock) = environment(sports: ["Rowing"])
        recorder.begin(sport: "Rowing", expected: 600)
        let window = RawDonationPlan.windows(expected: 600)[0]
        recorder.tick(elapsed: window.startOffset + 1, strapConnected: true)
        clock.advance(window.duration)
        await recorder.finish()
        let donation = try! XCTUnwrap(recorder.pending.first)
        recorder.forget(donation)
        XCTAssertTrue(recorder.pending.isEmpty)
    }
}

/// A clock a test can move by hand.
final class Clock {
    private(set) var value = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { value = value.addingTimeInterval(seconds) }
}

/// A mutable box for what the injected closures recorded.
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
