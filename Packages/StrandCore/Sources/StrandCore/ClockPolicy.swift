import Foundation

/// Pure decision: should we SET_CLOCK on this connect? Mirrors WHOOP — set only when the strap's RTC
/// has drifted beyond a small threshold (or is frozen/way off), not blindly every connect. Avoids
/// gratuitous clock resets that could introduce discontinuities in derived historical timestamps.
public enum ClockPolicy {
    /// `deviceClock` = the strap's current RTC reading (unix seconds, from GET_CLOCK). `wallNow` =
    /// phone wall time (unix seconds). Returns true if |drift| >= threshold.
    public static func shouldSetClock(deviceClock: Int, wallNow: Int, driftThreshold: Int = 2) -> Bool {
        abs(wallNow - deviceClock) >= driftThreshold
    }
}
