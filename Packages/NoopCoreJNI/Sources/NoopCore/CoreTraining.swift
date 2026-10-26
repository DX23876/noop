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
    }

    /// One resolved strength session as the history and the week card list it.
    public struct StrengthSession: Encodable {
        public var id: String, title: String, startTs: Int, endTs: Int, durationS: Double
        public var workingSets: Int, volumeKg: Double, exercises: [String]
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
                exercises: session.exercises.map { $0.source.title })
        }
        return Snapshot(exercises: exercises, plan: plan, workouts: workouts, draft: draft, strength: sessions,
                        muscleLoad: load.byMuscle, workingSets: load.workingSets, mappedSets: load.mappedSets)
    }

    // MARK: Writes (Apple: Repository's native training functions)

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    public static func saveRoutine(store: WhoopStore, json: String) async -> Bool {
        guard let routine = decode(TrainingRoutine.self, json) else { return false }
        return (try? await store.upsertTrainingRoutine(routine)) != nil
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
}
