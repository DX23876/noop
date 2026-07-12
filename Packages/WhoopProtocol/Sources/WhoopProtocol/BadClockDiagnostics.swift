import Foundation

/// #324 bad-clock strap diagnostics: pure formatters for the Backfiller's strap-log lines about a strap
/// whose RTC reset to a wrong base (future- or far-past-dated banking). Kept here (not in the app target)
/// so the formatting is `swift test`-able on Linux and mirrored byte-for-byte by the Kotlin twin. No state,
/// no `Date()` inside — callers inject `now` so the output is deterministic and testable.
public enum BadClockDiagnostics {

    /// UTC `yyyy-MM-dd` for a unix-seconds timestamp — the human-readable day a dropped record CLAIMED,
    /// which on a bad-clock strap is the wrong base its RTC jumped to.
    public static func isoDay(_ unix: Int) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// Signed hour offset of `unix` from `now`, worded for a log: "26445h ahead" / "512h behind" / "~now"
    /// (within an hour). The magnitude is what tells a future-clock strap (#928) from a stale-clock one.
    public static func hoursOffset(_ unix: Int, now: Int) -> String {
        let h = (unix - now) / 3600
        if h > 0 { return "\(h)h ahead" }
        if h < 0 { return "\(-h)h behind" }
        return "~now"
    }

    /// The parenthetical span clause appended to the dropped-record log: " (dated 2028-06-24 -> 2029-07-15,
    /// 26445h ahead)". Empty string when nothing was dropped (both nil), so the base sentence reads normally.
    /// When oldest == newest a single date is shown. `now` words the offset of the NEWEST (frontier) record.
    public static func droppedSpanClause(oldest: Int?, newest: Int?, now: Int) -> String {
        guard let o = oldest, let n = newest else { return "" }
        let offset = hoursOffset(n, now: now)
        if o == n { return " (dated \(isoDay(n)), \(offset))" }
        return " (dated \(isoDay(o)) -> \(isoDay(n)), \(offset))"
    }
}
