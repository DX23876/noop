import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class SleepStagerMethodTests: XCTestCase {
    func testMethodValuesAreStableAndV3UsesTheExistingV2PhaseEngine() {
        XCTAssertEqual(SleepStager.Method.v1.rawValue, "v1")
        XCTAssertEqual(SleepStager.Method.v2.rawValue, "v2")
        XCTAssertEqual(SleepStager.Method.v3.rawValue, "v3")
        XCTAssertFalse(SleepStager.Method.v1.usesV2Stages)
        XCTAssertTrue(SleepStager.Method.v2.usesV2Stages)
        XCTAssertTrue(SleepStager.Method.v3.usesV2Stages)
    }

    func testExplicitValidPreferenceWinsOverEveryLegacyValue() {
        for method in [SleepStager.Method.v1, .v2, .v3] {
            for legacy in [nil, false, true] as [Bool?] {
                XCTAssertEqual(SleepStager.Method.resolvedPreference(rawValue: method.rawValue,
                                                                    legacyV2: legacy), method)
            }
        }
    }

    func testOnlyAnExplicitClassicPreferenceKeepsTheOldDefault() {
        for raw in [nil, "", "unknown-method"] as [String?] {
            XCTAssertEqual(SleepStager.Method.resolvedPreference(rawValue: raw, legacyV2: nil), .v3)
            XCTAssertEqual(SleepStager.Method.resolvedPreference(rawValue: raw, legacyV2: true), .v3)
            XCTAssertEqual(SleepStager.Method.resolvedPreference(rawValue: raw, legacyV2: false), .v1)
        }
    }

    private struct Fixture {
        let start: Int
        let mainStart: Int
        let end: Int
        let hr: [HRSample]
        let gravity: [GravitySample]
    }

    private func leadingRestFixture() -> Fixture {
        let start = 1_749_513_600
        var gravity: [GravitySample] = []
        var minute = 0
        func append(_ duration: Int, moving: Bool) {
            for offset in 0..<duration {
                let x: Double = moving && offset.isMultiple(of: 2) ? 1 : 0
                let y: Double = moving && !offset.isMultiple(of: 2) ? 1 : 0
                gravity.append(GravitySample(ts: start + (minute + offset) * 60,
                                             x: x, y: y, z: moving ? 0 : 1))
            }
            minute += duration
        }
        // Separate short rest bouts are followed by an independently long night. Both engines see
        // identical calm HR, including during movement; only V3's onset policy should omit the lead.
        for (quiet, active) in [(35, 20), (40, 25), (30, 20)] {
            append(quiet, moving: false)
            append(active, moving: true)
        }
        let mainStart = start + minute * 60
        append(120, moving: false)
        append(15, moving: true)
        append(225, moving: false)
        let end = start + minute * 60
        let hr = stride(from: start - 24 * 3_600, to: end, by: 60).map {
            HRSample(ts: $0, bpm: $0 < start ? 70 : 50)
        }
        return Fixture(start: start, mainStart: mainStart, end: end, hr: hr, gravity: gravity)
    }

    private func detect(_ input: Fixture, method: SleepStager.Method,
                        legacyV2: Bool = false) -> [SleepSession] {
        SleepStager.detectSleep(hr: input.hr, gravity: input.gravity,
                                useSleepStagerV2: legacyV2, method: method)
    }

    func testNilMethodPreservesBothLegacyBooleanPipelines() throws {
        let input = leadingRestFixture()
        for (flag, method) in [(false, SleepStager.Method.v1), (true, .v2)] {
            let oldCall = SleepStager.detectSleep(hr: input.hr, gravity: input.gravity,
                                                  useSleepStagerV2: flag)
            let explicitNil = SleepStager.detectSleep(hr: input.hr, gravity: input.gravity,
                                                      useSleepStagerV2: flag, method: nil)
            let explicitMethod = detect(input, method: method, legacyV2: !flag)
            XCTAssertEqual(oldCall, explicitNil)
            XCTAssertEqual(oldCall, explicitMethod,
                           "An explicit method overrides the compatibility Boolean")
            let night = try XCTUnwrap(oldCall.first)
            XCTAssertEqual(night.start, input.start,
                           "V1 and V2 retain their original leading-rest bridge behavior")
        }
    }

    func testSwitchingBetweenV2AndV3CannotReuseTheOtherMethodsDetectedWindow() throws {
        let input = leadingRestFixture()
        let previous = detect(input, method: .v2)
        let current = detect(input, method: .v3)
        XCTAssertEqual(try XCTUnwrap(previous.first).start, input.start)
        let currentNight = try XCTUnwrap(current.first)
        XCTAssertGreaterThanOrEqual(currentNight.start, input.mainStart - 10 * 60)
        XCTAssertLessThanOrEqual(currentNight.start, input.mainStart + 15 * 60)
        XCTAssertGreaterThanOrEqual(currentNight.end, input.end - 10 * 60,
                                    "The interior bathroom trip stays inside the night")

        XCTAssertEqual(detect(input, method: .v2), previous)
        XCTAssertEqual(detect(input, method: .v3, legacyV2: true), current)
        XCTAssertEqual(detect(input, method: .v2, legacyV2: true), previous)
        XCTAssertNotEqual(previous, current)
    }

    func testTracedV3AndCachedV3ReturnTheSameNight() {
        let input = leadingRestFixture()
        let cached = detect(input, method: .v3)
        var trace: [String] = []
        let traced = SleepStager.detectSleep(hr: input.hr, gravity: input.gravity,
                                             traceSink: { trace.append($0) }, method: .v3)
        XCTAssertFalse(trace.isEmpty)
        XCTAssertEqual(traced, cached)
        XCTAssertEqual(detect(input, method: .v3), cached)
    }

    func testV3KeepsV2PhaseFormulasOverItsChosenWindow() throws {
        let input = leadingRestFixture()
        let night = try XCTUnwrap(detect(input, method: .v3).first)
        let phases = SleepStagerV2.stageSession(start: night.start, end: night.end,
                                                grav: input.gravity, hr: input.hr, rr: [], resp: [])
        XCTAssertEqual(night.stages, phases,
                       "V3 versions detection; it must not silently introduce different phase formulas")
    }

    func testAnalyzeDayThreadsTheExplicitPipelineAndLegacyDefault() {
        let input = leadingRestFixture()
        let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
        let legacy = AnalyticsEngine.analyzeDay(day: "2025-06-10", hr: input.hr,
                                                gravity: input.gravity, profile: profile,
                                                useSleepStagerV2: true)
        let v2 = AnalyticsEngine.analyzeDay(day: "2025-06-10", hr: input.hr,
                                            gravity: input.gravity, profile: profile, method: .v2)
        let v3 = AnalyticsEngine.analyzeDay(day: "2025-06-10", hr: input.hr,
                                            gravity: input.gravity, profile: profile, method: .v3)
        XCTAssertEqual(legacy.sleepSessions, detect(input, method: .v2))
        XCTAssertEqual(v2.sleepSessions, legacy.sleepSessions)
        XCTAssertEqual(v3.sleepSessions, detect(input, method: .v3))
        XCTAssertNotEqual(v3.sleepSessions, v2.sleepSessions)
    }
}
