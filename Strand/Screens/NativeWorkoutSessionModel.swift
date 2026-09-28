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
    @Published var draft: WorkoutDraft {
        // Every way the timer changes (a completed set, ±15 s, pause, skip, restore) re-arms the strap cue.
        didSet { if oldValue.timer != draft.timer { scheduleStrapCues() } }
    }
    @Published var sessionRPE: Double?
    @Published var errorMessage: String?
    @Published var watchFinishRequested = false
    /// Why the last strap double-tap or Watch "complete set" was not acted on, shown on the phone and the
    /// Lock Screen: the missing buzz alone does not say why. Cleared by the next completed set, or dismissed.
    @Published private(set) var strapNotice: String?

    nonisolated let id = UUID()
    private let repo: Repository
    private unowned let controller: ActiveSessionController
    private let exerciseTitles: [String: String]
    private let exerciseModes: [String: TrainingMeasurementMode]
    private var pendingPersist: Task<Void, Never>?
    private var debouncedPersist: Task<Void, Never>?
    private var discarded = false
    /// Fires the strap buzz. Injected so the session knows nothing about BLE.
    private let strapBuzz: (UInt8) -> Void
    /// Writes a line to the strap log, where each strap step and each cue is accounted for.
    private let strapLog: (String) -> Void
    /// When the session last acted on a strap double-tap. Nil after a relaunch: a knock is judged
    /// against a tap in the same sitting, never one from before it.
    private var lastStrapStepAt: Int?
    /// The pending buzz for the running timer, replaced whenever the timer changes.
    private var strapCueTask: Task<Void, Never>?

    /// How long ordinary edits (steppers, notes) are gathered before one save. A completed set, a pause,
    /// backgrounding and finishing all save immediately.
    static let persistDebounceNanoseconds: UInt64 = 2_000_000_000

    init(draft: WorkoutDraft, repo: Repository, controller: ActiveSessionController,
         exercises: [TrainingExercise],
         strapBuzz: @escaping (UInt8) -> Void = { _ in },
         strapLog: @escaping (String) -> Void = { _ in }) {
        self.draft = draft
        self.repo = repo
        self.controller = controller
        self.exerciseTitles = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0.title) })
        self.exerciseModes = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0.mode) })
        self.strapBuzz = strapBuzz
        self.strapLog = strapLog
        publishCompanionState()
        // A session restored mid-rest still gets its buzz.
        scheduleStrapCues()
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
        // The same numbers a session started with this exercise would show: its last performance, native
        // first, then imported. Without one, the weight is left empty rather than a loggable 0 kg.
        let last = controller.context.performance.latest(for: exercise.id)?.sets.enumerated().map { index, prior in
            NativeWorkoutSet(index: index, phase: prior.isWarmup ? .warmup : .work, weightKg: prior.weightKg,
                             reps: prior.reps, leftReps: prior.leftReps, rightReps: prior.rightReps,
                             durationS: prior.durationS, distanceM: prior.distanceM)
        } ?? []
        let initial = NativeWorkoutEngine.setsForAddedExercise(lastPerformance: last,
                                                               unilateral: exercise.isUnilateral)
        NativeWorkoutEngine.addExercise(exercise.id, to: &draft,
            sets: initial, definition: exercise)
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

    /// Appends a routine's exercises to the running session, prefilled like a fresh start.
    func addRoutine(_ routine: TrainingRoutine, context: TrainingStartContext) {
        let added = StrengthDraftBuilder.exercises(adding: routine, to: draft, context: context)
        guard !added.isEmpty else { return }
        draft.exercises.append(contentsOf: added)
        if !draft.routineIds.contains(routine.id) { draft.routineIds.append(routine.id) }
        touchAndPersist(immediate: true)
    }

    var completedSetCount: Int { draft.exercises.reduce(0) { $0 + $1.sets.filter(\.isCompleted).count } }
    var totalSetCount: Int { draft.exercises.reduce(0) { $0 + $1.sets.count } }

    /// Active seconds so far: wall time since the start without the time spent paused.
    func activeSeconds(now: Int = Int(Date().timeIntervalSince1970)) -> Int {
        let end = draft.plannedEndTs.map { min($0, now) } ?? now
        let pauses = (draft.pauseIntervals ?? []).map { ($0.startedAtTs, $0.endedAtTs ?? end) }
        return StrengthSessionHeartRate.activeSeconds(start: draft.startedAt, end: end, pauses: pauses)
    }

    func clearEffort(exerciseIndex: Int, setIndex: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        draft.exercises[exerciseIndex].sets[setIndex].effort = nil
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
            strapNotice = nil
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
        editValues(exerciseIndex, setIndex) { $0.weightKg = max(0, old + delta) }
    }

    func adjustReps(exerciseIndex: Int, setIndex: Int, by delta: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let old = draft.exercises[exerciseIndex].sets[setIndex].reps ?? 0
        editValues(exerciseIndex, setIndex) { $0.reps = max(0, old + delta) }
    }

    func adjustSideReps(exerciseIndex: Int, setIndex: Int, left: Bool, by delta: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let set = draft.exercises[exerciseIndex].sets[setIndex]
        let value = max(0, ((left ? set.leftReps : set.rightReps) ?? 0) + delta)
        editValues(exerciseIndex, setIndex) {
            if left { $0.leftReps = value } else { $0.rightReps = value }
            $0.reps = nil
        }
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
        editValues(exerciseIndex, setIndex) { $0.weightKg = kg.map { max(0, $0) } }
    }

    func setReps(exerciseIndex: Int, setIndex: Int, reps: Int?) {
        editValues(exerciseIndex, setIndex) { $0.reps = reps.map { max(0, $0) } }
    }

    func setSideReps(exerciseIndex: Int, setIndex: Int, left: Bool, reps: Int?) {
        let value = reps.map { max(0, $0) }
        editValues(exerciseIndex, setIndex) {
            if left { $0.leftReps = value } else { $0.rightReps = value }
            $0.reps = nil
        }
    }

    func setDistance(exerciseIndex: Int, setIndex: Int, meters: Double?) {
        editValues(exerciseIndex, setIndex) { $0.distanceM = meters.map { max(0, $0) } }
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
        editValues(exerciseIndex, setIndex) { $0.durationS = max(0, old + delta) }
    }

    func adjustDistance(exerciseIndex: Int, setIndex: Int, by delta: Double) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let old = draft.exercises[exerciseIndex].sets[setIndex].distanceM ?? 0
        editValues(exerciseIndex, setIndex) { $0.distanceM = max(0, old + delta) }
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
            strapCueTask?.cancel()
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
        strapCueTask?.cancel()
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

    /// A number typed or stepped into a set. The open sets riding along with it follow the change
    /// (`NativeWorkoutEngine.editSet`), so a double-tap on the next set logs what the lifter now uses.
    private func editValues(_ exerciseIndex: Int, _ setIndex: Int, _ edit: (inout NativeWorkoutSet) -> Void) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        NativeWorkoutEngine.editSet(setIndex, ofExercise: exerciseIndex, in: &draft, edit)
        touchAndPersist()
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
            // The Watch cannot show the whole row either, so a set without its numbers stays open.
            guard isLoggableUnseen(exerciseIndex: activeExerciseIndex, setIndex: setIndex) else {
                strapLog("Strength session: Watch \"complete set\" not acted on, set \(setIndex + 1) of "
                         + "\(title(ofExercise: activeExerciseIndex)) has no numbers to log")
                showStrapNotice(Self.missingNumbersNotice(set: setIndex + 1,
                                                          exercise: title(ofExercise: activeExerciseIndex)))
                return
            }
            toggleSet(exerciseIndex: activeExerciseIndex, setIndex: setIndex)
        case .finish: watchFinishRequested = true
        default: break
        }
    }

    // MARK: - Strap

    /// One pulse confirms a strap double-tap registered; with the phone face-down there is otherwise no
    /// way to know. Three mean the rest is nearly up, two that a timed set's time is up. Patterns that
    /// cannot be mistaken for each other on a wrist that has been knocked about all session.
    static let strapConfirmBuzzes: UInt8 = 1
    static let restWarningBuzzes: UInt8 = 3
    static let timedSetEndBuzzes: UInt8 = 2
    /// How long before the rest ends the warning fires: time to chalk up and take the bar.
    static let restWarningLeadSec = 5
    /// A strap double-tap this soon after the last one the session acted on is taken as a knock.
    static let strapKnockWindowSec = 5
    /// A cue that could only run this long after its timer ended says nothing useful any more.
    static let staleCueSec = 10

    static var unixNow: Int { Int(Date().timeIntervalSince1970) }

    /// A strap double-tap: what tapping the next open set's checkmark does, with the numbers already in
    /// the row, so a set is logged with the phone left on the bench. A running timed set is finished
    /// instead. Called by `ActiveSessionController`, which claims the gesture for the session's lifetime.
    func strapDoubleTap(now: Int = NativeWorkoutSessionModel.unixNow) {
        guard !isRetrospective else { return }
        guard draft.state == .active else {
            strapLog("Strength session: double-tap not acted on, the workout is paused")
            showStrapNotice(String(localized: "Double-tap not logged: the workout is paused"))
            return
        }
        if let last = lastStrapStepAt, Self.isKnock(secondsSinceLastStep: now - last) {
            // No buzz: the missing confirmation is the lifter's cue to tap again.
            strapLog("Strength session: double-tap not acted on, \(now - last) s after the last one it acted on "
                     + "(under \(Self.strapKnockWindowSec) s is taken as a knock)")
            showStrapNotice(String(localized: "Double-tap not logged: under 5 seconds after the last one"))
            return
        }
        let finishesTimedSet = draft.timer?.kind == .timedSet
        let next = finishesTimedSet ? nil : NativeWorkoutEngine.nextOpenSet(in: draft)
        guard finishesTimedSet || next != nil else {
            strapLog("Strength session: double-tap not acted on, every set is done")
            showStrapNotice(String(localized: "Double-tap not logged: every set is done"))
            return
        }
        if let next, !isLoggableUnseen(exerciseIndex: next.exercise, setIndex: next.set) {
            // No buzz: the missing confirmation sends the lifter to the phone, where the empty field shows.
            strapLog("Strength session: double-tap not acted on, set \(next.set + 1) of "
                     + "\(title(ofExercise: next.exercise)) has no numbers to log")
            showStrapNotice(Self.missingNumbersNotice(set: next.set + 1, exercise: title(ofExercise: next.exercise)))
            return
        }
        lastStrapStepAt = now
        // The first set logged from the strap shows the lifter has found the feature: the tip card retires.
        UserDefaults.standard.set(true, forKey: TrainingPreferences.strapTapTipDoneKey)
        // Buzz first: the confirmation is a latency signal and must not queue behind the save below.
        strapBuzz(Self.strapConfirmBuzzes)
        strapNotice = nil
        if finishesTimedSet {
            finishTimedSet()
            strapLog("Strength session: double-tap finished the timed set")
        } else if let next {
            toggleSet(exerciseIndex: next.exercise, setIndex: next.set)
            strapLog("Strength session: double-tap completed set \(next.set + 1) of \(title(ofExercise: next.exercise))")
        }
    }

    /// Whether a set may be completed by a step that cannot see its row (the strap, the Watch): it has the
    /// numbers its exercise is logged with. The checkmark on the phone is never held back; the row is in view.
    func isLoggableUnseen(exerciseIndex: Int, setIndex: Int) -> Bool {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return false }
        let exercise = draft.exercises[exerciseIndex]
        return NativeWorkoutEngine.hasLoggableValues(exercise.sets[setIndex],
                                                     mode: exerciseModes[exercise.exerciseId])
    }

    func dismissStrapNotice() {
        guard strapNotice != nil else { return }
        strapNotice = nil
        controller.publishActivity()
    }

    private func showStrapNotice(_ text: String) {
        strapNotice = text
        controller.publishActivity()
    }

    static func missingNumbersNotice(set: Int, exercise: String) -> String {
        String(localized: "Not logged: set \(set) of \(exercise) has no numbers yet")
    }

    private func title(ofExercise index: Int) -> String {
        let id = draft.exercises[index].exerciseId
        return exerciseTitles[id] ?? id
    }

    /// Whether a strap double-tap `secondsSinceLastStep` after the last one the session acted on is a knock
    /// (the arm going onto the bar) rather than a tap. No set a lifter means to log is that short.
    static func isKnock(secondsSinceLastStep: Int) -> Bool {
        (0..<strapKnockWindowSec).contains(secondsSinceLastStep)
    }

    /// One strap buzz a running timer earns: when it fires, the end it belongs to, how many pulses.
    struct StrapCue: Equatable {
        let at: Int
        let endsAt: Int
        let loops: UInt8
    }

    /// The buzz a running timer earns. A rest warns `restWarningLeadSec` before its end, or a second from
    /// now when it is already inside that window; a timed set buzzes at its end. Nil for a paused timer, a
    /// timed set already over, or any cue that would come more than `staleCueSec` after its timer ended.
    static func strapCue(for timer: WorkoutTimerState, now: Int) -> StrapCue? {
        guard timer.pausedRemainingSeconds == nil, !isStaleCue(endsAt: timer.endsAtTs, now: now) else { return nil }
        switch timer.kind {
        case .rest, .restPause:
            return StrapCue(at: max(now + 1, timer.endsAtTs - restWarningLeadSec), endsAt: timer.endsAtTs,
                            loops: restWarningBuzzes)
        case .timedSet:
            guard timer.endsAtTs > now else { return nil }
            return StrapCue(at: timer.endsAtTs, endsAt: timer.endsAtTs, loops: timedSetEndBuzzes)
        }
    }

    static func isStaleCue(endsAt: Int, now: Int) -> Bool { now - endsAt > staleCueSec }

    /// Re-arms the strap buzz for the running timer. The wait is a task rather than a ticking timer: between
    /// changes a session does no work at all.
    private func scheduleStrapCues() {
        strapCueTask?.cancel()
        strapCueTask = nil
        guard !discarded, !isRetrospective, let timer = draft.timer,
              let cue = Self.strapCue(for: timer, now: Self.unixNow) else { return }
        let delay = Date(timeIntervalSince1970: TimeInterval(cue.at)).timeIntervalSinceNow
        strapCueTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self?.fireStrapCue(cue)
        }
    }

    private func fireStrapCue(_ cue: StrapCue) {
        let now = Self.unixNow
        guard !discarded, let timer = draft.timer, timer.endsAtTs == cue.endsAt,
              timer.pausedRemainingSeconds == nil else { return }
        guard !Self.isStaleCue(endsAt: cue.endsAt, now: now) else {
            // iOS kept NOOP asleep past the end: a buzz now would announce a rest that is long over.
            strapLog("Strength session: timer buzz dropped, NOOP only woke \(now - cue.endsAt) s after the timer ended")
            return
        }
        guard HapticPrefs.enabled(HapticPrefs.liftRest) else { return }
        strapBuzz(cue.loops)
        strapLog(timer.kind == .timedSet ? "Strength session: timed set over, strap buzzed"
                 : "Strength session: rest ends in \(max(0, cue.endsAt - now)) s, strap buzzed")
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
