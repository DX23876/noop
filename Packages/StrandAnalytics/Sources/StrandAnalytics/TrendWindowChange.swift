import Foundation

/// How a metric's readings in one window compare with the window before it.
///
/// One answer to "did this go up or down over this stretch", because the Trends tab had three. The chip
/// beside a chart card split the POINTS down the middle by count and reported an absolute difference
/// with no coverage rule at all; the change summary split by DATE, reported a relative change and
/// refused a half with too few readings; and the range report (`RangeReport`) splits by position for
/// its means but takes its DIRECTION from an OLS slope against a per-metric threshold. For one metric
/// over one stretch those can disagree on magnitude, on basis and even on sign, which is precisely what
/// a screen must not be able to do to itself.
///
/// This resolves the first two. The report's slope is deliberately left alone: it answers a different
/// question, across the whole range rather than half against half, and it is shown on its own screen
/// (see `docs/fork/decisions.md`).
public struct TrendWindowChange: Equatable, Sendable {
    /// Mean of the readings in the earlier half.
    public let beforeMean: Double
    /// Mean of the readings in the later half.
    public let nowMean: Double
    public let beforeCount: Int
    public let nowCount: Int

    public init(beforeMean: Double, nowMean: Double, beforeCount: Int, nowCount: Int) {
        self.beforeMean = beforeMean
        self.nowMean = nowMean
        self.beforeCount = beforeCount
        self.nowCount = nowCount
    }

    /// The move in the metric's own units, which is what a chip beside a figure in those units shows.
    public var absolute: Double { nowMean - beforeMean }

    /// The move as a share of where it started, or nil when it started at zero, where a share would be
    /// a division by nothing rather than a big change.
    public var relative: Double? {
        beforeMean == 0 ? nil : (nowMean - beforeMean) / abs(beforeMean)
    }
}

/// The one place that decides what "it moved over this window" means.
///
/// Pure: no calendar, no database, no clock. It is generic over whatever the caller already uses to
/// order its readings — day keys on the screen that works in `yyyy-MM-dd`, dates on the screen that
/// parsed them into dates — so neither has to re-derive the other's kind of key. Re-deriving is its own
/// bug: the chart's day strings are parsed in UTC, and turning those dates back into LOCAL day keys
/// shifts every point by a day for a wearer west of UTC.
public enum TrendWindow {

    /// Readings each half must hold before the comparison means anything: a third of the span, and
    /// never fewer than two, because the mean of one reading is that reading.
    public static func minimumReadings(forSpan span: Int) -> Int { max(2, span / 3) }

    /// The later half against the earlier one, or nil when either half is too thin to compare.
    ///
    /// Split by the key, never by how many readings happen to be in the array: with gaps in the data a
    /// count-split puts both halves inside the same recent stretch and then reports a move that covers
    /// neither half of the window.
    ///
    /// - Parameters:
    ///   - after: the earlier half starts after this key, or nil to start at the first reading.
    ///   - cut: the later half is everything after this key; the earlier half is what lies between.
    public static func change<Key: Comparable>(of series: [(key: Key, value: Double)],
                                               after start: Key?,
                                               cut: Key,
                                               minimumReadings: Int) -> TrendWindowChange? {
        let now = series.filter { $0.key > cut }.map(\.value)
        let before = series.filter { (start == nil || $0.key > start!) && $0.key <= cut }.map(\.value)
        guard now.count >= minimumReadings, before.count >= minimumReadings else { return nil }
        return TrendWindowChange(beforeMean: before.reduce(0, +) / Double(before.count),
                                 nowMean: now.reduce(0, +) / Double(now.count),
                                 beforeCount: before.count,
                                 nowCount: now.count)
    }
}
