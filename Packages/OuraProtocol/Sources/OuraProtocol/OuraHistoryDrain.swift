import Foundation

/// Pure, testable decision core for the Oura history drain + durable resume cursor (#91 / #291).
///
/// Extracted from `OuraLiveSource` so the drain guards and cursor logic — which silently regressed once
/// already when the Oura BLE stack was refactored (#291: "lost when refactoring") — are pinned by unit
/// tests instead of only on-device observation. This owns ONLY the per-drain counters and the decisions;
/// the caller (`OuraLiveSource`) keeps all I/O — anchor resolution, persistence, logging, and the actual
/// `historyCursorAdvanced` emit.
///
/// The `0x11` history summary carries no cursor — only `bytes_left` (a remaining-byte count) and a
/// `moreData` flag. A healthy drain runs until `bytes_left == 0`; the resume cursor commits from the
/// newest STORED sample's ring-time at drain end. Byte counts are never persisted.
public struct OuraHistoryDrain: Sendable, Equatable {
    /// A ring-time above this is corrupt (~1.6 years of ticks) and must not set the resume cursor, or the
    /// next session would seek into nonsense. Bounds the cursor at the source.
    public static let maxPlausibleResumeTicks: UInt32 = 500_000_000
    /// `bytes_left` not shrinking for this many straight summaries = the ring is looping; stop.
    public static let maxStallSummaries = 3
    /// A healthy full pull finishes in ~1-2 min; past this something upstream is wrong — stop, keep the
    /// banked progress, and let the periodic re-fetch try again later.
    public static let maxDrainSeconds: TimeInterval = 300

    private var minBytesLeftSeen: UInt32 = .max
    private var stallCount = 0
    /// Newest STORED ring-time seen this drain — the value the resume cursor commits to at drain end.
    public private(set) var maxStoredRingTime: UInt32 = 0
    /// A real stored sample older than where we sought this fetch: the ring's clock reset (or it ignored
    /// the seek), so the persisted cursor is stale → full pull next connect.
    public private(set) var sawPreResumeData = false

    public init() {}

    /// Reset the per-drain state at the start of a fetch. Mirrors `OuraLiveSource`'s fetch-start reset.
    public mutating func reset() {
        minBytesLeftSeen = .max
        stallCount = 0
        maxStoredRingTime = 0
        sawPreResumeData = false
    }

    /// Fold in one history summary; returns whether the drain should CONTINUE.
    ///
    /// `moreData == false` (`bytes_left == 0`) always completes. Otherwise two backstops force-stop a
    /// misbehaving ring while keeping banked progress: the STALL guard (`bytes_left` must shrink across
    /// summaries — [maxStallSummaries] flat reads means it's looping) and the DEADLINE guard
    /// (`elapsedSeconds` past [maxDrainSeconds]). `elapsedSeconds` is the caller's wall clock since the
    /// drain started, or `0` when no drain-start is set (matching the old `let started = …` guard).
    public mutating func onSummary(bytesLeft: UInt32, moreData: Bool, elapsedSeconds: TimeInterval) -> Bool {
        guard moreData else { return false }
        if bytesLeft < minBytesLeftSeen {
            minBytesLeftSeen = bytesLeft
            stallCount = 0
        } else {
            stallCount += 1
            if stallCount >= Self.maxStallSummaries { return false }
        }
        if elapsedSeconds > Self.maxDrainSeconds { return false }
        return true
    }

    /// Record a STORED history sample's ring-time toward the resume cursor. Call ONLY where a sample
    /// resolved a REAL anchored time (never a wall-clock fallback). Ignores corrupt (over-ceiling) times,
    /// and flags a reboot when a real sample predates `resumeCursorAtFetchStart` (0 = full pull, no floor).
    public mutating func noteStoredRingTime(_ rt: UInt32, resumeCursorAtFetchStart: UInt32) {
        guard rt <= Self.maxPlausibleResumeTicks else { return }
        if rt > maxStoredRingTime { maxStoredRingTime = rt }
        if resumeCursorAtFetchStart > 0, rt < resumeCursorAtFetchStart { sawPreResumeData = true }
    }

    /// The cursor to persist at drain end, given the current cursor and whether `maxStoredRingTime`
    /// resolves under the CURRENT anchor. A reboot (`sawPreResumeData`) resets to 0 (honest full pull next
    /// connect); otherwise the cursor advances to `maxStoredRingTime` only if it moved forward AND
    /// resolves. Unchanged in every other case.
    public func resumeCursorAtDrainEnd(currentCursor: UInt32, resolvesUnderAnchor: Bool) -> UInt32 {
        if sawPreResumeData { return 0 }
        if maxStoredRingTime > currentCursor, resolvesUnderAnchor { return maxStoredRingTime }
        return currentCursor
    }

    /// Sanitize a cursor loaded from persistence: a value above the plausibility ceiling is pre-fix
    /// garbage and must reset to a full pull.
    public static func sanitizeLoadedCursor(_ persisted: UInt32) -> UInt32 {
        persisted <= maxPlausibleResumeTicks ? persisted : 0
    }
}
