import Foundation

/// The mood check-in's storage ids, scale and wording, apart from its `Repository` persistence
/// (`MoodStore.swift`) so the coach and the Android core read the same values.
enum MoodStore {
    /// Dedicated source id for native mood rows (mirrors `Repository.journalDeviceId`
    /// — imports write under their own device ids and can never touch this one).
    static let moodDeviceId = "noop-mood"

    /// metricSeries key for the daily 1–5 mood scalar.
    static let moodKey = "mood"

    /// The check-in scale: 1 (lowest) … 5 (highest).
    static let scale: ClosedRange<Int> = 1...5

    /// Face glyph for a stored 1–5 value (clamps out-of-range defensively).
    static func face(for value: Int) -> String {
        switch value {
        case ...1: return "😞"
        case 2:    return "😕"
        case 3:    return "😐"
        case 4:    return "🙂"
        default:   return "😄"
        }
    }

    /// Neutral, non-clinical word for a stored 1–5 value — never a verdict.
    static func label(for value: Int) -> String {
        switch value {
        case ...1: return String(localized: "Rough")
        case 2:    return String(localized: "Low")
        case 3:    return String(localized: "Okay")
        case 4:    return String(localized: "Good")
        default:   return String(localized: "Great")
        }
    }
}
