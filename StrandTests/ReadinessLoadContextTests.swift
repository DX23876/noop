import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// P2: Readiness and the Coach read the Training Load lanes. These pin that they read the SAME reading
/// the screen shows — a Today load signal that named another band than the Training Load hero would be
/// the two-scales problem P1 removed, moved one screen over.
final class ReadinessLoadContextTests: XCTestCase {
    private typealias F = TrainingLoadLanesTests

    private func context(_ fixture: F.Fixture) -> ReadinessLoadContext {
        TrainingLoadLanes.readinessContext(
            strengthWorkouts: fixture.strength.workouts,
            cardio: TrainingLoadLanes.cardioSeries(sessions: fixture.sessions, resolution: fixture.cardio,
                                                   tzOffsetSeconds: 0),
            today: F.today, tzOffsetSeconds: 0)
    }

    func testContextCarriesTheScreensReadings() {
        let fixture = F.fixture(days: 120)
        let screen = F.prepared(fixture)
        let lanes = context(fixture).lanes
        XCTAssertEqual(lanes.map(\.kind), [.strength, .cardio])

        let strength = lanes[0]
        XCTAssertEqual(strength.band, screen.strength.reading?.band)
        XCTAssertEqual(strength.guardState, screen.strength.reading?.guardState)
        XCTAssertEqual(strength.percentChange, screen.strength.trend?.percentChange)
        XCTAssertEqual(strength.monotony, screen.strength.distribution?.monotony)

        let cardio = lanes[1]
        XCTAssertEqual(cardio.band, screen.cardio.reading?.band)
        XCTAssertEqual(cardio.guardState, screen.cardio.reading?.guardState)
        XCTAssertEqual(cardio.percentChange, screen.cardio.trend?.percentChange)
        XCTAssertEqual(cardio.monotony, screen.cardio.distribution?.monotony)
    }

    /// Nothing logged: no band anywhere, so Readiness shows no load signal instead of a guessed one.
    func testNoTrainingGivesNoLoadSignal() {
        let context = TrainingLoadLanes.readinessContext(
            strengthWorkouts: [],
            cardio: TrainingLoadLanes.cardioSeries(sessions: [], resolution: TrainingCardioLoadResolution(),
                                                   tzOffsetSeconds: 0),
            today: F.today, tzOffsetSeconds: 0)
        XCTAssertTrue(context.lanes.allSatisfy { $0.band == nil })
        let readiness = ReadinessEngine.evaluate(days: [], loadContext: context)
        XCTAssertNil(readiness.signals.first { $0.key == "trainingLoad" })
    }

    // MARK: - Coach

    func testReadinessLinesNameEachLaneAndItsGuard() {
        let context = ReadinessLoadContext(lanes: [
            ReadinessLoadContext.Lane(kind: .strength, band: .muchHigher, guardState: .none,
                                      percentChange: 52, monotony: 1.26),
            ReadinessLoadContext.Lane(kind: .cardio, band: nil, guardState: .tooFewSessions,
                                      percentChange: nil, monotony: nil)
        ])
        let lines = CoachTrainingLoadBrief.readinessLines(context)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1], "  Strength: well above usual, +52 %, monotony 1.3")
        XCTAssertEqual(lines[2], "  Cardio: no band: fewer than 3 sessions in the baseline")
        XCTAssertTrue(CoachTrainingLoadBrief.readinessLines(nil).isEmpty,
                      "lanes not read yet: say nothing rather than a ratio")
    }

    func testToolTextCarriesTheScreensBandsAndNoACWR() {
        let screen = F.prepared(F.fixture(days: 120))
        let text = CoachTrainingLoadBrief.text(screen)
        XCTAssertTrue(text.hasPrefix("TRAINING LOAD"))
        XCTAssertTrue(text.contains("Strength (weighted working sets)"))
        XCTAssertTrue(text.contains("Cardio (heart-rate load (TRIMP))"))
        XCTAssertTrue(text.contains("Session load (RPE × minutes)"))
        if let band = screen.cardio.reading?.band {
            XCTAssertTrue(text.contains("band: \(CoachTrainingLoadBrief.bandPhrase(band))"))
        }
        XCTAssertFalse(text.lowercased().contains("acute:chronic"))
        XCTAssertTrue(text.contains("never add"))
    }

    func testLoadOnlyVerdictSaysThereIsNoJudgement() {
        XCTAssertEqual(CoachTrainingLoadBrief.verdictText(.status(.productive)), "productive")
        XCTAssertEqual(CoachTrainingLoadBrief.verdictText(.loadOnly(.higher)),
                       "load only — above usual, no performance evidence for a judgement")
    }

    func testTheToolIsConsentGatedWithWorkouts() {
        XCTAssertEqual(CoachTool.trainingLoad.purpose, .workouts)
        XCTAssertEqual(CoachTool.trainingLoad.rawValue, "get_training_load")
    }

    // MARK: - P6

    /// A planned session is placed against today's room: inside, above, or well above the usual week.
    func testPlannedCardioSessionIsPlacedAgainstTheRoom() {
        let room = LaneHeadroom(day: "2026-09-24", loggedToday: 0, beforeAbove: 40, beforeWellAbove: 90)
        XCTAssertTrue(CoachTrainingLoadBrief.plannedCardioLine(low: 20, high: 35, room: room)
            .contains("fits inside the usual week"))
        XCTAssertTrue(CoachTrainingLoadBrief.plannedCardioLine(low: 50, high: 70, room: room)
            .contains("take the week above usual"))
        XCTAssertTrue(CoachTrainingLoadBrief.plannedCardioLine(low: 80, high: 120, room: room)
            .contains("well above usual"))
        XCTAssertTrue(CoachTrainingLoadBrief.plannedCardioLine(low: 20, high: 35, room: nil)
            .contains("no band yet"))
        XCTAssertTrue(CoachTrainingLoadBrief.plannedCardioLine(low: 20, high: 35, room: room)
            .contains("describes load only"))
    }

    func testOutlookLinesNameRoomAndSettlingPerLane() {
        var outlook = TrainingLoadModel.Outlook()
        XCTAssertTrue(CoachTrainingLoadBrief.outlookLines(outlook).isEmpty)
        outlook.strengthRoom = LaneHeadroom(day: "2026-09-24", loggedToday: 0, beforeAbove: 12, beforeWellAbove: nil)
        outlook.cardioSettles = "2026-09-28"
        let lines = CoachTrainingLoadBrief.outlookLines(outlook)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1], "  Strength: room today 12.0 weighted sets before above usual")
        XCTAssertEqual(lines[2], "  Cardio: back to usual on 2026-09-28 if every day from now is rest")
    }

    func testRoomTextRoundsDownAndNamesTheEdge() {
        let room = LaneHeadroom(day: "2026-09-24", loggedToday: 3, beforeAbove: 12.9, beforeWellAbove: 20.2)
        let text = TrainingLoadView.roomText(room, unit: "TRIMP")
        XCTAssertTrue(text.contains("12"))
        XCTAssertFalse(text.contains("13"), "rounded down: 13 would already be past the edge")
    }
}

