import Foundation

/// Ready-made plans: a few built from the builder's own rules, and a few that reproduce a named
/// published programme.
///
/// A published programme is reproduced as it is published, not loosely: its exercises, its sets and
/// its repetitions. Where this app's weekly plan cannot express part of it (a programme that
/// alternates its sessions week by week, which a repeating week cannot), the plan's own notes say so
/// in words rather than quietly flattening it. The source is named on the plan, so nobody has to
/// wonder whose programme they are following.
public enum TrainingProgramCatalog {

    public struct Template: Identifiable, Sendable {
        public let id: String
        public let title: String
        /// One line on what it is for, shown in the list.
        public let summary: String
        public let daysPerWeek: Int
        /// Equipment the plan cannot be run without, canonical ids. The list marks a template the
        /// wearer has not got the kit for rather than hiding it.
        public let requiredEquipment: Set<String>
        public let origin: TrainingProgramOrigin
        /// Builds the plan and its routines. Separate from the entry so a list can be shown without
        /// building anything.
        public let make: @Sendable (_ now: Int, _ weightStepKg: Double)
            -> (program: TrainingProgram, routines: [TrainingRoutine])

        public init(id: String, title: String, summary: String, daysPerWeek: Int,
                    requiredEquipment: Set<String>, origin: TrainingProgramOrigin,
                    make: @escaping @Sendable (Int, Double)
                        -> (program: TrainingProgram, routines: [TrainingRoutine])) {
            self.id = id
            self.title = title
            self.summary = summary
            self.daysPerWeek = daysPerWeek
            self.requiredEquipment = requiredEquipment
            self.origin = origin
            self.make = make
        }
    }

    /// Every template, in the order the list shows them: the wearer's own shapes first, then the
    /// named programmes.
    public static func templates(exercises: [TrainingExercise]) -> [Template] {
        own(exercises: exercises) + published()
    }

    // MARK: - Built from this app's own rules

    private static func own(exercises: [TrainingExercise]) -> [Template] {
        [
            builderTemplate(id: "own-fullbody-3", title: "Full body, three days",
                            summary: "Three sessions a week, each one covering the whole body.",
                            request: PlanRequest(daysPerWeek: 3), exercises: exercises,
                            requiredEquipment: []),
            builderTemplate(id: "own-upper-lower-4", title: "Upper and lower, four days",
                            summary: "Two upper body and two lower body sessions a week.",
                            request: PlanRequest(daysPerWeek: 4, experience: .intermediate),
                            exercises: exercises, requiredEquipment: []),
            builderTemplate(id: "own-ppl-6", title: "Push, pull and legs, six days",
                            summary: "Each pattern twice a week, for someone already training a lot.",
                            request: PlanRequest(daysPerWeek: 6, experience: .advanced),
                            exercises: exercises, requiredEquipment: []),
            builderTemplate(id: "own-bodyweight-3", title: "Body weight only, three days",
                            summary: "No equipment beyond a bar to hang from.",
                            request: PlanRequest(daysPerWeek: 3, equipment: ["bodyweight", "bar"],
                                                 title: "Body weight plan"),
                            exercises: exercises, requiredEquipment: [])
        ]
    }

    private static func builderTemplate(id: String, title: String, summary: String,
                                        request: PlanRequest, exercises: [TrainingExercise],
                                        requiredEquipment: Set<String>) -> Template {
        Template(id: id, title: title, summary: summary, daysPerWeek: request.daysPerWeek,
                 requiredEquipment: requiredEquipment, origin: .builder) { now, step in
            var withStep = request
            withStep.weightStepKg = step
            withStep.title = request.title ?? title
            return PlanBuilder.build(withStep, exercises: exercises, now: now)
        }
    }

    // MARK: - Named published programmes

    private static func published() -> [Template] {
        [
            Template(id: "stronglifts-5x5", title: "5×5, three days",
                     summary: "Two alternating barbell sessions, five sets of five.",
                     daysPerWeek: 3, requiredEquipment: ["barbell", "bench", "squat-rack"],
                     origin: TrainingProgramOrigin(kind: .published, name: "StrongLifts 5×5",
                                                   attribution: "Mehdi Hadim")) { now, step in
                fiveByFive(now: now, weightStepKg: step)
            },
            Template(id: "greyskull-lp", title: "Greyskull LP, three days",
                     summary: "Two alternating sessions, the last set taken as far as it goes.",
                     daysPerWeek: 3, requiredEquipment: ["barbell", "bench", "squat-rack"],
                     origin: TrainingProgramOrigin(kind: .published, name: "Greyskull LP",
                                                   attribution: "John Sheaffer")) { now, step in
                greyskull(now: now, weightStepKg: step)
            }
        ]
    }

    /// The programme as published: squat every session, pressing and pulling alternating, five sets
    /// of five throughout and one set of five on the deadlift.
    ///
    /// It alternates its two sessions week by week (A, B, A then B, A, B). A repeating week cannot
    /// say that, so the plan carries the first week and its notes say what to do in the second, which
    /// is the honest way round: a silently flattened programme would stop being the programme.
    private static func fiveByFive(now: Int, weightStepKg: Double)
        -> (program: TrainingProgram, routines: [TrainingRoutine]) {
        let progression = ProgressionConfiguration(policy: .linear, weightIncrementKg: weightStepKg,
                                                   repsMin: 5, repsMax: 5)
        var program = TrainingProgram(
            title: "5×5", kind: .strength,
            notes: "Sessions alternate: A, B, A one week, then B, A, B the next. Swap the two "
                 + "routines on the third day each week.",
            targets: TrainingProgramTargets(sessionsPerWeek: 3), isActive: false,
            origin: TrainingProgramOrigin(kind: .published, name: "StrongLifts 5×5",
                                          attribution: "Mehdi Hadim"),
            createdAt: now, updatedAt: now)
        let a = routine("5×5 A", program: program.id, now: now, progression: progression, entries: [
            ("noop:back-squat", 5, 5, 180),
            ("noop:barbell-bench-press", 5, 5, 180),
            ("noop:barbell-row", 5, 5, 180)
        ])
        let b = routine("5×5 B", program: program.id, now: now, progression: progression, entries: [
            ("noop:back-squat", 5, 5, 180),
            ("noop:overhead-press", 5, 5, 180),
            ("noop:deadlift", 1, 5, 180)
        ])
        program.schedule = [.monday: [a.id], .wednesday: [b.id], .friday: [a.id]]
        return (program, [a, b])
    }

    /// The programme as published: two sets of five and a last set taken as far as it goes, with the
    /// app's own Greyskull progression doing what the programme asks of a missed session.
    ///
    /// The open last set is stored as a set with a lower bound and no upper one, which is what "5+"
    /// means and what the logger already understands.
    private static func greyskull(now: Int, weightStepKg: Double)
        -> (program: TrainingProgram, routines: [TrainingRoutine]) {
        let progression = ProgressionConfiguration(policy: .greyskullLP,
                                                   weightIncrementKg: weightStepKg,
                                                   repsMin: 5, repsMax: 5)
        var program = TrainingProgram(
            title: "Greyskull LP", kind: .strength,
            notes: "Sessions alternate: A, B, A one week, then B, A, B the next. The last set of "
                 + "each lift is taken as far as it goes.",
            targets: TrainingProgramTargets(sessionsPerWeek: 3), isActive: false,
            origin: TrainingProgramOrigin(kind: .published, name: "Greyskull LP",
                                          attribution: "John Sheaffer"),
            createdAt: now, updatedAt: now)
        let a = openLastSetRoutine("Greyskull A", program: program.id, now: now,
                                   progression: progression,
                                   exerciseIds: ["noop:barbell-bench-press", "noop:back-squat"])
        let b = openLastSetRoutine("Greyskull B", program: program.id, now: now,
                                   progression: progression,
                                   exerciseIds: ["noop:overhead-press", "noop:deadlift"])
        program.schedule = [.monday: [a.id], .wednesday: [b.id], .friday: [a.id]]
        return (program, [a, b])
    }

    // MARK: - Helpers

    /// `entries` are exercise id, number of sets, repetitions per set and rest in seconds.
    private static func routine(_ title: String, program: UUID, now: Int,
                                progression: ProgressionConfiguration,
                                entries: [(String, Int, Int, Int)]) -> TrainingRoutine {
        TrainingRoutine(title: title, exercises: entries.map { id, sets, reps, rest in
            RoutineExercise(exerciseId: id,
                            sets: [RoutineSetPlan(phase: .warmup, repsMin: 5, repsMax: 5)]
                                + (0..<sets).map { _ in RoutineSetPlan(repsMin: reps, repsMax: reps) },
                            restSeconds: rest, warmupRestSeconds: 60, progression: progression)
        }, defaultProgression: progression, programId: program, createdAt: now, updatedAt: now)
    }

    private static func openLastSetRoutine(_ title: String, program: UUID, now: Int,
                                           progression: ProgressionConfiguration,
                                           exerciseIds: [String]) -> TrainingRoutine {
        TrainingRoutine(title: title, exercises: exerciseIds.map { id in
            RoutineExercise(exerciseId: id, sets: [
                RoutineSetPlan(phase: .warmup, repsMin: 5, repsMax: 5),
                RoutineSetPlan(repsMin: 5, repsMax: 5),
                RoutineSetPlan(repsMin: 5, repsMax: 5),
                // "5+": a lower bound and no upper one.
                RoutineSetPlan(repsMin: 5, repsMax: nil)
            ], restSeconds: 180, warmupRestSeconds: 60, progression: progression)
        }, defaultProgression: progression, programId: program, createdAt: now, updatedAt: now)
    }
}
