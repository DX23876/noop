import Foundation
import WhoopStore

/// The same local-day total for hydration cards and goals: manual and imported water are separate
/// inputs, summed only on read. Missing days remain zero in the complete requested day window.
public enum HydrationRead {
    public static let sourceId = "hydration"
    public static let manualKey = "hydration"
    public static let importedKey = "hydrationImported"

    public static func history(store: WhoopStore?, days: Int, now: Date) async -> [(day: String, value: Double)] {
        let n = max(1, days)
        let from = now.addingTimeInterval(-Double(n - 1) * 86_400)
        let fromKey = StoreReader.localDayKey(from), toKey = StoreReader.localDayKey(now)
        var byDay: [String: Double] = [:]
        if let store {
            for key in [manualKey, importedKey] {
                let points = (try? await store.metricSeries(deviceId: sourceId, key: key, from: fromKey, to: toKey)) ?? []
                for point in points { byDay[point.day, default: 0] += point.value }
            }
        }
        return (0..<n).map { index in
            let key = StoreReader.localDayKey(now.addingTimeInterval(-Double(n - 1 - index) * 86_400))
            return (key, byDay[key] ?? 0)
        }
    }
}
