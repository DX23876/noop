import Foundation
import Combine
import StrandAnalytics
import StrandDesign
import StrandTraining
import WhoopProtocol

/// The one active training session in the app.
///
/// Before this existed a strength workout lived in two unrelated places depending on where it was
/// started: the Today quick action recorded heart rate in `AppModel.activeWorkout` and showed a screen
/// without sets, while the Training tab kept a `WorkoutDraft` in its own view model and additionally
/// started a second heart-rate recording behind it. Discarding one left the other running, and each
/// screen only knew about its own half.
///
/// Now every entry point asks this controller. A strength session is the persisted `WorkoutDraft` and
/// nothing else — its heart rate is read back from the strap's stored stream for the session window
/// when it finishes, the way training load and auto-detected workouts already get theirs. A cardio
/// session is still the live recording in `AppModel`, because a route and the zone coach are genuinely
/// live; the controller only makes sure the two kinds share one slot.
@MainActor
final class ActiveSessionController: ObservableObject {
    enum Kind: Equatable { case strength, cardio }

    /// A start that collided with a session already running.
    struct PendingStart: Identifiable {
        enum Request {
            /// Open the freestyle-or-routine choice.
            case strengthChoice
            /// Start exactly these routines; empty means freestyle.
            case strength(routines: [TrainingRoutine])
            case cardio(sport: String, targetZone: Int?)
        }
        let id = UUID()
        let request: Request
        let runningTitle: String
    }

    /// Minimum time since the last change before an unfinished strength session is treated as
    /// forgotten and the wearer is asked what to do with it, instead of silently reopening it.
    static let staleAfterSeconds = 4 * 3_600

    /// The running strength session, or a retrospective one being filled in.
    @Published private(set) var strength: NativeWorkoutSessionModel? {
        // Every way a strength session appears or goes — start, restore, finish, discard — reaches the
        // system surfaces, not only later edits.
        didSet { if oldValue !== strength { publishActivity() } }
    }
    /// Whether the full-screen session is showing. False with a session running means minimized.
    @Published var isPresented = false
    @Published var pendingStart: PendingStart?
    /// A strength draft found at launch whose last change is older than `staleAfterSeconds`.
    @Published var staleDraft: WorkoutDraft?
    /// The strength workout that just finished, for its summary.
    @Published var completedWorkout: NativeWorkout?
    /// Offered when a strength session is requested without a plan chosen yet.
    @Published var isChoosingStrengthStart = false
    @Published private(set) var context = TrainingStartContext()
    @Published private(set) var contextLoaded = false
    @Published var errorMessage: String?
    /// Shown once when a live cardio session could not run as a system workout because Health does not
    /// allow NOOP to share workouts. The workout itself keeps recording either way.
    @Published var showsHealthBackgroundHint = false
    static let healthBackgroundHintShownKey = "training.healthBackgroundHint.shown"

    /// Heart rate a Watch reports for the running session. Kept in its own object so a 1 Hz Watch sample
    /// re-renders the heart-rate leaf, not every view that observes the session.
    let watchHeartRate = WatchHeartRateFeed()

    private unowned let app: AppModel
    private var repo: Repository { app.repo }
    /// For session views that need the store or profile without observing `AppModel` (1 Hz).
    var repository: Repository { app.repo }
    var profile: ProfileStore { app.profile }
    private var cancellables: Set<AnyCancellable> = []
    private var handledWatchOperations: Set<UUID> = []
    private var contextLoad: Task<Void, Never>?
    private var restoring = false

    init(app: AppModel) {
        self.app = app
        app.strengthWorkoutWatchCommandHandler = { [weak self] command in
            guard let self, self.handledWatchOperations.insert(command.operationId).inserted else { return }
            self.strength?.handleWatchCommand(command)
        }
        app.strengthWorkoutWatchTelemetryHandler = { [weak self] telemetry in
            guard let self, telemetry.sessionId == self.strength?.draft.trainingSessionId else { return }
            self.watchHeartRate.record(bpm: telemetry.bpm, sampleCount: telemetry.sampleCount)
        }
        app.onSystemWorkoutSessionResult = { [weak self] result in
            guard let self, result == .notAuthorized,
                  !UserDefaults.standard.bool(forKey: Self.healthBackgroundHintShownKey) else { return }
            UserDefaults.standard.set(true, forKey: Self.healthBackgroundHintShownKey)
            self.showsHealthBackgroundHint = true
        }
        // Republish only on the edge of a cardio session starting or ending, never per heart-rate sample.
        app.$activeWorkout
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] active in
                guard let self else { return }
                // A cardio session records live samples, so the session — not whichever screen is open —
                // keeps the strap's realtime stream armed until it ends. Minimizing no longer starves it.
                if active { self.holdCardioHeartRate() } else { self.releaseCardioHeartRate() }
                self.publishActivity()
                if !active, self.strength == nil { self.isPresented = false }
                self.objectWillChange.send()
            }
            .store(in: &cancellables)
        // The system surfaces follow the live values, at most every two seconds: heart rate for both kinds,
        // distance for a GPS session. Elapsed time and rest countdowns are rendered by the system itself.
        app.$bpm.map { _ in () }
            .merge(with: app.gpsRecorder.$distanceM.map { _ in () })
            .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                guard let self, self.hasLiveSession else { return }
                self.publishActivity()
            }
            .store(in: &cancellables)
    }

    // MARK: - State

    /// The kind of the session occupying the slot. A retrospective entry does not occupy it.
    var kind: Kind? {
        if let strength, !strength.isRetrospective { return .strength }
        if app.activeWorkout != nil { return .cardio }
        if strength != nil { return .strength }
        return nil
    }

    var hasLiveSession: Bool {
        if let strength, !strength.isRetrospective { return true }
        return app.activeWorkout != nil
    }

    var runningTitle: String {
        if let strength, !strength.isRetrospective { return strength.draft.title }
        return app.activeWorkout?.sport ?? ""
    }

    func present() { if strength != nil || app.activeWorkout != nil { isPresented = true } }
    func minimize() { isPresented = false }

    // MARK: - Context

    /// Loads what a strength start needs. Shared with the Training tab, which reports its own load here
    /// so a start from Today reuses it rather than reading the whole history again.
    func loadContextIfNeeded() async {
        if contextLoaded { return }
        if let contextLoad { await contextLoad.value; return }
        let task = Task { @MainActor in
            await repo.prepareNativeTraining()
            async let exercises = repo.nativeTrainingExercises()
            async let plan = repo.nativeTrainingPlan(weekStartsOn: TrainingWeekStart(
                rawValue: UserDefaults.standard.string(forKey: TrainingPreferences.weekStartKey) ?? "") ?? .monday)
            async let workouts = repo.nativeWorkouts()
            async let resolved = repo.resolvedStrengthHistory(days: ResolvedStrengthHistory.allHistoryDays)
            let loadedExercises = await exercises
            let loadedWorkouts = await workouts
            update(context: TrainingStartContext(
                exercises: loadedExercises, plan: await plan, workouts: loadedWorkouts,
                performance: TrainingPerformanceHistory(native: loadedWorkouts, resolved: await resolved,
                                                        exercises: loadedExercises)))
        }
        contextLoad = task
        await task.value
        contextLoad = nil
    }

    func update(context: TrainingStartContext) {
        self.context = context
        contextLoaded = true
    }

    // MARK: - Starting

    /// Opens the strength start choice (freestyle or a routine). Used by entries that have no plan
    /// selection of their own, such as the Today quick action.
    func chooseStrengthStart() {
        if hasLiveSession {
            pendingStart = .init(request: .strengthChoice, runningTitle: runningTitle)
            return
        }
        isChoosingStrengthStart = true
        Task { await loadContextIfNeeded() }
    }

    func requestStrength(routines: [TrainingRoutine]) {
        guard !hasLiveSession else {
            pendingStart = .init(request: .strength(routines: routines), runningTitle: runningTitle)
            return
        }
        Task { await startStrength(routines: routines) }
    }

    func requestCardio(sport: String, targetZone: Int?) {
        if Self.isStrengthSport(sport) {
            chooseStrengthStart()
            return
        }
        guard !hasLiveSession else {
            pendingStart = .init(request: .cardio(sport: sport, targetZone: targetZone),
                                 runningTitle: runningTitle)
            return
        }
        app.startWorkout(sport: sport, targetZone: targetZone)
        isPresented = true
    }

    /// Resolves a start that collided with a running session.
    /// The pending start is passed in rather than read back: a dialog clears its binding before the
    /// button's action runs, so by then `pendingStart` is already nil.
    func resolvePendingStart(_ pending: PendingStart, _ choice: PendingStartChoice) async {
        pendingStart = nil
        switch choice {
        case .returnToRunning:
            present()
            return
        case .finishAndStart:
            guard await finishRunning() else { return }
        case .discardAndStart:
            guard await discardRunning() else { return }
        }
        switch pending.request {
        case .strengthChoice:
            chooseStrengthStart()
        case .strength(let routines):
            await startStrength(routines: routines)
        case .cardio(let sport, let targetZone):
            app.startWorkout(sport: sport, targetZone: targetZone)
            isPresented = true
        }
    }

    enum PendingStartChoice { case returnToRunning, finishAndStart, discardAndStart }

    func startStrength(routines: [TrainingRoutine]) async {
        let closingChooser = isChoosingStrengthStart
        isChoosingStrengthStart = false
        await loadContextIfNeeded()
        let tracker = await currentTrackerAttribution()
        var draft = StrengthDraftBuilder.draft(routines: routines, tracker: tracker, context: context)
        prepareLifecycle(&draft)
        do {
            try await repo.saveNativeWorkoutDraft(draft)
        } catch {
            errorMessage = String(localized: "The workout could not be started.")
            return
        }
        strength = makeSession(draft)
        // The start sheet has to be gone before the full-screen session can present over the shell.
        if closingChooser { try? await Task.sleep(nanoseconds: 450_000_000) }
        isPresented = true
    }

    /// A workout entered after the fact. It is edited in the same logger but is not a running session:
    /// it records no heart rate, shows no minimized bar and never blocks a live start.
    func startRetrospective(routines: [TrainingRoutine], tracker: SessionTrackerAttribution?,
                            date: Date, durationS: Int) async {
        guard strength == nil else {
            errorMessage = String(localized: "Finish or discard the current workout first.")
            return
        }
        await loadContextIfNeeded()
        var draft = StrengthDraftBuilder.draft(routines: routines, tracker: tracker, context: context,
                                               date: date, pastDurationS: durationS)
        prepareLifecycle(&draft)
        do {
            try await repo.saveNativeWorkoutDraft(draft)
        } catch {
            errorMessage = String(localized: "The workout could not be started.")
            return
        }
        strength = makeSession(draft)
        isPresented = true
    }

    // MARK: - Ending

    /// Called by the logger once a strength workout is saved.
    func strengthFinished(_ workout: NativeWorkout) {
        if let draft = strength?.draft { retireLegacyRecording(for: draft) }
        strength = nil
        publishActivity()
        isPresented = false
        watchHeartRate.reset()
        app.strengthWorkoutWatchStateSink?(nil)
        contextLoaded = false
        completedWorkout = workout
    }

    /// Called by the logger once a strength workout is thrown away.
    func strengthDiscarded() {
        if let draft = strength?.draft { retireLegacyRecording(for: draft) }
        strength = nil
        publishActivity()
        isPresented = false
        watchHeartRate.reset()
        app.strengthWorkoutWatchStateSink?(nil)
    }

    private func finishRunning() async -> Bool {
        if let strength, !strength.isRetrospective {
            guard let workout = await strength.finish() else { return false }
            strengthFinished(workout)
            return true
        }
        if app.activeWorkout != nil { app.endWorkout() }
        return true
    }

    private func discardRunning() async -> Bool {
        if let strength, !strength.isRetrospective {
            guard await strength.discard() else { return false }
            strengthDiscarded()
            return true
        }
        if app.activeWorkout != nil { app.discardWorkout() }
        return true
    }

    // MARK: - Restore

    /// Reopens an unfinished strength draft after a relaunch. A draft untouched for longer than
    /// `staleAfterSeconds` is not reopened silently; the wearer decides what happens to it.
    func restoreIfNeeded(now: Int = Int(Date().timeIntervalSince1970)) async {
        guard strength == nil, !restoring else { return }
        restoring = true
        defer { restoring = false }
        guard let draft = await repo.nativeWorkoutDraft() else { return }
        // The logger names exercises and shows last time from the context; restoring before it is loaded
        // showed raw ids until something else happened to load it.
        await loadContextIfNeeded()
        retireLegacyRecording(for: draft)
        if Self.isStale(draft, now: now) {
            staleDraft = draft
        } else {
            strength = makeSession(draft)
        }
    }

    static func isStale(_ draft: WorkoutDraft, now: Int) -> Bool {
        draft.plannedEndTs == nil && now - lastActivity(of: draft) > staleAfterSeconds
    }

    /// The best available "last touched" instant. `updatedAt` is a revision that is kept at or above the
    /// wall clock on every edit, so it is the time of the latest change.
    static func lastActivity(of draft: WorkoutDraft) -> Int {
        max(draft.startedAt, min(draft.updatedAt, Int(Date().timeIntervalSince1970)))
    }

    enum StaleChoice { case save, resume, discard }

    func resolveStaleDraft(_ draft: WorkoutDraft, _ choice: StaleChoice) async {
        staleDraft = nil
        let session = makeSession(draft)
        switch choice {
        case .resume:
            strength = session
            isPresented = true
        case .save:
            strength = session
            if let workout = await session.finish(endTs: Self.lastActivity(of: draft)) {
                strengthFinished(workout)
            } else {
                // Nothing completed to save, or the save failed: keep it open so nothing is lost.
                errorMessage = session.errorMessage
                isPresented = true
            }
        case .discard:
            if await session.discard() { strengthDiscarded() }
            else { errorMessage = session.errorMessage }
        }
    }

    /// Builds before the single session started a second "Strength Training" heart-rate recording beside
    /// every strength draft. That recording is redundant now — the session's heart rate is read from the
    /// strap's stored stream — and left running it is exactly the "workout still in progress after
    /// discard" the unified session fixes. A recording is only retired when it is unmistakably that twin:
    /// a strength sport started within ten minutes of this draft. Its samples were never the only copy.
    private func retireLegacyRecording(for draft: WorkoutDraft) {
        guard let recording = app.activeWorkout,
              Self.isLegacyTwin(recordingSport: recording.sport,
                                recordingStart: Int(recording.start.timeIntervalSince1970),
                                draftStart: draft.startedAt) else { return }
        app.discardWorkout()
    }

    static func isLegacyTwin(recordingSport: String, recordingStart: Int, draftStart: Int) -> Bool {
        WorkoutSource.sportKey(recordingSport) == WorkoutSource.sportKey("Strength Training")
            && abs(recordingStart - draftStart) <= 600
    }

    // MARK: - Watch companion

    func publishCompanion(_ draft: WorkoutDraft, exerciseTitle: String?, setNumber: Int?) {
        publishActivity()
        guard draft.physiologyProvider == .appleWatch, let sessionId = draft.trainingSessionId else {
            app.strengthWorkoutWatchStateSink?(nil)
            return
        }
        let phase: StrengthWorkoutCompanionState.Phase
        switch draft.state {
        case .paused, .interrupted: phase = .paused
        case .completing: phase = .finishing
        case .active: phase = .active
        }
        let bpm = watchHeartRate.bpm
        let zone = bpm.map { app.profile.hrZoneSet.zoneNumber(forBPM: Double($0)) }.flatMap { $0 > 0 ? $0 : nil }
        app.strengthWorkoutWatchStateSink?(.init(
            sessionId: sessionId, revision: draft.updatedAt, title: draft.title,
            exerciseTitle: exerciseTitle, setNumber: setNumber,
            setCount: draft.exercises.flatMap(\.sets).count, startedAtTs: draft.startedAt,
            bpm: bpm, heartRateZone: zone, restEndsAtTs: draft.timer?.endsAtTs, phase: phase))
    }

    // MARK: - System surfaces

    /// Sends the running session to the Lock Screen / Dynamic Island, or nil when none runs.
    func publishActivity() {
        app.liveWorkoutActivitySink?(activitySnapshot())
    }

    func activitySnapshot(now: Date = Date()) -> LiveWorkoutActivitySnapshot? {
        let zoneSet = app.profile.hrZoneSet
        func zone(_ bpm: Int?) -> Int? {
            bpm.map { zoneSet.zoneNumber(forBPM: Double($0)) }.flatMap { $0 > 0 ? $0 : nil }
        }
        if let strength, !strength.isRetrospective {
            let draft = strength.draft
            let nowTs = Int(now.timeIntervalSince1970)
            let intervals = draft.pauseIntervals ?? []
            let open = intervals.last.flatMap { $0.endedAtTs == nil ? $0.startedAtTs : nil }
            let closedPaused = intervals.reduce(0) { total, interval in
                guard let end = interval.endedAtTs else { return total }
                return total + max(0, end - interval.startedAtTs)
            }
            let sets = draft.exercises.flatMap(\.sets)
            let bpm = draft.physiologyProvider == .appleWatch ? watchHeartRate.bpm : app.bpm
            var restEnds: Date?
            if let timer = draft.timer, timer.kind != .timedSet, timer.pausedRemainingSeconds == nil,
               timer.endsAtTs > nowTs {
                restEnds = Date(timeIntervalSince1970: TimeInterval(timer.endsAtTs))
            }
            return LiveWorkoutActivitySnapshot(
                kind: .strength, title: draft.title,
                startedAt: Date(timeIntervalSince1970: TimeInterval(draft.startedAt)),
                pausedAt: open.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                pausedSeconds: TimeInterval(closedPaused), bpm: bpm, zone: zone(bpm),
                distanceM: nil, paceSecPerKm: nil,
                setsDone: sets.filter(\.isCompleted).count, setsTotal: sets.count, restEndsAt: restEnds)
        }
        if let workout = app.activeWorkout {
            let gps = app.gpsRecorder
            let hasRoute = gps.pointCount > 1
            return LiveWorkoutActivitySnapshot(
                kind: .cardio, title: workout.sport, startedAt: workout.start,
                pausedAt: workout.pausedAt, pausedSeconds: workout.pausedDuration,
                bpm: app.bpm, zone: zone(app.bpm),
                distanceM: hasRoute ? gps.distanceM : nil, paceSecPerKm: hasRoute ? gps.paceSecPerKm : nil,
                setsDone: nil, setsTotal: nil, restEndsAt: nil)
        }
        return nil
    }

    // MARK: - Live heart rate

    private var cardioHeartRateHeld = false

    private func holdCardioHeartRate() {
        guard !cardioHeartRateHeld else { return }
        cardioHeartRateHeld = true
        app.startRealtimeHR()
    }

    private func releaseCardioHeartRate() {
        guard cardioHeartRateHeld else { return }
        cardioHeartRateHeld = false
        app.stopRealtimeHR()
    }

    private var liveHeartRateHeld = false

    /// Streams live heart rate from the strap while the logger is on screen. Balanced by
    /// `stopLiveHeartRate`; the strap's stored heart rate is recorded either way.
    func startLiveHeartRate() {
        guard !liveHeartRateHeld else { return }
        liveHeartRateHeld = true
        app.startRealtimeHR()
    }

    func stopLiveHeartRate() {
        guard liveHeartRateHeld else { return }
        liveHeartRateHeld = false
        app.stopRealtimeHR()
    }

    // MARK: - Heart rate for a finished strength session

    /// Writes buffered strap heart rate to the store so the session window is complete when it is read.
    func flushHeartRate() async {
        await app.ble.flushStandardHRForLifecycle(reason: .explicit)
    }

    /// Which source covered the session and how much of its active time, read from stored samples.
    /// Nothing is recorded for this; a window without samples yet reports no coverage and is filled in
    /// by the normal read path once the strap has synced.
    func physiology(for draft: WorkoutDraft, endTs: Int) async -> (WorkoutPhysiologyProvider, Double?) {
        let pauses = (draft.pauseIntervals ?? []).map { ($0.startedAtTs, $0.endedAtTs ?? endTs) }
        let samples = await repo.hrSamples(from: draft.startedAt, to: endTs, limit: 20_000)
        let active = StrengthSessionHeartRate.activeSamples(samples, pauses: pauses)
        let activeSeconds = StrengthSessionHeartRate.activeSeconds(start: draft.startedAt, end: endTs,
                                                                   pauses: pauses)
        if let coverage = StrengthSessionHeartRate.coverage(sampleCount: Set(active.map(\.ts)).count,
                                                            activeSeconds: activeSeconds) {
            return (.noopBand, coverage)
        }
        if watchHeartRate.sampleCount > 0 {
            let coverage = StrengthSessionHeartRate.coverage(sampleCount: watchHeartRate.sampleCount,
                                                             activeSeconds: activeSeconds)
            return (.appleWatch, coverage)
        }
        return (draft.physiologyProvider ?? .none, nil)
    }

    // MARK: - Private

    private func makeSession(_ draft: WorkoutDraft) -> NativeWorkoutSessionModel {
        NativeWorkoutSessionModel(draft: draft, repo: repo, controller: self,
                                  exercises: context.exercises)
    }

    private func prepareLifecycle(_ draft: inout WorkoutDraft) {
        draft.trainingSessionId = draft.trainingSessionId ?? UUID()
        draft.lifecycleVersion = max(draft.lifecycleVersion ?? 0, 3)
        draft.physiologyProvider = draft.plannedEndTs != nil ? WorkoutPhysiologyProvider.none
            : automaticProvider()
    }

    /// Picks where heart rate will come from without asking: a connected strap first, then a reachable
    /// Watch, otherwise none. The app's active device is never switched to make this happen.
    private func automaticProvider() -> WorkoutPhysiologyProvider {
        if app.live.connected { return .noopBand }
        if app.isStrengthCompanionReachable?() == true { return .appleWatch }
        return .none
    }

    /// Attributes the session to the connected strap so its stored samples are read from that device.
    private func currentTrackerAttribution() async -> SessionTrackerAttribution? {
        guard app.live.connected, let activeId = app.deviceRegistry?.activeDeviceId else { return nil }
        let trackers = await repo.nativeTrainingTrackers()
        guard var tracker = trackers.first(where: { $0.trackerId == activeId }) else { return nil }
        tracker.confidence = .direct
        return tracker
    }

    private static let strengthSportKeys: Set<String> = [
        "Strength", "Strength Training", "Bodybuilding", "Weightlifting",
        "Traditional Strength Training", "Functional Strength Training"
    ].reduce(into: Set<String>()) { $0.insert(WorkoutSource.sportKey($1)) }

    static func isStrengthSport(_ sport: String) -> Bool {
        strengthSportKeys.contains(WorkoutSource.sportKey(sport))
    }
}

/// Heart rate reported by a Watch for the running strength session.
@MainActor
final class WatchHeartRateFeed: ObservableObject {
    @Published private(set) var bpm: Int?
    private(set) var sampleCount = 0

    func record(bpm: Int?, sampleCount: Int) {
        self.sampleCount = max(self.sampleCount, sampleCount)
        if self.bpm != bpm { self.bpm = bpm }
    }

    func reset() {
        sampleCount = 0
        bpm = nil
    }
}

/// Pure helpers for reading a strength session's heart rate from stored samples.
enum StrengthSessionHeartRate {
    static func activeSamples(_ samples: [HRSample], pauses: [(Int, Int)]) -> [HRSample] {
        guard !pauses.isEmpty else { return samples }
        return samples.filter { sample in !pauses.contains { sample.ts >= $0.0 && sample.ts < $0.1 } }
    }

    static func activeSeconds(start: Int, end: Int, pauses: [(Int, Int)]) -> Int {
        let paused = pauses.reduce(0) { total, pause in
            let lo = max(start, pause.0), hi = min(end, pause.1)
            return total + max(0, hi - lo)
        }
        return max(0, end - start - paused)
    }

    /// Share of active seconds that carry a sample, or nil when there is nothing to report.
    static func coverage(sampleCount: Int, activeSeconds: Int) -> Double? {
        guard sampleCount > 0, activeSeconds > 0 else { return nil }
        return min(1, Double(sampleCount) / Double(activeSeconds))
    }
}
