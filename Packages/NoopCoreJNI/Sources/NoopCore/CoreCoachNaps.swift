import Foundation

/// The coach's naps block (`CoachNapContext.swift` on Apple) reads the Sleep tab's night selector, which lives in
/// the Apple app. The Android core has no such selector yet, so its coach leaves the block out, as it does for a
/// window without naps.
extension AICoachEngine {
    func napsBlock() async -> String { "" }
}
