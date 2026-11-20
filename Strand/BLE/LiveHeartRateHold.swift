import Foundation

/// One screen's hold on the realtime heart-rate stream: taken when the screen appears, released exactly
/// once when it leaves.
///
/// `AppModel.startRealtimeHR()` / `stopRealtimeHR()` are ref-counted so two surfaces showing live HR at
/// once cannot disarm the stream from under each other (#681). That only holds while every surface takes
/// and releases in pairs, and the Live screen did not: it took its hold only when the strap was connected
/// AND bonded at the moment the screen appeared, while releasing unconditionally on the way out. Two
/// things followed from the same line.
///
/// A screen opened before the link was up - a cold start, a reconnect, the seconds while the strap is
/// still handing over its history - never registered that it wanted the stream. The link event that
/// followed re-armed through `rearmRealtimeIfWanted()`, which is deliberately a no-op when nothing wants
/// the stream, so there was nothing to re-arm and live HR stayed blank for as long as the screen was open,
/// although the link was healthy and the battery reading beside it kept updating. Starting a workout fixed
/// it, because every workout surface takes its hold without asking about the link.
///
/// And the unbalanced release could take away a hold that was not this screen's. With a workout running,
/// opening the Live screen during a momentary drop took nothing, and leaving it released the workout's
/// hold instead - the exact failure the ref-count exists to prevent.
///
/// Holding is about WHICH DEVICE the screen is for, never about whether its link happens to be up this
/// instant. `BLEManager` keeps the want and arms it when it can: on a WHOOP 4 the keep-alive tick re-arms
/// from `wantsRealtime`, on a 5/MG the post-bond branch does. A want registered while offline is how both
/// of those are meant to be reached.
struct LiveHeartRateHold {
    private(set) var isHeld = false

    /// True exactly once per hold: on the call that takes it. `isWhoop` is the only condition, because an
    /// Oura ring streams through its own source and never went through this path.
    mutating func take(isWhoop: Bool) -> Bool {
        guard !isHeld, isWhoop else { return false }
        isHeld = true
        return true
    }

    /// True exactly once per hold: on the call that gives it back. False when this screen never took one,
    /// so a release can never reach somebody else's hold.
    mutating func release() -> Bool {
        guard isHeld else { return false }
        isHeld = false
        return true
    }
}
