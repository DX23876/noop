import XCTest
import WhoopStore
@testable import Strand

/// Pins how a Hevy session behaves inside the EXISTING workout machinery — the part of this feature
/// that is deliberately not new code.
///
/// The requirement was "no double counting of load". That was already solved before Hevy existed, in
/// three places that only had to be pointed at the new source:
///
///   1. a Hevy row carries no `strain`, so it can never become cardiovascular load;
///   2. `dropDetectedShadows` removes the strap's auto-detected twin of the same bout (#975);
///   3. `dedupCrossSource` collapses the same session arriving from two lanes.
///
/// These tests hold all three against the new source, because "it already works" is a claim that
/// stops being true the moment someone adds a `case` and forgets one of them.
final class HevyWorkoutSourceTests: XCTestCase {

    private func row(_ source: String, sport: String, start: Int, end: Int,
                     strain: Double? = nil, avgHr: Int? = nil) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: source,
                   durationS: Double(end - start), energyKcal: nil, avgHr: avgHr, maxHr: nil,
                   strain: strain, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    // MARK: - Classification

    /// The API lane is its OWN source, not folded into the CSV importer's `.lifting`. The two can hold
    /// the same session — someone who imported a Hevy CSV export before connecting the API — and
    /// keeping them distinct is precisely what lets the cross-source dedup collapse that pair instead
    /// of one lane silently overwriting the other's history.
    func testHevyIsItsOwnSourceAndNotTheCsvLiftingLane() {
        XCTAssertEqual(WorkoutSource.classify("hevy"), .hevy)
        XCTAssertEqual(WorkoutSource.classify("lifting"), .lifting)
        XCTAssertNotEqual(WorkoutSource.classify("hevy"), .lifting)
    }

    /// It must not be mistaken for the strap. `classify` matches "whoop" as a substring, so a source
    /// id has to be checked before that rule can claim it.
    func testHevyIsNotClassifiedAsAStrapSource() {
        XCTAssertNotEqual(WorkoutSource.classify(HevySource.id), .whoop)
        XCTAssertNotEqual(WorkoutSource.classify(HevySource.id), .detected)
    }

    /// Imported history is read-only, and a synced session is imported history: NOOP must never rewrite
    /// what lives in the user's Hevy account.
    func testAHevyRowIsNotMergeableOrEditable() {
        XCTAssertFalse(WorkoutMerge.isMergeable(row(HevySource.id, sport: HevySource.sport,
                                                    start: 1000, end: 4600)))
    }

    // MARK: - No double counting

    /// The load half of the promise. A Hevy row carries no strain, so the day's Effort — which is
    /// computed from heart rate — cannot absorb lifting volume as if it were cardio.
    func testAMirroredHevyRowCarriesNoStrain() {
        let r = row(HevySource.id, sport: HevySource.sport, start: 1000, end: 4600)
        XCTAssertNil(r.strain)
        XCTAssertEqual(WorkoutSource.richness(r), 0,
                       "a row with no captured signals is the least rich, so a real capture always wins")
    }

    /// THE anti-duplicate test. The strap auto-detects a bout during the gym session; Hevy has the same
    /// session logged. The list must show ONE workout. `dropDetectedShadows` handles it without knowing
    /// anything about Hevy, because it drops a detected row shadowing ANY non-detected one.
    func testTheStrapsDetectedTwinOfAHevySessionIsDropped() {
        let hevy = row(HevySource.id, sport: HevySource.sport, start: 1000, end: 4600)
        // A wider, sport-agnostic HR window, which is what the detector produces.
        let detected = row("my-whoop-noop", sport: "detected", start: 900, end: 4800, strain: 8.2)

        let out = WorkoutSource.dedupCrossSource([detected, hevy])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(WorkoutSource.classify(out[0].source), .hevy,
                       "the logged session is the real one; the detected shadow goes")
    }

    /// A genuinely separate session on the same day is NOT collapsed. The >50%-of-the-shorter overlap
    /// rule is what keeps a morning lift and an evening run distinct.
    func testASeparateSessionLaterTheSameDaySurvives() {
        let hevy = row(HevySource.id, sport: HevySource.sport, start: 1000, end: 4600)
        let evening = row("my-whoop-noop", sport: "detected", start: 40_000, end: 43_000, strain: 9)

        XCTAssertEqual(WorkoutSource.dedupCrossSource([hevy, evening]).count, 2)
    }

    /// The migration case: a user who imported the Hevy CSV export months ago and now connects the API.
    /// Both lanes hold the session; the list must show one. They fold to the same `sportKey`, so the
    /// existing collapse recognises them.
    func testACsvImportAndAnApiSyncOfTheSameSessionCollapseToOne() {
        let csv = row("lifting", sport: "Strength Training", start: 1000, end: 4600)
        let api = row(HevySource.id, sport: HevySource.sport, start: 1010, end: 4600)

        XCTAssertEqual(WorkoutSource.sportKey(csv.sport), WorkoutSource.sportKey(api.sport))
        XCTAssertEqual(WorkoutSource.dedupCrossSource([csv, api]).count, 1)
    }

    /// A real strap capture of the same window keeps its richer data. The Hevy row contributes the sets;
    /// the capture contributes the heart rate — and `preferred` keeps whichever row actually measured
    /// something, so the surviving entry is never the emptier one.
    func testARichStrapCaptureOutranksTheThinMirroredRow() {
        let hevy = row(HevySource.id, sport: HevySource.sport, start: 1000, end: 4600)
        let strap = row("my-whoop", sport: "Strength Training", start: 1000, end: 4600,
                        strain: 7.5, avgHr: 118)

        let kept = WorkoutSource.preferred(hevy, strap)
        XCTAssertEqual(WorkoutSource.classify(kept.source), .whoop)
        XCTAssertEqual(kept.avgHr, 118)
    }

    // MARK: - Labels

    /// The source badge names Hevy specifically rather than lumping it in with file imports. A user who
    /// has both lanes has to be able to tell which row came from where.
    func testHevyHasItsOwnDiagnosticLabel() {
        XCTAssertEqual(WorkoutSource.sourceLabel(row(HevySource.id, sport: HevySource.sport,
                                                     start: 1, end: 2)), "hevy")
    }
}
