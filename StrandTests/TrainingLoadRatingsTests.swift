import XCTest
@testable import Strand

/// Session Load is the wearer's own figure, so it must count a session exactly once. A rating is stored
/// against the component that was open when it was given, which means one physical session can carry a
/// rating from its Hevy detail AND one from its Apple Health row, under different start seconds.
final class TrainingLoadRatingsTests: XCTestCase {
    private func entry(_ id: String, sessionId: String?, startTs: Int, rpe: Double,
                       ratedAtTs: Int? = nil) -> SessionRPEEntry {
        SessionRPEEntry(id: id, sessionId: sessionId, startTs: startTs, rpe: rpe,
                        sport: "Strength Training", ratedAtTs: ratedAtTs)
    }

    func testTwoRatingsOfOneCanonicalSessionCollapseToTheLatest() {
        let fromHevy = entry("session-rpe-1000", sessionId: "session|abc", startTs: 1_000, rpe: 8)
        let fromHealth = entry("session-rpe-1030", sessionId: "session|abc", startTs: 1_030, rpe: 6)
        let chosen = TrainingLoadModel.canonicalRatings(entries: [fromHevy, fromHealth],
                                                        canonicalIdByStart: [:])
        XCTAssertEqual(chosen.map(\.id), ["session-rpe-1030"])
        XCTAssertEqual(chosen.first?.rpe, 6)
    }

    /// Ratings written before fusion carry no session name. They must still collapse with a newer one
    /// for the same session, via the start second they were stored against.
    func testALegacyRatingIsGroupedByTheSessionItsStartBelongsTo() {
        let legacy = entry("session-rpe-1000", sessionId: nil, startTs: 1_000, rpe: 8)
        let tagged = entry("session-rpe-1030", sessionId: "session|abc", startTs: 1_030, rpe: 6)
        let chosen = TrainingLoadModel.canonicalRatings(
            entries: [legacy, tagged],
            canonicalIdByStart: [1_000: "session|abc", 1_030: "session|abc"])
        XCTAssertEqual(chosen.count, 1)
    }

    /// A legacy rating whose session cannot be resolved is still the wearer's data: it keeps counting
    /// on its own rather than being folded into an unrelated session or dropped.
    func testAnUnresolvedLegacyRatingKeepsCountingOnItsOwn() {
        let orphan = entry("session-rpe-500", sessionId: nil, startTs: 500, rpe: 7)
        let tagged = entry("session-rpe-1030", sessionId: "session|abc", startTs: 1_030, rpe: 6)
        let chosen = TrainingLoadModel.canonicalRatings(entries: [orphan, tagged],
                                                        canonicalIdByStart: [1_030: "session|abc"])
        XCTAssertEqual(Set(chosen.map(\.id)), ["session-rpe-500", "session-rpe-1030"])
    }

    func testRatingsOfDifferentSessionsAllSurvive() {
        let a = entry("a", sessionId: "session|a", startTs: 1_000, rpe: 8)
        let b = entry("b", sessionId: "session|b", startTs: 90_000, rpe: 5)
        XCTAssertEqual(TrainingLoadModel.canonicalRatings(entries: [a, b], canonicalIdByStart: [:]).count, 2)
    }

    /// Lab markers come back in whatever order the store returns them; the surviving rating must not.
    func testTheSurvivingRatingDoesNotDependOnReadOrder() {
        let first = entry("session-rpe-1000", sessionId: "session|abc", startTs: 1_000, rpe: 8)
        let second = entry("session-rpe-1030", sessionId: "session|abc", startTs: 1_030, rpe: 6)
        let forwards = TrainingLoadModel.canonicalRatings(entries: [first, second], canonicalIdByStart: [:])
        let backwards = TrainingLoadModel.canonicalRatings(entries: [second, first], canonicalIdByStart: [:])
        XCTAssertEqual(forwards.map(\.id), backwards.map(\.id))
    }

    func testLatestAnswerWinsEvenWhenItBelongsToTheEarlierComponent() {
        let laterComponent = entry("health", sessionId: "session|abc", startTs: 1_030, rpe: 6,
                                   ratedAtTs: 2_000)
        let latestAnswer = entry("hevy", sessionId: "session|abc", startTs: 1_000, rpe: 8,
                                 ratedAtTs: 3_000)
        let chosen = TrainingLoadModel.canonicalRatings(entries: [laterComponent, latestAnswer],
                                                        canonicalIdByStart: [:])
        XCTAssertEqual(chosen.map(\.id), ["hevy"])
    }
}
