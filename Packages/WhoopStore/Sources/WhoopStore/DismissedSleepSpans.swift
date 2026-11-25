import Foundation

/// The pure logic behind a DELETED sleep night's durable tombstone (#65/#68).
///
/// Deleting a DETECTED sleep must suppress its re-detection so the night does not silently come back
/// on the next analyze pass, WITH an undo. The tombstones live as `"startTs:endTs"` strings in
/// UserDefaults (the macOS `CachedSleepSession` lives in the WhoopStore Journal DB, which the app
/// layer must not extend with a new table; the same reason the dismissed-WORKOUT spans live in
/// UserDefaults, not the DB). This enum owns everything about those strings that has no I/O, so it is
/// unit-tested directly and stays in lockstep with the Kotlin `dismissedSleep` Room table's read/guard
/// semantics (`com.noop.data.DismissedSleepGuard`).
///
/// The Swift side has NO deviceId split (one UserDefaults list, id-free), so unlike Android there is no
/// namespace-mismatch hazard on the read: the tombstone is found whatever namespace owned the row. The
/// undo path still has to restore the row into its ORIGINAL owning namespace, but that namespace is
/// resolved at the Repository layer against the DB, not here.
public enum DismissedSleepSpans {

    /// The canonical token for a dismissed window. `startTs` is the deleted session's immutable detected
    /// key; `endTs` is the night's span, so the engine's overlap test still matches when a re-detected
    /// onset drifts second-to-second.
    public static func token(startTs: Int, endTs: Int) -> String { "\(startTs):\(endTs)" }

    /// Parse a stored token list into `(start, end)` windows for the engine's re-detection guard.
    /// Malformed / non-positive-width entries are dropped so a corrupt value can never hide everything
    /// (mirrors `WorkoutSource`'s parser). Order is preserved.
    public static func windows(from tokens: [String]) -> [(start: Int, end: Int)] {
        tokens.compactMap { s in
            let parts = s.split(separator: ":")
            guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), b > a else { return nil }
            return (a, b)
        }
    }

    /// Add a token to `tokens` idempotently (no duplicate), returning the new list. The caller persists it.
    public static func adding(startTs: Int, endTs: Int, to tokens: [String]) -> [String] {
        let t = token(startTs: startTs, endTs: endTs)
        guard !tokens.contains(t) else { return tokens }
        var out = tokens
        out.append(t)
        return capped(out)
    }

    /// Remove the token for `(startTs, endTs)` from `tokens`, returning the new list. This is the undo
    /// and "allow re-detection" escape hatch. Removes EVERY matching copy (belt-and-braces; add is
    /// idempotent so there should only be one).
    public static func removing(startTs: Int, endTs: Int, from tokens: [String]) -> [String] {
        let t = token(startTs: startTs, endTs: endTs)
        return tokens.filter { $0 != t }
    }

    /// True when at least half of `[sessionStart, sessionEnd)` lies inside one dismissed window: the
    /// engine's re-detection guard predicate. Overlap rather than an exact startTs, because a re-detected
    /// onset drifts as more raw data arrives; the deleted night found again keeps nearly all of itself
    /// inside its old window.
    ///
    /// Half, not any overlap (tester report, 2026-11-24): a wearer deleted a false "sleep" from 2 to 4 am
    /// spent awake in bed, then slept. The detector saw one night from 2 am onwards, which touched the
    /// tombstone, and the real night was dropped whole. A night that only shares its first hours with a
    /// deleted window is a different night. Half-open intervals, as the Android twin uses.
    public static func isSuppressed(sessionStart: Int, sessionEnd: Int,
                                    windows: [(start: Int, end: Int)]) -> Bool {
        let length = sessionEnd - sessionStart
        guard length > 0 else {
            return windows.contains { sessionStart < $0.end && $0.start < sessionEnd }
        }
        return windows.contains { window in
            let overlap = min(sessionEnd, window.end) - max(sessionStart, window.start)
            return overlap > 0 && overlap * 2 >= length
        }
    }

    /// Whether deleting a night writes a suppression tombstone (#65). A DETECTED night is tombstoned so
    /// the recompute does not regenerate it. A user-created/edited (`userEdited`) night (a hand-corrected
    /// night or a manually-added nap) is deleted WITHOUT a tombstone: it is never re-detected, so
    /// suppressing its window would needlessly block a real future night overlapping it. (Android twin:
    /// `DismissedSleepGuard.writesTombstoneOnDelete`.)
    public static func writesTombstoneOnDelete(userEdited: Bool) -> Bool { !userEdited }

    /// Defensive hard cap on the tombstone list. The list is a permanent user choice, so unlike the
    /// auto-detect spans there is NO age prune (a prune would silently resurrect nights while banked raw
    /// still covers the window). Only guard against an unbounded list: keep the newest by end-time.
    /// Mirrored on Android.
    public static let hardCap = 500

    static func capped(_ tokens: [String]) -> [String] {
        guard tokens.count > hardCap else { return tokens }
        // Drop the OLDEST by end-time. Malformed tokens sort last (endTs 0) and are dropped first.
        func endTs(_ s: String) -> Int {
            let parts = s.split(separator: ":")
            return parts.count == 2 ? (Int(parts[1]) ?? 0) : 0
        }
        return Array(tokens.sorted { endTs($0) > endTs($1) }.prefix(hardCap))
    }
}
