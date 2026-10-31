import Foundation
import StrandAnalytics

// activitybench --db PATH --from YYYY-MM-DD --to YYYY-MM-DD [--device my-whoop] [--split YYYY-MM-DD]
//               [--own-bundle-marker noop] [--min-awake-hours 8] [--hr-max BPM] [--dump YYYY-MM-DD]
//
// Prints, per detector, hits per kind, suggestions without an entry per worn awake day and the start and
// end error, with week-bootstrap intervals. `--split` reports the days before and from that date apart
// (a strap change). Kinds with fewer than five entries print their count only, never a rate.

struct Options {
    var db = ""
    var from = ""
    var to = ""
    var device = "my-whoop"
    var split: String?
    var ownBundleMarker = "noop"
    var minAwakeHours = 8.0
    var hrMax: Int?
    var dump: String?

    static func parse(_ args: [String]) -> Options? {
        var o = Options()
        var i = 1
        while i < args.count {
            let key = args[i]
            guard i + 1 < args.count else { return nil }
            let value = args[i + 1]
            switch key {
            case "--db": o.db = value
            case "--from": o.from = value
            case "--to": o.to = value
            case "--device": o.device = value
            case "--split": o.split = value
            case "--own-bundle-marker": o.ownBundleMarker = value
            case "--min-awake-hours": o.minAwakeHours = Double(value) ?? o.minAwakeHours
            case "--hr-max": o.hrMax = Int(value)
            case "--dump": o.dump = value
            default: return nil
            }
            i += 2
        }
        return o.db.isEmpty || o.from.isEmpty || o.to.isEmpty ? nil : o
    }
}

/// What a detector sees for one local day: that day's minutes and heart rate, the two weeks of minutes
/// before it, and the day's resting and maximum heart rate. Never a later day.
struct DayInput {
    let hr: [(ts: Int, bpm: Int)]
    let minutes: [ActivityCandidates.Minute]
    let history: [ActivityCandidates.Minute]
    let restingHR: Int?
    let hrMax: Int
}

/// A detector as the bench runs it: the shipped rule, fed one local day.
struct Detector {
    let name: String
    let run: (DayInput) -> [ActivityDetectionScore.Span]
}

func newTracks(_ d: DayInput, level: ActivityCandidates.Level?, tracks: Set<ActivityCandidates.Track>)
    -> [ActivityDetectionScore.Span] {
    guard let resting = d.restingHR else { return [] }
    let everyday = ActivityCandidates.everydayHRR(history: d.history, restingHR: resting, hrMax: d.hrMax)
    return ActivityCandidates.candidates(d.minutes, restingHR: resting, hrMax: d.hrMax, everydayHRR: everyday)
        .filter { tracks.contains($0.track) && (level.map($0.asks) ?? true) }
        .map { .init(start: $0.start, end: $0.end) }
}

let detectors: [Detector] = [
    // Today's published rule (resting + 30 bpm, 12 min), the "old" side of every paired comparison.
    Detector(name: "today") { d in
        AutoWorkoutDetector.detect(hr: d.hr, restingBpm: d.restingHR)
            .map { .init(start: $0.startSec, end: $0.endSec) }
    },
    Detector(name: "walk") { newTracks($0, level: nil, tracks: [.walk]) },
    Detector(name: "heartRate (no minimum load)") { newTracks($0, level: nil, tracks: [.heartRate]) },
    Detector(name: "both, more") { newTracks($0, level: .more, tracks: [.walk, .heartRate]) },
    Detector(name: "both, balanced") { newTracks($0, level: .balanced, tracks: [.walk, .heartRate]) },
    Detector(name: "both, only clear") { newTracks($0, level: .onlyClear, tracks: [.walk, .heartRate]) },
]

guard let opts = Options.parse(CommandLine.arguments) else {
    FileHandle.standardError.write(Data("""
        usage: activitybench --db PATH --from YYYY-MM-DD --to YYYY-MM-DD [--device my-whoop]
                             [--split YYYY-MM-DD] [--own-bundle-marker noop] [--min-awake-hours 8] [--hr-max BPM]

        """.utf8))
    exit(2)
}

let calendar = Calendar.current
let dayFormat: DateFormatter = {
    let f = DateFormatter()
    f.calendar = calendar
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = calendar.timeZone
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

guard let first = dayFormat.date(from: opts.from), let last = dayFormat.date(from: opts.to) else {
    FileHandle.standardError.write(Data("activitybench: dates must be YYYY-MM-DD\n".utf8))
    exit(2)
}
let splitTs = opts.split.flatMap { dayFormat.date(from: $0) }.map { Int($0.timeIntervalSince1970) }

let db: ReadOnlyDB
do { db = try ReadOnlyDB(path: opts.db) } catch {
    FileHandle.standardError.write(Data("activitybench: \(error)\n".utf8))
    exit(1)
}

var dayStarts: [Int] = []
var cursor = calendar.startOfDay(for: first)
while cursor <= last {
    dayStarts.append(Int(cursor.timeIntervalSince1970))
    cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
}
let rangeStart = dayStarts.first!
let rangeEndExclusive = dayStarts.last! + 86_400 + 3_600   // one DST hour of slack

func week(of ts: Int) -> Int { (ts - rangeStart) / (7 * 86_400) }

do {
    let resting = try db.restingHR(device: opts.device)
    let rows = try db.entries(device: opts.device, from: rangeStart, to: rangeEndExclusive)
    let entries = ActivityDetectionScore.uniqueLabels(
        rows.filter { EntryFilter.isWearerEntry($0, ownBundleMarker: opts.ownBundleMarker) }
            .filter { $0.startTs >= rangeStart && $0.startTs < rangeEndExclusive }
            .map { .init(span: .init(start: $0.startTs, end: $0.endTs), kind: .of(sport: $0.sport)) })
    let sleep = try db.sleepSpans(device: opts.device, from: rangeStart - 86_400, to: rangeEndExclusive)

    var wornDays: [Int] = []
    var hrByDay: [Int: [(ts: Int, bpm: Int)]] = [:]
    for start in dayStarts {
        let end = Int(calendar.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: TimeInterval(start)))!
            .timeIntervalSince1970)
        let hr = try db.heartRate(device: opts.device, from: start, to: end)
        hrByDay[start] = hr
        let awake = Set(hr.lazy.filter { s in !sleep.contains { s.ts >= $0.start && s.ts < $0.end } }.map(\.ts)).count
        if Double(awake) >= opts.minAwakeHours * 3_600 { wornDays.append(start) }
    }
    // Two weeks of history before the first day, for the everyday level; sixty days for the maximum.
    let historyStart = rangeStart - 14 * 86_400
    let allMinutes = try db.minutes(device: opts.device, from: historyStart - 46 * 86_400, to: rangeEndExclusive,
                                    sleep: try db.sleepSpans(device: opts.device, from: historyStart - 47 * 86_400,
                                                             to: rangeEndExclusive))
    func minutes(_ from: Int, _ to: Int) -> [ActivityCandidates.Minute] {
        let lo = allMinutes.partitionIndex { $0.ts >= from }, hi = allMinutes.partitionIndex { $0.ts >= to }
        return Array(allMinutes[lo..<hi])
    }
    /// The highest minute mean of the sixty days before, at least 150: the maximum the app could have known.
    func trailingHRMax(before start: Int) -> Int {
        let peak = minutes(start - 60 * 86_400, start).compactMap(\.bpm).max() ?? 0
        return max(150, Int(peak.rounded()))
    }

    print("activitybench \(opts.from) to \(opts.to), device \(opts.device): \(dayStarts.count) days, "
          + "\(wornDays.count) worn awake days (≥ \(opts.minAwakeHours) h), \(entries.count) unique entries")

    for detector in detectors {
        var candidates: [ActivityDetectionScore.Span] = []
        for start in dayStarts {
            // The day's resting heart rate is known from the morning (the night before it); a day without
            // one takes the day before. Never a later day: the bench must not see what the app could not.
            let day = dayFormat.string(from: Date(timeIntervalSince1970: TimeInterval(start + 43_200)))
            let previousDay = dayFormat.string(from: Date(timeIntervalSince1970: TimeInterval(start - 43_200)))
            let end = start + 86_400 + 3_600
            let input = DayInput(hr: hrByDay[start] ?? [],
                                 minutes: minutes(start, end).filter { $0.ts < start + 86_400 },
                                 history: minutes(start - 14 * 86_400, start),
                                 restingHR: resting[day] ?? resting[previousDay],
                                 hrMax: opts.hrMax ?? trailingHRMax(before: start))
            let found = detector.run(input)
            if opts.dump == day {
                let f = DateFormatter()
                f.dateFormat = "HH:mm"
                print("dump \(detector.name) \(day) resting \(input.restingHR.map(String.init) ?? "-") max \(input.hrMax): "
                      + found.map { "\(f.string(from: Date(timeIntervalSince1970: TimeInterval($0.start))))"
                          + "-\(f.string(from: Date(timeIntervalSince1970: TimeInterval($0.end))))" }.joined(separator: ", "))
            }
            candidates += found
        }
        let matched = ActivityDetectionScore.match(candidates: candidates, labels: entries)
        func outcomes(_ keep: (Int) -> Bool) -> [Outcome] {
            var out: [Outcome] = []
            for (i, c) in candidates.enumerated() where keep(c.start) {
                out.append(.init(week: week(of: c.start), what: .suggestion(found: matched[i].map { entries[$0].kind })))
            }
            for e in entries where keep(e.span.start) { out.append(.init(week: week(of: e.span.start), what: .entry(e.kind))) }
            for d in wornDays where keep(d) { out.append(.init(week: week(of: d), what: .wornDay)) }
            return out
        }
        let errors = zip(candidates, matched).compactMap { c, l in l.map { (c, entries[$0].span) } }
        report(name: detector.name, part: "all", outcomes: outcomes { _ in true }, errors: errors)
        if let splitTs {
            report(name: detector.name, part: "before \(opts.split!)", outcomes: outcomes { $0 < splitTs },
                   errors: errors.filter { $0.0.start < splitTs })
            report(name: detector.name, part: "from \(opts.split!)", outcomes: outcomes { $0 >= splitTs },
                   errors: errors.filter { $0.0.start >= splitTs })
        }
    }
} catch {
    FileHandle.standardError.write(Data("activitybench: \(error)\n".utf8))
    exit(1)
}

func report(name: String, part: String, outcomes: [Outcome],
            errors: [(ActivityDetectionScore.Span, ActivityDetectionScore.Span)]) {
    let weeks = WeekTally.byWeek(outcomes)
    let total = WeekTally.sum(weeks)
    func fmt(_ v: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", v) }
    print("\n[\(name)] \(part)")
    for kind in ActivityDetectionScore.Kind.allCases {
        let n = total.entries[kind] ?? 0, h = total.hits[kind] ?? 0
        guard n > 0 else { continue }
        if n < 5 { print("  \(kind.rawValue): \(h)/\(n) (too few for a rate)"); continue }
        let ci = WeekBootstrap.interval(weeks) { t in
            let n = t.entries[kind] ?? 0
            return n > 0 ? Double(t.hits[kind] ?? 0) / Double(n) : nil
        }
        print("  \(kind.rawValue): \(h)/\(n) = \(fmt(Double(h) / Double(n)))"
              + (ci.map { " [\(fmt($0.low)) to \(fmt($0.high))]" } ?? ""))
    }
    if total.wornDays > 0 {
        let rate = Double(total.unlabelled) / Double(total.wornDays)
        let ci = WeekBootstrap.interval(weeks) { t in t.wornDays > 0 ? Double(t.unlabelled) / Double(t.wornDays) : nil }
        print("  without an entry: \(total.unlabelled) on \(total.wornDays) worn days = \(fmt(rate)) per day"
              + (ci.map { " [\(fmt($0.low)) to \(fmt($0.high))]" } ?? ""))
    }
    if !errors.isEmpty {
        let s = errors.map { Double(abs($0.0.start - $0.1.start)) }.reduce(0, +) / Double(errors.count) / 60
        let e = errors.map { Double(abs($0.0.end - $0.1.end)) }.reduce(0, +) / Double(errors.count) / 60
        print("  mean error of \(errors.count) matches: start \(fmt(s, 1)) min, end \(fmt(e, 1)) min")
    }
}
