import XCTest
@testable import StrandTraining

/// The plan builder: a whole plan out of a handful of answers, the same way twice.
final class PlanBuilderTests: XCTestCase {

    /// The wearer's own library, which is what the builder is handed in the app.
    private var library: [TrainingExercise] {
        TrainingStarterCatalog.exercises + BundledExerciseCatalog.exercises
    }

    private func build(_ request: PlanRequest) -> (TrainingProgram, [TrainingRoutine]) {
        PlanBuilder.build(request, exercises: library, now: 1_000)
    }

    func testEveryDayCountProducesThatManySessionsOnSpreadDays() {
        for days in 2...6 {
            let (program, routines) = build(PlanRequest(daysPerWeek: days))
            XCTAssertEqual(routines.count, days, "\(days) days")
            let scheduled = program.schedule.values.flatMap { $0 }
            XCTAssertEqual(Set(scheduled), Set(routines.map(\.id)), "\(days) days")
            XCTAssertEqual(program.schedule.keys.count, days, "\(days) days")
            XCTAssertEqual(program.targets.sessionsPerWeek, days)
            // Two or three days a week always leave a rest day between sessions.
            if days <= 3 {
                let weekdays = program.schedule.keys.map(\.rawValue).sorted()
                for (first, second) in zip(weekdays, weekdays.dropFirst()) {
                    XCTAssertGreaterThan(second - first, 1)
                }
            }
        }
    }

    /// Building the same plan twice must give the same plan. Anything else and a test cannot pin the
    /// builder down, and two wearers answering alike would get different sessions.
    func testBuildingTwiceGivesTheSameSessions() {
        let request = PlanRequest(daysPerWeek: 4, experience: .intermediate)
        let first = build(request).1
        let second = build(request).1
        XCTAssertEqual(first.map(\.title), second.map(\.title))
        XCTAssertEqual(first.map { $0.exercises.map(\.exerciseId) },
                       second.map { $0.exercises.map(\.exerciseId) })
        XCTAssertEqual(first.map { $0.exercises.map { $0.sets.count } },
                       second.map { $0.exercises.map { $0.sets.count } })
    }

    func testOnlyTheEquipmentTheWearerHasIsPrescribed() {
        let (_, routines) = build(PlanRequest(daysPerWeek: 3, equipment: ["bodyweight"]))
        let byId = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        XCTAssertFalse(routines.isEmpty)
        for routine in routines {
            for entry in routine.exercises {
                let exercise = byId[entry.exerciseId]
                XCTAssertNotNil(exercise)
                XCTAssertTrue(TrainingEquipmentCatalog.matches(exercise?.equipmentIds ?? [],
                                                               available: ["bodyweight"]),
                              "\(exercise?.title ?? entry.exerciseId) needs more than body weight")
            }
        }
    }

    func testNoSessionPrescribesTheSameExerciseTwice() {
        let (_, routines) = build(PlanRequest(daysPerWeek: 6, experience: .advanced))
        for routine in routines {
            let ids = routine.exercises.map(\.exerciseId)
            XCTAssertEqual(Set(ids).count, ids.count, routine.title)
        }
    }

    func testASessionIsCutToTheTimeTheWearerHasAndKeepsItsMainLifts() {
        let short = build(PlanRequest(daysPerWeek: 3, minutesPerSession: 30)).1
        let long = build(PlanRequest(daysPerWeek: 3, minutesPerSession: 90)).1
        for routine in short {
            XCTAssertLessThanOrEqual(SessionEstimate.minutes(routine), 32, routine.title)
            // Never cut below the main lifts.
            XCTAssertGreaterThanOrEqual(routine.exercises.count, 2, routine.title)
        }
        XCTAssertGreaterThan(long.map { $0.exercises.count }.reduce(0, +),
                             short.map { $0.exercises.count }.reduce(0, +))
    }

    func testABeginnerAddsWeightWhileAnyonePastThatEarnsTheStep() {
        let beginner = build(PlanRequest(daysPerWeek: 3, experience: .beginner)).1
        let intermediate = build(PlanRequest(daysPerWeek: 3, experience: .intermediate)).1
        XCTAssertTrue(beginner.allSatisfy { routine in
            routine.exercises.allSatisfy { $0.progression?.policy == .linear }
        })
        XCTAssertTrue(intermediate.allSatisfy { routine in
            routine.exercises.allSatisfy { $0.progression?.policy == .doubleProgression }
        })
    }

    func testAStrengthLeanPrescribesFewerRepetitionsAndLongerRestsThanAHypertrophyLean() {
        let strength = build(PlanRequest(daysPerWeek: 3, experience: .intermediate,
                                          emphasis: .strength)).1
        let size = build(PlanRequest(daysPerWeek: 3, experience: .intermediate,
                                      emphasis: .hypertrophy)).1
        func firstWorkSet(_ routines: [TrainingRoutine]) -> RoutineSetPlan? {
            routines.first?.exercises.first?.sets.first { $0.phase == .work }
        }
        XCTAssertLessThan(firstWorkSet(strength)?.repsMax ?? 99, firstWorkSet(size)?.repsMax ?? 0)
        XCTAssertGreaterThan(strength.first?.exercises.first?.restSeconds ?? 0,
                             size.first?.exercises.first?.restSeconds ?? 999)
    }

    /// A loaded main lift gets a warm-up set with no weight on it. Inventing a warm-up weight would
    /// be a prescription nobody checked, and the session's own ramp fills it once a working weight
    /// exists.
    func testALoadedMainLiftGetsAnUnweightedWarmupSet() {
        let (_, routines) = build(PlanRequest(daysPerWeek: 3))
        let byId = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        var checked = 0
        for routine in routines {
            for entry in routine.exercises {
                guard let exercise = byId[entry.exerciseId],
                      TrainingEquipmentCatalog.carriesExternalLoad(exercise.equipmentIds),
                      entry.sets.contains(where: { $0.phase == .warmup }) else { continue }
                checked += 1
                let warmups = entry.sets.filter { $0.phase == .warmup }
                XCTAssertEqual(warmups.count, 1)
                XCTAssertNil(warmups.first?.targetWeightKg)
            }
        }
        XCTAssertGreaterThan(checked, 0, "no loaded main lift was prescribed at all")
    }

    func testAPlanIsRestingUntilTheWearerTakesItUp() {
        let (program, _) = build(PlanRequest(daysPerWeek: 3))
        XCTAssertFalse(program.isActive)
        XCTAssertEqual(program.origin.kind, .builder)
        XCTAssertNil(program.block?.startedOn)
    }

    func testTheSplitCoversPushPullAndLegsOnEveryDayCount() {
        for days in 2...6 {
            let slots = PlanBuilder.split(days: days, emphasis: .balanced).flatMap(\.slots)
            XCTAssertTrue(slots.contains { PlanBuilder.isLower($0.pattern) }, "\(days) days")
            XCTAssertTrue(slots.contains { [.horizontalPush, .verticalPush].contains($0.pattern) },
                          "\(days) days")
            XCTAssertTrue(slots.contains { [.horizontalPull, .verticalPull].contains($0.pattern) },
                          "\(days) days")
        }
    }

    func testSessionEstimateCountsWorkAndRestButNotARestAfterTheLastSet() {
        let entry = RoutineExercise(exerciseId: "x",
                                    sets: [RoutineSetPlan(repsMin: 10, repsMax: 10),
                                           RoutineSetPlan(repsMin: 10, repsMax: 10)],
                                    restSeconds: 60)
        // Two sets of ten at three seconds a repetition, with one rest between them.
        XCTAssertEqual(SessionEstimate.seconds(entry), 30 + 30 + 60)
        let routine = TrainingRoutine(title: "One", exercises: [entry])
        XCTAssertEqual(SessionEstimate.seconds(routine), SessionEstimate.seconds(entry))
    }

    /// A pair done side by side costs the longer of the two, not the sum, or a plan with supersets
    /// would read as far longer than it takes and get trimmed for nothing.
    func testASupersetCountsOnceRatherThanTwice() {
        let group = UUID()
        let sets = [RoutineSetPlan(repsMin: 10, repsMax: 10), RoutineSetPlan(repsMin: 10, repsMax: 10)]
        let routine = TrainingRoutine(title: "Pair", exercises: [
            RoutineExercise(exerciseId: "a", sets: sets, restSeconds: 60, supersetId: group),
            RoutineExercise(exerciseId: "b", sets: sets, restSeconds: 60, supersetId: group)
        ])
        let alone = TrainingRoutine(title: "Alone", exercises: [
            RoutineExercise(exerciseId: "a", sets: sets, restSeconds: 60)
        ])
        XCTAssertEqual(SessionEstimate.seconds(routine), SessionEstimate.seconds(alone))
    }
}
