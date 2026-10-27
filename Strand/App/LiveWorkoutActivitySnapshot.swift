import Foundation
import StrandTraining

/// The next set selected by the same flow that handles a hands-free step. Both the logger and the
/// Lock Screen read this value, so a superset cannot show one set while a tap completes another.
struct StrengthNextSet: Equatable {
    let sessionId: UUID
    let setId: UUID
    let exercise: String
    /// The working-set number, nil for a warm-up or a drop or rest-pause segment, which have none.
    let number: Int?
    let label: String
    let heading: String
    let target: String?
    let canCompleteWithoutOpening: Bool

    static func setToComplete(in draft: WorkoutDraft, sessionId: UUID, setId: UUID,
                              modes: [String: TrainingMeasurementMode]) -> (exercise: Int, set: Int)? {
        guard draft.state == .active, draft.id == sessionId,
              let next = NativeWorkoutEngine.nextOpenSet(in: draft) else { return nil }
        let exercise = draft.exercises[next.exercise]
        let set = exercise.sets[next.set]
        guard set.id == setId,
              NativeWorkoutEngine.hasLoggableValues(set, mode: modes[exercise.exerciseId]) else { return nil }
        return next
    }

    /// What a surface that names one set calls it: "Set 2", "Warm-up", "Drop set" or "Rest-pause". Numbered
    /// as the logger's set column numbers it, so a segment never borrows the next set's number.
    static func label(of setIndex: Int, in sets: [NativeWorkoutSet]) -> String {
        guard sets.indices.contains(setIndex) else { return String(localized: "Set \(setIndex + 1)") }
        let set = sets[setIndex]
        if set.phase == .warmup { return String(localized: "Warm-up") }
        if set.parentSetId != nil {
            return set.intensifier == .restPause ? String(localized: "Rest-pause") : String(localized: "Drop set")
        }
        return String(localized: "Set \(NativeWorkoutEngine.workingSetNumber(of: setIndex, in: sets) ?? 1)")
    }

    static func resolve(in draft: WorkoutDraft, titles: [String: String],
                        modes: [String: TrainingMeasurementMode],
                        unit: TrainingWeightUnit) -> StrengthNextSet? {
        guard let next = NativeWorkoutEngine.nextOpenSet(in: draft) else { return nil }
        let exercise = draft.exercises[next.exercise]
        let set = exercise.sets[next.set]
        let mode = modes[exercise.exerciseId]
        let target: String?
        switch mode {
        case .weightReps, .weightedBodyweight, .assistedBodyweight:
            if let weight = set.weightKg, let reps = set.reps {
                let sign = mode == .weightedBodyweight ? "+" : (mode == .assistedBodyweight ? "−" : "")
                target = "\(sign)\(TrainingPreferences.formattedWeight(weight, unit: unit)) × \(reps)"
            } else { target = nil }
        case .bodyweightReps, .repetitions:
            target = set.reps.map { String(localized: "\($0) reps") }
        case .weightDuration, .distanceWeight:
            // Loaded carries and holds: the weight is what the Lock Screen can say; time and distance are logged.
            target = set.weightKg.map { TrainingPreferences.formattedWeight($0, unit: unit) }
        case .duration, .distanceDuration, nil:
            target = nil
        }
        return StrengthNextSet(
            sessionId: draft.id, setId: set.id,
            exercise: titles[exercise.exerciseId] ?? exercise.exerciseId,
            number: NativeWorkoutEngine.workingSetNumber(of: next.set, in: exercise.sets),
            label: label(of: next.set, in: exercise.sets),
            heading: String(localized: "Up next"), target: target,
            canCompleteWithoutOpening: setToComplete(in: draft, sessionId: draft.id,
                                                     setId: set.id, modes: modes) != nil)
    }
}

enum StrengthRestAction {
    static func canApply(to draft: WorkoutDraft, sessionId: UUID,
                         expectedEnd: Int, seconds: Int) -> Bool {
        guard draft.state == .active, draft.id == sessionId,
              let timer = draft.timer, timer.kind != .timedSet,
              timer.pausedRemainingSeconds == nil, timer.endsAtTs == expectedEnd else { return false }
        return seconds == -15 || seconds == 0 || seconds == 15
    }
}

/// What the system surfaces (Lock Screen, Dynamic Island) show about the running session.
///
/// Platform-neutral on purpose: the session controller builds it on every platform, and only the iOS app
/// turns it into an ActivityKit content state. Times are absolute so the system can count elapsed time and
/// a rest countdown itself, without the app pushing an update every second.
struct LiveWorkoutActivitySnapshot: Equatable {
    enum Kind: String { case strength, cardio }

    var kind: Kind
    var title: String
    var startedAt: Date
    /// Set while the session is paused; elapsed time is frozen at this instant.
    var pausedAt: Date?
    /// Paused time before `pausedAt` (or before now, when running).
    var pausedSeconds: TimeInterval
    var bpm: Int?
    var zone: Int?
    var distanceM: Double?
    var paceSecPerKm: Double?
    var setsDone: Int?
    var setsTotal: Int?
    /// End of the current strength rest, when one is counting down.
    var restEndsAt: Date?
    /// The interval's start, so the Lock Screen counts down the real length of the rest.
    var restStartedAt: Date? = nil
    var strengthSessionId: UUID? = nil
    /// Next open strength set, resolved once for the logger and the system surfaces.
    var nextStrengthSet: StrengthNextSet? = nil
    /// Why the last strap double-tap was not logged, until the next set is completed.
    var notice: String? = nil
    /// SF Symbol for the sport, resolved from the stored sport key (the title is localized).
    var symbol: String? = nil

    /// The instant elapsed time counts from once pauses are taken out, for a system-rendered timer.
    var elapsedAnchor: Date { startedAt.addingTimeInterval(pausedSeconds) }

    /// Elapsed active seconds at `now`, for the frozen display while paused.
    func activeSeconds(at now: Date = Date()) -> Int {
        let end = pausedAt ?? now
        return max(0, Int(end.timeIntervalSince(startedAt) - pausedSeconds))
    }
}
