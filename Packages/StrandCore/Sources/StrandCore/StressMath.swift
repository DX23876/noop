import Foundation
import StrandAnalytics
import WhoopStore

// Moved from `Strand/Screens/StressView.swift` and `IntelligenceEngine` (Android plan B3 step 2). The app
// keeps the localised `explanation(band:…)` as an extension next to the Stress screen.

public enum StressMath {
    /// The first night each baseline still counts after a manual "Recalibrate baseline": HRV on its own
    /// epoch, resting HR on the recovery epoch, as Charge folds them. nil = every night counts.
    public struct Cut: Equatable, Sendable {
        public var hrvFirstNight: String?
        public var rhrFirstNight: String?

        public init(hrvFirstNight: String? = nil, rhrFirstNight: String? = nil) {
            self.hrvFirstNight = hrvFirstNight
            self.rhrFirstNight = rhrFirstNight
        }

        public static let none = Cut()

        /// The cut for the two recalibration epochs (epoch seconds, 0 when never recalibrated).
        public init(hrvBaselineEpoch: Double, recoveryBaselineEpoch: Double) {
            self.init(hrvFirstNight: Baselines.firstNightAfterRecalibration(epoch: hrvBaselineEpoch),
                      rhrFirstNight: Baselines.firstNightAfterRecalibration(epoch: recoveryBaselineEpoch))
        }

        public static func current(_ defaults: UserDefaults = .standard) -> Cut {
            Cut(hrvBaselineEpoch: Baselines.hrvBaselineEpoch(defaults),
                recoveryBaselineEpoch: Baselines.recoveryBaselineEpoch(defaults))
        }
    }

    public struct Reference: Equatable, Sendable {
        public let meanRHR: Double?
        public let sdRHR: Double
        public let meanHRV: Double?
        public let sdHRV: Double
    }

    /// What `days[index]` is read against: up to the 30 rows before it, keeping only the nights after a
    /// recalibration. Shared by the live Stress screen and the stored series, so a chart and the screen
    /// cannot disagree. Before the cut, the window kept the nights before a reset, so a recalibrated
    /// HRV baseline of 78 ms still read a night of 82 ms as "HRV is down". A day before the reset keeps
    /// its own past: the cut applies only from the first night it counts.
    public static func reference(before index: Int, in days: [DailyMetric], cut: Cut) -> Reference {
        let window = index > 0 ? days[0..<index].suffix(30) : []
        let scored = index < days.count ? days[index].day : nil
        func counts(_ day: DailyMetric, from first: String?) -> Bool {
            guard let first, let scored, scored >= first else { return true }
            return day.day >= first
        }
        let rhrBase = window.filter { counts($0, from: cut.rhrFirstNight) }
            .compactMap { $0.restingHr }.map(Double.init)
        let hrvBase = window.filter { counts($0, from: cut.hrvFirstNight) }
            .compactMap { $0.avgHrv }
        let meanRHR = mean(rhrBase)
        let meanHRV = mean(hrvBase)
        return Reference(meanRHR: meanRHR, sdRHR: std(rhrBase, mean: meanRHR),
                         meanHRV: meanHRV, sdHRV: std(hrvBase, mean: meanHRV))
    }

    public static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Population standard deviation; 0 when there's no spread.
    public static func std(_ xs: [Double], mean m: Double?) -> Double {
        guard let m, xs.count > 1 else { return 0 }
        let v = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)
        return v.squareRoot()
    }

    /// Combined autonomic z-score. RHR-up and HRV-down both push it positive.
    public static func rawScore(
        rhrToday: Double?, meanRHR: Double?, sdRHR: Double,
        hrvToday: Double?, meanHRV: Double?, sdHRV: Double
    ) -> Double {
        var sum = 0.0
        if let r = rhrToday, let m = meanRHR, sdRHR > 0.0001 {
            sum += (r - m) / sdRHR            // up = stress
        }
        if let h = hrvToday, let m = meanHRV, sdHRV > 0.0001 {
            sum += (m - h) / sdHRV            // down = stress
        }
        return sum
    }

    /// Logistic squash of the raw z-sum onto 0–3 (baseline 0 → 1.5).
    public static func squash(_ raw: Double) -> Double {
        let s = 3.0 / (1.0 + exp(-raw))
        return min(max(s, 0), 3)
    }

    /// Daily 0–3 stress-proxy points (#R-stress-chart) — the SAME z-score formula `StressView` derives
    /// live when nothing is stored for a day (`rawScore`/`squash` over a rolling RHR/HRV
    /// baseline), computed here so it can be PERSISTED and therefore charted (`plot_metric`'s generic
    /// day-series lookup only finds keys that are actually in the store — "stress" never was). `days` must
    /// be oldest→newest; the baseline for each day is up to the 30 days ending the day BEFORE it, the exact
    /// window `StressModel.init` uses, so a plotted chart and the live Stress screen never disagree. A day
    /// with neither a resting HR nor an HRV reading (and no baseline to fall back on either) is skipped —
    /// no fabricated value.
    public static func proxyRows(days: [DailyMetric], cut: Cut) -> [MetricPoint] {
        var rows: [MetricPoint] = []
        for (idx, today) in days.enumerated() {
            let reference = reference(before: idx, in: days, cut: cut)
            let meanRHR = reference.meanRHR
            let sdRHR = reference.sdRHR
            let meanHRV = reference.meanHRV
            let sdHRV = reference.sdHRV
            let rhrToday = today.restingHr.map(Double.init)
            let hrvToday = today.avgHrv
            guard (rhrToday != nil && meanRHR != nil) || (hrvToday != nil && meanHRV != nil) else { continue }
            let raw = rawScore(rhrToday: rhrToday, meanRHR: meanRHR, sdRHR: sdRHR,
                               hrvToday: hrvToday, meanHRV: meanHRV, sdHRV: sdHRV)
            rows.append(MetricPoint(day: today.day, key: "stress", value: squash(raw)))
        }
        return rows
    }

    /// Every one of NOOP's own stress rows over `days`, read again: the analysis rebuild (AI-31 and later).
    ///
    /// `days` is the whole merged daily history, oldest first, so each day reads its full 30-row reference.
    /// Days in `importedDays` carry a stress value from a WHOOP export and are left as they are. Every other
    /// day takes the current reading when it differs from `existing`, or loses its row when the current rule
    /// cannot score it.
    public static func proxyRebuild(days: [DailyMetric], cut: Cut,
                                    existing: [String: Double], importedDays: Set<String>)
        -> (upserts: [MetricPoint], deletions: [String]) {
        let fresh = Dictionary(proxyRows(days: days, cut: cut).map { ($0.day, $0) },
                               uniquingKeysWith: { _, b in b })
        var upserts: [MetricPoint] = []
        var deletions: [String] = []
        for day in days.map(\.day) where !importedDays.contains(day) {
            let stored = existing[day]
            if let row = fresh[day] {
                if stored.map({ abs($0 - row.value) > 1e-9 }) ?? true { upserts.append(row) }
            } else if stored != nil {
                deletions.append(day)
            }
        }
        return (upserts, deletions)
    }

    /// The stored stress rows a recalibration made stale, and what replaces them.
    ///
    /// `proxyRows` reads each day against the nights after a manual "Recalibrate baseline", but a
    /// row is gap-filled and never overwritten, so a day written before the cut (or before this rule)
    /// kept its old reading. The days whose 30-row window reaches back across the first counted night
    /// are recomputed: from that night up to 30 rows past the later of the two cuts. Rows outside that
    /// interval read the same either way and stay untouched.
    ///
    /// Only NOOP's own proxy rows change. An imported WHOOP export writes a stress value together with
    /// its daily row under the same source, so every day in `importedDays` is left as it is. A day the
    /// new rule cannot score (no counted night before it yet) loses its stale row instead of keeping it.
    /// `days` must start on or before the first counted night, or the window would miss counted nights;
    /// otherwise nothing is repaired.
    public static func proxyRepairs(days: [DailyMetric], cut: Cut,
                                    existing: [String: Double], importedDays: Set<String>)
        -> (upserts: [MetricPoint], deletions: [String]) {
        let cuts = [cut.hrvFirstNight, cut.rhrFirstNight].compactMap { $0 }
        guard let earliest = cuts.min(), let latest = cuts.max(),
              let firstDay = days.first?.day, firstDay <= earliest,
              let start = days.firstIndex(where: { $0.day >= earliest }) else { return ([], []) }
        let lastCut = days.firstIndex(where: { $0.day >= latest }) ?? days.count
        let end = min(days.count, lastCut + 30)
        guard start < end else { return ([], []) }
        let fresh = Dictionary(proxyRows(days: days, cut: cut).map { ($0.day, $0) },
                               uniquingKeysWith: { _, b in b })
        var upserts: [MetricPoint] = []
        var deletions: [String] = []
        for day in days[start..<end].map(\.day) where !importedDays.contains(day) {
            let stored = existing[day]
            if let row = fresh[day] {
                if stored.map({ abs($0 - row.value) > 1e-9 }) ?? true { upserts.append(row) }
            } else if stored != nil {
                deletions.append(day)
            }
        }
        return (upserts, deletions)
    }
}
