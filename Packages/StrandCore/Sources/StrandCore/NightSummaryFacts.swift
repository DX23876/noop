import Foundation
import WhoopStore

/// The four figures a night is summed up in: time in bed, time asleep, restorative sleep (deep plus REM)
/// and efficiency, each with the wearer's own usual beside it.
///
/// They exist because a sleep screen that shows only shares cannot answer "how long did I sleep, and was
/// that a lot for me". The old Sleep screen's "Stage breakdown" header carries them; the Forge Sleep page
/// carried efficiency and restorative sleep as percentages only, and a tester asked for the figures back
/// (2026-11-19), reporting that the only way to them was Health, Sleep, Sleep details.
///
/// They are resolved here rather than per screen because three screens had already written their own
/// version: two private copies of the restorative typical, and an efficiency that preferred the stored
/// session value on one screen and recomputed it from the stages on another, so the same night could read
/// 95 % in one place and 94 % in the next.
public enum NightSummaryFacts {

    /// One night, as every screen already holds it.
    public struct Night: Equatable, Sendable {
        /// The stages' own sum, not the onset-to-wake span: a gap between the blocks of a split night is
        /// not time in bed.
        public let inBedMin: Double
        public let asleepMin: Double
        public let deepMin: Double
        public let remMin: Double
        /// The efficiency the night was stored with, as a fraction or a percentage. Nil recomputes it.
        public let storedEfficiency: Double?

        public init(inBedMin: Double, asleepMin: Double, deepMin: Double, remMin: Double,
                    storedEfficiency: Double?) {
            self.inBedMin = inBedMin
            self.asleepMin = asleepMin
            self.deepMin = deepMin
            self.remMin = remMin
            self.storedEfficiency = storedEfficiency
        }
    }

    public struct Facts: Equatable, Sendable {
        public let inBedMin: Double
        public let asleepMin: Double
        public let restorativeMin: Double
        public let efficiencyPct: Double?
        public let typicalAsleepMin: Double?
        public let typicalRestorativeMin: Double?
    }

    /// One stored night, as the typicals read it. The screens hold their day rows in different shapes —
    /// `DailyMetric` on the Apple side, a JSON hand-over on Android — and the averages must not be
    /// written twice for that.
    public struct NightRow: Equatable, Sendable {
        public let asleepMin: Double?
        public let deepMin: Double?
        public let remMin: Double?
        public init(asleepMin: Double?, deepMin: Double?, remMin: Double?) {
            self.asleepMin = asleepMin
            self.deepMin = deepMin
            self.remMin = remMin
        }
    }

    /// Nights needed before a typical is stated at all. Below it the wearer has no usual yet, and a mean
    /// of two nights presented as one would be a number pretending to be a baseline.
    public static let minimumNightsForTypical = 5

    /// How far back a typical looks.
    public static let typicalNights = 30

    public static func read(night: Night, nights: [NightRow]) -> Facts {
        Facts(inBedMin: night.inBedMin,
              asleepMin: night.asleepMin,
              restorativeMin: night.deepMin + night.remMin,
              efficiencyPct: efficiencyPct(asleepMin: night.asleepMin, inBedMin: night.inBedMin,
                                           stored: night.storedEfficiency),
              typicalAsleepMin: typicalAsleepMin(nights),
              typicalRestorativeMin: typicalRestorativeMin(nights))
    }

    /// The same, from the stored day rows the Apple screens already hold.
    public static func read(night: Night, days: [DailyMetric]) -> Facts {
        read(night: night, nights: rows(days))
    }

    public static func rows(_ days: [DailyMetric]) -> [NightRow] {
        days.map { NightRow(asleepMin: $0.totalSleepMin, deepMin: $0.deepMin, remMin: $0.remMin) }
    }

    /// Share of the time in bed spent asleep.
    ///
    /// The stored value wins: it is what the night was scored with, and recomputing it from display
    /// totals can disagree with it by a point or two. Import paths deliver it both as a fraction and as a
    /// percentage, so a value at or below 1 is read as a fraction — which also means a stored 100 %
    /// arrives as 1.0 and reads as 100, the same number either way.
    public static func efficiencyPct(asleepMin: Double, inBedMin: Double, stored: Double?) -> Double? {
        if let stored, stored > 0 { return stored <= 1.0 ? stored * 100 : stored }
        guard inBedMin > 0, asleepMin > 0 else { return nil }
        return min(100, asleepMin / inBedMin * 100)
    }

    /// The wearer's usual night, as the mean of the stored totals.
    public static func typicalAsleepMin(_ nights: [NightRow]) -> Double? {
        mean(nights.suffix(typicalNights).compactMap(\.asleepMin).filter { $0 > 0 })
    }

    public static func typicalAsleepMin(_ days: [DailyMetric]) -> Double? { typicalAsleepMin(rows(days)) }

    /// The wearer's usual restorative sleep: deep plus REM, per night, averaged.
    ///
    /// Per night and not as the sum of the two separate means: a night missing one of the stages would
    /// otherwise contribute to one mean and not the other, and the two halves would be taken over
    /// different nights.
    public static func typicalRestorativeMin(_ nights: [NightRow]) -> Double? {
        mean(nights.suffix(typicalNights).compactMap { night in
            guard let deep = night.deepMin, let rem = night.remMin else { return nil }
            let value = deep + rem
            return value > 0 ? value : nil
        })
    }

    public static func typicalRestorativeMin(_ days: [DailyMetric]) -> Double? {
        typicalRestorativeMin(rows(days))
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard values.count >= minimumNightsForTypical else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
