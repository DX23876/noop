import Foundation

/// The cycle-awareness opt-in (default off, the most sensitive health category, manual-first): one UserDefaults
/// key, written by the Settings toggle and the card's opt-in, read by the coach (`AppModel.cycleAwarenessKey`).
enum CycleAwarenessPrefs {
    static let key = "noopCycleAwareness"
}
