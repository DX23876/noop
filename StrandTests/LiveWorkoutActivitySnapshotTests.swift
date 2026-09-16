import XCTest
@testable import Strand

/// The Lock Screen counts elapsed time from an anchor the app computes once; pauses must be taken out and
/// a paused session must show frozen time.
final class LiveWorkoutActivitySnapshotTests: XCTestCase {
    private func snapshot(pausedAt: Date?, pausedSeconds: TimeInterval) -> LiveWorkoutActivitySnapshot {
        LiveWorkoutActivitySnapshot(kind: .cardio, title: "Walking",
                                    startedAt: Date(timeIntervalSince1970: 1_000),
                                    pausedAt: pausedAt, pausedSeconds: pausedSeconds, bpm: 110, zone: 2,
                                    distanceM: 1_200, paceSecPerKm: 600, setsDone: nil, setsTotal: nil,
                                    restEndsAt: nil)
    }

    func testTheElapsedAnchorShiftsByThePausedTime() {
        let running = snapshot(pausedAt: nil, pausedSeconds: 120)
        XCTAssertEqual(running.elapsedAnchor, Date(timeIntervalSince1970: 1_120))
        XCTAssertEqual(running.activeSeconds(at: Date(timeIntervalSince1970: 1_720)), 600)
    }

    func testAPausedSessionFreezesItsElapsedTime() {
        let paused = snapshot(pausedAt: Date(timeIntervalSince1970: 1_600), pausedSeconds: 100)
        XCTAssertEqual(paused.activeSeconds(at: Date(timeIntervalSince1970: 9_999)), 500)
    }
}
