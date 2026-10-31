import Foundation

// ActivityDetectionScore.swift — the fixed yardstick for activity detection (plan building block 3).
//
// Every detector the plan builds is judged by the same numbers, fixed before any detector exists: a
// one-to-one match between suggestions and the wearer's own entries at an overlap (intersection over
// union) of at least 0.3, hits per kind, suggestions without an entry per worn awake day, and the mean
// start and end error of the matches. ActivityBench prints them over a database copy; the daily pass
// writes one shadow line per suggestion in the Workouts test mode. A suggestion with no entry is
// "unlabelled", never "false": the wearer logs gym sessions but rarely walks, so a missing entry is not
// evidence that nothing happened.
//
// Pure: no I/O, no clock. All timestamps are unix seconds.
public enum ActivityDetectionScore {

    /// The overlap a suggestion needs with an entry to count as finding it.
    public static let minimumIoU = 0.3

    public struct Span: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }
        var length: Int { max(0, end - start) }
    }

    /// What an entry was. The bench maps sport names onto these; the yardstick reports each one apart.
    public enum Kind: String, CaseIterable, Sendable {
        case walk, run, cycle, strength, other

        /// Folds a stored sport name (any source's spelling) onto a kind.
        public static func of(sport: String) -> Kind {
            let s = sport.lowercased()
            if s.contains("walk") || s.contains("hik") || s.contains("spazier") { return .walk }
            if s.contains("run") || s.contains("lauf") || s.contains("jog") { return .run }
            if s.contains("cycl") || s.contains("bik") || s.contains("rad") || s.contains("spin") { return .cycle }
            if s.contains("strength") || s.contains("bodybuild") || s.contains("weight") || s.contains("lift")
                || s.contains("kraft") || s.contains("functional") { return .strength }
            return .other
        }
    }

    public struct Label: Equatable, Sendable {
        public let span: Span
        public let kind: Kind
        public init(span: Span, kind: Kind) {
            self.span = span
            self.kind = kind
        }
    }

    public static func iou(_ a: Span, _ b: Span) -> Double {
        let inter = max(0, min(a.end, b.end) - max(a.start, b.start))
        let union = a.length + b.length - inter
        return union > 0 ? Double(inter) / Double(union) : 0
    }

    /// One-to-one matching: the pair with the largest overlap is taken first, then the next among the
    /// remaining ones, so one long suggestion that spans two entries finds at most one of them. Ties go to
    /// the earlier suggestion, then the earlier entry, so the result does not depend on input order.
    /// Returns, for every suggestion, the index of the entry it found (nil = unlabelled).
    public static func match(candidates: [Span], labels: [Label]) -> [Int?] {
        var pairs: [(iou: Double, c: Int, l: Int)] = []
        for (c, cand) in candidates.enumerated() {
            for (l, label) in labels.enumerated() {
                let v = iou(cand, label.span)
                if v >= minimumIoU { pairs.append((v, c, l)) }
            }
        }
        pairs.sort {
            if $0.iou != $1.iou { return $0.iou > $1.iou }
            let a = candidates[$0.c].start, b = candidates[$1.c].start
            if a != b { return a < b }
            return labels[$0.l].span.start < labels[$1.l].span.start
        }
        var byCandidate = [Int?](repeating: nil, count: candidates.count)
        var taken = Set<Int>()
        for p in pairs where byCandidate[p.c] == nil && !taken.contains(p.l) {
            byCandidate[p.c] = p.l
            taken.insert(p.l)
        }
        return byCandidate
    }

    public struct Summary: Equatable, Sendable {
        public var hits: [Kind: Int] = [:]
        public var entries: [Kind: Int] = [:]
        public var suggestions = 0
        public var unlabelled = 0
        public var wornAwakeDays = 0
        /// Mean absolute start and end error of the matched pairs, in seconds; nil without a match.
        public var meanStartErrorS: Double?
        public var meanEndErrorS: Double?

        public init() {}

        public var unlabelledPerWornDay: Double? {
            wornAwakeDays > 0 ? Double(unlabelled) / Double(wornAwakeDays) : nil
        }
    }

    public static func summarize(candidates: [Span], labels: [Label], wornAwakeDays: Int) -> Summary {
        let matched = match(candidates: candidates, labels: labels)
        var out = Summary()
        out.suggestions = candidates.count
        out.wornAwakeDays = wornAwakeDays
        for label in labels { out.entries[label.kind, default: 0] += 1 }
        var startErr = 0, endErr = 0, pairs = 0
        for (c, l) in matched.enumerated() {
            guard let l else { out.unlabelled += 1; continue }
            out.hits[labels[l].kind, default: 0] += 1
            startErr += abs(candidates[c].start - labels[l].span.start)
            endErr += abs(candidates[c].end - labels[l].span.end)
            pairs += 1
        }
        if pairs > 0 {
            out.meanStartErrorS = Double(startErr) / Double(pairs)
            out.meanEndErrorS = Double(endErr) / Double(pairs)
        }
        return out
    }

    /// Pieces of one session less than this apart are one entry (a session logged in three parts).
    public static let entryJoinGapS = 10 * 60

    /// Entries the wearer logged twice (a walk in Apple Health and again by hand) are one entry: any two
    /// that overlap in time merge into the earliest start and latest end, keeping the first one's kind
    /// (earliest start). So are pieces of the same kind less than `entryJoinGapS` apart. Without this one
    /// walk counts as two entries and at most one can ever be found.
    public static func uniqueLabels(_ labels: [Label]) -> [Label] {
        let sorted = labels.sorted { ($0.span.start, $0.span.end) < ($1.span.start, $1.span.end) }
        var out: [Label] = []
        for label in sorted {
            if let last = out.last,
               label.span.start < last.span.end
                || (label.kind == last.kind && label.span.start - last.span.end < entryJoinGapS) {
                out[out.count - 1] = Label(span: Span(start: last.span.start, end: max(last.span.end, label.span.end)),
                                           kind: last.kind)
            } else {
                out.append(label)
            }
        }
        return out
    }

    /// The Workouts test-mode shadow line for one suggestion of the daily pass: which track found it, the
    /// rule version, its rounded length and heart rate, and whether it matched an entry. Counts and bpm
    /// only, no timestamps beyond the day key. `result` is `matched` or `unlabelled`, never "false".
    public static func shadowLine(day: String, track: String, ruleVersion: String, span: Span, avgBpm: Int,
                                  matchedKind: Kind?) -> String {
        "activityShadow day=\(day) track=\(track) rule=\(ruleVersion) durMin=\(span.length / 60) "
            + "avgBpm=\(avgBpm) result=\(matchedKind.map { "matched kind=\($0.rawValue)" } ?? "unlabelled")"
    }
}
