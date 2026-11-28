import Foundation

// MARK: - New fitness markers, as Lab instruments only
//
// The cardio verdict has two kinds of evidence: fresh Apple Watch VO₂max, or beats per kilometre in the
// main sport. Walks detected without GPS carry neither (Training Load plan, §8.1, finding 5). These three
// instruments read what such walks do carry (Q19):
//
//   • PULSE AT THE SAME CADENCE. The strap counts steps about once a second, so each minute of a walk has a
//     cadence beside its heart rate. Comparing the pulse at one cadence across weeks is a submaximal test
//     with no distance needed. Weight loss lowers it too, because less mass is carried: that is everyday
//     fitness, and the screen names it so, never VO₂max.
//   • PULSE RECOVERY. How far the pulse falls in the minute after a session that ended hard
//     (`HeartRateRecovery`), a marker independent of the sport (Cole et al. 1999).
//   • PULSE AT THE SAME PACE. Kilometre splits of a NOOP GPS recording, flat ones only.
//
// None of them is evidence yet (Q35): each runs in the Lab until `InstrumentCheck.passes` holds for the
// owner and one tester, a rule fixed here before any real data was looked at.

/// Which way an instrument reads.
public enum InstrumentDirection: String, Sendable, Codable, Equatable {
    case improving, worsening, unclear, unknown
}

/// One instrument's reading over its window.
public struct InstrumentReading: Equatable, Sendable {
    public let direction: InstrumentDirection
    /// The change across the window in the instrument's own unit (bpm, or bpm fallen in a minute).
    public let change: Double?
    public let sessions: Int
    /// Weekly values, oldest first: the week's first day and the median of its sessions.
    public let weeks: [(start: String, value: Double)]

    public init(direction: InstrumentDirection, change: Double?, sessions: Int, weeks: [(start: String, value: Double)]) {
        self.direction = direction; self.change = change; self.sessions = sessions; self.weeks = weeks
    }

    public static func == (a: InstrumentReading, b: InstrumentReading) -> Bool {
        a.direction == b.direction && a.change == b.change && a.sessions == b.sessions
            && a.weeks.map(\.start) == b.weeks.map(\.start) && a.weeks.map(\.value) == b.weeks.map(\.value)
    }
}

public enum FitnessInstruments {
    /// The window every instrument reads, eight weeks as the VO₂max response.
    public static let windowDays = 56
    public static let minimumSessions = 4
    /// The smallest change across the window that counts as a direction.
    public static let minimumPulseChange = 3.0
    public static let minimumRecoveryChange = 3.0
    /// Cadence bins in strap step ticks a minute. Ticks are not calibrated steps, so the range is wide and the
    /// reference bin is simply the wearer's most common one: the comparison is with themselves.
    public static let cadenceBinWidth = 10
    public static let cadenceRange = 40...300
    /// Minutes a session needs in the reference bin.
    public static let minimumMinutesInBin = 5

    /// One minute of a walk: cadence in steps a minute, mean heart rate.
    public struct WalkMinute: Equatable, Sendable {
        public let cadence: Int
        public let bpm: Double
        public init(cadence: Int, bpm: Double) { self.cadence = cadence; self.bpm = bpm }
    }

    /// The pulse at the wearer's most common walking cadence, per session, as a weekly line. Lower is better.
    public static func pulseAtCadence(sessions: [(day: String, minutes: [WalkMinute])], weekStart: (String) -> String)
    -> InstrumentReading {
        func bin(_ c: Int) -> Int? {
            guard cadenceRange.contains(c) else { return nil }
            return (c - cadenceRange.lowerBound) / cadenceBinWidth
        }
        var binCounts: [Int: Int] = [:]
        for s in sessions { for m in s.minutes { if let b = bin(m.cadence) { binCounts[b, default: 0] += 1 } } }
        guard let reference = binCounts.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) })?.key else {
            return InstrumentReading(direction: .unknown, change: nil, sessions: 0, weeks: [])
        }
        var values: [(day: String, value: Double)] = []
        for s in sessions {
            let inBin = s.minutes.filter { bin($0.cadence) == reference }.map(\.bpm)
            guard inBin.count >= minimumMinutesInBin, let median = median(inBin) else { continue }
            values.append((s.day, median))
        }
        return reading(values, weekStart: weekStart, lowerIsBetter: true, minimumChange: minimumPulseChange)
    }

    /// The pulse fallen in the first minute after sessions that ended hard, as a weekly line. Higher is better.
    public static func pulseRecovery(sessions: [(day: String, dropAfterOneMinute: Double)], weekStart: (String) -> String)
    -> InstrumentReading {
        reading(sessions.map { ($0.day, $0.dropAfterOneMinute) }, weekStart: weekStart, lowerIsBetter: false,
                minimumChange: minimumRecoveryChange)
    }

    /// One kilometre split of a GPS recording.
    public struct Split: Equatable, Sendable {
        public let secondsPerKm: Double
        public let ascentM: Double
        public let bpm: Double
        public init(secondsPerKm: Double, ascentM: Double, bpm: Double) {
            self.secondsPerKm = secondsPerKm; self.ascentM = ascentM; self.bpm = bpm
        }
    }

    /// Splits within this of the reference pace count as the same pace.
    public static let paceToleranceSeconds = 30.0
    /// Splits climbing more than this are not flat.
    public static let flatAscentM = 10.0

    /// The pulse on flat splits at the wearer's most common pace, per session, as a weekly line. Lower is better.
    public static func pulseAtPace(sessions: [(day: String, splits: [Split])], weekStart: (String) -> String)
    -> InstrumentReading {
        let flat = sessions.flatMap { $0.splits.filter { $0.ascentM <= flatAscentM && $0.secondsPerKm > 0 } }
        guard let reference = median(flat.map(\.secondsPerKm)) else {
            return InstrumentReading(direction: .unknown, change: nil, sessions: 0, weeks: [])
        }
        var values: [(day: String, value: Double)] = []
        for s in sessions {
            let near = s.splits.filter {
                $0.ascentM <= flatAscentM && abs($0.secondsPerKm - reference) <= paceToleranceSeconds
            }.map(\.bpm)
            guard let m = median(near) else { continue }
            values.append((s.day, m))
        }
        return reading(values, weekStart: weekStart, lowerIsBetter: true, minimumChange: minimumPulseChange)
    }

    /// Weekly medians and a Theil–Sen line through the session values. A direction needs the middle half
    /// of the pairwise slopes on one side of zero and a change of at least `minimumChange` across the window.
    static func reading(_ values: [(day: String, value: Double)], weekStart: (String) -> String,
                        lowerIsBetter: Bool, minimumChange: Double) -> InstrumentReading {
        let sorted = values.sorted { $0.day < $1.day }
        var byWeek: [String: [Double]] = [:]
        for v in sorted { byWeek[weekStart(v.day), default: []].append(v.value) }
        let weeks = byWeek.keys.sorted().compactMap { k in median(byWeek[k]!).map { (start: k, value: $0) } }
        guard sorted.count >= minimumSessions, let first = sorted.first, let last = sorted.last,
              let firstDay = dayNumber(first.day), let lastDay = dayNumber(last.day), lastDay > firstDay else {
            return InstrumentReading(direction: .unknown, change: nil, sessions: sorted.count, weeks: weeks)
        }
        var slopes: [Double] = []
        for i in 0..<sorted.count {
            for j in (i + 1)..<sorted.count {
                guard let a = dayNumber(sorted[i].day), let b = dayNumber(sorted[j].day), b > a else { continue }
                slopes.append((sorted[j].value - sorted[i].value) / Double(b - a))
            }
        }
        slopes.sort()
        guard !slopes.isEmpty else {
            return InstrumentReading(direction: .unknown, change: nil, sessions: sorted.count, weeks: weeks)
        }
        let slope = slopes[slopes.count / 2]
        let q1 = slopes[slopes.count / 4], q3 = slopes[(3 * slopes.count) / 4]
        let change = slope * Double(lastDay - firstDay)
        let agrees = q1 > 0 || q3 < 0
        let direction: InstrumentDirection
        if !agrees || abs(change) < minimumChange {
            direction = .unclear
        } else {
            let better = lowerIsBetter ? change < 0 : change > 0
            direction = better ? .improving : .worsening
        }
        return InstrumentReading(direction: direction, change: change, sessions: sorted.count, weeks: weeks)
    }

    public static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Days since 1970-01-01 for a `yyyy-MM-dd` key, nil when it is not one.
    public static func dayNumber(_ day: String) -> Int? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        // Days since a fixed epoch, enough to order and space keys (Howard Hinnant's days_from_civil).
        let y = p[1] <= 2 ? p[0] - 1 : p[0]
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let m = p[1], d = p[2]
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe
    }
}

/// The check an instrument must pass before the verdict may read it (Q35), fixed before any real data.
public enum InstrumentCheck {
    /// Week-on-week comparisons needed.
    public static let minimumPairs = 8
    /// Share of those comparisons that must point the same way as the independent reference.
    public static let minimumAgreement = 0.70

    public struct Result: Equatable, Sendable {
        public let pairs: Int
        public let agreeing: Int
        public var agreement: Double { pairs > 0 ? Double(agreeing) / Double(pairs) : 0 }
        public var passes: Bool { pairs >= InstrumentCheck.minimumPairs && agreement >= InstrumentCheck.minimumAgreement }
    }

    /// Compares the week-on-week moves of an instrument with those of an independent marker over the weeks
    /// both have. Both lines are oriented so that up means fitter (`higherIsBetter`). A week with no move in
    /// either line is left out: it says nothing about direction.
    public static func compare(instrument: [(start: String, value: Double)], instrumentHigherIsBetter: Bool,
                               reference: [(start: String, value: Double)], referenceHigherIsBetter: Bool) -> Result {
        let a = Dictionary(instrument.map { ($0.start, $0.value) }, uniquingKeysWith: { x, _ in x })
        let b = Dictionary(reference.map { ($0.start, $0.value) }, uniquingKeysWith: { x, _ in x })
        let weeks = Set(a.keys).intersection(b.keys).sorted()
        var pairs = 0, agreeing = 0
        for (w0, w1) in zip(weeks, weeks.dropFirst()) {
            let da = (a[w1]! - a[w0]!) * (instrumentHigherIsBetter ? 1 : -1)
            let db = (b[w1]! - b[w0]!) * (referenceHigherIsBetter ? 1 : -1)
            guard da != 0, db != 0 else { continue }
            pairs += 1
            if (da > 0) == (db > 0) { agreeing += 1 }
        }
        return Result(pairs: pairs, agreeing: agreeing)
    }
}
