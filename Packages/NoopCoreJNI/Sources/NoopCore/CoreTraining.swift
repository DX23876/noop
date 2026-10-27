import Foundation
import StrandAnalytics
import StrandCore
import StrandTraining
import WhoopProtocol
import WhoopStore

/// Native training for the Android app (Android parity plan 1.2 and 2.3): the same store calls and shared logic the
/// Apple `Repository` training functions make (`prepareNativeTraining`, `nativeTrainingPlan`, `finishNativeWorkout`,
/// `resolvedStrengthHistory`), as JSON the Kotlin screens read and send back. The training types are `Codable`, so
/// a routine or a workout crosses unchanged.
public enum CoreTraining {
    /// What the Training tab shows at once: the exercise library, the plan, the native workouts of `days`, the
    /// strength sessions resolved across every source and the muscle load of the last three weeks.
    public struct Snapshot: Encodable {
        public var exercises: [TrainingExercise]
        public var plan: TrainingPlan
        public var workouts: [NativeWorkout]
        public var draft: WorkoutDraft?
        public var strength: [StrengthSession]
        public var muscleLoad: [String: Double]
        public var workingSets: Int, mappedSets: Int
        /// The seven days of the current week with the routines planned on each (`TrainingPlan.effectiveRoutineIds`:
        /// the weekly schedule unless a day has its own override).
        public var week: [PlannedDay]
        /// Each routine's planned muscle involvement (`TrainingMuscleProjection.routine`), keyed by routine id, for the
        /// small front and back figures on its card.
        public var routineMuscles: [String: [String: Double]]
        /// Minutes logged per day over the past year, whole weeks from the plan's first weekday
        /// (`TrainingActivityDay.pastYear`), for the Consistency heatmap.
        public var activity: [ActivityDay]
        /// Balance, fatigue and strength per muscle (`MuscleAnalyticsSnapshot`), for the muscle analytics card.
        public var muscles: MuscleAnalytics
        /// The weekdays (ISO, Monday 1) each routine is scheduled on, keyed by routine id.
        public var routineWeekdays: [String: [Int]]
    }

    public struct ActivityDay: Encodable {
        public var day: String, minutes: Double
    }

    /// The three muscle readings with their coverage, as the iOS muscle analytics surface shows them.
    public struct MuscleAnalytics: Encodable {
        public struct Coverage: Encodable {
            public var workingSets: Int, mappedSets: Int, ratedSets: Int
            init(_ c: MuscleMetricCoverage) {
                workingSets = c.workingSetCount; mappedSets = c.mappedSetCount; ratedSets = c.ratedSetCount
            }
        }
        public struct Evidence: Encodable {
            public var exercise: String, session: String
        }
        public struct Balance: Encodable {
            public var muscleId: String, effectiveSets: Double, share: Double, usualShare: Double?, state: String
            public var evidence: [Evidence]
        }
        public struct Fatigue: Encodable {
            public var muscleId: String, relative: Double, tauHours: Double, personal: Bool
            public var evidence: [Evidence]
        }
        public struct StrengthExercise: Encodable {
            public var title: String, points: Int, slopePerWeek: Double?, unclear: Bool
        }
        public struct Strength: Encodable {
            public var muscleId: String, slopePerWeek: Double?, direction: String
            public var exercises: [StrengthExercise]
        }
        public var balance: [Balance], balanceCoverage: Coverage, personalBaseline: Bool
        public var fatigue: [Fatigue], fatigueCoverage: Coverage
        public var strength: [Strength], strengthCoverage: Coverage

        init(_ m: MuscleAnalyticsSnapshot) {
            func evidence(_ rows: [MuscleMetricEvidence]) -> [Evidence] {
                rows.prefix(10).map { Evidence(exercise: $0.exerciseTitle, session: $0.sessionTitle) }
            }
            balance = m.balance.readings.map {
                Balance(muscleId: $0.muscleId, effectiveSets: $0.effectiveSets, share: $0.distributionShare,
                        usualShare: $0.usualShare, state: $0.state.rawValue, evidence: evidence($0.evidence))
            }
            balanceCoverage = Coverage(m.balance.coverage)
            personalBaseline = m.balance.hasPersonalBaseline
            fatigue = m.fatigue.readings.map {
                Fatigue(muscleId: $0.muscleId, relative: $0.relativeToTypicalSession, tauHours: $0.tauSeconds / 3_600,
                        personal: $0.usesPersonalTau, evidence: evidence($0.evidence))
            }
            fatigueCoverage = Coverage(m.fatigue.coverage)
            strength = m.strength.readings.map {
                Strength(muscleId: $0.muscleId, slopePerWeek: $0.normalizedSlopePerWeek, direction: $0.direction.rawValue,
                         exercises: $0.exerciseEvidence.map {
                             StrengthExercise(title: $0.exerciseTitle, points: $0.pointCount,
                                              slopePerWeek: $0.normalizedSlopePerWeek, unclear: $0.directionIsUnclear)
                         })
            }
            strengthCoverage = Coverage(m.strength.coverage)
        }
    }

    /// One day of the week strip.
    public struct PlannedDay: Encodable {
        public var day: String, weekday: Int, isToday: Bool, routineIds: [String]
    }

    /// The current week as the Training tab's strip shows it, starting on the plan's first weekday.
    static func week(plan: TrainingPlan, now: Date = Date()) -> [PlannedDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        let isoWeekday = (calendar.component(.weekday, from: today) + 5) % 7 + 1   // Monday 1 … Sunday 7
        let back = plan.weekStartsOn == .sunday ? isoWeekday % 7 : isoWeekday - 1
        let start = calendar.date(byAdding: .day, value: -back, to: today) ?? today
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let iso = (calendar.component(.weekday, from: date) + 5) % 7 + 1
            let key = StoreReader.localDayKey(date)
            let ids = TrainingWeekday(rawValue: iso).map { plan.effectiveRoutineIds(day: key, weekday: $0) } ?? []
            return PlannedDay(day: key, weekday: iso, isToday: date == today, routineIds: ids.map(\.uuidString))
        }
    }

    /// One resolved strength session as the history and the week card list it.
    public struct StrengthSession: Encodable {
        public var id: String, title: String, startTs: Int, endTs: Int, durationS: Double
        public var workingSets: Int, volumeKg: Double, exercises: [String], exerciseCount: Int
        /// Each exercise with its working sets, for the session detail.
        public var lines: [Line]
    }

    public struct Line: Encodable {
        public struct Entry: Encodable { public var weightKg: Double?, reps: Int?, durationS: Double?, distanceM: Double? }
        public var title: String, sets: [Entry]
    }

    // MARK: Catalogue

    /// Seeds or refreshes the bundled exercise catalogue as the Apple app does (`ExerciseCatalogSeed.decide`). The
    /// seeded versions are kept as store cursors here, the Android app having no UserDefaults of its own for them.
    public static func prepare(store: WhoopStore) async {
        let now = Int(Date().timeIntervalSince1970)
        let seededVersion = (try? await store.cursor(contentCursor)) ?? 0
        let seededStarter = (try? await store.cursor(starterCursor)) ?? 0
        let shipped = Set(TrainingStarterCatalog.exercises.map(\.id)).union(BundledExerciseCatalog.exercises.map(\.id)).count
        let stored = seededVersion < BundledExerciseCatalog.contentVersion ? nil : try? await store.trainingExerciseCount()
        switch ExerciseCatalogSeed.decide(seededContentVersion: seededVersion, seededStarterVersion: seededStarter,
                                          storedCount: stored, shippedCount: shipped) {
        case .none:
            return
        case .full:
            do {
                try await store.upsertTrainingExercises(TrainingStarterCatalog.exercises + BundledExerciseCatalog.exercises,
                                                        nowTs: now)
                try await store.setCursor(contentCursor, BundledExerciseCatalog.contentVersion)
                try await store.setCursor(starterCursor, TrainingStarterCatalog.contentVersion)
            } catch {}
        case .starterOnly:
            do {
                try await store.upsertTrainingExercises(TrainingStarterCatalog.exercises, nowTs: now)
                try await store.setCursor(starterCursor, TrainingStarterCatalog.contentVersion)
            } catch {}
        }
    }
    static let contentCursor = "training.catalog.seededContentVersion"
    static let starterCursor = "training.catalog.seededStarterVersion"

    // MARK: Reads

    public static func snapshot(reader: StoreReader, days: Int, weekStartsOn: TrainingWeekStart,
                                dismissedWorkoutSpans: [String]) async -> Snapshot {
        let store = reader.store
        await prepare(store: store)
        let now = Int(Date().timeIntervalSince1970)
        let exercises = (try? await store.trainingExercises()) ?? []
        let plan = (try? await store.trainingPlan(weekStartsOn: weekStartsOn)) ?? .init(weekStartsOn: weekStartsOn)
        let workouts = (try? await store.nativeWorkouts(from: now - max(1, days) * 86_400, to: now + 86_400)) ?? []
        let draft = try? await store.workoutDraft()
        let history = await StrengthHistoryReader.read(store: store, days: days) {
            await TrainingSessionResolver.read(reader: reader, from: now - days * 86_400, to: now + 86_400,
                                               dismissedDetectedSpans: dismissedWorkoutSpans)
        }
        let load = DetailedMuscleLoadSnapshot.current(history: history, now: now)
        let sessions = history.sessions.map { session in
            StrengthSession(
                id: session.id, title: session.workout.title, startTs: session.startTs, endTs: session.endTs,
                durationS: session.durationS, workingSets: session.workingSetCount,
                volumeKg: session.exercises.reduce(0) { total, exercise in
                    total + exercise.source.workingSets.reduce(0) { $0 + ($1.weightKg ?? 0) * Double($1.reps ?? 0) }
                },
                exercises: session.exercises.map { $0.source.title }, exerciseCount: session.workout.exercises.count,
                lines: session.exercises.map { exercise in
                    Line(title: exercise.source.title, sets: exercise.source.workingSets.map {
                        Line.Entry(weightKg: $0.weightKg, reps: $0.reps, durationS: $0.durationS, distanceM: $0.distanceM)
                    })
                })
        }
        let byId = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var routineMuscles: [String: [String: Double]] = [:]
        for routine in plan.routines {
            routineMuscles[routine.id.uuidString] = TrainingMuscleProjection.routine(routine, exercises: byId)
        }
        let observations = MuscleAnalyticsSnapshot.observations((try? await store.muscleRecoveryFeedback()) ?? [])
        let analytics = MuscleAnalyticsSnapshot.compute(history: history, observations: observations, now: now)
        return Snapshot(exercises: exercises, plan: plan, workouts: workouts, draft: draft, strength: sessions,
                        muscleLoad: load.byMuscle, workingSets: load.workingSets, mappedSets: load.mappedSets,
                        week: week(plan: plan), routineMuscles: routineMuscles,
                        activity: TrainingActivityDay.pastYear(sessions: history.sessions, weekStart: weekStartsOn)
                            .map { ActivityDay(day: $0.day, minutes: $0.minutes) },
                        muscles: MuscleAnalytics(analytics),
                        routineWeekdays: Dictionary(plan.routines.map { routine in
                            (routine.id.uuidString,
                             RoutineEditing.weekdays(of: routine.id, in: plan.schedule).map(\.rawValue).sorted())
                        }, uniquingKeysWith: { first, _ in first }))
    }

    // MARK: Writes (Apple: Repository's native training functions)

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    public static func saveRoutine(store: WhoopStore, json: String) async -> Bool {
        guard let routine = decode(TrainingRoutine.self, json) else { return false }
        return (try? await store.upsertTrainingRoutine(routine)) != nil
    }

    /// Creates or edits a routine from a title and library exercises (Apple: `RoutineEditorView` then
    /// `TrainingHubModel.saveRoutine(_:weekdays:)`). An exercise the routine already had keeps its planned sets; a new
    /// one starts with three working sets of 8 to 12 reps and the default rest, as the Apple editor adds it. With
    /// `weekdays` (ISO, Monday 1) the routine is scheduled on exactly those days, the other routines keeping theirs.
    public static func createRoutine(store: WhoopStore, id: String?, title: String, exerciseIds: [String],
                                     weekdays: [Int]? = nil) async -> Bool {
        let existing = try? await store.trainingPlan(weekStartsOn: .monday)
        let uuid = id.flatMap(UUID.init(uuidString:)) ?? UUID()
        var routine = existing?.routines.first { $0.id == uuid } ?? TrainingRoutine(id: uuid, title: title)
        let kept = Dictionary(routine.exercises.map { ($0.exerciseId, $0) }, uniquingKeysWith: { first, _ in first })
        routine.title = title
        let definitions = Dictionary(((try? await store.trainingExercises()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        routine.exercises = exerciseIds.map { exerciseId in
            kept[exerciseId] ?? RoutineExercise(exerciseId: exerciseId,
                                                sets: RoutineSetPlan.defaults(for: definitions[exerciseId]?.mode ?? .weightReps))
        }
        do {
            try await store.upsertTrainingRoutine(routine)
            if let weekdays, let plan = existing {
                let schedule = RoutineEditing.schedule(plan.schedule, assigning: uuid,
                                                       to: Set(weekdays.compactMap(TrainingWeekday.init(rawValue:))))
                if schedule != plan.schedule { try await store.replaceTrainingSchedule(schedule) }
            }
            return true
        } catch {
            return false
        }
    }

    /// Saves a copy of a routine under `title` (Apple: `TrainingHubModel.duplicateRoutine`).
    public static func duplicateRoutine(store: WhoopStore, id: String, title: String) async -> Bool {
        guard let uuid = UUID(uuidString: id),
              let routine = (try? await store.trainingPlan(weekStartsOn: .monday))?.routines.first(where: { $0.id == uuid })
        else { return false }
        let copy = RoutineEditing.duplicate(routine, title: title, now: Int(Date().timeIntervalSince1970))
        return (try? await store.upsertTrainingRoutine(copy)) != nil
    }

    /// The starter plans the Apple "Browse starter plans" list offers, with their exercise titles.
    public struct Starter: Encodable {
        public var index: Int, title: String, exercises: [String]
    }

    public static func starters(store: WhoopStore) async -> [Starter] {
        await prepare(store: store)
        let titles = Dictionary(((try? await store.trainingExercises()) ?? []).map { ($0.id, $0.title) },
                                uniquingKeysWith: { first, _ in first })
        return TrainingStarterCatalog.starterRoutines().enumerated().map { index, routine in
            Starter(index: index, title: routine.title, exercises: routine.exercises.compactMap { titles[$0.exerciseId] })
        }
    }

    /// Adds the starter plan at `index` as a new routine (Apple: `TrainingHubModel.addStarter`).
    public static func addStarter(store: WhoopStore, index: Int) async -> Bool {
        let routines = TrainingStarterCatalog.starterRoutines()
        guard routines.indices.contains(index) else { return false }
        return (try? await store.upsertTrainingRoutine(routines[index])) != nil
    }

    /// Replaces the weekly schedule (Apple: `TrainingScheduleEditorView` then `saveSchedule`): routine ids per ISO
    /// weekday ("1" Monday … "7" Sunday); a weekday left out has no routine.
    public static func setSchedule(store: WhoopStore, days: [String: [String]]) async -> Bool {
        var schedule: [TrainingWeekday: [UUID]] = [:]
        for (key, ids) in days {
            guard let weekday = Int(key).flatMap(TrainingWeekday.init(rawValue:)) else { continue }
            schedule[weekday] = ids.compactMap(UUID.init(uuidString:))
        }
        return (try? await store.replaceTrainingSchedule(schedule)) != nil
    }

    public static func deleteRoutine(store: WhoopStore, id: String) async -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        return (try? await store.deleteTrainingRoutine(id: uuid)) != nil
    }

    public static func saveSchedule(store: WhoopStore, json: String) async -> Bool {
        guard let schedule = decode([TrainingWeekday: [UUID]].self, json) else { return false }
        return (try? await store.replaceTrainingSchedule(schedule)) != nil
    }

    public static func saveExercise(store: WhoopStore, json: String) async -> Bool {
        guard let exercise = decode(TrainingExercise.self, json) else { return false }
        return (try? await store.upsertTrainingExercises([exercise], nowTs: Int(Date().timeIntervalSince1970))) != nil
    }

    public static func saveDraft(store: WhoopStore, json: String) async -> Bool {
        guard let draft = decode(WorkoutDraft.self, json) else { return false }
        return (try? await store.saveWorkoutDraft(draft)) != nil
    }

    public static func discardDraft(store: WhoopStore, id: String) async -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        return (try? await store.deleteWorkoutDraft(id: uuid)) != nil
    }

    /// Saves a finished workout; the energy model and the session rating follow at the next analysis pass, as the
    /// Apple app schedules them.
    public static func finishWorkout(store: WhoopStore, json: String) async -> Bool {
        guard let workout = decode(NativeWorkout.self, json) else { return false }
        guard (try? await store.completeNativeWorkout(workout)) != nil else { return false }
        await EnergyCorrections.noteInputsRederived(store: store, dayStartTs: workout.startedAt)
        return true
    }

    // MARK: A session in progress (Apple: ActiveSessionController, StrengthDraftBuilder)

    /// Starts a strength session from the routines with `routineIds` (none: a freestyle session), prefilled from
    /// the last performance and progressed exactly as the Apple app starts one, and saves it as the draft.
    public static func startDraft(reader: StoreReader, routineIds: [String], dismissedWorkoutSpans: [String]) async
        -> WorkoutDraft? {
        let store = reader.store
        await prepare(store: store)
        let now = Int(Date().timeIntervalSince1970)
        let days = TrainingHistoryWindow.allDays
        let exercises = (try? await store.trainingExercises()) ?? []
        let plan = (try? await store.trainingPlan(weekStartsOn: .monday)) ?? .init()
        let workouts = (try? await store.nativeWorkouts(from: now - days * 86_400, to: now + 86_400)) ?? []
        let history = await StrengthHistoryReader.read(store: store, days: days) {
            await TrainingSessionResolver.read(reader: reader, from: now - days * 86_400, to: now + 86_400,
                                               dismissedDetectedSpans: dismissedWorkoutSpans)
        }
        let wanted = Set(routineIds.compactMap(UUID.init(uuidString:)))
        let routines = plan.routines.filter { wanted.contains($0.id) }
        let context = TrainingStartContext(exercises: exercises, plan: plan, workouts: workouts,
                                           performance: TrainingPerformanceHistory(native: workouts, resolved: history,
                                                                                   exercises: exercises))
        let draft = StrengthDraftBuilder.draft(routines: routines, tracker: nil, context: context)
        guard (try? await store.saveWorkoutDraft(draft)) != nil else { return nil }
        return draft
    }

    /// Applies one change to the draft and saves it: `set` (exercise, set, measurements, done), `addSet`,
    /// `addExercise` (a library id) or `removeExercise`. Returns the draft as saved, nil without one.
    public static func changeDraft(store: WhoopStore, args: [String: Any]) async -> WorkoutDraft? {
        guard var draft = (try? await store.workoutDraft()) ?? nil else { return nil }
        let exerciseUUID = (args["exercise"] as? String).flatMap(UUID.init(uuidString:))
        switch args["change"] as? String {
        case "set":
            guard let exerciseUUID, let setId = (args["set"] as? String).flatMap(UUID.init(uuidString:)),
                  let e = draft.exercises.firstIndex(where: { $0.id == exerciseUUID }),
                  let i = draft.exercises[e].sets.firstIndex(where: { $0.id == setId }) else { return draft }
            if let w = args["weightKg"] as? NSNumber { draft.exercises[e].sets[i].weightKg = w.doubleValue }
            if args["weightKg"] is NSNull { draft.exercises[e].sets[i].weightKg = nil }
            if let r = args["reps"] as? NSNumber { draft.exercises[e].sets[i].reps = r.intValue }
            if args["reps"] is NSNull { draft.exercises[e].sets[i].reps = nil }
            if let value = args["leftReps"] as? NSNumber { draft.exercises[e].sets[i].leftReps = value.intValue }
            if args["leftReps"] is NSNull { draft.exercises[e].sets[i].leftReps = nil }
            if let value = args["rightReps"] as? NSNumber { draft.exercises[e].sets[i].rightReps = value.intValue }
            if args["rightReps"] is NSNull { draft.exercises[e].sets[i].rightReps = nil }
            if let value = args["durationS"] as? NSNumber { draft.exercises[e].sets[i].durationS = value.intValue }
            if args["durationS"] is NSNull { draft.exercises[e].sets[i].durationS = nil }
            if let value = args["distanceM"] as? NSNumber { draft.exercises[e].sets[i].distanceM = value.doubleValue }
            if args["distanceM"] is NSNull { draft.exercises[e].sets[i].distanceM = nil }
            if let done = args["done"] as? Bool { draft.exercises[e].sets[i].isCompleted = done }
        case "addSet":
            guard let exerciseUUID else { return draft }
            try? NativeWorkoutEngine.appendSet(to: exerciseUUID, in: &draft)
        case "addExercise":
            guard let id = args["exerciseId"] as? String else { return draft }
            let definition = (try? await store.trainingExercises())?.first { $0.id == id }
            NativeWorkoutEngine.addExercise(id, to: &draft, sets: NativeWorkoutEngine.setsForAddedExercise(lastPerformance: [],
                unilateral: definition?.isUnilateral ?? false, workingSets: 1, mode: definition?.mode), definition: definition)
            if let last = draft.exercises.last, last.sets.isEmpty { try? NativeWorkoutEngine.appendSet(to: last.id, in: &draft) }
        case "removeExercise":
            guard let exerciseUUID else { return draft }
            try? NativeWorkoutEngine.removeExercise(exerciseUUID, from: &draft)
        default:
            return draft
        }
        draft.updatedAt = Int(Date().timeIntervalSince1970)
        _ = try? await store.saveWorkoutDraft(draft)
        return draft
    }

    /// Completes the draft as the Apple app does (`NativeWorkoutEngine.complete`): only completed sets are kept,
    /// the workout is stored and the draft removed. Nil when nothing was completed.
    public static func finishDraft(store: WhoopStore, sessionRPE: Double?) async -> NativeWorkout? {
        guard let draft = (try? await store.workoutDraft()) ?? nil,
              let workout = try? NativeWorkoutEngine.complete(draft: draft, endTs: Int(Date().timeIntervalSince1970),
                                                              sessionRPE: sessionRPE) else { return nil }
        guard (try? await store.completeNativeWorkout(workout)) != nil else { return nil }
        await EnergyCorrections.noteInputsRederived(store: store, dayStartTs: workout.startedAt)
        return workout
    }
}
