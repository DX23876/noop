import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The Lab's staging recipe (`SleepStager.StagingRecipe`): the standard recipe stages exactly as before it existed,
/// the trained recipe stages the same detected window with `SleepStagerTrained`, and neither can be served the
/// other's memoized night. Every V2-family call site stages through `SleepStager.stageV2Family`.
final class SleepStagingRecipeTests: XCTestCase {

    private struct Night { let hr: [HRSample]; let gravity: [GravitySample] }

    /// A plain night: calm heart rate, still wrist with one turn and one bathroom trip.
    private func night() -> Night {
        let start = 1_749_513_600
        var gravity: [GravitySample] = []
        var minute = 0
        func append(_ duration: Int, moving: Bool) {
            for offset in 0..<duration {
                let x: Double = moving && offset.isMultiple(of: 2) ? 1 : 0
                let y: Double = moving && !offset.isMultiple(of: 2) ? 1 : 0
                gravity.append(GravitySample(ts: start + (minute + offset) * 60, x: x, y: y, z: moving ? 0 : 1))
            }
            minute += duration
        }
        append(150, moving: false)
        append(10, moving: true)
        append(240, moving: false)
        let end = start + minute * 60
        let hr = stride(from: start - 24 * 3_600, to: end, by: 60).map { ts in
            HRSample(ts: ts, bpm: ts < start ? 70 : 50 + (ts / 600) % 4)
        }
        return Night(hr: hr, gravity: gravity)
    }

    private func detect(_ n: Night, _ method: SleepStager.Method, _ recipe: SleepStager.StagingRecipe? = nil)
        -> [SleepSession] {
        guard let recipe else { return SleepStager.detectSleep(hr: n.hr, gravity: n.gravity, method: method) }
        return SleepStager.detectSleep(hr: n.hr, gravity: n.gravity, method: method, stagingRecipe: recipe)
    }

    func testAnUnknownOrMissingStoredRecipeIsTheStandardOne() {
        XCTAssertEqual(SleepStager.StagingRecipe.resolved(rawValue: nil), .standard)
        XCTAssertEqual(SleepStager.StagingRecipe.resolved(rawValue: "garbage"), .standard)
        XCTAssertEqual(SleepStager.StagingRecipe.resolved(rawValue: "trained"), .trained)
        XCTAssertEqual(SleepStager.StagingRecipe.resolved(rawValue: "restless"), .restless)
        XCTAssertEqual(SleepStager.StagingRecipe.standard.signatureSuffix, "")
        XCTAssertEqual(SleepStager.StagingRecipe.trained.signatureSuffix, "+trained")
        XCTAssertEqual(SleepStager.StagingRecipe.restless.signatureSuffix, "+restless")
    }

    /// The restless recipe is the standard recipe with the restless term, on the same detected window.
    func testTheRestlessRecipeStagesTheSameWindowWithTheRestlessTerm() throws {
        let n = night()
        let standard = try XCTUnwrap(detect(n, .v3, .standard).first)
        let restless = try XCTUnwrap(detect(n, .v3, .restless).first)
        XCTAssertEqual(restless.start, standard.start, "the recipe stages a window; it never moves detection")
        XCTAssertEqual(restless.end, standard.end)
        XCTAssertEqual(restless.stages, SleepStagerV2.stageSession(start: restless.start, end: restless.end,
                                                                   grav: n.gravity, hr: n.hr, rr: [], resp: [],
                                                                   restless: .remOnly))
        XCTAssertEqual(SleepStager.stageV2Family(.restless, start: restless.start, end: restless.end, grav: n.gravity,
                                                 hr: n.hr, rr: [], resp: []),
                       restless.stages)
    }

    func testTheStandardRecipeStagesExactlyAsBefore() throws {
        let n = night()
        let before = detect(n, .v3)
        XCTAssertEqual(detect(n, .v3, .standard), before)
        let first = try XCTUnwrap(before.first)
        XCTAssertEqual(first.stages, SleepStagerV2.stageSession(start: first.start, end: first.end, grav: n.gravity,
                                                                hr: n.hr, rr: [], resp: []))
    }

    func testTheTrainedRecipeStagesTheSameWindowWithTheTrainedModel() throws {
        let n = night()
        let standard = try XCTUnwrap(detect(n, .v3, .standard).first)
        let trained = try XCTUnwrap(detect(n, .v3, .trained).first)
        XCTAssertEqual(trained.start, standard.start, "the recipe stages a window; it never moves detection")
        XCTAssertEqual(trained.end, standard.end)
        XCTAssertEqual(trained.stages, SleepStagerTrained.stageSession(start: trained.start, end: trained.end,
                                                                       grav: n.gravity, hr: n.hr, rr: [], resp: []))
        XCTAssertNotEqual(trained.stages, standard.stages, "the two recipes stage this night differently")
    }

    func testSwitchingTheRecipeCannotReuseTheOtherRecipesNight() {
        let n = night()
        let standard = detect(n, .v3, .standard)
        let trained = detect(n, .v3, .trained)
        XCTAssertNotEqual(standard, trained)
        XCTAssertEqual(detect(n, .v3, .standard), standard)
        XCTAssertEqual(detect(n, .v3, .trained), trained)
    }

    func testV1KeepsItsOwnStagerWhateverTheRecipe() {
        let n = night()
        XCTAssertEqual(detect(n, .v1, .trained), detect(n, .v1, .standard))
    }

    func testTheDayAnalysisAndTheHeartRateOnlyPathStageThroughTheRecipe() throws {
        let n = night()
        let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
        let day = AnalyticsEngine.analyzeDay(day: "2025-06-10", hr: n.hr, gravity: n.gravity, profile: profile,
                                             method: .v3, stagingRecipe: .trained)
        XCTAssertEqual(day.sleepSessions, detect(n, .v3, .trained))

        // A day with no motion at all is found from heart rate alone and staged by the same recipe.
        let hrOnly = try XCTUnwrap(SleepStager.hrOnlySessions(day: "2025-06-10", hr: n.hr, rr: [], resp: [],
                                                              stagingRecipe: .trained).first)
        XCTAssertEqual(hrOnly.stages, SleepStagerTrained.stageSession(start: hrOnly.start, end: hrOnly.end, grav: [],
                                                                      hr: n.hr, rr: [], resp: []))
    }

    func testTheTraceNamesOnlyANonStandardRecipe() {
        let standard = AnalyticsEngine.sleepMotionLine(day: "2025-06-10", grav: 1, hr: 2, sparse: false,
                                                       useSleepStagerV2: true, family: .whoop5, method: .v3)
        XCTAssertEqual(standard, AnalyticsEngine.sleepMotionLine(day: "2025-06-10", grav: 1, hr: 2, sparse: false,
                                                                 useSleepStagerV2: true, family: .whoop5, method: .v3,
                                                                 recipe: .standard))
        XCTAssertFalse(standard.contains("recipe="))
        XCTAssertTrue(AnalyticsEngine.sleepMotionLine(day: "2025-06-10", grav: 1, hr: 2, sparse: false,
                                                      useSleepStagerV2: true, family: .whoop5, method: .v3,
                                                      recipe: .trained).hasSuffix(" recipe=trained"))
        XCTAssertFalse(AnalyticsEngine.sleepMotionLine(day: "2025-06-10", grav: 1, hr: 2, sparse: false,
                                                       useSleepStagerV2: false, family: .whoop5, method: .v1,
                                                       recipe: .trained).contains("recipe="),
                       "V1 ignores the recipe, so its line does not claim one")
    }
}
