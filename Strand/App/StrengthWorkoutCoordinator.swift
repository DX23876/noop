import Foundation
import StrandAnalytics
import StrandDesign
import StrandTraining

/// Connects the native set draft to NOOP's existing physiological workout recorder and optional Watch
/// companion. It owns no samples and creates no second set history.
@MainActor
final class StrengthWorkoutCoordinator: ObservableObject {
    struct Completion: Equatable {
        let provider: WorkoutPhysiologyProvider
        let componentKey: String?
        let hrCoverage: Double?
    }

    private unowned let app: AppModel
    private(set) var watchBPM: Int?
    private(set) var watchSampleCount = 0
    private var activeSessionId: UUID?
    private var handledOperations: Set<UUID> = []
    var onWatchCommand: ((StrengthWorkoutCompanionCommand) -> Void)?
    var onTelemetry: ((Int?) -> Void)?

    init(app: AppModel) {
        self.app = app
        app.strengthWorkoutWatchCommandHandler = { [weak self] command in
            guard let self, self.handledOperations.insert(command.operationId).inserted else { return }
            self.onWatchCommand?(command)
        }
        app.strengthWorkoutWatchTelemetryHandler = { [weak self] telemetry in
            guard let self, telemetry.sessionId == self.activeSessionId else { return }
            self.watchBPM = telemetry.bpm
            self.watchSampleCount = max(self.watchSampleCount, telemetry.sampleCount)
            self.onTelemetry?(telemetry.bpm)
            self.objectWillChange.send()
        }
    }

    func beginOrResume(_ draft: inout WorkoutDraft) {
        draft.trainingSessionId = draft.trainingSessionId ?? UUID()
        if activeSessionId != draft.trainingSessionId {
            watchBPM = nil
            watchSampleCount = 0
            handledOperations.removeAll(keepingCapacity: true)
        }
        activeSessionId = draft.trainingSessionId
        draft.lifecycleVersion = max(draft.lifecycleVersion ?? 0, 2)
        draft.physiologyProvider = draft.physiologyProvider ?? Self.provider(for: draft.tracker)
        guard draft.plannedEndTs == nil else { return }
        if draft.physiologyProvider == .noopBand || draft.physiologyProvider == .externalTracker {
            guard let trackerId = draft.tracker?.trackerId, let registry = app.deviceRegistry else {
                draft.physiologyProvider = .none
                return
            }
            if registry.activeDeviceId != trackerId {
                app.resetSmoothing()
                registry.setActive(trackerId)
            }
            guard registry.activeDeviceId == trackerId else {
                draft.physiologyProvider = .none
                return
            }
        }
        if draft.physiologyProvider != .appleWatch,
           draft.physiologyProvider != .none {
            if let active = app.activeWorkout {
                let sameSession = WorkoutSource.sportKey(active.sport)
                    == WorkoutSource.sportKey("Strength Training")
                    && abs(Int(active.start.timeIntervalSince1970) - draft.startedAt) <= 600
                if !sameSession { draft.physiologyProvider = .none }
            } else {
                app.startWorkout(sport: "Strength Training")
            }
        }
    }

    var liveBPM: Int? {
        switch currentProvider {
        case .appleWatch: watchBPM
        case .noopBand, .externalTracker: app.activeWorkout == nil ? nil : app.bpm
        case .none: nil
        }
    }

    private var currentProvider: WorkoutPhysiologyProvider = .none

    func publish(_ draft: WorkoutDraft, exerciseTitle: String?, setNumber: Int?) {
        activeSessionId = draft.trainingSessionId
        currentProvider = draft.physiologyProvider ?? .none
        guard currentProvider == .appleWatch else {
            app.strengthWorkoutWatchStateSink?(nil)
            return
        }
        guard let sessionId = draft.trainingSessionId else { return }
        let phase: StrengthWorkoutCompanionState.Phase
        switch draft.state {
        case .paused, .interrupted: phase = .paused
        case .completing: phase = .finishing
        case .active: phase = .active
        }
        app.strengthWorkoutWatchStateSink?(.init(
            sessionId: sessionId, revision: draft.updatedAt, title: draft.title,
            exerciseTitle: exerciseTitle, setNumber: setNumber,
            setCount: draft.exercises.flatMap(\.sets).count, startedAtTs: draft.startedAt,
            bpm: liveBPM, heartRateZone: heartRateZone,
            restEndsAtTs: draft.timer?.endsAtTs, phase: phase))
    }

    func pause(_ draft: inout WorkoutDraft, now: Int = Int(Date().timeIntervalSince1970)) {
        guard draft.state == .active else { return }
        draft.state = .paused
        draft.interruptionReason = .userPaused
        var intervals = draft.pauseIntervals ?? []
        intervals.append(.init(startedAtTs: now))
        draft.pauseIntervals = intervals
        if app.activeWorkout?.isPaused == false { app.toggleWorkoutPause() }
    }

    func resume(_ draft: inout WorkoutDraft, now: Int = Int(Date().timeIntervalSince1970)) {
        guard draft.state == .paused || draft.state == .interrupted else { return }
        draft.state = .active
        draft.interruptionReason = nil
        if var intervals = draft.pauseIntervals, let last = intervals.indices.last,
           intervals[last].endedAtTs == nil {
            intervals[last].endedAtTs = now
            draft.pauseIntervals = intervals
        }
        if app.activeWorkout?.isPaused == true { app.toggleWorkoutPause() }
    }

    func complete(_ draft: WorkoutDraft, endedAt: Int) -> Completion {
        let provider = draft.physiologyProvider ?? .none
        let activeSeconds = max(1, endedAt - draft.startedAt - pausedSeconds(draft, endedAt: endedAt))
        let sampleCount: Int
        switch provider {
        case .appleWatch: sampleCount = watchSampleCount
        case .noopBand, .externalTracker: sampleCount = Set(app.activeWorkout?.samples.map(\.ts) ?? []).count
        case .none: sampleCount = 0
        }
        let coverage = provider == .none ? nil : min(1, Double(sampleCount) / Double(activeSeconds))
        var componentKey: String?
        if provider == .noopBand || provider == .externalTracker, app.activeWorkout != nil {
            componentKey = "manual|\(draft.startedAt)|\(WorkoutSource.sportKey("Strength Training"))"
            app.endWorkout()
        }
        if provider == .appleWatch, let sessionId = draft.trainingSessionId {
            app.strengthWorkoutWatchStateSink?(.init(
                sessionId: sessionId, revision: max(draft.updatedAt + 1, endedAt),
                title: draft.title, exerciseTitle: nil, setNumber: nil,
                setCount: draft.exercises.flatMap(\.sets).count, startedAtTs: draft.startedAt,
                bpm: watchBPM, heartRateZone: heartRateZone,
                restEndsAtTs: nil, phase: .finishing))
        } else {
            app.strengthWorkoutWatchStateSink?(nil)
        }
        activeSessionId = nil
        currentProvider = .none
        return .init(provider: provider, componentKey: componentKey,
                     hrCoverage: sampleCount == 0 ? nil : coverage)
    }

    /// Ends the session without recording anything, for a draft the wearer discarded.
    ///
    /// It mirrors `complete` in what it touches and differs in one way: the physiological recording this
    /// coordinator started is thrown away rather than saved, because a discarded workout that still left
    /// a "Strength Training" row behind would be a session the wearer explicitly said did not happen.
    /// Only a recording this coordinator started is discarded — the same provider gate `complete` uses —
    /// so an unrelated workout already running is never cancelled by discarding a set log. The strap's
    /// own stored samples are not involved and stay exactly where they are.
    func abandon(_ draft: WorkoutDraft) {
        let provider = draft.physiologyProvider ?? .none
        if provider == .noopBand || provider == .externalTracker, app.activeWorkout != nil {
            app.discardWorkout()
        }
        app.strengthWorkoutWatchStateSink?(nil)
        activeSessionId = nil
        currentProvider = .none
    }

    static func provider(for tracker: SessionTrackerAttribution?) -> WorkoutPhysiologyProvider {
        guard let tracker, tracker.capabilities.contains(.heartRate) else { return .none }
        let identity = [tracker.manufacturer, tracker.model, tracker.sourceApplication,
                        tracker.sourceBundleId, tracker.trackerId]
            .compactMap { $0?.lowercased() }.joined(separator: " ")
        if identity.contains("apple") || identity.contains("watch") { return .appleWatch }
        if identity.contains("whoop") || identity.contains("noop") { return .noopBand }
        return .externalTracker
    }

    private func pausedSeconds(_ draft: WorkoutDraft, endedAt: Int) -> Int {
        (draft.pauseIntervals ?? []).reduce(0) { result, interval in
            result + max(0, (interval.endedAtTs ?? endedAt) - interval.startedAtTs)
        }
    }

    private var heartRateZone: Int? {
        guard let bpm = liveBPM else { return nil }
        let zone = app.profile.hrZoneSet.zoneNumber(forBPM: Double(bpm))
        return zone > 0 ? zone : nil
    }
}
