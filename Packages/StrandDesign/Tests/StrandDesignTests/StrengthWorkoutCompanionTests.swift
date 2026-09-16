import XCTest
@testable import StrandDesign

final class StrengthWorkoutCompanionTests: XCTestCase {
    func testLatestStateRoundTripsWithoutWorkoutHistory() throws {
        let sessionId = UUID()
        let state = StrengthWorkoutCompanionState(
            sessionId: sessionId, revision: 42, title: "Push",
            exerciseTitle: "Bench Press", setNumber: 3, setCount: 12,
            startedAtTs: 1_700_000_000, bpm: 134, heartRateZone: 3,
            restEndsAtTs: 1_700_000_090,
            phase: .active)

        let decoded = try JSONDecoder().decode(
            StrengthWorkoutCompanionState.self, from: JSONEncoder().encode(state))

        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.sessionId, sessionId)
        XCTAssertEqual(decoded.revision, 42)
        XCTAssertEqual(decoded.heartRateZone, 3)
    }

    func testCommandCarriesIdempotencyAndExpectedRevision() throws {
        let operationId = UUID()
        let sessionId = UUID()
        let command = StrengthWorkoutCompanionCommand(
            operationId: operationId, sessionId: sessionId,
            expectedRevision: 99, kind: .completeSet)

        let decoded = try JSONDecoder().decode(
            StrengthWorkoutCompanionCommand.self, from: JSONEncoder().encode(command))

        XCTAssertEqual(decoded.operationId, operationId)
        XCTAssertEqual(decoded.sessionId, sessionId)
        XCTAssertEqual(decoded.expectedRevision, 99)
        XCTAssertEqual(decoded.kind, .completeSet)
    }

    func testLegacyStateWithoutHeartRateZoneStillDecodes() throws {
        let data = Data("""
        {
          "sessionId":"00000000-0000-0000-0000-000000000001",
          "revision":1,
          "title":"Workout",
          "setCount":0,
          "startedAtTs":10,
          "phase":"active"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(StrengthWorkoutCompanionState.self, from: data)

        XCTAssertNil(decoded.heartRateZone)
    }

    func testTelemetryClampsAnInvalidSampleCount() {
        let telemetry = StrengthWorkoutCompanionTelemetry(
            sessionId: UUID(), bpm: nil, sampleCount: -2, recordedAtTs: 10)

        XCTAssertEqual(telemetry.sampleCount, 0)
    }
}
