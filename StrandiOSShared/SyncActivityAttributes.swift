#if os(iOS)
import Foundation
import ActivityKit

/// Live Activity attributes for a strap history sync — the Lock Screen banner and the Dynamic Island
/// while NOOP pulls stored history off the strap.
///
/// A SEPARATE activity type from `NOOPActivityAttributes` (live HR) and `LiftActivityAttributes`, for the
/// same reason those two are separate: a different question with a different lifetime. It lives from the
/// moment a sync is asked for until a few seconds after it ends. While it is showing, the app suppresses
/// the live-HR activity rather than stacking two banners.
///
/// THERE IS NO PERCENT. The strap never says how much history is pending, so the app's own Today control
/// shows a chunk COUNT and, when the strap reported one at connect, a "pages behind" figure. This carries
/// the same and nothing more. Elapsed time is carried as a date and rendered with `Text(timerInterval:)`,
/// which ticks on its own; every word is localized APP-SIDE because the widget extension ships no catalog.
public struct SyncActivityAttributes: ActivityAttributes {
    public enum Phase: String, Codable, Hashable {
        /// Asked for by the Sync Strap shortcut while the strap link was still coming up.
        case connecting
        case syncing
        /// The strap reported HISTORY_COMPLETE.
        case done
        /// The offload ended on the idle watchdog, or never started.
        case interrupted
    }

    public struct ContentState: Codable, Hashable {
        public var phase: Phase
        /// Chunks acked so far this session. A count, never a fraction.
        public var chunks: Int
        /// When the activity's current run began; the widget counts up from here while active.
        public var startedAt: Date
        /// "Syncing…" / "Synced · 12 chunks" / "Sync interrupted" — resolved and localized app-side.
        public var status: String
        /// "120 pages behind at connect", when known. Nil otherwise.
        public var detail: String?

        public init(phase: Phase, chunks: Int, startedAt: Date, status: String, detail: String?) {
            self.phase = phase
            self.chunks = chunks
            self.startedAt = startedAt
            self.status = status
            self.detail = detail
        }
    }

    /// "Strap sync", localized app-side.
    public var title: String

    public init(title: String) {
        self.title = title
    }
}
#endif
