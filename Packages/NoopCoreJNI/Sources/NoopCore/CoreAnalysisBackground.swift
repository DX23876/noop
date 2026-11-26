import Foundation
import StrandCore

extension CoreAnalysis {
    /// Whether the Android app is in the background, and the post-offload pass it put off there: Apple's
    /// `RescoreBackgroundScheduler` for the core's own pass queue, by the same shared rules
    /// (`RescoreBackgroundPolicy`). In the background a pass rests as long as it worked after each ten seconds of
    /// work, and a post-offload pass starts at most every 30 minutes. The one put off runs with the next offload
    /// past that spacing, which scores what both banked, or when the app comes to the front.
    public enum Background {
        private final class State: @unchecked Sendable {
            let lock = NSLock()
            /// True until the app reports a screen in front: a process the strap service started has none.
            var isBackground = true
            /// When the last pass that did any work started (Apple: the attempt time the spacing reads).
            var lastPassStartedAt: Date?
            var passInProgress = false
            /// The post-offload pass put off in the background, run when the app comes to the front.
            var owed: AnalysisRuns.Request?
        }
        private static let state = State()

        public static var isBackground: Bool { state.lock.withLock { state.isBackground } }

        /// The app went to the background or came to the front (`analysis.background`). Returns the pass put off
        /// in the background when the app has just come to the front, for the caller to queue; nil otherwise.
        static func set(background: Bool) -> AnalysisRuns.Request? {
            state.lock.withLock {
                state.isBackground = background
                guard !background, let owed = state.owed else { return nil }
                state.owed = nil
                return owed
            }
        }

        /// Whether a requested pass is queued now. Only a post-offload pass in the background can be put off; it
        /// is then kept as owed and the reason goes to the strap log, as Apple logs its deferrals.
        static func admit(_ request: AnalysisRuns.Request, now: Date = Date()) -> Bool {
            guard request.settings.afterOffload else { return true }
            let decision: RescoreBackgroundPolicy.Decision = state.lock.withLock {
                RescoreBackgroundPolicy.decide(
                    isBackground: state.isBackground, isRealUpdate: true,
                    rescoreAlreadyOwed: state.owed != nil, passInProgress: state.passInProgress,
                    secondsSinceLastAttempt: state.lastPassStartedAt.map { now.timeIntervalSince($0) })
            }
            switch decision {
            case .run:
                // This pass reads everything the put-off one would have: the debt is settled by it.
                state.lock.withLock { state.owed = nil }
                return true
            case .deferToBackgroundTask(let reason):
                state.lock.withLock { state.owed = request }
                PassLog.append("re-score: deferred (post-offload) — \(reason)")
                return false
            }
        }

        /// A pass got past its skip gate and is about to work (`AnalysisHost.passWillStart`).
        static func passWillWork(now: Date = Date()) {
            state.lock.withLock { state.lastPassStartedAt = now }
        }

        /// A pass is running in this process, so its own start is no reason to put the next one off.
        static func passRunning(_ running: Bool) {
            state.lock.withLock { state.passInProgress = running }
        }

        /// Apple's `RescoreBackgroundScheduler.paceIfBackgrounded`: rests after each quantum of work while the app
        /// is in the background. `mark` is the uptime the current stretch of work began, in nanoseconds.
        static func pace(since mark: inout UInt64) async {
            let workSeconds = Double(DispatchTime.now().uptimeNanoseconds &- mark) / 1_000_000_000
            let background = isBackground
            let rest = RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: workSeconds, isBackground: background)
            if rest > 0 { try? await Task.sleep(nanoseconds: UInt64(rest * 1_000_000_000)) }
            if rest > 0 || !background { mark = DispatchTime.now().uptimeNanoseconds }
        }

        static func resetForTesting(background: Bool) {
            state.lock.withLock {
                state.isBackground = background
                state.lastPassStartedAt = nil
                state.passInProgress = false
                state.owed = nil
            }
        }
    }
}
