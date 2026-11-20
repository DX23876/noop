import Foundation

// ActivityCandidates.swift — the two tracks that find "something happened" (plan building blocks 5 and 6).
//
// Both work on minutes, never on the raw seconds, and both are suggestions only: nothing here writes a
// workout or feeds a score (fork decision 2026-10-31).
//
// - The WALK track reads the strap's own walking/running class and the step counter (WHOOP 5.0/MG; a 4.0
//   has neither, so the track finds nothing there and its features are masked, never read as zero). A
//   minute counts when the strap called most of it walking or running and the counter rose by at least
//   `walkMinuteSteps`, which is a stroll, not a brisk pace.
// - The HEART-RATE track is the general "activity detected": heart rate above the wearer's OWN everyday
//   level (the 75th percentile of their awake heart-rate reserve over the two weeks before, plus
//   `everydayMarginHRR`), so one fixed threshold does not fit everyone. A span must also carry a minimum
//   training load (Edwards' zone minutes) before it is asked about, which keeps housework and errands out.
//
// A walk is a run of walking minutes from its first to its last, ended by more than `walkStopMinutes` of
// standing still, so a red light is not the end of a walk and a tram ride is not part of one. It is offered
// when it holds `minimumWalkMinutes` walking minutes and `walkDensity` of its length was walked; a thinner
// run is cut at its longest stop and both halves are judged again, so errands with a lot of standing never
// become one long span. Start, end and duration therefore say the same thing: there is no span whose length
// outruns the walking in it (measured 2026-11-20, see docs/fork/decisions.md).
// Heart-rate pieces are built the GGIR way (short gaps as long as at least `boutShare` qualifies), joined
// first (a strength session is sets with rests) and measured after, with the walks cut out of them. There is
// no "mixed way": a way with a stop in the middle is two walks, and what is left of the heart-rate span is
// held to its own length and load like any other. Pure: no I/O, no clock, unix seconds.
public enum ActivityCandidates {

    /// Bumped whenever a threshold or rule below changes, so stored suggestions and answers can be told apart.
    public static let ruleVersion = "activity-v3"

    /// Length a HEART-RATE span must reach. Walks are held to `minimumWalkMinutes` of walking instead.
    public static let minimumMinutes = 15
    public static let boutShare = 0.8
    /// Longest run of non-qualifying minutes inside a span.
    public static let maxGapMinutes = 2
    /// Steps in a minute the strap calls walking for it to count as walked. A stroll: the measurement of
    /// 2026-11-20 found the missed walks were ten to twenty minutes at 40 to 79 steps a minute, which a
    /// brisk-pace floor threw away.
    public static let walkMinuteSteps = 40
    /// Longest stretch of standing still inside a walk. A two-minute light touches up to three clock
    /// minutes, plus the slowing down and getting going around it.
    public static let walkStopMinutes = 5
    /// Walking minutes a walk must hold before it is offered. Below this it is pottering about, which is in
    /// the day's step count and does not need a card.
    public static let minimumWalkMinutes = 10
    /// Share of a walk's length that must be walked, so its duration never outruns the walking in it.
    public static let walkDensity = 0.6
    /// Share of a span's minutes with a class that must be walked for it to be offered as a walk first.
    public static let walkingKindShare = 0.5
    public static let everydayMarginHRR = 0.12
    public static let everydayQuantile = 0.75
    /// Without enough history, the heart-rate track uses this fixed reserve instead of the everyday level.
    public static let fallbackThresholdHRR = 0.35
    /// Awake minutes of history needed before the everyday level is trusted (about three worn days).
    public static let minimumHistoryMinutes = 3 * 600
    /// Heart-rate pieces closer than this are one span (a set break, a red light).
    public static let joinGapMinutes = 10
    /// A heart-rate piece shorter than this does not take part in joining (a flight of stairs).
    public static let minimumPieceMinutes = 3
    /// Share of a joined span that must be above the bar or fully walked, so joining cannot chain a whole
    /// busy afternoon into one span.
    public static let joinedShare = 0.5

    /// The three "how often to ask" levels as a minimum Edwards load for a heart-rate span. Walks are not
    /// held to it: the walk track is already specific.
    public enum Level: String, CaseIterable, Sendable {
        case more, balanced, onlyClear
        public var minimumLoad: Double {
            switch self {
            case .more: return 60
            case .balanced: return 90
            case .onlyClear: return 130
            }
        }
    }

    public struct Minute: Equatable, Sendable {
        public let ts: Int
        /// Mean bpm, nil when the minute has too few heart-rate seconds to mean anything.
        public let bpm: Double?
        /// nil when the strap reports no step stream at all (WHOOP 4.0), so absence is not read as stillness.
        public let steps: Int?
        public let walkSeconds: Int?
        public let runSeconds: Int?
        public let classSeconds: Int?
        public let asleep: Bool

        public init(ts: Int, bpm: Double?, steps: Int?, walkSeconds: Int?, runSeconds: Int?,
                    classSeconds: Int?, asleep: Bool) {
            self.ts = ts
            self.bpm = bpm
            self.steps = steps
            self.walkSeconds = walkSeconds
            self.runSeconds = runSeconds
            self.classSeconds = classSeconds
            self.asleep = asleep
        }
    }

    public enum Track: String, CaseIterable, Sendable {
        case walk, heartRate
    }

    public struct Candidate: Equatable, Sendable {
        public let track: Track
        public let start: Int
        public let end: Int
        public let avgBpm: Int?
        public let peakBpm: Int?
        /// Edwards' zone minutes over the span.
        public let load: Double
        /// Median steps per minute over the span's minutes with a step reading; nil without a step stream.
        public let cadence: Int?
        /// Share of the span's classified seconds the strap called walking or running; nil without a class.
        public let locomotionShare: Double?
        /// The most likely kinds, best first. A walk-track span carries one; a heart-rate span three.
        public let kinds: [ActivityDetectionScore.Kind]

        public var durationMinutes: Int { (end - start) / 60 }

        public init(track: Track, start: Int, end: Int, avgBpm: Int?, peakBpm: Int?, load: Double,
                    cadence: Int?, locomotionShare: Double?, kinds: [ActivityDetectionScore.Kind]) {
            self.track = track
            self.start = start
            self.end = end
            self.avgBpm = avgBpm
            self.peakBpm = peakBpm
            self.load = load
            self.cadence = cadence
            self.locomotionShare = locomotionShare
            self.kinds = kinds
        }

        /// Whether a span is asked about at `level`. Walks always are: the walk track is already specific.
        /// A heart-rate span is when it carries enough load. A way with a stop in it is two walks on the
        /// walk track, so nothing here needs a share of walking to be asked about.
        public func asks(at level: Level) -> Bool {
            track == .walk || load >= level.minimumLoad
        }
    }

    // MARK: - Walk track

    /// A minute that counts as walked: the strap classified at least half of it, called at least half of it
    /// walking or running, and the counter rose by at least `walkMinuteSteps`. A stroll counts.
    static func isWalkMinute(_ m: Minute) -> Bool {
        guard !m.asleep, let steps = m.steps, let classed = m.classSeconds, classed >= 30 else { return false }
        return (m.walkSeconds ?? 0) + (m.runSeconds ?? 0) >= 30 && steps >= walkMinuteSteps
    }

    /// Index ranges of walks: each a run of walked minutes from its first to its last, cut wherever more
    /// than `walkStopMinutes` of standing still lie between two of them. A hole in the data counts as
    /// standing still, so a stretch the strap never delivered does not join two walks into one.
    static func walkSpans(_ minutes: [Minute]) -> [ClosedRange<Int>] {
        var runs: [[Int]] = []
        var current: [Int] = []
        for (i, m) in minutes.enumerated() where isWalkMinute(m) {
            if let last = current.last, (m.ts - minutes[last].ts) / 60 - 1 > walkStopMinutes {
                runs.append(current)
                current = []
            }
            current.append(i)
        }
        if !current.isEmpty { runs.append(current) }
        return runs.flatMap { offered($0, in: minutes) }
    }

    /// `run` kept as one walk when it holds `minimumWalkMinutes` walked minutes and `walkDensity` of its
    /// length was walked. A thinner run is cut at its longest stop and both halves are judged again, so
    /// errands with a lot of standing fall apart into the walks inside them, or into nothing.
    static func offered(_ run: [Int], in minutes: [Minute]) -> [ClosedRange<Int>] {
        guard run.count >= minimumWalkMinutes, let first = run.first, let last = run.last else { return [] }
        let length = (minutes[last].ts - minutes[first].ts) / 60 + 1
        if Double(run.count) / Double(length) >= walkDensity { return [first ... last] }
        var cut = 0, longest = 0
        for i in 1 ..< run.count {
            let stop = (minutes[run[i]].ts - minutes[run[i - 1]].ts) / 60 - 1
            if stop > longest { longest = stop; cut = i }
        }
        guard longest > 0 else { return [] }
        return offered(Array(run[..<cut]), in: minutes) + offered(Array(run[cut...]), in: minutes)
    }

    public static func walkCandidates(_ minutes: [Minute], hrMax: Int) -> [Candidate] {
        walkSpans(minutes).map { range in
            let span = Array(minutes[range])
            let walk = span.reduce(0) { $0 + ($1.walkSeconds ?? 0) }
            let run = span.reduce(0) { $0 + ($1.runSeconds ?? 0) }
            return candidate(.walk, span, hrMax: hrMax, kinds: [run > walk ? .run : .walk])
        }
    }

    // MARK: - Heart-rate track

    public static func heartRateReserve(_ bpm: Double, restingHR: Int, hrMax: Int) -> Double? {
        let reserve = Double(hrMax - restingHR)
        return reserve > 0 ? (bpm - Double(restingHR)) / reserve : nil
    }

    /// The wearer's everyday level: the `everydayQuantile` of awake heart-rate reserve over `history`, the
    /// minutes BEFORE the day being scanned (never the day itself, so a long workout cannot raise its own
    /// bar). nil until `minimumHistoryMinutes` awake minutes exist.
    public static func everydayHRR(history: [Minute], restingHR: Int, hrMax: Int) -> Double? {
        let values = history.compactMap { m -> Double? in
            guard !m.asleep, let bpm = m.bpm else { return nil }
            return heartRateReserve(bpm, restingHR: restingHR, hrMax: hrMax)
        }.sorted()
        guard values.count >= minimumHistoryMinutes else { return nil }
        let index = min(values.count - 1, Int((Double(values.count - 1) * everydayQuantile).rounded()))
        return values[index]
    }

    public static func heartRateThreshold(everydayHRR: Double?) -> Double {
        everydayHRR.map { $0 + everydayMarginHRR } ?? fallbackThresholdHRR
    }

    /// Pieces above the bar are joined first and measured after: a strength session is sets of a few
    /// minutes with rests between them, so no single piece lasts `minimumMinutes`. `walks` are cut out of
    /// the result (the way to the gym and back is a walk of its own, and left in it would stretch the span
    /// past the session it belongs to).
    public static func heartRateCandidates(_ minutes: [Minute], restingHR: Int, hrMax: Int,
                                           everydayHRR: Double?, walks: [Candidate] = []) -> [Candidate] {
        let threshold = heartRateThreshold(everydayHRR: everydayHRR)
        let above: (Minute) -> Bool = { m in
            guard !m.asleep, let bpm = m.bpm,
                  let hrr = heartRateReserve(bpm, restingHR: restingHR, hrMax: hrMax) else { return false }
            return hrr >= threshold
        }
        let pieces = bouts(minutes, minimum: minimumPieceMinutes, qualifies: above)
        var joined: [ClosedRange<Int>] = []
        for r in pieces {
            if let last = joined.last, minutes[r.lowerBound].ts - minutes[last.upperBound].ts <= joinGapMinutes * 60 {
                joined[joined.count - 1] = last.lowerBound ... r.upperBound
            } else {
                joined.append(r)
            }
        }
        let walkSpans = walks.map { (start: $0.start, end: $0.end) }
        var out: [Candidate] = []
        for range in joined {
            // Cut the walks out, then hold every remaining piece to the length and the share.
            var piece: [Minute] = []
            func close() {
                defer { piece.removeAll() }
                while let last = piece.last, !above(last) { piece.removeLast() }
                while let first = piece.first, !above(first) { piece.removeFirst() }
                guard let first = piece.first, let last = piece.last else { return }
                let length = (last.ts - first.ts) / 60 + 1
                guard length >= minimumMinutes,
                      Double(piece.filter(above).count) / Double(length) >= joinedShare else { return }
                out.append(candidate(.heartRate, piece, hrMax: hrMax, kinds: likelyKinds(piece)))
            }
            for m in minutes[range] {
                if walkSpans.contains(where: { m.ts >= $0.start && m.ts < $0.end }) { close() } else { piece.append(m) }
            }
            close()
        }
        return out
    }

    /// The three kinds to offer first for a heart-rate span, from how the wrist moved during it. Counted in
    /// MINUTES walked out of the minutes the strap classified, never in seconds: a weak signal of ten to
    /// twenty-five walking seconds a minute adds up to a share that looks like walking with no walked minute
    /// in it, which is how a tram ride came to be labelled a walk (measured 2026-11-20).
    static func likelyKinds(_ span: [Minute]) -> [ActivityDetectionScore.Kind] {
        let classified = span.filter { ($0.classSeconds ?? 0) >= 30 }
        guard !classified.isEmpty else { return [.strength, .cycle, .other] }   // no step stream: nothing to tell
        let walked = classified.filter(isWalkMinute)
        guard Double(walked.count) / Double(classified.count) >= walkingKindShare else {
            return [.strength, .cycle, .other]
        }
        let walk = walked.reduce(0) { $0 + ($1.walkSeconds ?? 0) }
        let run = walked.reduce(0) { $0 + ($1.runSeconds ?? 0) }
        return run > walk ? [.run, .walk, .other] : [.walk, .strength, .other]
    }

    // MARK: - Both tracks

    /// Walk spans plus the heart-rate spans with the walks cut out; a heart-rate span still overlapping a
    /// walk span at the bench's match overlap is dropped, so one stretch is never asked about twice.
    public static func candidates(_ minutes: [Minute], restingHR: Int, hrMax: Int,
                                  everydayHRR: Double?) -> [Candidate] {
        let walks = walkCandidates(minutes, hrMax: hrMax)
        let hr = heartRateCandidates(minutes, restingHR: restingHR, hrMax: hrMax, everydayHRR: everydayHRR,
                                     walks: walks)
            .filter { h in
                !walks.contains {
                    ActivityDetectionScore.iou(.init(start: h.start, end: h.end), .init(start: $0.start, end: $0.end))
                        >= ActivityDetectionScore.minimumIoU
                }
            }
        return (walks + hr).sorted { ($0.start, $0.track.rawValue) < ($1.start, $1.track.rawValue) }
    }

    /// Edwards' zone minutes: each minute weighs 1 to 5 for 50, 60, 70, 80 and 90 % of maximum heart rate.
    public static func edwardsLoad(_ minutes: [Minute], hrMax: Int) -> Double {
        guard hrMax > 0 else { return 0 }
        return minutes.reduce(0.0) { sum, m in
            guard let bpm = m.bpm else { return sum }
            let pct = bpm / Double(hrMax)
            let zone = pct >= 0.9 ? 5 : pct >= 0.8 ? 4 : pct >= 0.7 ? 3 : pct >= 0.6 ? 2 : pct >= 0.5 ? 1 : 0
            return sum + Double(zone)
        }
    }

    // MARK: - Building blocks

    /// Index ranges of spans: start at a qualifying minute, extend over qualifying minutes and gaps of at
    /// most `maxGapMinutes` while the share stays at least `boutShare`, end on a qualifying minute, keep spans
    /// of at least `minimum` minutes. Minutes must be ascending; a hole in the data longer than the gap
    /// allowance ends a span.
    static func bouts(_ minutes: [Minute], minimum: Int = minimumMinutes,
                      qualifies: (Minute) -> Bool) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        var i = 0
        while i < minutes.count {
            guard qualifies(minutes[i]) else { i += 1; continue }
            var lastGood = i, good = 1, gap = 0, j = i + 1
            while j < minutes.count {
                if minutes[j].ts - minutes[j - 1].ts > 60 * (maxGapMinutes + 1) { break }
                if qualifies(minutes[j]) {
                    good += 1
                    lastGood = j
                    gap = 0
                } else {
                    gap += 1
                    if gap > maxGapMinutes { break }
                }
                let length = (minutes[j].ts - minutes[i].ts) / 60 + 1
                if Double(good) / Double(length) < boutShare, gap > 0 { break }
                j += 1
            }
            if (minutes[lastGood].ts - minutes[i].ts) / 60 + 1 >= minimum { out.append(i ... lastGood) }
            i = lastGood + 1
        }
        return out
    }

    static func candidate(_ track: Track, _ span: [Minute], hrMax: Int,
                          kinds: [ActivityDetectionScore.Kind]) -> Candidate {
        let bpms = span.compactMap(\.bpm)
        let steps = span.compactMap(\.steps).sorted()
        let classed = span.reduce(0) { $0 + ($1.classSeconds ?? 0) }
        let moving = span.reduce(0) { $0 + ($1.walkSeconds ?? 0) + ($1.runSeconds ?? 0) }
        return Candidate(
            track: track, start: span.first!.ts, end: span.last!.ts + 60,
            avgBpm: bpms.isEmpty ? nil : Int((bpms.reduce(0, +) / Double(bpms.count)).rounded()),
            peakBpm: bpms.max().map { Int($0.rounded()) },
            load: edwardsLoad(span, hrMax: hrMax),
            cadence: steps.isEmpty ? nil : steps[steps.count / 2],
            locomotionShare: classed > 0 ? Double(moving) / Double(classed) : nil,
            kinds: kinds)
    }
}
