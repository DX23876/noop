import Foundation

/// What the card about a night that is not finished yet SAYS — in one place, because two surfaces say it.
///
/// The same state (`AICoach.unconfirmedWakeNeedingReview`, i.e. `SleepWindowSettledness.awaitingSync`)
/// was reported twice in different words and with different buttons: Forge's Today notice read "The
/// night may not be fully synced yet", while the classic morning card read "Check last night first" and
/// named the detected wake. One fact, two readouts, free to drift — and they had.
///
/// So the wording lives here and both render it. Decided with the owner on 2026-11-18:
///
/// - The headline is about the RESULT, not about the transfer: the night is still being scored. That is
///   what the reader is in the middle of, and it is what WHOOP's own wording gets right.
/// - The line underneath carries the truth the headline cannot: how far the data reaches, and what is
///   holding the rest. "Still being processed" on its own would promise work that is not running while
///   the strap sits in the next room.
/// - The time alone would not do either. "Data up to 06:12" reads like a finished statement to someone
///   who got up at seven; under a headline that says the scoring is unfinished, it reads as the edge of
///   what has arrived.
///
/// Pure and clock-injected (the formatter needs a locale, nothing else), so both lines are testable
/// without a strap, a store or a view.
enum UnsettledNightReadout {

    struct Reading: Equatable {
        /// The card's headline. The same in both states on purpose: the state the reader is in has not
        /// changed, only the reason for it.
        let headline: String
        /// How far the data reaches, and what the rest is waiting for.
        let line: String
        /// The detected wake, for the surfaces that offer confirming it.
        let wakeTs: Int
        /// Whether an offload is running, for a surface that wants to show it is moving.
        let fetching: Bool
    }

    /// - Parameters:
    ///   - wakeTs: the detected wake, which is also where the arrived data stops (that equality is what
    ///     `SleepWindowSettledness` detects; within two minutes of it).
    ///   - fetching: an offload is running right now (`LiveState.backfilling`).
    static func reading(wakeTs: Int, fetching: Bool,
                        locale: Locale = .current, timeZone: TimeZone = .current) -> Reading {
        let at = timeString(wakeTs, locale: locale, timeZone: timeZone)
        let line = fetching
            ? String(localized: "Data up to \(at), still coming in.")
            : String(localized: "Data up to \(at). The strap hasn't handed over the rest yet.")
        return Reading(headline: String(localized: "Still being scored"), line: line,
                       wakeTs: wakeTs, fetching: fetching)
    }

    /// The wake as a short local time. One formatter for both surfaces: the classic card built its own
    /// and Forge printed none, which is how a screen and a log end up naming different minutes.
    static func timeString(_ ts: Int, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let df = DateFormatter()
        df.locale = locale
        df.timeZone = timeZone
        df.timeStyle = .short
        df.dateStyle = .none
        return df.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}
