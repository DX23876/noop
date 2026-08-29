import Foundation

/// Bounded, on-demand raw-capture window. Never 24/7 — clamps to a sane max.
/// The Collector ORs `isActive(at:)` into its raw-persist gate; the deadline
/// auto-expires the window so a missed stop callback can't leak raw forever.
struct RawCaptureWindow {
    static let minSeconds: TimeInterval = 1
    // A manually stopped research session may legitimately last for hours. It is still bounded so an
    // interrupted UI/process cannot accidentally turn the opt-in capture into permanent 24/7 logging.
    static let maxSeconds: TimeInterval = 24 * 60 * 60
    static func clamp(_ s: TimeInterval) -> TimeInterval { min(max(s, minSeconds), maxSeconds) }

    private var deadline: TimeInterval?       // monotonic deadline; nil = inactive
    /// Returns true while the window is open, inclusive of the deadline instant (`t <= deadline`).
    func isActive(at t: TimeInterval) -> Bool { if let d = deadline { return t <= d } else { return false } }
    mutating func open(at t: TimeInterval, duration: TimeInterval) { deadline = t + Self.clamp(duration) }
    mutating func close() { deadline = nil }
}
