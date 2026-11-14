import Foundation

/// How much training the wearer has behind them. It decides how many sets a movement gets, in what
/// repetition range, and how a prescription is meant to move.
public enum TrainingExperience: String, Codable, CaseIterable, Sendable {
    case beginner
    case intermediate
    case advanced
}

/// What the plan should lean towards. Balanced is the default because it is the honest answer when
/// nobody has said.
public enum TrainingEmphasis: String, Codable, CaseIterable, Sendable {
    case balanced
    case strength
    case hypertrophy
    case upperBody
    case lowerBody
}

/// The answers a plan is built from.
public struct PlanRequest: Equatable, Sendable {
    public var daysPerWeek: Int
    /// Canonical equipment ids the wearer has. Empty means no filter, exactly as the exercise
    /// library's own "available equipment" setting behaves.
    public var equipment: Set<String>
    public var experience: TrainingExperience
    public var emphasis: TrainingEmphasis
    public var minutesPerSession: Int
    /// The smallest weight step this wearer can actually load, from their settings.
    public var weightStepKg: Double
    public var title: String?
    /// A block, when the wearer wants the plan to run for a fixed number of weeks.
    public var block: TrainingProgramBlock?

    public init(daysPerWeek: Int = 3, equipment: Set<String> = [],
                experience: TrainingExperience = .beginner,
                emphasis: TrainingEmphasis = .balanced, minutesPerSession: Int = 60,
                weightStepKg: Double = 2.5, title: String? = nil,
                block: TrainingProgramBlock? = nil) {
        self.daysPerWeek = min(6, max(2, daysPerWeek))
        self.equipment = equipment
        self.experience = experience
        self.emphasis = emphasis
        self.minutesPerSession = min(180, max(20, minutesPerSession))
        self.weightStepKg = max(0.5, weightStepKg)
        self.title = title
        self.block = block
    }
}

/// Builds a whole plan from a handful of answers: its routines, their exercises, sets, repetitions,
/// rests and progression, and the week they sit in.
///
/// **Why this is code and not a prompt.** A plan has to come out the same twice, has to work with no
/// network and no key, and has to be testable case by case. The coach can still propose one where it
/// is switched on, and goes through the same review before anything is saved.
///
/// **What the numbers are.** The split by days, the repetition ranges and the rests below are
/// ordinary strength-training practice, written down here with their reasons rather than hidden in a
/// table. They are a starting point the wearer edits, not a claim about what is right for them:
/// nothing in NOOP knows that. Where a judgement would need evidence about this wearer, the plan
/// review says what their own history has been and leaves the decision where it belongs.
public enum PlanBuilder {

    // MARK: - Shape of a session

    /// One slot in a session: a movement pattern and whether it is a main lift or an accessory.
    /// Patterns rather than exercise names, so the same shape works with a barbell, a pair of
    /// dumbbells or nothing but the floor.
    struct Slot {
        let pattern: TrainingMovementPattern
        let isCompound: Bool

        static func main(_ p: TrainingMovementPattern) -> Slot { Slot(pattern: p, isCompound: true) }
        static func extra(_ p: TrainingMovementPattern) -> Slot { Slot(pattern: p, isCompound: false) }
    }

    struct DayTemplate {
        let title: String
        let slots: [Slot]
    }

    /// The splits, by how many days a week the wearer has. Each is the common shape for that number:
    /// few days means every session covers the whole body, more days means each session can be
    /// narrower and still hit everything twice.
    static func split(days: Int, emphasis: TrainingEmphasis) -> [DayTemplate] {
        var templates: [DayTemplate]
        switch days {
        case 2:
            templates = [fullBody("Full body A", .squat, .horizontalPush, .horizontalPull),
                         fullBody("Full body B", .hinge, .verticalPush, .verticalPull)]
        case 3:
            templates = [fullBody("Full body A", .squat, .horizontalPush, .horizontalPull),
                         fullBody("Full body B", .hinge, .verticalPush, .verticalPull),
                         fullBody("Full body C", .lunge, .horizontalPush, .verticalPull)]
        case 4:
            templates = [upper("Upper A", vertical: false), lower("Lower A", hinge: false),
                         upper("Upper B", vertical: true), lower("Lower B", hinge: true)]
        case 5:
            templates = [push("Push"), pull("Pull"), legs("Legs"),
                         upper("Upper", vertical: true), lower("Lower", hinge: true)]
        default:
            templates = [push("Push A"), pull("Pull A"), legs("Legs A"),
                         push("Push B"), pull("Pull B"), legs("Legs B")]
        }
        return templates.map { DayTemplate(title: $0.title, slots: emphasised($0.slots, emphasis)) }
    }

    private static func fullBody(_ title: String, _ first: TrainingMovementPattern,
                                 _ push: TrainingMovementPattern,
                                 _ pull: TrainingMovementPattern) -> DayTemplate {
        DayTemplate(title: title, slots: [.main(first), .main(push), .main(pull),
                                          .extra(.trunkStability)])
    }

    private static func upper(_ title: String, vertical: Bool) -> DayTemplate {
        let first: TrainingMovementPattern = vertical ? .verticalPush : .horizontalPush
        let second: TrainingMovementPattern = vertical ? .horizontalPull : .verticalPull
        return DayTemplate(title: title, slots: [.main(first), .main(second),
                                                 .extra(.shoulderIsolation), .extra(.elbowFlexion),
                                                 .extra(.elbowExtension)])
    }

    private static func lower(_ title: String, hinge: Bool) -> DayTemplate {
        let first: TrainingMovementPattern = hinge ? .hinge : .squat
        let second: TrainingMovementPattern = hinge ? .lunge : .hinge
        return DayTemplate(title: title, slots: [.main(first), .main(second),
                                                 .extra(.kneeFlexion), .extra(.calfRaise),
                                                 .extra(.trunkFlexion)])
    }

    private static func push(_ title: String) -> DayTemplate {
        DayTemplate(title: title, slots: [.main(.horizontalPush), .main(.verticalPush),
                                          .extra(.shoulderIsolation), .extra(.elbowExtension)])
    }

    private static func pull(_ title: String) -> DayTemplate {
        DayTemplate(title: title, slots: [.main(.verticalPull), .main(.horizontalPull),
                                          .extra(.elbowFlexion), .extra(.trunkStability)])
    }

    private static func legs(_ title: String) -> DayTemplate {
        DayTemplate(title: title, slots: [.main(.squat), .main(.hinge),
                                          .extra(.kneeExtension), .extra(.calfRaise)])
    }

    /// What a lean adds. Nothing is taken away: an emphasis gives its region one more accessory, so
    /// a plan is never thinner than the balanced one.
    private static func emphasised(_ slots: [Slot], _ emphasis: TrainingEmphasis) -> [Slot] {
        switch emphasis {
        case .balanced, .strength, .hypertrophy:
            return slots
        case .upperBody:
            return slots.contains(where: { isUpper($0.pattern) })
                ? slots + [.extra(.horizontalPull)] : slots
        case .lowerBody:
            return slots.contains(where: { isLower($0.pattern) })
                ? slots + [.extra(.hinge)] : slots
        }
    }

    static func isUpper(_ pattern: TrainingMovementPattern) -> Bool {
        [.horizontalPush, .verticalPush, .horizontalPull, .verticalPull, .elbowFlexion,
         .elbowExtension, .shoulderIsolation].contains(pattern)
    }

    static func isLower(_ pattern: TrainingMovementPattern) -> Bool {
        [.squat, .hinge, .lunge, .kneeFlexion, .kneeExtension, .calfRaise].contains(pattern)
    }

    // MARK: - Prescription

    /// Sets and repetitions per slot. Lower repetitions and more rest for a main lift, more
    /// repetitions and less rest for an accessory; a strength lean goes lower still, a hypertrophy
    /// lean higher. Beginners get fewer sets, since the first weeks add strength without needing
    /// volume and a shorter session is one that actually happens.
    static func prescription(_ slot: Slot, request: PlanRequest) -> (sets: Int, low: Int, high: Int) {
        switch (slot.isCompound, request.experience, request.emphasis) {
        case (true, .beginner, .strength):      return (3, 4, 6)
        case (true, .beginner, _):              return (3, 6, 8)
        case (true, .intermediate, .strength):  return (4, 3, 5)
        case (true, .intermediate, .hypertrophy): return (4, 8, 12)
        case (true, .intermediate, _):          return (3, 5, 8)
        case (true, .advanced, .strength):      return (5, 3, 5)
        case (true, .advanced, .hypertrophy):   return (4, 8, 12)
        case (true, .advanced, _):              return (4, 4, 8)
        case (false, .beginner, _):             return (2, 10, 12)
        case (false, _, .hypertrophy):          return (3, 10, 15)
        case (false, _, _):                     return (3, 8, 12)
        }
    }

    /// Rest between sets. A main lift needs the minutes; an accessory does not, and giving it them
    /// is the quickest way to a session nobody has time for.
    static func restSeconds(_ slot: Slot, request: PlanRequest) -> Int {
        guard slot.isCompound else {
            return [.trunkStability, .trunkFlexion, .trunkExtension].contains(slot.pattern) ? 60 : 90
        }
        return request.emphasis == .strength ? 210 : 150
    }

    /// How a prescription is meant to move. A beginner adds weight while the sets stay easy, which
    /// linear progression says plainly; anyone past that earns the step by filling the repetition
    /// range first.
    static func progression(_ request: PlanRequest, low: Int, high: Int) -> ProgressionConfiguration {
        ProgressionConfiguration(
            policy: request.experience == .beginner ? .linear : .doubleProgression,
            weightIncrementKg: request.weightStepKg, repsMin: low, repsMax: high)
    }

    // MARK: - Which exercise

    /// The exercises that can fill a pattern, best first, out of the wearer's own library.
    ///
    /// Only the equipment they have, and never an exercise this plan already uses, so a session does
    /// not prescribe the same movement twice under two names. Reviewed anatomy comes first because a
    /// guessed pattern is a guessed session, and the order is fully determined so that building the
    /// same plan twice gives the same plan.
    static func candidates(for pattern: TrainingMovementPattern, slot: Slot,
                           from library: [(TrainingExercise, ExerciseAnatomy)],
                           equipment: Set<String>, used: Set<String>) -> [TrainingExercise] {
        library
            .filter { $0.1.movementPattern == pattern }
            .filter { !used.contains($0.0.id) }
            .filter { equipment.isEmpty || TrainingEquipmentCatalog.matches($0.0.equipmentIds, available: equipment) }
            .sorted { left, right in
                let (a, b) = (rank(left, slot: slot), rank(right, slot: slot))
                if a != b { return a < b }
                return left.0.title.localizedCaseInsensitiveCompare(right.0.title) == .orderedAscending
            }
            .map(\.0)
    }

    /// Lower sorts first. Reviewed mapping beats a guess; for a main lift a loaded implement beats
    /// body weight, because that is what can be stepped up week to week; for an accessory the order
    /// does not matter much and the title decides.
    private static func rank(_ entry: (TrainingExercise, ExerciseAnatomy), slot: Slot) -> Int {
        var score = entry.1.confidence == .reviewed ? 0 : 100
        if slot.isCompound {
            let ids = entry.0.equipmentIds.map(TrainingEquipmentCatalog.canonical)
            if ids.contains("barbell") { score += 0 }
            else if ids.contains("dumbbell") || ids.contains("kettlebell") { score += 2 }
            else if ids.contains("machine") || ids.contains("cable") { score += 4 }
            else { score += 6 }
        }
        return score
    }

    // MARK: - The build

    /// A plan, resting until the wearer takes it up, and its routines.
    ///
    /// Returns an empty list of routines only when the library cannot fill a single slot with the
    /// equipment given, which a caller should say out loud rather than saving an empty plan.
    public static func build(_ request: PlanRequest, exercises: [TrainingExercise],
                             now: Int) -> (program: TrainingProgram, routines: [TrainingRoutine]) {
        let library: [(TrainingExercise, ExerciseAnatomy)] = exercises.compactMap { exercise in
            guard let anatomy = TrainingMuscleProjection.anatomy(for: exercise) else { return nil }
            return (exercise, anatomy)
        }
        let templates = split(days: request.daysPerWeek, emphasis: request.emphasis)
        let days = weekdays(for: request.daysPerWeek)

        var program = TrainingProgram(
            title: request.title ?? defaultTitle(request),
            kind: .strength, targets: TrainingProgramTargets(sessionsPerWeek: request.daysPerWeek),
            block: request.block, isActive: false, origin: .builder,
            createdAt: now, updatedAt: now)
        var routines: [TrainingRoutine] = []
        var used = Set<String>()
        var schedule: [TrainingWeekday: [UUID]] = [:]

        for (index, template) in templates.enumerated() {
            var entries: [RoutineExercise] = []
            for slot in template.slots {
                // A pattern nothing can fill is skipped rather than substituted: a session with one
                // movement missing is honest, a session with a movement that does not belong is not.
                guard let exercise = candidates(for: slot.pattern, slot: slot, from: library,
                                                equipment: request.equipment, used: used).first
                      ?? candidates(for: slot.pattern, slot: slot, from: library,
                                    equipment: request.equipment, used: []).first
                else { continue }
                used.insert(exercise.id)
                entries.append(entry(exercise, slot: slot, request: request))
            }
            guard !entries.isEmpty else { continue }
            var routine = TrainingRoutine(
                title: template.title, exercises: entries,
                defaultProgression: progression(request, low: 6, high: 10),
                programId: program.id, createdAt: now, updatedAt: now)
            routine = trim(routine, to: request.minutesPerSession)
            routines.append(routine)
            if index < days.count { schedule[days[index], default: []].append(routine.id) }
        }
        program.schedule = schedule
        return (program, routines)
    }

    private static func entry(_ exercise: TrainingExercise, slot: Slot,
                              request: PlanRequest) -> RoutineExercise {
        let shape = prescription(slot, request: request)
        var sets: [RoutineSetPlan] = []
        // One warm-up set for a loaded main lift, with no weight on it: the plan does not yet know
        // what the wearer lifts, and inventing a number would be a prescription nobody checked.
        // Once there is a working weight, the session's own ramp fills it in.
        if slot.isCompound, TrainingEquipmentCatalog.carriesExternalLoad(exercise.equipmentIds) {
            sets.append(RoutineSetPlan(phase: .warmup, repsMin: 8, repsMax: 8))
        }
        let records = exercise.mode.recordsRepetitions
        sets += (0..<shape.sets).map { _ in
            RoutineSetPlan(repsMin: records ? shape.low : nil, repsMax: records ? shape.high : nil,
                           targetDurationS: records ? nil : 45)
        }
        return RoutineExercise(exerciseId: exercise.id, sets: sets,
                               restSeconds: restSeconds(slot, request: request),
                               warmupRestSeconds: 60,
                               progression: progression(request, low: shape.low, high: shape.high))
    }

    /// Cuts a session down to the time the wearer said they have, by dropping accessories from the
    /// end. Main lifts are never dropped: a shorter session that keeps them is still the session,
    /// and one without them is a different plan.
    static func trim(_ routine: TrainingRoutine, to minutes: Int) -> TrainingRoutine {
        var trimmed = routine
        let budget = minutes * 60
        while SessionEstimate.seconds(trimmed) > budget, trimmed.exercises.count > 2 {
            trimmed.exercises.removeLast()
        }
        return trimmed
    }

    /// Training days spread through the week with rest between them where the number allows it.
    static func weekdays(for days: Int) -> [TrainingWeekday] {
        switch days {
        case 2: return [.monday, .thursday]
        case 3: return [.monday, .wednesday, .friday]
        case 4: return [.monday, .tuesday, .thursday, .friday]
        case 5: return [.monday, .tuesday, .wednesday, .friday, .saturday]
        default: return [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
        }
    }

    private static func defaultTitle(_ request: PlanRequest) -> String {
        switch request.daysPerWeek {
        case 2, 3: return "Full body plan"
        case 4: return "Upper and lower plan"
        case 5: return "Five day plan"
        default: return "Push, pull and legs plan"
        }
    }
}
