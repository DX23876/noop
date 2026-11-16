import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// An answer the store did not keep must not stay on the screen as recorded.
///
/// The same defect the gym report of 2026-11-16 was: the screen holds the change, the store refused the
/// write, and nothing says so. Here it is one tap quieter — the muscle-recovery answer is appended to
/// `feedback`, the bars refit around it, and the save is attempted afterwards with its failure dropped.
/// The answer then survives exactly until the next launch.
@MainActor
final class MuscleFeedbackPersistenceTests: XCTestCase {

    func testARefusedAnswerIsTakenBackOffTheScreen() async {
        let model = StrengthModel()
        await model.record(.clearlyTired, for: .chest, repo: Repository(deviceId: "test-refused"),
                           save: { _ in false })

        XCTAssertTrue(model.feedback.isEmpty, "an answer the store refused is not an answer it has")
        XCTAssertTrue(model.feedbackRefused, "and the screen says so rather than keeping it quiet")
    }

    func testAnAcceptedAnswerStaysAndNothingIsSaid() async {
        let model = StrengthModel()
        await model.record(.fresh, for: .chest, repo: Repository(deviceId: "test-accepted"),
                           save: { _ in true })

        XCTAssertEqual(model.feedback.map(\.group), [.chest])
        XCTAssertEqual(model.feedback.map(\.feeling), [.fresh])
        XCTAssertFalse(model.feedbackRefused)
    }

    /// A second answer after a refused one clears the line, so it belongs to the attempt it came from.
    func testTheNoticeBelongsToTheLastAttempt() async {
        let model = StrengthModel()
        let repo = Repository(deviceId: "test-twice")
        await model.record(.clearlyTired, for: .lats, repo: repo, save: { _ in false })
        XCTAssertTrue(model.feedbackRefused)
        await model.record(.fresh, for: .lats, repo: repo, save: { _ in true })
        XCTAssertFalse(model.feedbackRefused)
        XCTAssertEqual(model.feedback.count, 1)
    }
}
