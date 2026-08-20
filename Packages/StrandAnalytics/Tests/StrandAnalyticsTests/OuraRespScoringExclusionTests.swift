import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// The 0x6A `breath` channel is stored as INSTRUMENTATION: a real row in `respSample`, under the ring's
/// own deviceId, that no scored path may read. These tests pin BOTH halves of that claim from the
/// stager's side — the refusal itself, and the fact that today's refusal changes nothing (so the PR
/// that introduces the rows cannot be moving a single night's stages).
final class OuraRespScoringExclusionTests: XCTestCase {

    private let ring = "oura-2H3B2405003655"

    // MARK: - fixtures

    /// A still 1 Hz gravity stream — the quiescent sleep floor, enough for the stager to stage.
    private func stillGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
    }

    private func sleepingHR(start: Int, durationS: Int) -> [HRSample] {
        (0..<durationS).map { HRSample(ts: start + $0, bpm: 52 + ($0 / 600) % 4) }
    }

    private func regularRR(start: Int, durationS: Int) -> [RRInterval] {
        (0..<durationS).map { i -> RRInterval in
            RRInterval(ts: start + i, rrMs: 1_150 + Int(40.0 * sin(2.0 * Double.pi * Double(i) / 4.0)))
        }
    }

    /// What a real night of 0x6A looks like once persisted: one row per ~296 s window, milli-bpm,
    /// values drifting over the observed 13–16 bpm band.
    private func ringRespRows(start: Int, durationS: Int) -> [RespSample] {
        stride(from: 0, to: durationS, by: 296).map { i -> RespSample in
            let byte = 112 + (i / 296) % 12                       // 14.000 … 15.375 bpm, in 0.125 steps
            return RespSample(ts: start + i, raw: byte * 125, unit: OuraRespScale.unitTag)
        }
    }

    // MARK: - The refusal

    /// The guarantee, stated where the stager can see it: the rows never arrive.
    func testRingRespirationNeverReachesTheStager() {
        let start = 1_754_000_000
        let rows = ringRespRows(start: start, durationS: 8 * 3_600)
        XCTAssertFalse(rows.isEmpty, "fixture sanity: a night of 0x6A is ~100 rows")
        XCTAssertTrue(OuraRespScale.forScoring(rows, deviceId: ring).isEmpty)
    }

    /// …and that refusing them is a NO-OP on today's firmware, which is what makes this change safe to
    /// land: `respRateAndRRV` needs ≥8 samples in its rolling 5-minute window, and a ~296 s cadence
    /// never supplies more than two, so every epoch's RRV is NaN either way. Staging is bit-identical
    /// with the rows and without them.
    ///
    /// This is exactly why the refusal is written by PROVENANCE rather than left to the cadence: the day
    /// a decoder expands one record into per-second rows, or the record period changes, this assertion
    /// stops being free — and `forScoring` is already the place that keeps the outcome the same.
    func testTodaysCadenceWouldNotHaveMovedStagingEitherWay() {
        let start = 1_754_000_000
        let dur = 8 * 3_600
        let grav = stillGravity(start: start, durationS: dur)
        let hr = sleepingHR(start: start, durationS: dur)
        let rr = regularRR(start: start, durationS: dur)
        let rows = ringRespRows(start: start, durationS: dur)

        let without = SleepStager.stageSession(start: start, end: start + dur,
                                               grav: grav, hr: hr, rr: rr, resp: [])
        let with = SleepStager.stageSession(start: start, end: start + dur,
                                            grav: grav, hr: hr, rr: rr, resp: rows)
        XCTAssertFalse(without.isEmpty, "fixture sanity: the night must actually stage")
        XCTAssertEqual(with.map(\.start), without.map(\.start))
        XCTAssertEqual(with.map(\.end), without.map(\.end))
        XCTAssertEqual(with.map(\.stage), without.map(\.stage))
    }

    /// A 1 Hz stream of the SAME numbers does move the stager — the control that proves the test above
    /// is measuring the cadence and not simply a stager that ignores `resp`. If this one ever stops
    /// failing to match, the invariance above has become vacuous.
    func testAOneHertzStreamOfTheSameValuesWouldMoveStaging() {
        let start = 1_754_000_000
        let dur = 8 * 3_600
        let grav = stillGravity(start: start, durationS: dur)
        let hr = sleepingHR(start: start, durationS: dur)
        let rr = regularRR(start: start, durationS: dur)
        // A plausible raw-ADC-shaped waveform at 1 Hz: what the stager's peak detector is built for.
        let dense = (0..<dur).map { i -> RespSample in
            RespSample(ts: start + i, raw: 1_000 + Int(200.0 * sin(2.0 * Double.pi * Double(i) / 4.0)))
        }
        let without = SleepStager.stageSession(start: start, end: start + dur,
                                               grav: grav, hr: hr, rr: rr, resp: [])
        let withDense = SleepStager.stageSession(start: start, end: start + dur,
                                                 grav: grav, hr: hr, rr: rr, resp: dense)
        XCTAssertNotEqual(withDense.map(\.stage), without.map(\.stage),
                          "a dense resp stream must reach the stager — otherwise the invariance test proves nothing")
    }
}
