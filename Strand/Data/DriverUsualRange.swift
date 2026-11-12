import Foundation

/// A Charge driver's usual range, shared by iOS (`ForgeToday.middleHalf`, `ForgeToday.place`) and the Android core:
/// the middle half (25 % to 75 %) of the nights before the shown one, and the night's figure placed on a 0 to 100
/// track with that range in its middle third. Pure, so both platforms place a night the same way.
enum DriverUsualRange {
    /// The 25th and 75th percentile of [values] (linear between neighbours), nil under seven values.
    static func middleHalf(_ values: [Double]) -> (low: Double, high: Double)? {
        let xs = values.filter(\.isFinite).sorted()
        guard xs.count >= 7 else { return nil }
        func at(_ p: Double) -> Double {
            let pos = p * Double(xs.count - 1)
            let lo = Int(pos), hi = min(lo + 1, xs.count - 1)
            return xs[lo] + (pos - Double(lo)) * (xs[hi] - xs[lo])
        }
        return (at(0.25), at(0.75))
    }

    /// A value and a range on one 0 to 100 track: the range sits in the middle third, the track widens so a value
    /// far outside it still lands on the track.
    static func place(_ value: Double, low: Double, high: Double) -> (position: Double, band: ClosedRange<Double>) {
        let width = max(high - low, abs(high) * 0.02, 0.1)
        let start = min(low - width, value - width * 0.25)
        let end = max(high + width, value + width * 0.25)
        func p(_ x: Double) -> Double { (x - start) / (end - start) * 100 }
        return (p(value), p(low)...p(high))
    }
}
