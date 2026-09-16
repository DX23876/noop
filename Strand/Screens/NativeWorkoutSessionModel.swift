import Foundation
import StrandDesign
import StrandTraining
import UserNotifications

/// The editing model of one strength session: the persisted `WorkoutDraft` and every change a wearer
/// makes to it. Owned by `ActiveSessionController`, so there is exactly one per session no matter how
/// often the logger is opened, minimized or rebuilt.
///
/// It records nothing on the side. Heart rate is not captured here; the session's window is read back
/// from the stored stream when it finishes.
@MainActor
final class NativeWorkoutSessionModel: ObservableObject, Identifiable {
    @Published var draft: WorkoutDraft
    @Published var sessionRPE: Double?
    @Published var errorMessage: String?
    @Published var watchFinishRequested = false

    nonisolated let id = UUID()
    private let repo: Repository
    private unowned let controller: ActiveSessionController
    private let exerciseTitles: [String: String]
    private var pendingPersist: Task<Void, Never>?
    private var debouncedPersist: Task<Void, Never>?
    private var discarded = false

    /// How long ordinary edits (steppers, notes) are gathered before one save. A completed set, a pause,
    /// backgrounding and finishing all save immediately.
    static let persistDebounceNanoseconds: UInt64 = 2_000_000_000

    init(draft: WorkoutDraft, repo: Repository, controller: ActiveSessionController,
         exercises: [TrainingExercise]) {
        self.draft = draft
        self.repo = repo
        self.controller = controller
        self.exerciseTitles = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0.title) })
        publishCompanionState()
    }

    /// Entered after the fact: no heart rate, no minimized bar, and it never blocks a live start.
    var isRetrospective: Bool { draft.plannedEndTs != nil }

    var activeTimer: WorkoutTimerState? { draft.timer }

    var activeExerciseIndex: Int {
        guard let id = draft.cursor?.exerciseId,
              let index = draft.exercises.firstIndex(where: { $0.id == id }) else { return 0 }
        return index
    }

    func selectExercise(at index: Int) {
        guard draft.exercises.indices.contains(index) else { return }
        draft.cursor = .init(exerciseId: draft.exercises[index].id,
                             setId: draft.exercises[index].sets.first(where: { !$0.isCompleted })?.id)
        touchAndPersist()
    }

    /// Pauses or resumes only this session. It never touches another recording that happens to run.
    func toggleWorkoutPause(now: Int = Int(Date().timeIntervalSince1970)) {
        if draft.state == .active {
            draft.state = .paused
            draft.interruptionReason = .userPaused
            var intervals = draft.pauseIntervals ?? []
            intervals.append(.init(startedAtTs: now))
            draft.pauseIntervals = intervals
        } else if draft.state == .paused || draft.state == .interrupted {
            draft.state = .active
            draft.interruptionReason = nil
            if var intervals = draft.pauseIntervals, let last = intervals.indices.last,
               intervals[last].endedAtTs == nil {
                intervals[last].endedAtTs = now
                draft.pauseIntervals = intervals
            }
        }
        touchAndPersist(immediate: true)
    }

    func appMovedToBackground() {
        if draft.state == .active { draft.interruptionReason = .appBackgrounded }
        touchAndPersist(immediate: true)
    }

    func appReturnedToForeground() {
        guard draft.state == .active, draft.interruptionReason == .appBackgrounded else { return }
        draft.interruptionReason = nil
        touchAndPersist()
    }

    func addExercise(_ exercise: TrainingExercise) {
        let initial = exercise.isUnilateral
            ? NativeWorkoutSet(index: 0, weightKg: exercise.mode == .bodyweightReps ? nil : 0,
                               leftReps: 8, rightReps: 8)
            : NativeWorkoutSet(index: 0, weightKg: exercise.mode == .bodyweightReps ? nil : 0,
                               reps: 8)
        NativeWorkoutEngine.addExercise(exercise.id, to: &draft,
            sets: [initial], definition: exercise)
        if let index = draft.exercises.indices.last {
            draft.exercises[index].restSeconds = UserDefaults.standard.object(
                forKey: TrainingPreferences.defaultRestKey) as? Int
                ?? TrainingPreferences.defaultRestSeconds
            draft.exercises[index].warmupRestSeconds = UserDefaults.standard.object(
                forKey: TrainingPreferences.warmupRestKey) as? Int
                ?? TrainingPreferences.defaultWarmupRestSeconds
        }
        touchAndPersist()
    }

    func addSet(to exerciseId: UUID) {
        try? NativeWorkoutEngine.appendSet(to: exerciseId, in: &draft)
        touchAndPersist()
    }

    func addWarmup(to exerciseId: UUID, mode: TrainingMeasurementMode, incrementKg: Double = 2.5) {
        guard let exerciseIndex = draft.exercises.firstIndex(where: { $0.id == exerciseId }) else { return }
        let exercise = draft.exercises[exerciseIndex]
        let firstWork = exercise.sets.first(where: { $0.phase == .work })
        let suggestions = WarmupPlanner.suggestedSets(firstWorkSetKg: firstWork?.weightKg, mode: mode,
                                                       incrementKg: incrementKg, count: 3)
        guard !suggestions.isEmpty else { return }
        let sets = suggestions.map { suggestion in
            NativeWorkoutSet(index: 0, phase: .warmup,
                             weightKg: suggestion.targetWeightKg,
                             reps: suggestion.repsMin ?? firstWork?.reps ?? 8)
        }
        let insertion = exercise.sets.firstIndex(where: { $0.phase == .work }) ?? exercise.sets.count
        draft.exercises[exerciseIndex].sets.insert(contentsOf: sets, at: insertion)
        reindexSets(exerciseIndex)
        touchAndPersist()
    }

    func removeExercise(_ id: UUID) {
        try? NativeWorkoutEngine.removeExercise(id, from: &draft)
        touchAndPersist()
    }

    func moveExercise(_ id: UUID, by offset: Int) {
        guard let from = draft.exercises.firstIndex(where: { $0.id == id }) else { return }
        let destination = from + offset
        guard draft.exercises.indices.contains(destination) else { return }
        try? NativeWorkoutEngine.moveExercise(id, to: destination, in: &draft)
        touchAndPersist()
    }

    /// Replacing an unlogged entry is safe in place. Once a set was recorded, preserve it as the
    /// historical exercise and insert the replacement beside it instead.
    func replaceExercise(_ id: UUID, with replacement: TrainingExercise) {
        guard let index = draft.exercises.firstIndex(where: { $0.id == id }) else { return }
        if draft.exercises[index].sets.contains(where: \.isCompleted) {
            let set = replacement.isUnilateral
                ? NativeWorkoutSet(index: 0, weightKg: replacement.mode == .bodyweightReps ? nil : 0,
                                   leftReps: 8, rightReps: 8)
                : NativeWorkoutSet(index: 0, weightKg: replacement.mode == .bodyweightReps ? nil : 0,
                                   reps: 8)
            var inserted = WorkoutDraft(title: draft.title, startedAt: draft.startedAt,
                                        plannedDay: draft.plannedDay, routineIds: draft.routineIds,
                                        exercises: [], tracker: draft.tracker)
            NativeWorkoutEngine.addExercise(replacement.id, to: &inserted, sets: [set], definition: replacement)
            draft.exercises.insert(inserted.exercises[0], at: index + 1)
        } else {
            draft.exercises[index].exerciseId = replacement.id
            draft.exercises[index].equipmentSnapshot = .init(equipmentIds: replacement.equipmentIds,
                loadSemantics: ExerciseLoadSemantics.defaultValue(for: replacement.mode,
                                                                  equipmentIds: replacement.equipmentIds))
        }
        touchAndPersist()
    }

    func toggleSet(exerciseIndex: Int, setIndex: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        draft.exercises[exerciseIndex].sets[setIndex].isCompleted.toggle()
        if draft.exercises[exerciseIndex].sets[setIndex].isCompleted {
            draft.cursor = .init(exerciseId: draft.exercises[exerciseIndex].id,
                setId: draft.exercises[exerciseIndex].sets.first(where: { !$0.isCompleted })?.id)
            startRestAfterCompletedSet(exerciseIndex: exerciseIndex, setIndex: setIndex)
        }
        touchAndPersist(immediate: true)
    }

    func skipRest() {
        cancelTimer()
    }

    func adjustTimer(by seconds: Int) {
        guard let timer = draft.timer else { return }
        let now = Int(Date().timeIntervalSince1970)
        draft.timer = WorkoutTimerCoordinator.adjust(timer, by: seconds, now: now)
        scheduleTimerNotification()
        touchAndPersist()
    }

    func pauseTimer() {
        guard let timer = draft.timer else { return }
        draft.timer = WorkoutTimerCoordinator.pause(timer, now: Int(Date().timeIntervalSince1970))
        TrainingRestNotification.cancel(for: draft.id)
        touchAndPersist()
    }

    func resumeTimer() {
        guard let timer = draft.timer else { return }
        draft.timer = WorkoutTimerCoordinator.resume(timer, now: Int(Date().timeIntervalSince1970))
        scheduleTimerNotification()
        touchAndPersist()
    }

    func cancelTimer() {
        draft.timer = nil
        TrainingRestNotification.cancel(for: draft.id)
        touchAndPersist()
    }

    func startTimedSet(exerciseIndex: Int, setIndex: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let set = draft.exercises[exerciseIndex].sets[setIndex]
        let seconds = set.targetDurationS ?? set.durationS ?? 0
        guard let timer = WorkoutTimerCoordinator.start(kind: .timedSet, seconds: seconds,
                                                         exerciseId: draft.exercises[exerciseIndex].id,
                                                         setId: set.id,
                                                         now: Int(Date().timeIntervalSince1970)) else { return }
        draft.timer = timer
        scheduleTimerNotification()
        touchAndPersist()
    }

    func finishTimedSet() {
        guard let timer = draft.timer, timer.kind == .timedSet,
              let exerciseId = timer.exerciseId, let setId = timer.setId,
              let exerciseIndex = draft.exercises.firstIndex(where: { $0.id == exerciseId }),
              let setIndex = draft.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setId }) else {
            cancelTimer(); return
        }
        let elapsed = max(0, Int(Date().timeIntervalSince1970) - timer.startedAtTs)
        draft.exercises[exerciseIndex].sets[setIndex].durationS = elapsed
        draft.timer = nil
        TrainingRestNotification.cancel(for: draft.id)
        if !draft.exercises[exerciseIndex].sets[setIndex].isCompleted {
            toggleSet(exerciseIndex: exerciseIndex, setIndex: setIndex)
        } else {
            touchAndPersist()
        }
    }

    func adjustWeight(exerciseIndex: Int, setIndex: Int, by delta: Double) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let old = draft.exercises[exerciseIndex].sets[setIndex].weightKg ?? 0
        draft.exercises[exerciseIndex].sets[setIndex].weightKg = max(0, old + delta)
        touchAndPersist()
    }

    func adjustReps(exerciseIndex: Int, setIndex: Int, by delta: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let old = draft.exercises[exerciseIndex].sets[setIndex].reps ?? 0
        draft.exercises[exerciseIndex].sets[setIndex].reps = max(0, old + delta)
        touchAndPersist()
    }

    func adjustSideReps(exerciseIndex: Int, setIndex: Int, left: Bool, by delta: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        if left {
            let old = draft.exercises[exerciseIndex].sets[setIndex].leftReps ?? 0
            draft.exercises[exerciseIndex].sets[setIndex].leftReps = max(0, old + delta)
        } else {
            let old = draft.exercises[exerciseIndex].sets[setIndex].rightReps ?? 0
            draft.exercises[exerciseIndex].sets[setIndex].rightReps = max(0, old + delta)
        }
        draft.exercises[exerciseIndex].sets[setIndex].reps = nil
        touchAndPersist()
    }

    func setEffort(exerciseIndex: Int, setIndex: Int, scale: TrainingEffortScale, value: Double) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        draft.exercises[exerciseIndex].sets[setIndex].effort = .init(scale: scale, value: value)
        touchAndPersist()
    }

    func setWorkoutNote(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.note = trimmed.isEmpty ? nil : value
        touchAndPersist()
    }

    func setWeight(exerciseIndex: Int, setIndex: Int, kg: Double?) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        draft.exercises[exerciseIndex].sets[setIndex].weightKg = kg.map { max(0, $0) }
        touchAndPersist()
    }

    func setReps(exerciseIndex: Int, setIndex: Int, reps: Int?) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        draft.exercises[exerciseIndex].sets[setIndex].reps = reps.map { max(0, $0) }
        touchAndPersist()
    }

    func setSideReps(exerciseIndex: Int, setIndex: Int, left: Bool, reps: Int?) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let value = reps.map { max(0, $0) }
        if left { draft.exercises[exerciseIndex].sets[setIndex].leftReps = value }
        else { draft.exercises[exerciseIndex].sets[setIndex].rightReps = value }
        draft.exercises[exerciseIndex].sets[setIndex].reps = nil
        touchAndPersist()
    }

    func setDistance(exerciseIndex: Int, setIndex: Int, meters: Double?) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        draft.exercises[exerciseIndex].sets[setIndex].distanceM = meters.map { max(0, $0) }
        touchAndPersist()
    }

    func setExerciseNote(_ exerciseId: UUID, _ value: String) {
        guard let index = draft.exercises.firstIndex(where: { $0.id == exerciseId }) else { return }
        draft.exercises[index].note = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        touchAndPersist()
    }

    /// Ends the exercise early and moves on to the next exercise that still has open sets.
    func skipExercise(_ exerciseId: UUID) {
        guard let index = draft.exercises.firstIndex(where: { $0.id == exerciseId }) else { return }
        let nextId = draft.exercises.indices
            .first { $0 > index && draft.exercises[$0].sets.contains(where: { !$0.isCompleted }) }
            .map { draft.exercises[$0].id }
        try? NativeWorkoutEngine.skipRemainingSets(of: exerciseId, in: &draft)
        if let timer = draft.timer, timer.kind == .timedSet, timer.exerciseId == exerciseId {
            draft.timer = nil
            TrainingRestNotification.cancel(for: draft.id)
        }
        if let nextId, let next = draft.exercises.firstIndex(where: { $0.id == nextId }) {
            selectExercise(at: next)
        } else {
            touchAndPersist()
        }
    }

    func adjustDuration(exerciseIndex: Int, setIndex: Int, by delta: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let old = draft.exercises[exerciseIndex].sets[setIndex].durationS ?? 0
        draft.exercises[exerciseIndex].sets[setIndex].durationS = max(0, old + delta)
        touchAndPersist()
    }

    func adjustDistance(exerciseIndex: Int, setIndex: Int, by delta: Double) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let old = draft.exercises[exerciseIndex].sets[setIndex].distanceM ?? 0
        draft.exercises[exerciseIndex].sets[setIndex].distanceM = max(0, old + delta)
        touchAndPersist()
    }

    func setKind(exerciseIndex: Int, setIndex: Int, phase: TrainingSetPhase,
                 intensifier: TrainingSetIntensifier) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        draft.exercises[exerciseIndex].sets[setIndex].phase = phase
        draft.exercises[exerciseIndex].sets[setIndex].intensifier = intensifier
        touchAndPersist()
    }

    func addTechniqueSegment(exerciseIndex: Int, setIndex: Int, intensifier: TrainingSetIntensifier) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let origin = draft.exercises[exerciseIndex].sets[setIndex]
        try? NativeWorkoutEngine.appendSegment(to: origin.id, intensifier: intensifier, in: &draft)
        touchAndPersist()
    }

    func removeSet(exerciseIndex: Int, setIndex: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        draft.exercises[exerciseIndex].sets.remove(at: setIndex)
        reindexSets(exerciseIndex)
        touchAndPersist()
    }

    func duplicateSet(exerciseIndex: Int, setIndex: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let source = draft.exercises[exerciseIndex].sets[setIndex]
        let duplicate = NativeWorkoutSet(index: 0, phase: source.phase,
                                         intensifier: source.isClusterSegment ? .none : source.intensifier,
                                         weightKg: source.weightKg, reps: source.reps,
                                         leftReps: source.leftReps, rightReps: source.rightReps,
                                         targetDurationS: source.targetDurationS,
                                         durationS: source.durationS, distanceM: source.distanceM,
                                         effort: source.effort)
        draft.exercises[exerciseIndex].sets.insert(duplicate, at: setIndex + 1)
        reindexSets(exerciseIndex)
        touchAndPersist()
    }

    func supersetWithNext(exerciseIndex: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises.indices.contains(exerciseIndex + 1) else { return }
        try? NativeWorkoutEngine.formSuperset(
            [draft.exercises[exerciseIndex].id, draft.exercises[exerciseIndex + 1].id], in: &draft)
        touchAndPersist()
    }

    func dissolveSuperset(_ group: UUID) {
        NativeWorkoutEngine.dissolveSuperset(group, in: &draft)
        touchAndPersist()
    }

    /// Saves the session. The heart rate is not part of what is stored: the session's window is read
    /// back from the strap's stream, so a window the strap has not synced yet simply fills in later.
    /// `endTs` lets a forgotten session end at its last change rather than hours later.
    func finish(endTs: Int? = nil) async -> NativeWorkout? {
        let end = endTs ?? draft.plannedEndTs ?? Int(Date().timeIntervalSince1970)
        do {
            var workout = try NativeWorkoutEngine.complete(draft: draft, endTs: end, sessionRPE: sessionRPE)
            debouncedPersist?.cancel()
            await pendingPersist?.value
            if !isRetrospective {
                await controller.flushHeartRate()
                let (provider, coverage) = await controller.physiology(for: draft, endTs: end)
                workout.physiologyProvider = provider
                workout.hrCoverage = coverage
            } else {
                workout.physiologyProvider = WorkoutPhysiologyProvider.none
            }
            workout.trainingSessionId = draft.trainingSessionId
            workout.physiologyComponentKey = nil
            workout.lifecycleVersion = draft.lifecycleVersion
            try await repo.finishNativeWorkout(workout)
            TrainingRestNotification.cancel(for: draft.id)
            let saved = workout
            Task { await repo.linkNativeWorkoutPhysiology(saved) }
            return workout
        } catch WorkoutMutationError.noCompletedWork {
            errorMessage = String(localized: "Complete at least one set before finishing.")
        } catch {
            errorMessage = String(localized: "The workout could not be saved.")
        }
        return nil
    }

    /// Throws the session away without recording it.
    ///
    /// The draft is deleted only after the writes already in flight have landed, so a save queued a
    /// moment earlier cannot put the discarded draft back. Everything the session held open goes with
    /// it: the rest timer's notification, the Watch companion, and the physiological recording this
    /// session started. Returns false when the delete failed, so the caller keeps the logger open
    /// rather than reporting a discard that did not happen.
    func discard() async -> Bool {
        discarded = true
        debouncedPersist?.cancel()
        await pendingPersist?.value
        do {
            try await repo.discardNativeWorkoutDraft(draft)
        } catch {
            discarded = false
            errorMessage = String(localized: "The workout could not be discarded.")
            return false
        }
        TrainingRestNotification.cancel(for: draft.id)
        return true
    }

    private func startRestAfterCompletedSet(exerciseIndex: Int, setIndex: Int) {
        let exercise = draft.exercises[exerciseIndex]
        let set = exercise.sets[setIndex]
        guard shouldRest(after: set, exerciseIndex: exerciseIndex) else { return }
        let seconds: Int
        if set.intensifier == .restPause { seconds = TrainingPreferences.restPauseSeconds }
        else { seconds = NativeWorkoutEngine.restSeconds(after: set, in: exercise) }
        guard let timer = WorkoutTimerCoordinator.start(kind: set.intensifier == .restPause ? .restPause : .rest,
                                                         seconds: seconds, exerciseId: exercise.id,
                                                         setId: set.id, now: Int(Date().timeIntervalSince1970)) else { return }
        draft.timer = timer
        scheduleTimerNotification()
    }

    private func shouldRest(after set: NativeWorkoutSet, exerciseIndex: Int) -> Bool {
        guard let group = draft.exercises[exerciseIndex].supersetId else { return true }
        let ordinal = draft.exercises[exerciseIndex].sets.filter { $0.phase == .work && $0.index <= set.index }.count
        let groupExercises = draft.exercises.filter { $0.supersetId == group }
        return groupExercises.allSatisfy { exercise in
            exercise.sets.filter { $0.phase == .work }.prefix(ordinal).allSatisfy(\.isCompleted)
        }
    }

    private func scheduleTimerNotification() {
        guard let timer = draft.timer, timer.pausedRemainingSeconds == nil else { return }
        guard TrainingPreferences.timerFeedbackEnabled else { return }
        TrainingRestNotification.schedule(identifier: draft.id,
            at: Date(timeIntervalSince1970: TimeInterval(timer.endsAtTs)),
            kind: timer.kind, sound: TrainingPreferences.timerSoundEnabled)
    }

    private func reindexSets(_ exerciseIndex: Int) {
        for index in draft.exercises[exerciseIndex].sets.indices {
            draft.exercises[exerciseIndex].sets[index].index = index
        }
    }

    private func touchAndPersist(immediate: Bool = false) {
        draft.updatedAt = max(draft.updatedAt + 1, Int(Date().timeIntervalSince1970))
        publishCompanionState()
        if immediate { persistNow() } else { schedulePersist() }
    }

    private func publishCompanionState() {
        guard draft.exercises.indices.contains(activeExerciseIndex) else {
            controller.publishCompanion(draft, exerciseTitle: nil, setNumber: nil); return
        }
        let exercise = draft.exercises[activeExerciseIndex]
        let setNumber = exercise.sets.firstIndex(where: { !$0.isCompleted }).map { $0 + 1 }
        controller.publishCompanion(draft, exerciseTitle: exerciseTitles[exercise.exerciseId],
                                    setNumber: setNumber)
    }

    func handleWatchCommand(_ command: StrengthWorkoutCompanionCommand) {
        guard command.sessionId == draft.trainingSessionId,
              command.expectedRevision == draft.updatedAt else { return }
        draft.lastConfirmedWatchRevision = max(draft.lastConfirmedWatchRevision ?? 0,
                                               command.expectedRevision)
        switch command.kind {
        case .pause where draft.state == .active: toggleWorkoutPause()
        case .resume where draft.state != .active: toggleWorkoutPause()
        case .completeSet:
            guard draft.exercises.indices.contains(activeExerciseIndex),
                  let setIndex = draft.exercises[activeExerciseIndex].sets.firstIndex(where: { !$0.isCompleted }) else { return }
            toggleSet(exerciseIndex: activeExerciseIndex, setIndex: setIndex)
        case .finish: watchFinishRequested = true
        default: break
        }
    }

    /// Gathers ordinary edits into one save. A later immediate save supersedes it.
    private func schedulePersist() {
        guard !discarded else { return }
        debouncedPersist?.cancel()
        debouncedPersist = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.persistDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    /// Saves the draft in the order the edits were made, and stops once the session has been discarded.
    /// Chaining each write onto the previous one is what lets `discard` know when the last save landed.
    func persistNow() {
        guard !discarded else { return }
        debouncedPersist?.cancel()
        debouncedPersist = nil
        let snapshot = draft
        let previous = pendingPersist
        pendingPersist = Task {
            await previous?.value
            do { try await repo.saveNativeWorkoutDraft(snapshot) }
            catch { errorMessage = String(localized: "Changes could not be saved.") }
        }
    }
}

private enum TrainingRestNotification {
    private static func id(_ workoutId: UUID) -> String { "training-rest-\(workoutId.uuidString)" }

    static func schedule(identifier workoutId: UUID, at date: Date,
                         kind: WorkoutTimerKind, sound: Bool) {
        let center = UNUserNotificationCenter.current()
        Task {
            let settings = await center.notificationSettings()
            let allowed: Bool
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: allowed = true
            case .notDetermined: allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
            default: allowed = false
            }
            guard allowed else { return }
            center.removePendingNotificationRequests(withIdentifiers: [id(workoutId)])
            let content = UNMutableNotificationContent()
            content.title = String(localized: kind == .timedSet ? "Set complete" : "Rest complete")
            content.body = String(localized: kind == .timedSet ? "Your timed set is ready to finish." : "Your next set is ready.")
            if sound { content.sound = .default }
            let seconds = max(1, date.timeIntervalSinceNow)
            try? await center.add(UNNotificationRequest(identifier: id(workoutId), content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)))
        }
    }

    static func cancel(for workoutId: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id(workoutId)])
    }
}
