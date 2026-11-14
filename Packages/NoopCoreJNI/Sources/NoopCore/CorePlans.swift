import Foundation
import StrandCore
import StrandTraining
import WhoopStore

/// Training plans for Android: the plans a wearer holds, what each one amounts to, the ready-made
/// ones, the builder, and a session kept as a routine.
///
/// Everything here is a thin shell over `StrandTraining` and the store. Kotlin asks and draws; the
/// deciding, the counting and the rules all stay in the core, so both platforms answer from the same
/// code rather than from two implementations that drift.
public enum CorePlans {

    // MARK: - What Kotlin reads

    public struct Routine: Encodable {
        public var id: String
        public var title: String
        public var exerciseCount: Int
        public var minutes: Int
        /// ISO weekdays, Monday 1.
        public var weekdays: [Int]
    }

    public struct Block: Encodable {
        public var weeks: Int
        public var progression: String
        public var deloadInFinalWeek: Bool
        public var deloadEveryWeeks: Int?
        public var deloadFactor: Double
        /// Nil while the plan is resting: a plan nobody follows has no week to report.
        public var week: Int?
        public var isDeload: Bool
        public var isFinished: Bool
    }

    public struct Plan: Encodable {
        public var id: String
        public var title: String
        public var kind: String
        public var notes: String?
        public var isActive: Bool
        public var sessionsPerWeek: Int?
        public var cardioMinutesPerWeek: Int?
        public var originKind: String
        public var originName: String?
        public var originAttribution: String?
        public var block: Block?
        public var routines: [Routine]
        /// Weekday (ISO, Monday 1) to the routine ids planned on it.
        public var days: [String: [String]]
    }

    public struct Finding: Encodable {
        public var kind: String
        public var region: String?
        public var weeklySets: Double?
        public var usualWeeklySets: Double?
        public var firstWeekday: Int?
        public var secondWeekday: Int?
        public var routineId: String?
        public var minutes: Int?
        public var askedMinutes: Int?
    }

    public struct Review: Encodable {
        public var setsByRegion: [String: Double]
        public var minutesByRoutine: [String: Int]
        public var sessionsPerWeek: Int
        public var findings: [Finding]
    }

    public struct Template: Encodable {
        public var id: String
        public var title: String
        public var summary: String
        public var daysPerWeek: Int
        public var requiredEquipment: [String]
        public var sourceName: String?
        public var sourceAttribution: String?
    }

    public struct BlockRun: Encodable {
        public var id: String
        public var startedOn: String
        public var endedOn: String?
        public var outcome: String
        public var plannedSessions: Int?
        public var doneSessions: Int
        public var daysTrained: Int
        public var workSets: Int
        public var loadKg: Double
        public var unpricedWorkSets: Int
        /// How this run compared with the one before it, when there was one.
        public var deltaWorkSets: Int?
        public var deltaLoadKg: Double?
    }

    public struct Snapshot: Encodable {
        public var plans: [Plan]
        public var templates: [Template]
    }

    /// A plan the builder has produced but nobody has saved, with what it amounts to.
    public struct Preview: Encodable {
        public var title: String
        public var routines: [PreviewRoutine]
        public var review: Review
    }

    public struct PreviewRoutine: Encodable {
        public var title: String
        public var minutes: Int
        public var lines: [String]
    }

    // MARK: - Reads

    public static func snapshot(store: WhoopStore, today: String) async -> Snapshot {
        let programs = (try? await store.trainingPrograms()) ?? []
        let routines = (try? await store.trainingRoutines()) ?? []
        let exercises = Dictionary(((try? await store.trainingExercises()) ?? []).map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        return Snapshot(plans: programs.map { plan($0, routines: routines, today: today) },
                        templates: TrainingProgramCatalog.templates(exercises: Array(exercises.values))
                            .map(template))
    }

    static func plan(_ program: TrainingProgram, routines: [TrainingRoutine], today: String) -> Plan {
        let mine = TrainingProgramEditing.inWeekOrder(
            routines.filter { $0.programId == program.id }, schedule: program.schedule)
        let state = TrainingBlockState.resolve(block: program.block, today: today)
        return Plan(
            id: program.id.uuidString, title: program.title, kind: program.kind.rawValue,
            notes: program.notes, isActive: program.isActive,
            sessionsPerWeek: program.targets.sessionsPerWeek,
            cardioMinutesPerWeek: program.targets.cardioMinutesPerWeek,
            originKind: program.origin.kind.rawValue, originName: program.origin.name,
            originAttribution: program.origin.attribution,
            block: program.block.map { block in
                Block(weeks: block.weeks, progression: block.progression.rawValue,
                      deloadInFinalWeek: block.deloadInFinalWeek,
                      deloadEveryWeeks: block.deloadEveryWeeks, deloadFactor: block.deloadFactor,
                      week: state?.week, isDeload: state?.isDeload ?? false,
                      isFinished: state?.isFinished ?? false)
            },
            routines: mine.map { routine in
                Routine(id: routine.id.uuidString, title: routine.title,
                        exerciseCount: routine.exercises.count,
                        minutes: SessionEstimate.minutes(routine),
                        weekdays: RoutineEditing.weekdays(of: routine.id, in: program.schedule)
                            .map(\.rawValue).sorted())
            },
            days: program.schedule.reduce(into: [String: [String]]()) { out, entry in
                out[String(entry.key.rawValue)] = entry.value.map(\.uuidString)
            })
    }

    static func template(_ entry: TrainingProgramCatalog.Template) -> Template {
        Template(id: entry.id, title: entry.title, summary: entry.summary,
                 daysPerWeek: entry.daysPerWeek,
                 requiredEquipment: entry.requiredEquipment.sorted(),
                 sourceName: entry.origin.name, sourceAttribution: entry.origin.attribution)
    }

    /// What a plan amounts to in a week, measured against the wearer's own recent sessions.
    public static func review(store: WhoopStore, planId: String, askedMinutes: Int?) async -> Review? {
        guard let id = UUID(uuidString: planId),
              let program = (try? await store.trainingPrograms())?.first(where: { $0.id == id })
        else { return nil }
        let routines = ((try? await store.trainingRoutines()) ?? []).filter { $0.programId == id }
        let exercises = Dictionary(((try? await store.trainingExercises()) ?? []).map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        let now = Int(Date().timeIntervalSince1970)
        let workouts = (try? await store.nativeWorkouts(from: now - 120 * 86_400, to: now + 86_400)) ?? []
        return encode(PlanReview.evaluate(
            program: program, routines: routines, exercises: exercises,
            askedMinutesPerSession: askedMinutes,
            history: PlanHistory.from(workouts: workouts, exercises: exercises, now: now)))
    }

    static func encode(_ review: PlanReview) -> Review {
        Review(setsByRegion: review.weeklySetsByRegion.reduce(into: [String: Double]()) { out, entry in
                   out[entry.key.rawValue] = entry.value
               },
               minutesByRoutine: review.sessionMinutes.reduce(into: [String: Int]()) { out, entry in
                   out[entry.key.uuidString] = entry.value
               },
               sessionsPerWeek: review.weeklySessionCount,
               findings: review.findings.map(encode))
    }

    static func encode(_ finding: PlanReview.Finding) -> Finding {
        switch finding {
        case .regionUntrained(let region):
            return Finding(kind: "regionUntrained", region: region.rawValue)
        case .regionAboveUsual(let region, let weekly, let usual):
            return Finding(kind: "regionAboveUsual", region: region.rawValue,
                           weeklySets: weekly, usualWeeklySets: usual)
        case .heavyDaysBackToBack(let first, let second):
            return Finding(kind: "heavyDaysBackToBack", firstWeekday: first.rawValue,
                           secondWeekday: second.rawValue)
        case .sessionLongerThanAsked(let routineId, let minutes, let asked):
            return Finding(kind: "sessionLongerThanAsked", routineId: routineId.uuidString,
                           minutes: minutes, askedMinutes: asked)
        }
    }

    /// The blocks a plan has run, newest first, each with what the workout log says about its own
    /// window and how it compared with the block before it.
    public static func blockRuns(store: WhoopStore, planId: String, today: String) async -> [BlockRun] {
        guard let id = UUID(uuidString: planId) else { return [] }
        let runs = (try? await store.trainingBlockRuns(programId: id)) ?? []
        guard !runs.isEmpty else { return [] }
        let program = (try? await store.trainingPrograms())?.first { $0.id == id }
        let exercises = Dictionary(((try? await store.trainingExercises()) ?? []).map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        let workouts = (try? await store.nativeWorkouts(from: 0, to: Int(Date().timeIntervalSince1970) + 86_400)) ?? []
        let reports = runs.map {
            BlockReport.make(run: $0, workouts: workouts, exercises: exercises,
                             sessionsPerWeek: program?.targets.sessionsPerWeek, today: today)
        }
        return reports.enumerated().reversed().map { index, report in
            let previous = index > 0 ? BlockReport.compare(previous: reports[index - 1], current: report) : nil
            return BlockRun(id: report.run.id.uuidString, startedOn: report.run.startedOn,
                            endedOn: report.run.endedOn, outcome: report.run.outcome.rawValue,
                            plannedSessions: report.plannedSessions, doneSessions: report.doneSessions,
                            daysTrained: report.daysTrained, workSets: report.workSets,
                            loadKg: report.loadKg, unpricedWorkSets: report.unpricedWorkSets,
                            deltaWorkSets: previous?.workSets, deltaLoadKg: previous?.loadKg)
        }
    }

    // MARK: - Writes

    /// Creates or edits a plan. Only the fields given are changed, so Kotlin can send a title alone.
    public static func save(store: WhoopStore, args: [String: Any]) async -> String? {
        let programs = (try? await store.trainingPrograms()) ?? []
        let now = Int(Date().timeIntervalSince1970)
        var program: TrainingProgram
        if let raw = args["id"] as? String, let id = UUID(uuidString: raw),
           let existing = programs.first(where: { $0.id == id }) {
            program = existing
        } else {
            program = TrainingProgram(title: "", createdAt: now, updatedAt: now)
        }
        if let title = args["title"] as? String { program.title = title }
        if let kind = (args["kind"] as? String).flatMap(TrainingProgramKind.init(rawValue:)) {
            program.kind = kind
        }
        if args.keys.contains("notes") { program.notes = (args["notes"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        if args.keys.contains("sessionsPerWeek") || args.keys.contains("cardioMinutesPerWeek") {
            program.targets = TrainingProgramTargets(
                sessionsPerWeek: (args["sessionsPerWeek"] as? NSNumber)?.intValue,
                cardioMinutesPerWeek: (args["cardioMinutesPerWeek"] as? NSNumber)?.intValue,
                effortLow: program.targets.effortLow, effortHigh: program.targets.effortHigh)
        }
        if args.keys.contains("blockWeeks") {
            if let weeks = (args["blockWeeks"] as? NSNumber)?.intValue, weeks > 0 {
                var block = program.block ?? TrainingProgramBlock()
                block.weeks = weeks
                if let deload = args["deloadInFinalWeek"] as? Bool { block.deloadInFinalWeek = deload }
                if args.keys.contains("deloadEveryWeeks") {
                    block.deloadEveryWeeks = (args["deloadEveryWeeks"] as? NSNumber)?.intValue
                }
                if let policy = (args["blockProgression"] as? String)
                    .flatMap(BlockProgressionPolicy.init(rawValue:)) {
                    block.progression = policy
                }
                // A block already running keeps the day it started from: editing a plan must not put
                // the wearer back in week one.
                block.startedOn = program.block?.startedOn
                program.block = TrainingProgramBlock(weeks: block.weeks,
                                                     deloadInFinalWeek: block.deloadInFinalWeek,
                                                     deloadEveryWeeks: block.deloadEveryWeeks,
                                                     deloadFactor: block.deloadFactor,
                                                     progression: block.progression,
                                                     startedOn: block.startedOn)
            } else {
                program.block = nil
            }
        }
        program.updatedAt = now
        guard (try? await store.upsertTrainingProgram(program)) != nil else { return nil }
        return program.id.uuidString
    }

    public static func activate(store: WhoopStore, id: String, day: String) async -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        return (try? await store.activateTrainingProgram(id: uuid, day: day,
                                                         now: Int(Date().timeIntervalSince1970))) != nil
    }

    public static func deactivate(store: WhoopStore, id: String, day: String) async -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        return (try? await store.deactivateTrainingProgram(id: uuid, day: day,
                                                           now: Int(Date().timeIntervalSince1970))) != nil
    }

    public static func delete(store: WhoopStore, id: String) async -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        return (try? await store.deleteTrainingProgram(id: uuid)) != nil
    }

    /// An independent copy, resting, through the same core helper Apple uses.
    public static func duplicate(store: WhoopStore, id: String, title: String) async -> String? {
        guard let uuid = UUID(uuidString: id),
              let program = (try? await store.trainingPrograms())?.first(where: { $0.id == uuid })
        else { return nil }
        let routines = ((try? await store.trainingRoutines()) ?? []).filter { $0.programId == uuid }
        let copy = TrainingProgramEditing.duplicate(program, routines: routines, title: title,
                                                     now: Int(Date().timeIntervalSince1970))
        return await write(copy.program, routines: copy.routines, store: store, activate: false,
                           day: nil)
    }

    /// Writes a built plan: the plan, then its routines, then its week once they exist, since a
    /// scheduled day points at a routine.
    static func write(_ program: TrainingProgram, routines: [TrainingRoutine], store: WhoopStore,
                      activate: Bool, day: String?) async -> String? {
        var resting = program
        resting.isActive = false
        resting.block?.startedOn = nil
        // One transaction in the right order: a scheduled day points at a routine, so the week
        // cannot be written before the routines are there.
        guard (try? await store.upsertTrainingPlan(resting, routines: routines)) != nil else { return nil }
        if activate, let day {
            try? await store.activateTrainingProgram(id: program.id, day: day,
                                                     now: Int(Date().timeIntervalSince1970))
        }
        return program.id.uuidString
    }

    /// Builds a plan from the wearer's answers. With `save` false it is only shown, which is what the
    /// wizard's preview is for: nothing is written until they say so.
    public static func build(store: WhoopStore, args: [String: Any], today: String) async -> Preview? {
        let exercises = (try? await store.trainingExercises()) ?? []
        var request = PlanRequest(
            daysPerWeek: (args["daysPerWeek"] as? NSNumber)?.intValue ?? 3,
            equipment: Set((args["equipment"] as? [String] ?? []).map { $0.lowercased() }),
            experience: TrainingExperience(rawValue: args["experience"] as? String ?? "") ?? .beginner,
            emphasis: TrainingEmphasis(rawValue: args["emphasis"] as? String ?? "") ?? .balanced,
            minutesPerSession: (args["minutes"] as? NSNumber)?.intValue ?? 60,
            weightStepKg: (args["weightStepKg"] as? NSNumber)?.doubleValue ?? 2.5,
            title: args["title"] as? String)
        if let weeks = (args["blockWeeks"] as? NSNumber)?.intValue, weeks > 0 {
            request.block = TrainingProgramBlock(weeks: weeks)
        }
        let now = Int(Date().timeIntervalSince1970)
        let built = PlanBuilder.build(request, exercises: exercises, now: now)
        guard !built.routines.isEmpty else { return nil }
        if args["save"] as? Bool == true {
            _ = await write(built.program, routines: built.routines, store: store,
                            activate: args["activate"] as? Bool == true, day: today)
        }
        return preview(built.program, routines: built.routines, exercises: exercises,
                       askedMinutes: request.minutesPerSession, store: store)
    }

    /// Writes one of the ready-made plans, resting, and returns its id.
    public static func useTemplate(store: WhoopStore, id: String, weightStepKg: Double) async -> String? {
        let exercises = (try? await store.trainingExercises()) ?? []
        guard let template = TrainingProgramCatalog.templates(exercises: exercises)
            .first(where: { $0.id == id }) else { return nil }
        let built = template.make(Int(Date().timeIntervalSince1970), weightStepKg)
        return await write(built.program, routines: built.routines, store: store, activate: false,
                           day: nil)
    }

    static func preview(_ program: TrainingProgram, routines: [TrainingRoutine],
                        exercises: [TrainingExercise], askedMinutes: Int,
                        store: WhoopStore) -> Preview {
        let byId = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let review = PlanReview.evaluate(program: program, routines: routines, exercises: byId,
                                         askedMinutesPerSession: askedMinutes)
        return Preview(
            title: program.title,
            routines: routines.map { routine in
                PreviewRoutine(title: routine.title, minutes: SessionEstimate.minutes(routine),
                               lines: routine.exercises.map { entry in
                                   let name = byId[entry.exerciseId]?.title ?? entry.exerciseId
                                   let work = entry.sets.filter { $0.phase == .work }
                                   guard let first = work.first else { return name }
                                   if let low = first.repsMin {
                                       let high = first.repsMax.map { $0 == low ? "\($0)" : "\(low)–\($0)" } ?? "\(low)+"
                                       return "\(name): \(work.count) × \(high)"
                                   }
                                   if let seconds = first.targetDurationS {
                                       return "\(name): \(work.count) × \(seconds)s"
                                   }
                                   return "\(name): \(work.count)"
                               })
            },
            review: encode(review))
    }

    /// Keeps a session that has been done as a routine, in the plan the wearer picked.
    public static func routineFromWorkout(store: WhoopStore, workoutId: String, title: String,
                                          planId: String?) async -> Bool {
        // Android hands over the id its session page carries, which for a NOOP session is the
        // projected, prefixed one.
        guard let id = NativeTrainingProjection.nativeWorkoutId(workoutId) else { return false }
        let now = Int(Date().timeIntervalSince1970)
        let workouts = (try? await store.nativeWorkouts(from: 0, to: now + 86_400)) ?? []
        guard let workout = workouts.first(where: { $0.id == id }),
              let routine = RoutineFromWorkout.make(workout: workout, title: title,
                                                     programId: planId.flatMap(UUID.init(uuidString:)),
                                                     now: now)
        else { return false }
        return (try? await store.upsertTrainingRoutine(routine)) != nil
    }
}

/// One routine in full, and the single-step edits a screen makes to it.
///
/// Android edits a routine the way it already edits a live session: it reads what to draw and sends
/// one operation at a time, so the model, the defaults and the saving all stay in the core. Building
/// a routine's JSON in Kotlin would be a second copy of the model, and the two would drift.
extension CorePlans {

    public struct SetPlan: Encodable {
        public var id: String
        public var phase: String
        public var intensifier: String
        public var weightKg: Double?
        public var repsMin: Int?
        public var repsMax: Int?
        public var durationS: Int?
        public var distanceM: Double?
    }

    public struct Progression: Encodable {
        public var policy: String
        public var weightIncrementKg: Double
        public var repsMin: Int
        public var repsMax: Int
        public var failuresBeforeDeload: Int
    }

    public struct RoutineExerciseDetail: Encodable {
        public var id: String
        public var exerciseId: String
        public var title: String
        public var mode: String
        public var restSeconds: Int
        public var warmupRestSeconds: Int?
        public var supersetId: String?
        public var note: String?
        /// Nil when the exercise follows the routine's own default.
        public var progression: Progression?
        public var sets: [SetPlan]
    }

    public struct RoutineDetail: Encodable {
        public var id: String
        public var title: String
        public var notes: String?
        public var planId: String?
        public var planTitle: String?
        public var weekdays: [Int]
        public var minutes: Int
        public var defaultProgression: Progression
        public var excludeFromProgression: Bool
        public var exercises: [RoutineExerciseDetail]
    }

    public static func routine(store: WhoopStore, id: String) async -> RoutineDetail? {
        guard let uuid = UUID(uuidString: id),
              let routine = (try? await store.trainingRoutines())?.first(where: { $0.id == uuid })
        else { return nil }
        let exercises = Dictionary(((try? await store.trainingExercises()) ?? []).map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        let programs = (try? await store.trainingPrograms()) ?? []
        let plan = programs.first { $0.id == routine.programId }
        return RoutineDetail(
            id: routine.id.uuidString, title: routine.title, notes: routine.notes,
            planId: routine.programId?.uuidString, planTitle: plan?.title,
            weekdays: plan.map { RoutineEditing.weekdays(of: routine.id, in: $0.schedule)
                .map(\.rawValue).sorted() } ?? [],
            minutes: SessionEstimate.minutes(routine),
            defaultProgression: encode(routine.defaultProgression),
            excludeFromProgression: routine.excludeFromProgression,
            exercises: routine.exercises.map { entry in
                RoutineExerciseDetail(
                    id: entry.id.uuidString, exerciseId: entry.exerciseId,
                    title: exercises[entry.exerciseId]?.title ?? entry.exerciseId,
                    mode: (exercises[entry.exerciseId]?.mode ?? .weightReps).rawValue,
                    restSeconds: entry.restSeconds, warmupRestSeconds: entry.warmupRestSeconds,
                    supersetId: entry.supersetId?.uuidString, note: entry.note,
                    progression: entry.progression.map(encode),
                    sets: entry.sets.map { set in
                        SetPlan(id: set.id.uuidString, phase: set.phase.rawValue,
                                intensifier: set.intensifier.rawValue, weightKg: set.targetWeightKg,
                                repsMin: set.repsMin, repsMax: set.repsMax,
                                durationS: set.targetDurationS, distanceM: set.targetDistanceM)
                    })
            })
    }

    static func encode(_ configuration: ProgressionConfiguration) -> Progression {
        Progression(policy: configuration.policy.rawValue,
                    weightIncrementKg: configuration.weightIncrementKg,
                    repsMin: configuration.repsMin, repsMax: configuration.repsMax,
                    failuresBeforeDeload: configuration.failuresBeforeDeload)
    }

    /// Applies ONE edit to a routine and saves it. The caller names the operation; what a new set or a
    /// new exercise starts out as is decided here, once, for both platforms.
    public static func editRoutine(store: WhoopStore, args: [String: Any]) async -> Bool {
        let op = args["op"] as? String ?? ""
        let routineId = args["routineId"] as? String ?? ""
        let now = Int(Date().timeIntervalSince1970)
        let exercises = Dictionary(((try? await store.trainingExercises()) ?? []).map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })

        // Creating one is its own case: there is no routine to read yet. `createRoutine` is what a
        // screen calls when it needs the new id back, which is how a routine being written can take
        // exercises before it is saved.
        if op == "create" {
            return await createRoutine(store: store, title: args["title"] as? String ?? "",
                                       planId: args["planId"] as? String) != nil
        }

        guard let uuid = UUID(uuidString: routineId),
              var routine = (try? await store.trainingRoutines())?.first(where: { $0.id == uuid })
        else { return false }
        let entryId = (args["exerciseEntryId"] as? String).flatMap(UUID.init(uuidString:))
        let index = routine.exercises.firstIndex { $0.id == entryId }

        switch op {
        case "title":
            routine.title = args["value"] as? String ?? routine.title
        case "notes":
            let value = args["value"] as? String
            routine.notes = (value?.isEmpty ?? true) ? nil : value
        case "excludeFromProgression":
            routine.excludeFromProgression = args["value"] as? Bool ?? routine.excludeFromProgression
        case "defaultProgression":
            routine.defaultProgression = progression(args, from: routine.defaultProgression)
        case "addExercise":
            guard let id = args["exerciseId"] as? String else { return false }
            let mode = exercises[id]?.mode ?? .weightReps
            routine.exercises.append(RoutineExercise(
                exerciseId: id,
                sets: RoutineSetPlan.defaults(for: mode, count: (args["sets"] as? NSNumber)?.intValue ?? 3),
                restSeconds: (args["restSeconds"] as? NSNumber)?.intValue ?? 120,
                warmupRestSeconds: (args["warmupRestSeconds"] as? NSNumber)?.intValue ?? 60))
        case "removeExercise":
            guard let index else { return false }
            routine.exercises.remove(at: index)
            cleanSupersets(&routine)
        case "moveExercise":
            guard let index, let to = (args["toIndex"] as? NSNumber)?.intValue,
                  routine.exercises.indices.contains(to) else { return false }
            let entry = routine.exercises.remove(at: index)
            routine.exercises.insert(entry, at: to)
        case "rest":
            guard let index, let seconds = (args["value"] as? NSNumber)?.intValue else { return false }
            routine.exercises[index].restSeconds = max(0, seconds)
        case "warmupRest":
            guard let index, let seconds = (args["value"] as? NSNumber)?.intValue else { return false }
            routine.exercises[index].warmupRestSeconds = max(0, seconds)
        case "exerciseNote":
            guard let index else { return false }
            let value = args["value"] as? String
            routine.exercises[index].note = (value?.isEmpty ?? true) ? nil : value
        case "exerciseProgression":
            guard let index else { return false }
            if args["value"] == nil || args["value"] is NSNull {
                routine.exercises[index].progression = nil      // follow the routine's default
            } else {
                routine.exercises[index].progression = progression(
                    args, from: routine.exercises[index].progression ?? routine.defaultProgression)
            }
        case "superset":
            // Pairs this exercise with the one after it, or breaks the pair it is in.
            guard let index else { return false }
            if routine.exercises[index].supersetId != nil {
                routine.exercises[index].supersetId = nil
                cleanSupersets(&routine)
            } else if routine.exercises.indices.contains(index + 1) {
                let group = routine.exercises[index + 1].supersetId ?? UUID()
                routine.exercises[index].supersetId = group
                routine.exercises[index + 1].supersetId = group
            }
        case "addSet":
            guard let index else { return false }
            let warmup = args["warmup"] as? Bool == true
            let mode = exercises[routine.exercises[index].exerciseId]?.mode ?? .weightReps
            let template = routine.exercises[index].sets.last { $0.phase == (warmup ? .warmup : .work) }
            routine.exercises[index].sets.append(RoutineSetPlan(
                phase: warmup ? .warmup : .work,
                targetWeightKg: template?.targetWeightKg,
                repsMin: template?.repsMin ?? (mode.recordsRepetitions ? 8 : nil),
                repsMax: template?.repsMax ?? (mode.recordsRepetitions ? 12 : nil),
                targetDurationS: template?.targetDurationS ?? (mode.recordsRepetitions ? nil : 45)))
        case "removeSet":
            guard let index, let setId = (args["setId"] as? String).flatMap(UUID.init(uuidString:))
            else { return false }
            routine.exercises[index].sets.removeAll { $0.id == setId }
        case "setValues":
            guard let index, let setId = (args["setId"] as? String).flatMap(UUID.init(uuidString:)),
                  let at = routine.exercises[index].sets.firstIndex(where: { $0.id == setId })
            else { return false }
            if args.keys.contains("weightKg") {
                routine.exercises[index].sets[at].targetWeightKg = (args["weightKg"] as? NSNumber)?.doubleValue
            }
            if args.keys.contains("repsMin") {
                routine.exercises[index].sets[at].repsMin = (args["repsMin"] as? NSNumber)?.intValue
            }
            if args.keys.contains("repsMax") {
                routine.exercises[index].sets[at].repsMax = (args["repsMax"] as? NSNumber)?.intValue
            }
            if args.keys.contains("durationS") {
                routine.exercises[index].sets[at].targetDurationS = (args["durationS"] as? NSNumber)?.intValue
            }
        case "delete":
            return (try? await store.deleteTrainingRoutine(id: uuid)) != nil
        case "weekdays":
            // The routine's days belong to ITS plan, not to the week being followed.
            guard let planId = routine.programId,
                  let plan = (try? await store.trainingPrograms())?.first(where: { $0.id == planId })
            else { return false }
            let wanted = Set((args["value"] as? [Int] ?? []).compactMap(TrainingWeekday.init(rawValue:)))
            let schedule = RoutineEditing.schedule(plan.schedule, assigning: uuid, to: wanted)
            return (try? await store.replaceTrainingSchedule(schedule, programId: planId)) != nil
        default:
            return false
        }
        routine.updatedAt = now
        return (try? await store.upsertTrainingRoutine(routine)) != nil
    }

    /// Creates a routine and hands back its id, so a screen can keep editing the thing it just made.
    public static func createRoutine(store: WhoopStore, title: String,
                                     planId: String?) async -> String? {
        let now = Int(Date().timeIntervalSince1970)
        let routine = TrainingRoutine(title: title,
                                      programId: planId.flatMap(UUID.init(uuidString:)),
                                      createdAt: now, updatedAt: now)
        guard (try? await store.upsertTrainingRoutine(routine)) != nil else { return nil }
        return routine.id.uuidString
    }

    /// A superset group with only one exercise left in it is not a superset.
    static func cleanSupersets(_ routine: inout TrainingRoutine) {
        var counts: [UUID: Int] = [:]
        for entry in routine.exercises { if let group = entry.supersetId { counts[group, default: 0] += 1 } }
        for index in routine.exercises.indices {
            if let group = routine.exercises[index].supersetId, counts[group] ?? 0 < 2 {
                routine.exercises[index].supersetId = nil
            }
        }
    }

    static func progression(_ args: [String: Any],
                            from current: ProgressionConfiguration) -> ProgressionConfiguration {
        ProgressionConfiguration(
            policy: (args["policy"] as? String).flatMap(ProgressionPolicy.init(rawValue:)) ?? current.policy,
            weightIncrementKg: (args["weightIncrementKg"] as? NSNumber)?.doubleValue ?? current.weightIncrementKg,
            repsMin: (args["repsMin"] as? NSNumber)?.intValue ?? current.repsMin,
            repsMax: (args["repsMax"] as? NSNumber)?.intValue ?? current.repsMax,
            failuresBeforeDeload: (args["failuresBeforeDeload"] as? NSNumber)?.intValue ?? current.failuresBeforeDeload,
            deloadFactor: current.deloadFactor, bodyweightMaxSets: current.bodyweightMaxSets,
            targetEffort: current.targetEffort)
    }
}
