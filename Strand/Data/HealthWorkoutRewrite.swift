import Foundation
import SwiftUI
import StrandAnalytics
import WhoopStore
import StrandCore

/// A pending request to rewrite NOOP's workouts in Apple Health from a given time.
///
/// The regular write-back covers the last 14 days. When stored session energy is corrected further back
/// (recipes AI-13/AI-14), the Health copies of those sessions would keep the old figures, and every app reading
/// Health would keep quoting them. The request is a timestamp in UserDefaults because the correction runs
/// in shared analysis code while the writer is the iOS-only Health bridge; the bridge widens its next
/// workout pass to reach it and clears the request once that pass has written.
enum HealthWorkoutRewrite {
    static let key = "health.workoutRewriteFromTs"

    /// Asks for a rewrite from `ts`, keeping an earlier pending request if there is one.
    static func request(from ts: Int) {
        let pending = UserDefaults.standard.object(forKey: key) as? Int
        UserDefaults.standard.set(min(ts, pending ?? ts), forKey: key)
    }

    /// The pending start, if any.
    static var pendingFrom: Int? { UserDefaults.standard.object(forKey: key) as? Int }

    /// Clears the request, once a pass reaching `from` has written.
    static func complete(through from: Int) {
        guard let pending = pendingFrom, from <= pending else { return }
        UserDefaults.standard.removeObject(forKey: key)
    }
}
