import Foundation
import StrandAnalytics
import StrandCore

/// The detail page of one measure on Android, as iOS `MetricDetailView` reads it (`MetricDetailInsights`): the
/// statistics over the visible window, the change against the window before it and the catalog measures that
/// moved with it. The page hands over the series it already shows, so the numbers describe exactly that window.
public enum CoreMetricDetail {
    public struct Insights: Encodable {
        public let n: Int
        public let mean: Double?
        public let min: Double?
        public let max: Double?
        /// Present when both the visible window and the one before it hold readings.
        public let delta: Double?
        public let pctChange: Double?
        public let direction: Int
        public let correlations: [Correlation]
    }

    public struct Correlation: Encodable {
        public let key: String
        public let source: String
        public let title: String
        public let category: String
        public let r: Double
        public let n: Int
    }

    /// Every catalog measure's series, kept until the data revision moves on: the scan is a few hundred store
    /// reads, and switching the page's window must not repeat it.
    private static var catalogCache: (revision: Int, series: [String: [(day: String, value: Double)]])?
    private static let cacheLock = NSLock()

    /// [series] is the measure's full ascending history and [windowed] the part the page shows; [catalogKey] and
    /// [catalogSource] name it in `MetricCatalog`, so it is left out of its own correlations.
    public static func insights(reader: StoreReader, catalogKey: String, catalogSource: String,
                                series: [(day: String, value: Double)], windowed: [(day: String, value: Double)],
                                isAll: Bool, revision: Int, now: Date = Date()) async -> Insights {
        let values = windowed.map(\.value)
        let stat = ComparisonEngine.stat(values)
        let previous = MetricDetailInsights.previousWindow(series: series, windowed: windowed, isAll: isAll)
        let cmp = ComparisonEngine.compare(current: values, previous: previous.map(\.value))
        let hasDelta = cmp.current.n > 0 && cmp.previous.n > 0
        let all = await catalogSeries(reader: reader, revision: revision, now: now)
        let others = MetricCatalog.all
            .filter { !($0.key == catalogKey && $0.source == catalogSource) }
            .compactMap { descriptor -> (metric: MetricDescriptor, series: [(day: String, value: Double)])? in
                guard let s = all[descriptor.id], !s.isEmpty else { return nil }
                return (descriptor, s)
            }
        let rows = MetricDetailInsights.correlations(metricKey: catalogKey, windowed: windowed, others: others)
        return Insights(n: stat.n, mean: stat.n > 0 ? stat.mean : nil, min: stat.n > 0 ? stat.min : nil,
                        max: stat.n > 0 ? stat.max : nil, delta: hasDelta ? cmp.delta : nil,
                        pctChange: hasDelta ? cmp.pctChange : nil, direction: hasDelta ? cmp.direction : 0,
                        correlations: rows.map { Correlation(key: $0.key, source: $0.source, title: $0.title,
                                                             category: $0.category, r: $0.r, n: $0.n) })
    }

    /// `Repository.exploreAllSeries`: every catalog measure over the default Explore window.
    private static func catalogSeries(reader: StoreReader, revision: Int, now: Date) async
        -> [String: [(day: String, value: Double)]] {
        cacheLock.lock()
        if let cached = catalogCache, cached.revision == revision { cacheLock.unlock(); return cached.series }
        cacheLock.unlock()
        let from = StoreReader.localDayKey(now.addingTimeInterval(-4000 * 86_400))
        let to = StoreReader.localDayKey(now.addingTimeInterval(86_400))
        let days = await CoreRead.dailyRows(from: from, to: to, reader: reader)
        var byID: [String: [(day: String, value: Double)]] = [:]
        for descriptor in MetricCatalog.all {
            byID[descriptor.id] = await reader.exploreSeries(key: descriptor.key, source: descriptor.source,
                                                             from: from, to: to, dailyRows: days,
                                                             suppressedSleepWakeDays: [])
        }
        cacheLock.lock()
        catalogCache = (revision, byID)
        cacheLock.unlock()
        return byID
    }
}
