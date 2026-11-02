import Foundation

// CycleTrainingPattern.swift — does training feel harder in one part of THIS person's cycle?
//
// The research average says the cycle changes performance only slightly, with large differences between
// people (McNulty et al. 2020, Sports Medicine). So NOOP does not apply a rule; it compares the wearer's own
// sessions by phase: how hard they rated them (whole-session RPE, else the mean set RPE) and how much they
// lifted against their usual for that same workout. Pure, deterministic and DB-free. Phases come from the
// wearer's logged period starts and the temperature shift `CyclePhaseEngine` detected in each cycle; a cycle
// without a detected shift is left out rather than guessed.
//
// The thresholds below are a first, unvalidated heuristic (0.7 RPE points, 10 % volume). The result is advice
// wording only; it never changes a score.
public enum CycleTrainingPattern {

    public static let minCycles = 3
    public static let minSessionsPerPhase = 4
    public static let rpeThreshold = 0.7
    public static let volumeThreshold = 0.10
    /// A logged start further back than this does not anchor the following days.
    public static let maxCycleDays = 45

    public enum Phase: String, CaseIterable, Sendable { case period, follicular, luteal }

    /// One cycle: its logged start, the day its temperature rose (nil when none was detected) and how many
    /// days of period it had.
    public struct Cycle: Equatable, Sendable {
        public let start: String
        public let shift: String?
        public let periodDays: Int
        public init(start: String, shift: String?, periodDays: Int = 5) {
            self.start = start; self.shift = shift; self.periodDays = periodDays
        }
    }

    /// One training session. `rpe` is the whole-session rating when there is one, else the mean set RPE.
    /// `volumeKg` and `kind` (the routine or workout title) feed the volume comparison when both are known.
    public struct Session: Equatable, Sendable {
        public let day: String
        public let rpe: Double?
        public let volumeKg: Double?
        public let kind: String?
        public init(day: String, rpe: Double?, volumeKg: Double? = nil, kind: String? = nil) {
            self.day = day; self.rpe = rpe; self.volumeKg = volumeKg; self.kind = kind
        }
    }

    public struct PhaseStats: Equatable, Sendable {
        public let sessions: Int
        public let ratedSessions: Int
        public let meanRPE: Double?
        public let volumeSessions: Int
        /// Mean of each session's volume over the median of the same workout, so 0.9 is 10 % under usual.
        public let meanVolumeRatio: Double?
    }

    public enum Verdict: Equatable, Sendable {
        case learning
        /// Training felt harder or went lighter in this phase than in the follicular phase.
        case harder(rpeDelta: Double?, volumeDrop: Double?)
        case easier(rpeDelta: Double?, volumeDrop: Double?)
        case noDifference
    }

    public struct Result: Equatable, Sendable {
        public let cyclesUsed: Int
        public let stats: [Phase: PhaseStats]

        /// This phase against the follicular phase (the follicular phase against the luteal one).
        public func verdict(for phase: Phase) -> Verdict {
            let reference: Phase = phase == .follicular ? .luteal : .follicular
            guard cyclesUsed >= CycleTrainingPattern.minCycles,
                  let mine = stats[phase], let ref = stats[reference] else { return .learning }
            var rpeDelta: Double?
            if mine.ratedSessions >= minSessionsPerPhase, ref.ratedSessions >= minSessionsPerPhase,
               let a = mine.meanRPE, let b = ref.meanRPE { rpeDelta = a - b }
            var volumeDrop: Double?
            if mine.volumeSessions >= minSessionsPerPhase, ref.volumeSessions >= minSessionsPerPhase,
               let a = mine.meanVolumeRatio, let b = ref.meanVolumeRatio, b > 0 { volumeDrop = 1 - a / b }
            guard rpeDelta != nil || volumeDrop != nil else { return .learning }
            if (rpeDelta ?? 0) >= rpeThreshold || (volumeDrop ?? 0) >= volumeThreshold {
                return .harder(rpeDelta: rpeDelta, volumeDrop: volumeDrop)
            }
            if (rpeDelta ?? 0) <= -rpeThreshold || (volumeDrop ?? 0) <= -volumeThreshold {
                return .easier(rpeDelta: rpeDelta, volumeDrop: volumeDrop)
            }
            return .noDifference
        }

        /// How far the learning has come, for the "still learning" line.
        public var progress: (cycles: Int, rated: Int) {
            (cyclesUsed, min(stats[.luteal]?.ratedSessions ?? 0, stats[.follicular]?.ratedSessions ?? 0))
        }
    }

    // MARK: - Phase of a day

    /// The phase of `day`, or nil when it falls around the shift, outside any anchored cycle, or in a cycle
    /// without a detected shift (after its period days).
    public static func phase(of day: String, cycles: [Cycle]) -> Phase? {
        let sorted = cycles.sorted { $0.start < $1.start }
        guard let index = sorted.lastIndex(where: { $0.start <= day }) else { return nil }
        let cycle = sorted[index]
        guard let since = days(from: cycle.start, to: day), since < maxCycleDays else { return nil }
        if since < cycle.periodDays { return .period }
        guard let shift = cycle.shift, let toShift = days(from: day, to: shift) else { return nil }
        if toShift > 1 { return .follicular }
        if toShift < -1 { return .luteal }
        return nil
    }

    // MARK: - Analysis

    public static func analyse(sessions: [Session], cycles: [Cycle]) -> Result {
        // Each session's volume against the median of the same workout, where that workout recurs.
        var byKind: [String: [Double]] = [:]
        for s in sessions { if let k = s.kind, let v = s.volumeKg, v > 0 { byKind[k, default: []].append(v) } }
        let medians = byKind.compactMapValues { vs -> Double? in
            guard vs.count >= 3 else { return nil }
            let sorted = vs.sorted()
            return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }

        var rpes: [Phase: [Double]] = [:]
        var ratios: [Phase: [Double]] = [:]
        var counts: [Phase: Int] = [:]
        var cyclesWithData = Set<String>()
        for s in sessions {
            guard let p = phase(of: s.day, cycles: cycles) else { continue }
            counts[p, default: 0] += 1
            if let r = s.rpe { rpes[p, default: []].append(r) }
            if let k = s.kind, let v = s.volumeKg, v > 0, let m = medians[k], m > 0 { ratios[p, default: []].append(v / m) }
            if let c = cycles.filter({ $0.start <= s.day }).max(by: { $0.start < $1.start }), c.shift != nil {
                cyclesWithData.insert(c.start)
            }
        }
        func mean(_ xs: [Double]?) -> Double? {
            guard let xs, !xs.isEmpty else { return nil }
            return xs.reduce(0, +) / Double(xs.count)
        }
        var stats: [Phase: PhaseStats] = [:]
        for p in Phase.allCases {
            stats[p] = PhaseStats(sessions: counts[p] ?? 0, ratedSessions: rpes[p]?.count ?? 0, meanRPE: mean(rpes[p]),
                                  volumeSessions: ratios[p]?.count ?? 0, meanVolumeRatio: mean(ratios[p]))
        }
        return Result(cyclesUsed: cyclesWithData.count, stats: stats)
    }

    // MARK: - Day keys

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Whole days from `a` to `b` ("yyyy-MM-dd" keys).
    static func days(from a: String, to b: String) -> Int? {
        guard let x = date(a), let y = date(b) else { return nil }
        return utc.dateComponents([.day], from: x, to: y).day
    }
}
