import Foundation
import StrandTraining

/// The next set selected by the same flow that handles a hands-free step. Both the logger and the
/// Lock Screen read this value, so a superset cannot show one set while a tap completes another.
struct StrengthNextSet: Equatable {
    let sessionId: UUID
    let setId: UUID
    let exercise: String
    let number: Int
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
        case .duration, .distanceDuration, nil:
            target = nil
        }
        return StrengthNextSet(
            sessionId: draft.id, setId: set.id,
            exercise: titles[exercise.exerciseId] ?? exercise.exerciseId,
            number: next.set + 1,
            label: String(localized: "Set \(next.set + 1)"),
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
    /// The interval's start keeps the Lock Screen at zero after the deadline until rest is skipped.
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
