import Foundation

/// Hevy figures as the app shows them, in a file without app dependencies so the coach's card tool links into
/// the Android core.
enum HevyFormat {
    /// A kilogram total with thousands separators. Guards against a non-finite accumulation the way the
    /// CSV lane does — `Int(inf.rounded())` traps.
    static func groupedKg(_ kg: Double) -> String {
        guard kg.isFinite, kg >= 0, kg < 1e12 else { return "0" }
        let n = Int(kg.rounded())
        return groupedFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()
}
