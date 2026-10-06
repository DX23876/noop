import Foundation

/// A workout-scoped presentation value, separate from fresh GPS used by coaching and capture.
struct WorkoutSpeedDisplay: Equatable, Sendable {
    private var workoutID: UUID?
    private var lastMeasuredSpeedMps: Double?

    mutating func update(workoutID: UUID?, speedMps: Double?) {
        if self.workoutID != workoutID {
            self.workoutID = workoutID
            lastMeasuredSpeedMps = nil
        }
        guard workoutID != nil, let speedMps, speedMps.isFinite, speedMps > 0 else { return }
        lastMeasuredSpeedMps = speedMps
    }

    func value(workoutID: UUID?) -> Double? {
        guard let workoutID, workoutID == self.workoutID else { return nil }
        return lastMeasuredSpeedMps
    }
}
