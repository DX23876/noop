import XCTest
import WhoopStore
import StrandCore
@testable import Strand

/// Pins the pure workout-editing logic: source classification (the macOS read model has no
/// deviceId, so origin is recovered from `source`), the durable dismissed-span filter that keeps a
/// re-detected bout hidden (#107), manual-row validation, and field preservation on edit.
/// Mirrors the Android WorkoutEditingTest case-for-case.
final class WorkoutSourceTests: XCTestCase {

    private func row(start: Int, end: Int, sport: String, source: String,
                     avgHr: Int? = nil, maxHr: Int? = nil, strain: Double? = nil) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: source,
                   durationS: Double(end - start), energyKcal: nil, avgHr: avgHr, maxHr: maxHr,
                   strain: strain, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    // MARK: - cross-source dedup (#687)

    private func richRow(start: Int, end: Int, sport: String, source: String) -> WorkoutRow {
        // A live strap session: HR trace, peak, strain, zones, distance, energy all captured.
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: source,
                   durationS: Double(end - start), energyKcal: 600, avgHr: 150, maxHr: 178,
                   strain: 14.0, distanceM: 10_000, zonesJSON: #"{"z1":10}"#, notes: nil, steps: nil)
    }
    private func thinImport(start: Int, end: Int, sport: String, source: String) -> WorkoutRow {
        // A thin Health Connect / Apple import: only duration + calories.
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: source,
                   durationS: Double(end - start), energyKcal: 590, avgHr: nil, maxHr: nil,
                   strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    // MARK: - Filter predicate (#64)

    private func fullRow(start: Int, end: Int, sport: String, source: String,
                         avgHr: Int? = nil, kcal: Double? = nil, dist: Double? = nil,
                         strain: Double? = nil, maxHr: Int? = nil, notes: String? = nil,
                         steps: Int? = nil) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: source,
                   durationS: Double(end - start), energyKcal: kcal, avgHr: avgHr, maxHr: maxHr,
                   strain: strain, distanceM: dist, zonesJSON: nil, notes: notes, steps: steps)
    }

    func testDisplaySportRenamesDetectedToken() {
        XCTAssertEqual(WorkoutSource.displaySport("detected"), "Activity")
        XCTAssertEqual(WorkoutSource.displaySport("Running"), "Running")
    }

    func testFilterInactiveWhenEmptyPassesEverythingUntouched() {
        let rows = [fullRow(start: 100, end: 3700, sport: "Running", source: "whoop"),
                    fullRow(start: 5000, end: 8600, sport: "Cycling", source: "manual")]
        let f = WorkoutFilter()
        XCTAssertFalse(f.isActive)
        XCTAssertEqual(f.apply(rows), rows)
    }

    func testFilterSportSourceAndSearchCompose() {
        let run = fullRow(start: 100, end: 3700, sport: "Running", source: "whoop")
        let manualRun = fullRow(start: 5000, end: 8600, sport: "Running", source: "manual")
        let cycle = fullRow(start: 9000, end: 12000, sport: "Cycling", source: "manual")
        let detected = fullRow(start: 13000, end: 14000, sport: "detected", source: "my-whoop-noop")
        let rows = [run, manualRun, cycle, detected]

        // Sport filter uses the DISPLAYED name.
        XCTAssertEqual(WorkoutFilter(sport: "Running").apply(rows), [run, manualRun])
        // "detected" folds to "Activity" for the sport facet.
        XCTAssertEqual(WorkoutFilter(sport: "Activity").apply(rows), [detected])
        // Source filter uses classify.
        XCTAssertEqual(WorkoutFilter(sourceClass: .manual).apply(rows), [manualRun, cycle])
        // Sport AND source compose (Running that is manual only).
        XCTAssertEqual(WorkoutFilter(sport: "Running", sourceClass: .manual).apply(rows), [manualRun])
        // Search is a case-insensitive substring of the displayed sport.
        XCTAssertEqual(WorkoutFilter(search: "cyc").apply(rows), [cycle])
        XCTAssertEqual(WorkoutFilter(search: "  RUN ").apply(rows), [run, manualRun])
        // All three compose.
        XCTAssertEqual(WorkoutFilter(sport: "Running", sourceClass: .whoop, search: "run").apply(rows), [run])
    }

    // MARK: - Merge (#64)

    func testMergeEligibilityGatesOnManualOrDetected() {
        let manual = fullRow(start: 100, end: 3700, sport: "Running", source: "manual")
        let detected = fullRow(start: 100, end: 3700, sport: "detected", source: "my-whoop-noop")
        let whoop = fullRow(start: 100, end: 3700, sport: "Running", source: "whoop")
        let apple = fullRow(start: 100, end: 3700, sport: "Running", source: "apple-health")
        XCTAssertTrue(WorkoutMerge.isMergeable(manual))
        XCTAssertTrue(WorkoutMerge.isMergeable(detected))
        XCTAssertFalse(WorkoutMerge.isMergeable(whoop))
        XCTAssertFalse(WorkoutMerge.isMergeable(apple))
        // canMerge needs 2+ and every row eligible (a single imported row poisons the set).
        XCTAssertTrue(WorkoutMerge.canMerge([manual, detected]))
        XCTAssertFalse(WorkoutMerge.canMerge([manual]))
        XCTAssertFalse(WorkoutMerge.canMerge([manual, whoop]))
    }

    func testMergeTwoManualSumsAndSpansAndWeightsHr() {
        // A run split in two: 60 min @ 150 and 40 min @ 120. Merge is one manual session.
        let a = fullRow(start: 1000, end: 4600, sport: "Running", source: "manual",
                        avgHr: 150, kcal: 600, dist: 10_000, maxHr: 178)
        let b = fullRow(start: 5000, end: 7400, sport: "Running", source: "manual",
                        avgHr: 120, kcal: 300, dist: 5_000, maxHr: 150)
        let m = WorkoutMerge.merge([a, b])
        XCTAssertNotNil(m)
        XCTAssertEqual(m?.source, "manual")
        XCTAssertEqual(m?.sport, "Running")
        XCTAssertEqual(m?.startTs, 1000)          // min start
        XCTAssertEqual(m?.endTs, 7400)            // max end
        XCTAssertEqual(m?.durationS, 6000)        // SUM of durations (3600 + 2400), not the 6400s span
        XCTAssertEqual(m?.energyKcal, 900)        // sum
        XCTAssertEqual(m?.distanceM, 15_000)      // sum
        XCTAssertEqual(m?.maxHr, 178)             // max peak
        XCTAssertNil(m?.strain)                   // rescored by analyzeRecent, never summed (non-additive)
        XCTAssertNil(m?.zonesJSON)
        // Avg HR = duration-weighted: (150*3600 + 120*2400) / 6000 = 138.
        XCTAssertEqual(m?.avgHr, 138)
    }

    /// #1444: steps is cumulative per session, exactly like distance, so a merge must SUM it rather
    /// than drop it. It was dropped until making the field explicit forced the question. Kotlin twin:
    /// `merge_sumsStepsLikeDistance`.
    func testMergeSumsStepsLikeDistance() {
        let a = fullRow(start: 1000, end: 4600, sport: "Running", source: "manual",
                        dist: 10_000, steps: 6_200)
        let b = fullRow(start: 5000, end: 7400, sport: "Running", source: "manual",
                        dist: 5_000, steps: 3_100)
        XCTAssertEqual(WorkoutMerge.merge([a, b])?.steps, 9_300)
        // Nothing carried steps -> nil, never a fake 0 (same rule energy and distance follow).
        let c = fullRow(start: 1000, end: 4600, sport: "Running", source: "manual")
        let d = fullRow(start: 5000, end: 7400, sport: "Running", source: "manual")
        XCTAssertNil(WorkoutMerge.merge([c, d])?.steps)
    }

    func testMergeWeightsOnlyRowsWithHr() {
        // One row has no avg HR — it must NOT drag the weighted mean toward zero.
        let a = fullRow(start: 1000, end: 4600, sport: "Cycling", source: "manual", avgHr: 140)
        let b = fullRow(start: 5000, end: 7400, sport: "Cycling", source: "manual", avgHr: nil)
        let m = WorkoutMerge.merge([a, b])
        // Only `a` carried a HR, so the mean is a's 140 (b's null window is excluded from the weighting).
        XCTAssertEqual(m?.avgHr, 140)
    }

    func testMergeSportResolutionPrefersRealLabelOverDetected() {
        // A detected bout + a manual "Strength Training": the real label wins, detected never does.
        let detected = fullRow(start: 1000, end: 4600, sport: "detected", source: "my-whoop-noop")
        let manual = fullRow(start: 4600, end: 6000, sport: "Strength Training", source: "manual")
        XCTAssertEqual(WorkoutMerge.resolvedSport([detected, manual]), "Strength Training")
        XCTAssertEqual(WorkoutMerge.merge([detected, manual])?.sport, "Strength Training")
        // All-detected: no label to resolve, so the caller must pick (nil), and merge falls back to
        // "Activity" unless a sport override is supplied.
        let detected2 = fullRow(start: 6000, end: 7000, sport: "detected", source: "my-whoop-noop")
        XCTAssertNil(WorkoutMerge.resolvedSport([detected, detected2]))
        XCTAssertEqual(WorkoutMerge.merge([detected, detected2])?.sport, "Activity")
        XCTAssertEqual(WorkoutMerge.merge([detected, detected2], sport: "Yoga")?.sport, "Yoga")
    }

    func testMergeRejectsFewerThanTwo() {
        let a = fullRow(start: 1000, end: 4600, sport: "Running", source: "manual")
        XCTAssertNil(WorkoutMerge.merge([a]))
        XCTAssertNil(WorkoutMerge.merge([]))
    }

    func testMergeJoinsNotesAndOmitsAbsentSums() {
        // Notes join; energy/distance nil when NO row carried them (never a fabricated 0).
        let a = fullRow(start: 1000, end: 4600, sport: "Yoga", source: "manual", notes: "morning")
        let b = fullRow(start: 5000, end: 7400, sport: "Yoga", source: "manual", notes: "cooldown")
        let m = WorkoutMerge.merge([a, b])
        XCTAssertEqual(m?.notes, "morning · cooldown")
        XCTAssertNil(m?.energyKcal)
        XCTAssertNil(m?.distanceM)
        XCTAssertNil(m?.avgHr)
    }

    // MARK: - Oura

    /// Oura's sync stores Oura's OWN origin in `source`. Read as-is, "manual" made an Oura session a
    /// NOOP manual row (deletable through strap namespaces that do not hold it) and "autodetected"
    /// fell through to Apple Health; the Oura namespace was not read at all.
    func testOuraRowsAreReadAsOuraWithTheAppsSportVocabulary() {
        let stored = row(start: 1_000, end: 4_600, sport: "strength_training", source: "manual")
        let read = WorkoutSource.normalizedOuraRow(stored)
        XCTAssertEqual(read.source, WorkoutSource.ouraSource)
        XCTAssertEqual(WorkoutSource.classify(read.source), .oura)
        XCTAssertEqual(read.sport, "Strength Training")
        XCTAssertEqual(read.startTs, stored.startTs)
        XCTAssertEqual(read.endTs, stored.endTs)
        XCTAssertFalse(WorkoutMerge.isMergeable(read), "imported history stays read-only")

        XCTAssertEqual(WorkoutSource.ouraSport("walking"), "Walking")
        XCTAssertEqual(WorkoutSource.ouraSport("strengthTraining"), "Strength Training")
        XCTAssertEqual(WorkoutSource.ouraSport(""), "Workout")
        XCTAssertTrue(Repository.workoutNamespaces(rawIds: ["my-whoop"]).contains(WorkoutSource.ouraSource))
        XCTAssertFalse(Repository.deletableWorkoutNamespaces(rawIds: ["my-whoop"])
            .contains(WorkoutSource.ouraSource))
    }
}
