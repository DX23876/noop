import Foundation

/// The statistics behind every analysis. Deterministic: the bootstrap draws from a generator seeded by the
/// spec, so the same question over the same data gives the same answer every time.
public enum AnalysisStatistics {

    public static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    public static func median(_ xs: [Double]) -> Double? {
        quantile(xs, 0.5)
    }

    /// Linear-interpolated quantile (type 7, the R / NumPy default).
    public static func quantile(_ xs: [Double], _ q: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let sorted = xs.sorted()
        let h = Double(sorted.count - 1) * min(max(q, 0), 1)
        let lo = Int(h.rounded(.down))
        let hi = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (h - Double(lo)) * (sorted[hi] - sorted[lo])
    }

    /// Sample standard deviation (n − 1).
    public static func standardDeviation(_ xs: [Double]) -> Double? {
        guard xs.count >= 2, let m = mean(xs) else { return nil }
        let ss = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (ss / Double(xs.count - 1)).squareRoot()
    }

    /// Ordinary least-squares slope of y on x.
    public static func olsSlope(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 2, let mx = mean(x), let my = mean(y) else { return nil }
        var sxy = 0.0, sxx = 0.0
        for i in x.indices {
            sxy += (x[i] - mx) * (y[i] - my)
            sxx += (x[i] - mx) * (x[i] - mx)
        }
        return sxx > 0 ? sxy / sxx : nil
    }

    public static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 3, let mx = mean(x), let my = mean(y) else { return nil }
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in x.indices {
            sxy += (x[i] - mx) * (y[i] - my)
            sxx += (x[i] - mx) * (x[i] - mx)
            syy += (y[i] - my) * (y[i] - my)
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    /// Spearman's rank correlation: Pearson on average ranks, so ties are handled and one extreme night
    /// cannot carry the result.
    public static func spearman(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 3 else { return nil }
        return pearson(ranks(x), ranks(y))
    }

    static func ranks(_ xs: [Double]) -> [Double] {
        let order = xs.indices.sorted { xs[$0] < xs[$1] }
        var ranks = [Double](repeating: 0, count: xs.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count && xs[order[j + 1]] == xs[order[i]] { j += 1 }
            let average = Double(i + j) / 2 + 1
            for k in i...j { ranks[order[k]] = average }
            i = j + 1
        }
        return ranks
    }

    /// Hedges' g: the standardised mean difference a − b with the small-sample correction.
    public static func hedgesG(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count >= 2, b.count >= 2, let ma = mean(a), let mb = mean(b),
              let sa = standardDeviation(a), let sb = standardDeviation(b) else { return nil }
        let na = Double(a.count), nb = Double(b.count)
        let pooled = (((na - 1) * sa * sa + (nb - 1) * sb * sb) / (na + nb - 2)).squareRoot()
        guard pooled > 0 else { return nil }
        let correction = 1 - 3 / (4 * (na + nb) - 9)
        return (ma - mb) / pooled * correction
    }

    // MARK: - Block bootstrap

    /// Result of resampling a statistic.
    public struct Bootstrap: Equatable, Sendable {
        public let estimate: Double
        public let lower: Double
        public let upper: Double
        /// Two-sided: twice the smaller share of resamples on either side of zero.
        public let p: Double
    }

    /// Default resample count: enough for a stable 95 % interval and a p-value resolution of 0.001.
    public static let defaultResamples = 2_000

    /// Circular block bootstrap over `n` items in time order. Consecutive days are not independent — a
    /// good week of sleep is a run, not seven coin flips — so resampling single days would make intervals
    /// too narrow and differences look surer than they are. Blocks of about n^(1/3) days keep that run
    /// structure. `statistic` receives the resampled item indices and may return nil for a degenerate
    /// resample, which is then skipped.
    public static func blockBootstrap(count n: Int, seed: UInt64, resamples: Int = defaultResamples,
                                      estimate: Double,
                                      statistic: ([Int]) -> Double?) -> Bootstrap? {
        guard n >= 2 else { return nil }
        let block = max(2, Int((pow(Double(n), 1.0 / 3.0)).rounded()))
        var rng = SplitMix64(seed: seed)
        var draws: [Double] = []
        draws.reserveCapacity(resamples)
        var indices = [Int]()
        indices.reserveCapacity(n + block)
        for _ in 0..<resamples {
            indices.removeAll(keepingCapacity: true)
            while indices.count < n {
                let start = Int(rng.next() % UInt64(n))
                for k in 0..<block where indices.count < n { indices.append((start + k) % n) }
            }
            if let value = statistic(indices), value.isFinite { draws.append(value) }
        }
        guard draws.count >= resamples / 2 else { return nil }
        draws.sort()
        let lower = quantileSorted(draws, 0.025)
        let upper = quantileSorted(draws, 0.975)
        let below = Double(draws.filter { $0 <= 0 }.count) / Double(draws.count)
        let above = Double(draws.filter { $0 >= 0 }.count) / Double(draws.count)
        let p = min(1, max(2 * min(below, above), 1 / Double(draws.count + 1)))
        return Bootstrap(estimate: estimate, lower: lower, upper: upper, p: p)
    }

    private static func quantileSorted(_ sorted: [Double], _ q: Double) -> Double {
        let h = Double(sorted.count - 1) * q
        let lo = Int(h.rounded(.down))
        let hi = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (h - Double(lo)) * (sorted[hi] - sorted[lo])
    }

    // MARK: - Multiple testing

    /// Benjamini–Hochberg adjusted p-values (q-values), in the input order.
    public static func benjaminiHochberg(_ ps: [Double]) -> [Double] {
        let m = ps.count
        guard m > 0 else { return [] }
        let order = ps.indices.sorted { ps[$0] < ps[$1] }
        var q = [Double](repeating: 1, count: m)
        var running = 1.0
        for rank in stride(from: m, through: 1, by: -1) {
            let i = order[rank - 1]
            running = min(running, ps[i] * Double(m) / Double(rank))
            q[i] = min(1, running)
        }
        return q
    }

    // MARK: - Seeding

    /// FNV-1a over UTF-8, the platform-neutral hash the project uses wherever a value must not depend on
    /// the process (Swift's `hashValue` is randomised per launch).
    public static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

/// SplitMix64 — a small, fast, well-distributed generator with a 64-bit seed.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
