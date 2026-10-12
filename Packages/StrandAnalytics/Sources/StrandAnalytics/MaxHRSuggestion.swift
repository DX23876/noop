import Foundation
import WhoopProtocol

// MaxHRSuggestion.swift — fork: proposes a measured maximum heart rate when the band has seen one clearly
// above the value the app uses (entered, else Tanaka). Never applied silently: Settings offers it and the
// wearer decides, because a band artefact must not move Effort and every zone on its own.
//
// A peak only counts when it was HELD: the highest level the heart rate stayed at or above for 30 seconds
// without a gap, so a single spike or a cadence-locked reading of a few beats cannot set it. A suggestion
// needs that level on two different days in the last six months, and five beats above the current value.

public enum MaxHRSuggestion {

    public static let holdSeconds = 30
    /// A longer gap between samples breaks a hold: the band lost contact.
    public static let maxGapSeconds = 5
    public static let windowDays = 182
    public static let minimumDays = 2
    public static let marginBPM = 5

    /// The highest heart rate held for `holdSeconds` without a gap longer than `maxGapSeconds`: the maximum,
    /// over every such stretch, of the stretch's lowest sample. Nil when no stretch is long enough.
    public static func heldPeak(_ hr: [HRSample]) -> Int? {
        let s = hr.sorted { $0.ts < $1.ts }
        var best: Int?
        var i = 0
        while i < s.count {
            var low = s[i].bpm
            var j = i
            while j + 1 < s.count, s[j + 1].ts - s[j].ts <= maxGapSeconds, s[j].ts - s[i].ts < holdSeconds {
                j += 1
                low = min(low, s[j].bpm)
            }
            if s[j].ts - s[i].ts >= holdSeconds { best = max(best ?? 0, low) }
            i += 1
        }
        return best
    }

    /// The value to offer: the level reached on at least `minimumDays` days of the window (the second-highest
    /// day's peak), when it lies `marginBPM` above `current` and above a value the wearer already declined.
    public static func suggestion(dayPeaks: [(day: String, value: Double)], current: Double, declined: Int,
                                  today: String) -> Int? {
        let start = HealthspanWindow.dayKey(today, plus: -(windowDays - 1))
        let peaks = dayPeaks.filter { $0.day >= start && $0.day <= today }.map { Int($0.value.rounded()) }
            .sorted(by: >)
        guard peaks.count >= minimumDays else { return nil }
        let level = peaks[minimumDays - 1]
        guard Double(level) >= current + Double(marginBPM), level > declined else { return nil }
        return level
    }
}
