import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class SleepConservativeOnsetTests: XCTestCase {
    private let midnight = 1_749_513_600

    private struct Fixture {
        let hr: [HRSample]
        let gravity: [GravitySample]
        let mainStart: Int
        let end: Int
    }

    private func fixture(quietMinutes: [Int], movingMinutes: [Int],
                         shiftSeconds: Int = 0, mainMinutes: Int = 360,
                         bathroomAfterMinutes: Int? = 120) -> Fixture {
        precondition(quietMinutes.count == movingMinutes.count)
        let start = midnight + shiftSeconds
        var gravity: [GravitySample] = []
        var cursor = start

        func appendMinutes(_ count: Int, moving: Bool) {
            for minute in 0..<count {
                let turns = moving && minute.isMultiple(of: 2)
                gravity.append(GravitySample(ts: cursor + minute * 60,
                                             x: moving ? (turns ? 1 : 0) : 0,
                                             y: moving ? (turns ? 0 : 1) : 0,
                                             z: moving ? 0 : 1))
            }
            cursor += count * 60
        }

        for (quiet, moving) in zip(quietMinutes, movingMinutes) {
            appendMinutes(quiet, moving: false)
            appendMinutes(moving, moving: true)
        }
        let mainStart = cursor
        if let bathroomAfterMinutes {
            appendMinutes(bathroomAfterMinutes, moving: false)
            appendMinutes(15, moving: true)
            appendMinutes(mainMinutes - bathroomAfterMinutes - 15, moving: false)
        } else {
            appendMinutes(mainMinutes, moving: false)
        }
        let end = cursor

        // The same calm HR accompanies rest, movement and sleep. A preceding waking baseline keeps
        // existing daytime guards from deciding these cases merely from their clock hour.
        let hr = stride(from: start - 24 * 3_600, to: end, by: 60).map {
            HRSample(ts: $0, bpm: $0 < start ? 70 : 50)
        }
        return Fixture(hr: hr, gravity: gravity, mainStart: mainStart, end: end)
    }

    private func detect(_ input: Fixture) -> [SleepSession] {
        SleepStager.detectSleep(hr: input.hr, gravity: input.gravity, useSleepStagerV2: true, method: .v3)
    }

    func testShortQuietLeadingBoutsDoNotBecomeHoursOfSleepBeforeAnEstablishedNight() throws {
        for quiet in [[36, 42, 35], [28, 35, 44], [45, 30, 38]] {
            let input = fixture(quietMinutes: quiet, movingMinutes: [20, 22, 25])
            XCTAssertTrue(SleepStager.isGravitySparse(input.gravity, hr: input.hr))

            let sessions = detect(input)
            let night = try XCTUnwrap(sessions.last)
            XCTAssertEqual(sessions.count, 1, "The short leading rest must not survive as extra nights")
            XCTAssertGreaterThanOrEqual(night.start, input.mainStart - 10 * 60,
                                        "Quiet bouts separated by movement must not manufacture an early onset: \(quiet)")
            XCTAssertLessThanOrEqual(night.start, input.mainStart + 15 * 60,
                                     "The clear established night must still be detected")
            XCTAssertGreaterThanOrEqual(night.end, input.end - 10 * 60,
                                        "The bathroom interruption must not discard the rest of the night")
        }
    }

    func testConservativeOnsetDoesNotDependOnTheClockHour() throws {
        var relativeStarts: [Int]?
        var relativeEnds: [Int]?
        for shift in [0, 10 * 3_600, 17 * 3_600] {
            let input = fixture(quietMinutes: [36, 42, 35], movingMinutes: [20, 22, 25],
                                shiftSeconds: shift)
            let sessions = detect(input)
            let night = try XCTUnwrap(sessions.last)
            XCTAssertEqual(sessions.count, 1)
            XCTAssertGreaterThanOrEqual(night.start, input.mainStart - 10 * 60,
                                        "Clock shift \(shift) must not turn uncertain leading rest into sleep")
            XCTAssertLessThanOrEqual(night.start, input.mainStart + 15 * 60)
            XCTAssertGreaterThanOrEqual(night.end, input.end - 10 * 60)
            let starts = sessions.map { $0.start - shift }
            let ends = sessions.map { $0.end - shift }
            if let relativeStarts, let relativeEnds {
                XCTAssertEqual(starts, relativeStarts)
                XCTAssertEqual(ends, relativeEnds)
            } else {
                relativeStarts = starts
                relativeEnds = ends
            }
        }
    }

    func testBathroomInterruptionInsideAnEstablishedNightStillKeepsOneNight() throws {
        let input = fixture(quietMinutes: [], movingMinutes: [])
        let sessions = detect(input)
        let night = try XCTUnwrap(sessions.first)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertLessThanOrEqual(night.start, input.mainStart + 10 * 60)
        XCTAssertGreaterThanOrEqual(night.end, input.end - 10 * 60)
    }

    func testAnEstablishedInitialSleepBoutIsNotMistakenForShortLeadingRest() throws {
        let input = fixture(quietMinutes: [90], movingMinutes: [20])
        let sessions = detect(input)
        let night = try XCTUnwrap(sessions.first)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertLessThanOrEqual(night.start, midnight + 10 * 60)
        XCTAssertGreaterThanOrEqual(night.end, input.end - 10 * 60)
    }

    func testAWholeNightOfShortFragmentsCanStillBeRescued() throws {
        // No individual quiet bout clears the ordinary 60-minute floor. This is a fragmented night
        // without a separately established main block, rather than optional rest preceding one.
        let input = fixture(quietMinutes: [45, 45, 45], movingMinutes: [20, 20, 20],
                            mainMinutes: 45, bathroomAfterMinutes: nil)
        let sessions = detect(input)
        let night = try XCTUnwrap(sessions.first)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertLessThanOrEqual(night.start, midnight + 10 * 60)
        XCTAssertGreaterThanOrEqual(night.end, input.end - 10 * 60)
    }

    func testAGapAlreadyJoinedByMedianHRDoesNotEstablishAnEarlyOnset() throws {
        let original = fixture(quietMinutes: [40, 40], movingMinutes: [30, 20])
        let gapStart = midnight + 40 * 60
        let gapEnd = midnight + 70 * 60
        let gravity = original.gravity.filter { $0.ts < gapStart || $0.ts >= gapEnd }
        let hr = original.hr.map { sample in
            HRSample(ts: sample.ts,
                     bpm: sample.ts >= gapEnd - 8 * 60 && sample.ts < gapEnd ? 150 : sample.bpm)
        }
        let input = Fixture(hr: hr, gravity: gravity, mainStart: original.mainStart, end: original.end)

        let sessions = detect(input)
        let night = try XCTUnwrap(sessions.last)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertGreaterThanOrEqual(night.start, input.mainStart - 10 * 60,
                                    "A permissive HR-backed data gap must not manufacture the qualifying onset run")
        XCTAssertLessThanOrEqual(night.start, input.mainStart + 15 * 60)
        XCTAssertGreaterThanOrEqual(night.end, input.end - 10 * 60)
    }

    func testShortRunSmoothingCannotHideAnUnsupportedGapFromOnsetEvidence() throws {
        let original = fixture(quietMinutes: [10, 50], movingMinutes: [30, 20])
        let gapStart = midnight + 10 * 60
        let gapEnd = midnight + 40 * 60
        let gravity = original.gravity.filter { $0.ts < gapStart || $0.ts >= gapEnd }
        let hr = original.hr.map { sample in
            HRSample(ts: sample.ts,
                     bpm: sample.ts >= gapStart && sample.ts < gapEnd ? 150 : sample.bpm)
        }
        let input = Fixture(hr: hr, gravity: gravity, mainStart: original.mainStart, end: original.end)

        let sessions = detect(input)
        let night = try XCTUnwrap(sessions.last)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertGreaterThanOrEqual(night.start, input.mainStart - 10 * 60,
                                    "Absorbing a sub-15-minute run must not conceal a high-HR motion dropout")
        XCTAssertLessThanOrEqual(night.start, input.mainStart + 15 * 60)
        XCTAssertGreaterThanOrEqual(night.end, input.end - 10 * 60)
    }

    func testAMissingDataGapDoesNotDiscardTheLeadingBout() {
        let source = [
            SleepStager.Period(stage: "sleep", start: 0, end: 40 * 60),
            SleepStager.Period(stage: "sleep", start: 70 * 60, end: 240 * 60)
        ]
        let joined = SleepStager.Period(stage: "sleep", start: 0, end: 240 * 60)
        XCTAssertEqual(SleepStager.conservativeOnset(for: joined, evidence: source), 0,
                       "Missing motion is not observed activity before sleep")
    }

    func testARunExactlyAtTheStrictSessionFloorCannotEstablishTheOnset() {
        let source = [
            SleepStager.Period(stage: "sleep", start: 0, end: 30 * 60),
            SleepStager.Period(stage: "active", start: 30 * 60, end: 50 * 60),
            SleepStager.Period(stage: "sleep", start: 50 * 60, end: 110 * 60),
            SleepStager.Period(stage: "active", start: 110 * 60, end: 130 * 60),
            SleepStager.Period(stage: "sleep", start: 130 * 60, end: 300 * 60)
        ]
        let joined = SleepStager.Period(stage: "sleep", start: 0, end: 300 * 60)
        XCTAssertEqual(SleepStager.conservativeOnset(for: joined, evidence: source), 130 * 60,
                       "The ordinary session gate requires more than 60 minutes")
    }

    func testAQualifyingRunOutsideThisCandidateDoesNotChangeItsOnset() {
        let source = [
            SleepStager.Period(stage: "sleep", start: 0, end: 40 * 60),
            SleepStager.Period(stage: "active", start: 40 * 60, end: 60 * 60),
            SleepStager.Period(stage: "sleep", start: 60 * 60, end: 100 * 60),
            SleepStager.Period(stage: "sleep", start: 600 * 60, end: 900 * 60)
        ]
        let joined = SleepStager.Period(stage: "sleep", start: 0, end: 100 * 60)
        XCTAssertEqual(SleepStager.conservativeOnset(for: joined, evidence: source), 0,
                       "Another night must not disable this candidate's fragmentation rescue")
    }

    func testTheTraceAndMemoizedPathReturnTheSameConservativeNight() {
        let input = fixture(quietMinutes: [36, 42, 35], movingMinutes: [20, 22, 25])
        let plain = detect(input)
        var lines: [String] = []
        let traced = SleepStager.detectSleep(hr: input.hr, gravity: input.gravity,
                                             useSleepStagerV2: true, traceSink: { lines.append($0) }, method: .v3)
        XCTAssertEqual(traced, plain)
        XCTAssertTrue(lines.contains { $0.contains("gate=conservativeOnset ")
            && $0.contains("anchorStartTs=\(plain[0].start)") },
                      "The diagnostic must name the onset returned by the same detector")
    }
}
