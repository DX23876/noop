import Foundation

/// User-facing state of phone route recording for the active workout.
///
/// This is intentionally richer than a Boolean: "requested", "waiting for a fix", "paused" and
/// "permission denied" require different copy and different background-resource behaviour.
enum WorkoutGPSState: Equatable, Sendable {
    case idle
    case requestingPermission
    case acquiring
    case recording
    case paused
    case denied
    case unavailable
    case failed

    var isCapturing: Bool {
        self == .acquiring || self == .recording
    }
}
