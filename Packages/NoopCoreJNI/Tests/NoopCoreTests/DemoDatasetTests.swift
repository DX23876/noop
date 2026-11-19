import XCTest
@testable import NoopCore
import StrandTraining

/// The demo account both phones seed (`DemoDataset`). What is tested is what a comparison depends on:
/// that it is the same account every time and on every platform, and that nothing it writes is empty.
final class DemoDatasetTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_763_424_000)   // 2026-11-18

    func testTheSameAccountComesOutEveryTime() {
        let a = DemoDataset.build(today: day), b = DemoDataset.build(today: day)
        XCTAssertEqual(a.daily.map(\.day), b.daily.map(\.day))
        XCTAssertEqual(a.daily.compactMap(\.recovery), b.daily.compactMap(\.recovery))
        XCTAssertEqual(a.series.map(\.value), b.series.map(\.value))
        XCTAssertEqual(a.whoopWorkouts.map(\.startTs), b.whoopWorkouts.map(\.startTs))
    }

    /// The whole point of the dataset: no tile may be left looking broken because its measure is missing.
    func testEveryMeasureATileReadsIsFilled() {
        let plan = DemoDataset.build(today: day)
        XCTAssertEqual(plan.daily.count, DemoDataset.days)
        XCTAssertEqual(plan.sleeps.count, DemoDataset.days)
        XCTAssertEqual(plan.apple.count, DemoDataset.days)
        for field in ["recovery", "strain", "avgHrv", "restingHr", "spo2Pct", "respRateBpm", "skinTempDevC",
                      "skinTempC"] {
            let filled: Int
            switch field {
            case "recovery": filled = plan.daily.compactMap(\.recovery).count
            case "strain": filled = plan.daily.compactMap(\.strain).count
            case "avgHrv": filled = plan.daily.compactMap(\.avgHrv).count
            case "restingHr": filled = plan.daily.compactMap(\.restingHr).count
            case "spo2Pct": filled = plan.daily.compactMap(\.spo2Pct).count
            case "respRateBpm": filled = plan.daily.compactMap(\.respRateBpm).count
            case "skinTempDevC": filled = plan.daily.compactMap(\.skinTempDevC).count
            // The wrist temperature, not only the deviation: the tile leads with it, and a demo without
            // it showed every skin tile on its fallback scale ("+0.1 Δ°C") on both phones.
            default: filled = plan.daily.compactMap(\.skinTempC).count
            }
            XCTAssertEqual(filled, DemoDataset.days, "\(field) has holes, and a tile reading it would look broken")
        }
        for key in ["weightKg", "bodyFatPct", "sleep_need_min", "sleep_debt_min", "sleep_performance",
                    "sleep_consistency", "stress"] {
            XCTAssertFalse(plan.series.filter { $0.key == key }.isEmpty, "\(key) is missing from the demo")
        }
        for key in ["fitness_age", "vo2max_est", "vitality", "body_age"] {
            XCTAssertFalse(plan.computedSeries.filter { $0.key == key }.isEmpty, "\(key) is missing from the demo")
        }
        XCTAssertFalse(plan.whoopWorkouts.isEmpty)
        // The weigh-ins themselves, not only the series: the weight tile reads the weight store, and with
        // the series alone it said "No data yet" beside a screen full of figures.
        XCTAssertFalse(plan.weights.isEmpty)
        XCTAssertEqual(plan.hydration.count, DemoDataset.days, "the water tile reads a day, so every day has one")
        XCTAssertLessThan(plan.weights.count, plan.daily.count, "not every day has a weigh-in, and the tile says how long ago the last one was")
        XCTAssertFalse(plan.apple.compactMap(\.steps).isEmpty)
        XCTAssertFalse(plan.apple.compactMap(\.vo2max).isEmpty)
    }

    /// Plausible, not merely present: a reader should not be able to tell at a glance that it is invented.
    func testTheFiguresStayInsideTheirHumanRange() {
        let plan = DemoDataset.build(today: day)
        for d in plan.daily {
            XCTAssert((8...99).contains(d.recovery ?? -1), "charge \(d.recovery ?? -1)")
            XCTAssert((28...150).contains(d.avgHrv ?? -1), "hrv \(d.avgHrv ?? -1)")
            XCTAssert((42...70).contains(d.restingHr ?? -1), "resting hr \(d.restingHr ?? -1)")
            XCTAssert((300...540).contains(d.totalSleepMin ?? -1), "sleep \(d.totalSleepMin ?? -1)")
            XCTAssert((93...100).contains(d.spo2Pct ?? -1), "spo2 \(d.spo2Pct ?? -1)")
        }
        for d in plan.daily {
            XCTAssert((30...36).contains(d.skinTempC ?? -1), "wrist temperature \(d.skinTempC ?? -1) is not a worn one")
        }
        for s in plan.sleeps { XCTAssertGreaterThan(s.endTs, s.startTs) }
        for w in plan.whoopWorkouts {
            XCTAssertGreaterThan(w.endTs, w.startTs)
            XCTAssertNotNil(w.zonesJSON, "a strap workout carries its zones, as a real import does")
        }
        for w in plan.appleWorkouts {
            XCTAssertNil(w.zonesJSON, "an Apple row never carries zones, and the demo must not invent them")
        }
    }

    /// The days run up to today, so "today" on a demo phone is a day with data on it.
    func testItEndsToday() {
        let plan = DemoDataset.build(today: day)
        XCTAssertEqual(plan.daily.last?.day, DemoDataset.dayKey(day))
        XCTAssertEqual(plan.daily.first?.day,
                       DemoDataset.dayKey(day.addingTimeInterval(-Double(DemoDataset.days - 1) * 86_400)))
    }

    /// The weekly scores are stamped on Saturdays, where the engine stamps them, and they move.
    func testTheWeeklyScoresAreStampedAndTrend() {
        let plan = DemoDataset.build(today: day)
        let ages = plan.computedSeries.filter { $0.key == "fitness_age" }.map(\.value)
        XCTAssertGreaterThanOrEqual(ages.count, 15)
        XCTAssertLessThan(ages.last ?? 99, ages.first ?? 0, "the fitness age should fall across the window")
        let vo2 = plan.computedSeries.filter { $0.key == "vo2max_est" }.map(\.value)
        XCTAssertGreaterThan(vo2.last ?? 0, vo2.first ?? 99, "VO₂max should climb across the window")
    }

    /// The demo person's weight is the demo's own last weigh-in, not a figure beside it: a profile that
    /// disagreed with the scale is the fault this dataset exists to expose, not one to ship inside it.
    func testThePersonsWeightIsTheLastWeighIn() {
        let plan = DemoDataset.build(today: day)
        let person = DemoDataset.person(today: day)
        XCTAssertEqual(person.weightKg, plan.weights.last?.weightKg)
        XCTAssertEqual(person.sex, "male")
        XCTAssertGreaterThan(person.heightCm, 100)
        XCTAssertGreaterThan(person.ageYears, 13)
    }

    /// And the whole person is the same person every time, so both phones write one body.
    func testThePersonIsDeterministic() {
        XCTAssertEqual(DemoDataset.person(today: day), DemoDataset.person(today: day))
    }

    /// The cycle log: a start behind today and one ahead, with flow on the first days, so the cycle page
    /// and its Today card both have something to read.
    func testTheCycleLogHasStartsAroundToday() {
        let plan = DemoDataset.build(today: day)
        let starts = plan.cycle.filter { $0.key == CycleTrackingStore.periodStartKey }.map(\.day).sorted()
        XCTAssertGreaterThanOrEqual(starts.count, 4, "a 28-day cycle over 120 days")
        let today = DemoDataset.dayKey(day)
        XCTAssertNotNil(starts.last { $0 < today }, "a start behind today, so there is a cycle day to be on")
        let flow = plan.cycle.filter { $0.key == CycleLog.flowKey }
        XCTAssertEqual(flow.count, starts.count * 4, "four flow days per start")
        XCTAssertTrue(flow.allSatisfy { (1...4).contains(Int($0.value)) }, "flow is one of its four levels")
        XCTAssertTrue(plan.cycle.contains { $0.key == CycleLog.ovulationTestKey })
        XCTAssertTrue(plan.cycle.contains { $0.key.hasPrefix(CycleLog.symptomPrefix) })
        XCTAssertTrue(plan.cycle.contains { $0.key.hasPrefix(CycleLog.moodPrefix) })
    }

    /// Every exercise the demo plan names must exist in the shipped catalogue. Without this the plan would
    /// still write and its days would simply be blank, which reads as a broken screen rather than a demo.
    func testTheDemoPlansExercisesAreInTheShippedCatalogue() throws {
        let catalogue = Set(BundledExerciseCatalog.archive.exercises.map(\.id))
        XCTAssertFalse(catalogue.isEmpty, "the catalogue is shipped with the package")
        let p = DemoDataset.program(today: day)
        let named = p.routines.flatMap { $0.exercises.map(\.exerciseId) }
        XCTAssertEqual(named.count, 8)
        for id in named {
            XCTAssertTrue(catalogue.contains(id), "\(id) is not in the shipped exercise catalogue")
        }
        XCTAssertTrue(p.program.isActive, "the demo plan is the one being followed")
        XCTAssertEqual(Set(p.program.schedule.values.flatMap { $0 }), Set(p.routines.map(\.id)),
                       "the week references exactly the routines the plan carries")
    }

    /// The goals stand on the history this dataset wrote: the weight goal's baseline IS the last weigh-in.
    func testTheGoalsBaselineIsTheDatasetsOwnHistory() throws {
        let plan = DemoDataset.build(today: day)
        let goals = DemoDataset.goals(today: day)
        XCTAssertEqual(goals.count, 3)
        let weight = try XCTUnwrap(goals.first { $0.kind == .weight })
        XCTAssertEqual(weight.baseline, plan.weights.last?.weightKg)
        XCTAssertLessThan(try XCTUnwrap(weight.target), try XCTUnwrap(weight.baseline))
        XCTAssertTrue(goals.allSatisfy { $0.targetDate ?? day > day }, "every goal is still ahead")
        XCTAssertTrue(goals.allSatisfy { $0.status == .active })
    }
}
