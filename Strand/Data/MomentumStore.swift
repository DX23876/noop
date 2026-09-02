import Foundation
import Combine
import StrandAnalytics
import WhoopStore

/// The resolved Momentum feed, published once so every surface reads the SAME list.
///
/// The feed is assembled on the Today screen, because that is where the inputs live — the resolved day,
/// the recovery copy, the calibration state, the step figures the Key Metrics tile already worked out.
/// The dashboard can be opened from elsewhere (the More index, the macOS sidebar), and rebuilding the
/// feed there would mean a second assembly path: two code paths, two sets of inputs, and eventually two
/// different answers to "what matters right now" on one device. So Today publishes what it resolved and
/// the other entry points read it.
///
/// Deliberately NOT persisted: this is derived state with a dwell rule and a time-of-day weighting, and
/// a stale list restored from disk would be worse than an honest empty one. What DOES persist is the
/// small bookkeeping the dwell needs, which lives in `@AppStorage` on the Today screen.
@MainActor
final class MomentumStore: ObservableObject {
    static let shared = MomentumStore()

    /// The ranked feed, top-first. Empty until Today has resolved one.
    @Published private(set) var messages: [MomentumMessage] = []
    /// Recent daily rows, so the dashboard can draw the evidence charts without its own store read.
    @Published private(set) var recentDays: [DailyMetric] = []
    /// When the feed was last resolved, so a surface can say how fresh it is.
    @Published private(set) var updatedAt: Date?

    /// Called by Today whenever it rebuilds the feed. Skips the publish when nothing changed, so an
    /// observing dashboard is not re-rendered on every Today body pass.
    func publish(_ messages: [MomentumMessage], recentDays: [DailyMetric]) {
        guard self.messages != messages else { return }
        self.messages = messages
        self.recentDays = recentDays
        self.updatedAt = Date()
    }
}
