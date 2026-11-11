import Foundation

/// A usual day's burn, shared by the iPhone and the Android core: the median total of the finished days given, from
/// five of them on. The Energy page's ring fills to it, its history draws it as a dashed line, and Today's Energy card
/// compares against it, so the three cannot disagree. Display only; nothing is stored. Analysis migration
/// required: no.
enum EnergyUsualDay {
    /// `totals` are (day, total burned) pairs; `today` is left out, since its total is still running.
    static func total(_ totals: [(day: String, total: Double?)], today: String) -> Double? {
        let sorted = totals.filter { $0.day != today }.compactMap(\.total).filter { $0 > 0 }.sorted()
        guard sorted.count >= 5 else { return nil }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
