import Foundation
import StrandAnalytics

// Analysis migration required: no. A reviewed nap is written through the existing `addManualNap` path;
// nothing here derives or stores a score.

/// The opt-in switch and the marks that keep short-nap detection from dredging up old days.
///
/// Apple twin of Android's `NapPrefs`, down to the stored keys, so a log or a support answer describes one
/// mechanism rather than two. Default OFF: the detector offers a nap for review and never writes one, but
/// an offer is still an interruption, so it is asked for rather than assumed.
enum NapReviewPrefs {
    static let enabledKey = "noop.napDetectionEnabled"
    static let highWaterKey = "noop.napHighWaterTs"

    static func enabled(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: enabledKey) }

    /// The newest moment the review queue has already considered. A first offload after a long gap can
    /// carry days of history; without this mark every old afternoon would arrive at once as a question.
    /// Seeded to `now` the first time it is read, so detection starts from the moment it is switched on.
    static func highWaterOrSeed(now: Int, _ d: UserDefaults = .standard) -> Int {
        let stored = d.integer(forKey: highWaterKey)
        if stored > 0 { return stored }
        d.set(now, forKey: highWaterKey)
        return now
    }

    static func setHighWater(_ ts: Int, _ d: UserDefaults = .standard) { d.set(ts, forKey: highWaterKey) }

    /// The detector's own numbers, with the switch folded in. The thresholds are the shared defaults;
    /// only the master switch is a preference, because a wearer cannot calibrate a motion threshold.
    static func config(_ d: UserDefaults = .standard) -> NapDetector.Config {
        var cfg = NapDetector.Config()
        cfg.enabled = enabled(d)
        return cfg
    }
}

/// One detected nap waiting for the wearer's yes or no.
struct PendingNap: Identifiable, Equatable, Codable {
    let start: Int
    let end: Int
    let meanHr: Int?
    let confidence: Double
    /// Stable across re-detection: the same window maps to the same id, so a later offload neither
    /// queues it twice nor re-asks about one that was already declined. Same shape as Android's
    /// `NapStore.idFor` ("start|end").
    var id: String { "\(start)|\(end)" }
    var durationMin: Int { max(0, (end - start) / 60) }

    init(_ candidate: NapDetector.Candidate) {
        start = candidate.start
        end = candidate.end
        meanHr = candidate.meanHr
        confidence = candidate.confidence
    }
}

/// The review queue: tiny, transient items that live only until the wearer accepts or declines one.
///
/// Apple twin of Android's `NapStore`, same keys and same retention. Deliberately not a database row: a
/// candidate is a question, not a measurement, and a question that was never answered within a day and a
/// half is stale rather than pending.
enum NapReviewStore {
    static let pendingKey = "noop.napPending"
    static let dismissedKey = "noop.napDismissedIds"
    /// Pending and declined windows older than this are forgotten, so neither list can grow without end.
    static let retentionHours: Double = 36

    /// Whether a freshly detected window is worth asking about: not already queued, and not one the
    /// wearer has already declined. Pure, so the rule is testable without any stored state.
    static func shouldEnqueue(_ candidate: PendingNap, pending: [PendingNap], dismissedIds: Set<String>) -> Bool {
        !dismissedIds.contains(candidate.id) && !pending.contains { $0.id == candidate.id }
    }

    /// The windows still worth showing: everything whose end is within the retention window. Pure for the
    /// same reason — the pruning rule is the part that goes wrong silently.
    static func retained(_ items: [PendingNap], now: Int) -> [PendingNap] {
        let cutoff = now - Int(retentionHours * 3_600)
        return items.filter { $0.end >= cutoff }.sorted { $0.start > $1.start }
    }

    static func retainedIds(_ ids: [String], now: Int) -> [String] {
        let cutoff = now - Int(retentionHours * 3_600)
        return ids.filter { id in
            guard let end = Int(id.split(separator: "|").last.map(String.init) ?? "") else { return false }
            return end >= cutoff
        }
    }

    static func pending(now: Int = Int(Date().timeIntervalSince1970), _ d: UserDefaults = .standard) -> [PendingNap] {
        let items = (try? JSONDecoder().decode([PendingNap].self,
                                               from: d.data(forKey: pendingKey) ?? Data())) ?? []
        return retained(items, now: now)
    }

    /// Queue a candidate, or do nothing when it is already queued or was declined. Returns the list the
    /// review surface should now show.
    @discardableResult
    static func enqueue(_ candidate: PendingNap, now: Int = Int(Date().timeIntervalSince1970),
                        _ d: UserDefaults = .standard) -> [PendingNap] {
        let current = pending(now: now, d)
        let dismissed = Set(retainedIds(d.stringArray(forKey: dismissedKey) ?? [], now: now))
        guard shouldEnqueue(candidate, pending: current, dismissedIds: dismissed) else { return current }
        let next = retained(current + [candidate], now: now)
        write(next, d)
        return next
    }

    /// Drop a candidate the wearer accepted: it becomes a real session through `addManualNap`, so it is
    /// not remembered as declined.
    @discardableResult
    static func remove(id: String, now: Int = Int(Date().timeIntervalSince1970),
                       _ d: UserDefaults = .standard) -> [PendingNap] {
        let next = pending(now: now, d).filter { $0.id != id }
        write(next, d)
        return next
    }

    /// Drop a candidate the wearer declined AND remember the window, so the next offload over the same
    /// hours does not ask again.
    @discardableResult
    static func dismiss(id: String, now: Int = Int(Date().timeIntervalSince1970),
                        _ d: UserDefaults = .standard) -> [PendingNap] {
        var ids = retainedIds(d.stringArray(forKey: dismissedKey) ?? [], now: now)
        if !ids.contains(id) { ids.append(id) }
        d.set(ids, forKey: dismissedKey)
        return remove(id: id, now: now, d)
    }

    private static func write(_ items: [PendingNap], _ d: UserDefaults) {
        d.set((try? JSONEncoder().encode(items)) ?? Data(), forKey: pendingKey)
    }
}
