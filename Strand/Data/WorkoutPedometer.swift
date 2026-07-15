import Foundation
#if os(iOS)
import CoreMotion
#endif

/// One-shot HISTORICAL phone step count for a finished workout window `[start, end]` (#398).
///
/// CoreMotion's `CMPedometer` retains ~7 days of step history on-device, so a manual-workout summary can
/// show the phone's own step tally for a walk WITHOUT any live motion updates or a persistent sensor
/// subscription — a single historical query at display time, reconciled against the strap's own counter.
/// iOS only (`CMPedometer` is unavailable on macOS); the macOS build gets `nil` and falls back to strap
/// steps. `nil` always means "no phone steps" (unavailable / not authorized / query failed), never a
/// fabricated zero.
enum WorkoutPedometer {
    #if os(iOS)
    private static let pedometer = CMPedometer()

    /// The phone's step count between two unix-second bounds, or `nil` when steps can't be counted, Motion
    /// access is denied/restricted, the window is empty, or the query fails. The first call on a fresh
    /// install triggers the Motion & Fitness permission prompt (see `NSMotionUsageDescription`).
    static func steps(fromSec: Int, toSec: Int) async -> Int? {
        guard fromSec < toSec, CMPedometer.isStepCountingAvailable() else { return nil }
        switch CMPedometer.authorizationStatus() {
        case .denied, .restricted: return nil
        default: break
        }
        let start = Date(timeIntervalSince1970: TimeInterval(fromSec))
        let end = Date(timeIntervalSince1970: TimeInterval(toSec))
        return await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            pedometer.queryPedometerData(from: start, to: end) { data, _ in
                cont.resume(returning: data?.numberOfSteps.intValue)
            }
        }
    }
    #else
    /// macOS has no pedometer — steps come from the strap counter only.
    static func steps(fromSec: Int, toSec: Int) async -> Int? { nil }
    #endif
}
