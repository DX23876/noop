import Foundation

/// What the energy model's refreshes cost this session, for the log header.
///
/// A completed offload used to re-price 120 days on the main actor, 24 to 38 s on a real store; the
/// post-offload refresh now re-prices only from the first changed day. Whether that holds on a phone over a
/// normal day (how many refreshes, how many days each covered, how long the main actor was held) cannot be
/// read from a log without these. Counts, days and milliseconds only; process-lifetime, never persisted.
@MainActor
enum EnergyRefreshStats {

    private(set) static var refreshes = 0
    /// Days re-priced across every refresh.
    private(set) static var days = 0
    private(set) static var millis = 0
    private(set) static var longestMillis = 0

    static func record(days covered: Int, millis elapsed: Int) {
        refreshes += 1
        days += max(0, covered)
        millis += max(0, elapsed)
        longestMillis = max(longestMillis, elapsed)
    }

    /// Test seam: the counters are process-lifetime.
    static func reset() { refreshes = 0; days = 0; millis = 0; longestMillis = 0 }

    /// One header line, or nothing when no refresh ran this session.
    static func summaryLines() -> [String] {
        guard refreshes > 0 else { return [] }
        return ["Energy refreshes: count=\(refreshes) days=\(days) totalMs=\(millis) "
                + "avgMs=\(millis / refreshes) longestMs=\(longestMillis)"]
    }
}
