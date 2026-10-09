import Foundation

/// Which strap EVENT packets arrived this session, by name.
///
/// Every strap-pushed event kicks a rate-limited history sync (`FrameRouter`, `BackfillPolicy.strap`), and a
/// field log on 2026-10-07 showed 160 such kicks absorbed by the rate limit in one day without saying which
/// events they were. Battery and temperature reports are routine and say nothing about new history; a
/// prompt from the strap's own sync engine does. Deciding which may kick a sync needs these counts first.
///
/// Counts only, keyed by the event's name with its raw number stripped ("BATTERY_LEVEL(3)" counts as
/// BATTERY_LEVEL). Process-lifetime, never persisted, same privacy class as `HealthSyncStats`.
@MainActor
enum StrapEventStats {

    private(set) static var counts: [String: Int] = [:]

    static func record(_ event: String) {
        counts[name(of: event), default: 0] += 1
    }

    /// "BATTERY_LEVEL(3)" -> "BATTERY_LEVEL". An event without a raw number is kept as it is.
    nonisolated static func name(of event: String) -> String {
        guard let open = event.firstIndex(of: "(") else { return event }
        return String(event[..<open])
    }

    /// Test seam: the counts are process-lifetime.
    static func reset() { counts = [:] }

    /// One header line, most frequent first (ties by name so the line is stable), or nothing when no event
    /// arrived this session.
    static func summaryLines() -> [String] {
        guard !counts.isEmpty else { return [] }
        let parts = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        return ["Strap events: " + parts.joined(separator: " ")]
    }
}
