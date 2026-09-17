import Foundation
import WhoopStore

// MARK: - Cardio, in the units the sport is actually measured in
//
// The strength lane got a screen that says what a session held and whether it is moving. Cardio never
// had the equivalent: a run, a ride and a swim all arrived as "duration, average heart rate, calories",
// which is the one description under which they are indistinguishable. A 42-minute run says nothing
// until it says 7.6 km at 5:31 /km; a ride says nothing until it says 31 km/h.
//
// This file derives exactly the figures those questions need, and NOTHING that needs a model:
//
//   • pace and speed  — distance over time. Arithmetic on two measured quantities.
//   • beats per km    — average heart rate spent per kilometre covered. Also arithmetic, and the one
//                       figure here that is genuinely comparable across weeks for the same sport.
//   • weekly totals   — sessions, moving time, distance, calories, Effort.
//   • cardio load     — the session Effort values, compared with the wearer's own recent baseline.
//                       Effort is derived from heart-rate TRIMP; moving time remains a separate total.
//   • bests           — longest, farthest, fastest average pace within a band of session lengths.
//
// ## What is deliberately not here
//
// No "cardio fitness score", no VO2max estimate, no training-zone prescription, no "you should run
// slower". Beats per kilometre is offered as a MEASURED figure with an explicit warning attached at
// the call site: it moves with heat, hills, wind and sleep, so a single pair of sessions says nothing
// and the caller must present a trend or nothing at all.
//
// Splits are also absent, and that is a data limit rather than a choice: a stored `WorkoutRow` carries
// one distance and one duration, so a per-kilometre split would have to be invented by dividing them —
// which would draw a perfectly flat pace chart for a run that had none.

/// What kind of cardio a stored sport label is, and therefore which readout it deserves.
///
/// Matched on the STORED label, which is a cross-platform stable string (never localized — see
/// `WorkoutCatalog`), lowercased and stripped of punctuation so "Treadmill run", "treadmill_run" and
/// "TreadmillRun" all land together. Anything unrecognised is `.unknown` and gets the neutral readout:
/// a sport this build has never seen must still show its duration and heart rate.
public enum CardioModality: String, Equatable, Sendable, CaseIterable, Codable {
    case foot, cycling, swimming, rowing, other, strength, unknown

    /// Whether this modality belongs in the cardio lane at all. Strength sessions do not: they have
    /// their own screen, and folding them in is how "average pace" ends up printed on a bench day.
    public var isCardio: Bool {
        switch self {
        case .strength: return false
        default:        return true
        }
    }

    /// How the sport's speed is conventionally read.
    public enum Readout: Equatable, Sendable { case pace, speed, none }

    public var readout: Readout {
        switch self {
        case .foot, .swimming:      return .pace     // minutes per kilometre / per 100 m
        case .cycling, .rowing:     return .speed    // kilometres per hour
        case .other, .unknown:      return .none
        case .strength:             return .none
        }
    }

    /// Whether this sport's pace is read per 100 METRES rather than per kilometre.
    ///
    /// Swimming is the one that differs, and it differs by convention rather than by arithmetic: every
    /// pool clock, every set written on a whiteboard and every swimmer talks in "1:37 per hundred".
    /// Showing a swim as "4:37 /km" is technically the same number and is read by nobody — the header
    /// above already said as much, but only the comment knew. This is the property that lets the
    /// display layer act on it.
    public var usesPerHundredMetres: Bool { self == .swimming }

    /// Locale-stable key; the display layer localizes.
    public var label: String {
        switch self {
        case .foot:      return "On foot"
        case .cycling:   return "Cycling"
        case .swimming:  return "Swimming"
        case .rowing:    return "Rowing"
        case .other:     return "Other cardio"
        case .strength:  return "Strength"
        case .unknown:   return "Unclassified"
        }
    }

    /// Classify a stored sport label.
    public static func of(sport: String) -> CardioModality {
        let key = sport.lowercased().filter { $0.isLetter || $0.isNumber }
        func has(_ needle: String) -> Bool { key.contains(needle) }

        // Strength first: "functional strength training" contains none of the cardio words, but
        // "strength" must never fall through to `.other` and start reporting a pace.
        if has("strength") || has("weightlifting") || has("bodybuilding") || has("powerlifting")
            || has("lifting") { return .strength }
        if has("run") || has("jog") || has("walk") || has("hike") || has("hiking")
            || has("trail") || has("treadmill") { return .foot }
        if has("cycl") || has("bike") || has("biking") || has("spinning") || has("peloton") { return .cycling }
        if has("swim") { return .swimming }
        if has("row") || has("kayak") || has("canoe") || has("paddle") { return .rowing }
        if has("elliptical") || has("hiit") || has("cardio") || has("stair") || has("ski")
            || has("skating") || has("rope") { return .other }
        return .unknown
    }
}

/// One cardio session, with everything derivable from the stored row already worked out.
public struct CardioSessionMetrics: Equatable, Sendable {
    public let startTs: Int
    public let endTs: Int
    public let day: String
    public let sport: String
    public let source: String
    public let modality: CardioModality
    public let durationS: Double?
    public let distanceM: Double?
    public let avgHr: Int?
    public let maxHr: Int?
    public let energyKcal: Double?
    public let strain: Double?
    public let steps: Int?
    /// Additive cardiovascular load (raw TRIMP). Kept separate from `strain`, the compressed Effort
    /// presentation, because logarithmic Effort values cannot be summed across sessions.
    public let cardioLoad: Double?

    public init(startTs: Int, endTs: Int, day: String, sport: String, source: String,
                modality: CardioModality, durationS: Double?, distanceM: Double?,
                avgHr: Int?, maxHr: Int?, energyKcal: Double?, strain: Double?, steps: Int?,
                cardioLoad: Double? = nil) {
        self.startTs = startTs
        self.endTs = endTs
        self.day = day
        self.sport = sport
        self.source = source
        self.modality = modality
        self.durationS = durationS
        self.distanceM = distanceM
        self.avgHr = avgHr
        self.maxHr = maxHr
        self.energyKcal = energyKcal
        self.strain = strain
        self.steps = steps
        self.cardioLoad = cardioLoad
    }

    /// Minimum distance before a pace or a speed is offered at all. Below 100 m the figure is dominated
    /// by where the GPS thought the session started.
    public static let minimumDistanceM = 100.0
    /// Minimum duration, for the same reason from the other side.
    public static let minimumDurationS = 60.0

    /// Seconds per kilometre. Nil unless both measurements are present and large enough to mean
    /// something.
    public var paceSecPerKm: Double? {
        guard let d = distanceM, d >= Self.minimumDistanceM,
              let t = durationS, t >= Self.minimumDurationS else { return nil }
        return t / (d / 1000)
    }

    /// Seconds per 100 m — how swimming is read. Same guards.
    public var paceSecPer100m: Double? {
        paceSecPerKm.map { $0 / 10 }
    }

    /// Kilometres per hour.
    public var speedKmh: Double? {
        guard let d = distanceM, d >= Self.minimumDistanceM,
              let t = durationS, t >= Self.minimumDurationS else { return nil }
        return (d / 1000) / (t / 3600)
    }

    /// Heart beats spent per kilometre: average heart rate × minutes, over kilometres.
    ///
    /// Measured on both sides and unit-honest — it is literally how many beats it cost to cover a
    /// kilometre. Over a long enough run of sessions in the same sport a fall means the same work is
    /// costing fewer beats, which is the plain-language version of aerobic progress.
    ///
    /// It is ALSO confounded by heat, hills, wind, altitude, sleep and how hard the session was meant
    /// to be. The caller must never present a single value as a verdict, and never compare it across
    /// sports.
    public var beatsPerKm: Double? {
        guard let hr = avgHr, hr > 0,
              let d = distanceM, d >= Self.minimumDistanceM,
              let t = durationS, t >= Self.minimumDurationS else { return nil }
        return Double(hr) * (t / 60) / (d / 1000)
    }

    /// Minutes of moving time, from the recorded duration and falling back to the session window.
    public var minutes: Double {
        (durationS ?? Double(max(0, endTs - startTs))) / 60
    }
}

/// One sport's share of a window.
public struct CardioSportTotal: Equatable, Sendable {
    public let sport: String
    public let modality: CardioModality
    public let sessionCount: Int
    public let minutes: Double
    public let distanceM: Double
    public let energyKcal: Double

    public init(sport: String, modality: CardioModality, sessionCount: Int, minutes: Double,
                distanceM: Double, energyKcal: Double) {
        self.sport = sport
        self.modality = modality
        self.sessionCount = sessionCount
        self.minutes = minutes
        self.distanceM = distanceM
        self.energyKcal = energyKcal
    }
}

/// One Monday–Sunday week of cardio.
public struct CardioWeekSummary: Equatable, Sendable {
    public let mondayKey: String
    public let sessionCount: Int
    public let minutes: Double
    public let distanceM: Double
    public let energyKcal: Double
    /// Summed additive Cardio Load over the sessions that carry one, on ONE axis: raw TRIMP where the
    /// history has it, stored Effort where it has none (`CardioSession.totalsUseCardioLoad`). Nil means
    /// unmeasured rather than an easy week.
    public let effort: Double?
    /// How many of the sessions carried a distance. Reported for the same reason `volumeSetCount` is:
    /// a weekly distance is a different claim when half the sessions had none.
    public let sessionsWithDistance: Int
    public let bySport: [CardioSportTotal]

    public init(mondayKey: String, sessionCount: Int, minutes: Double, distanceM: Double,
                energyKcal: Double, effort: Double?, sessionsWithDistance: Int,
                bySport: [CardioSportTotal]) {
        self.mondayKey = mondayKey
        self.sessionCount = sessionCount
        self.minutes = minutes
        self.distanceM = distanceM
        self.energyKcal = energyKcal
        self.effort = effort
        self.sessionsWithDistance = sessionsWithDistance
        self.bySport = bySport
    }
}

/// Bands of session LENGTH, so a "fastest pace" compares like with like.
///
/// A 5 km best and a marathon best are different achievements, and one average pace over a long session
/// is not evidence about a short one. The bands are conventional distances for the modality; they group,
/// they do not score.
public enum CardioDistanceBand: String, Equatable, Sendable, CaseIterable, Codable {
    case short, medium, long, veryLong

    /// Metres, per modality. Cycling distances are simply larger than running ones; using one set of
    /// cut points for both would put every ride in the top band.
    public static func of(distanceM: Double, modality: CardioModality) -> CardioDistanceBand? {
        guard distanceM >= CardioSessionMetrics.minimumDistanceM else { return nil }
        let km = distanceM / 1000
        switch modality {
        case .foot:
            if km < 5 { return .short }
            if km < 10 { return .medium }
            if km < 21.1 { return .long }
            return .veryLong
        case .cycling:
            if km < 20 { return .short }
            if km < 50 { return .medium }
            if km < 100 { return .long }
            return .veryLong
        case .swimming:
            if km < 1 { return .short }
            if km < 2 { return .medium }
            if km < 4 { return .long }
            return .veryLong
        case .rowing:
            if km < 5 { return .short }
            if km < 10 { return .medium }
            if km < 21.1 { return .long }
            return .veryLong
        case .other, .strength, .unknown:
            return nil
        }
    }

    /// Locale-stable key. The display layer localizes AND appends the modality's own distances, which
    /// is why the label carries no numbers of its own.
    public var label: String {
        switch self {
        case .short:    return "Short"
        case .medium:   return "Medium"
        case .long:     return "Long"
        case .veryLong: return "Very long"
        }
    }
}

/// A measured cardio best.
public struct CardioBest: Equatable, Sendable {
    /// Metres for a distance best, seconds for a duration best, seconds per kilometre for a pace best.
    public let value: Double
    public let day: String
    public let startTs: Int
    public let sport: String
    public let distanceM: Double?
    public let durationS: Double?

    public init(value: Double, day: String, startTs: Int, sport: String,
                distanceM: Double?, durationS: Double?) {
        self.value = value
        self.day = day
        self.startTs = startTs
        self.sport = sport
        self.distanceM = distanceM
        self.durationS = durationS
    }
}

/// Every measured best for one sport.
public struct CardioBests: Equatable, Sendable {
    public let farthest: CardioBest?
    public let longest: CardioBest?
    /// Fastest AVERAGE pace within each band of session length. Never a split: this build has no
    /// per-kilometre data, so "your fastest 5 km" would be a claim the log cannot support.
    public let fastestPaceByBand: [CardioDistanceBand: CardioBest]

    public init(farthest: CardioBest?, longest: CardioBest?,
                fastestPaceByBand: [CardioDistanceBand: CardioBest]) {
        self.farthest = farthest
        self.longest = longest
        self.fastestPaceByBand = fastestPaceByBand
    }

    public var isEmpty: Bool { farthest == nil && longest == nil && fastestPaceByBand.isEmpty }
}

public enum CardioSession {

    // MARK: - One session

    /// Derive one session's figures. Rows of any source are accepted; the caller decides what to feed
    /// in, and `metrics.modality.isCardio` is how a strength row is dropped.
    public static func metrics(for row: WorkoutRow, tzOffsetSeconds: Int = 0,
                               cardioLoad: Double? = nil) -> CardioSessionMetrics {
        CardioSessionMetrics(
            startTs: row.startTs, endTs: row.endTs,
            day: AnalyticsEngine.dayString(row.startTs, offsetSec: tzOffsetSeconds),
            sport: row.sport, source: row.source,
            modality: CardioModality.of(sport: row.sport),
            durationS: row.durationS, distanceM: row.distanceM,
            avgHr: row.avgHr, maxHr: row.maxHr, energyKcal: row.energyKcal,
            strain: row.strain, steps: row.steps, cardioLoad: cardioLoad)
    }

    /// Every cardio session in `rows`, newest first, strength rows dropped.
    public static func sessions(_ rows: [WorkoutRow], tzOffsetSeconds: Int = 0,
                                cardioLoadByStart: [Int: Double] = [:]) -> [CardioSessionMetrics] {
        rows.map { metrics(for: $0, tzOffsetSeconds: tzOffsetSeconds,
                           cardioLoad: cardioLoadByStart[$0.startTs]) }
            .filter { $0.modality.isCardio }
            .sorted { $0.startTs > $1.startTs }
    }

    // MARK: - A week

    /// Summarise the Monday–Sunday week containing `anchorDay`.
    ///
    /// Monday-anchored to match `WeeklyDigestEngine` and the Strength week, so one session cannot land
    /// in different weeks on two screens.
    public static func week(containing anchorDay: String,
                            sessions: [CardioSessionMetrics]) -> CardioWeekSummary {
        guard let monday = WeeklyDigestEngine.mondayOfWeek(containing: anchorDay) else {
            return CardioWeekSummary(mondayKey: anchorDay, sessionCount: 0, minutes: 0, distanceM: 0,
                                     energyKcal: 0, effort: nil, sessionsWithDistance: 0, bySport: [])
        }
        let sunday = WeeklyDigestEngine.addDays(monday, 6)
        let inWeek = sessions.filter { $0.day >= monday && $0.day <= sunday }

        var minutes = 0.0, distance = 0.0, kcal = 0.0
        var effort: Double?
        var withDistance = 0
        // Decided over the WHOLE input, not this week's slice, so two weeks of the same history can
        // never be totalled on different axes.
        let usesCardioLoad = totalsUseCardioLoad(sessions)
        // A named accumulator rather than a tuple in a dictionary: the tuple version type-checked so
        // slowly the compiler gave up on it.
        struct Accumulator {
            var modality: CardioModality
            var sessionCount = 0
            var minutes = 0.0
            var distanceM = 0.0
            var energyKcal = 0.0
        }
        var bySport: [String: Accumulator] = [:]
        for session in inWeek {
            minutes += session.minutes
            if let d = session.distanceM, d > 0 { distance += d; withDistance += 1 }
            if let k = session.energyKcal { kcal += k }
            if let s = additiveLoad(session, usingCardioLoad: usesCardioLoad) { effort = (effort ?? 0) + s }
            var entry = bySport[session.sport] ?? Accumulator(modality: session.modality)
            entry.sessionCount += 1
            entry.minutes += session.minutes
            entry.distanceM += session.distanceM ?? 0
            entry.energyKcal += session.energyKcal ?? 0
            bySport[session.sport] = entry
        }

        // Most minutes first; ties on the name so the order never depends on dictionary iteration.
        var totals: [CardioSportTotal] = []
        for (sport, entry) in bySport {
            totals.append(CardioSportTotal(sport: sport, modality: entry.modality,
                                           sessionCount: entry.sessionCount, minutes: entry.minutes,
                                           distanceM: entry.distanceM, energyKcal: entry.energyKcal))
        }
        totals.sort { $0.minutes == $1.minutes ? $0.sport < $1.sport : $0.minutes > $1.minutes }

        return CardioWeekSummary(mondayKey: monday, sessionCount: inWeek.count, minutes: minutes,
                                 distanceM: distance, energyKcal: kcal, effort: effort,
                                 sessionsWithDistance: withDistance, bySport: totals)
    }

    /// Minutes and distance per LOCAL day, for a trend line.
    public static func dailyTotals(_ sessions: [CardioSessionMetrics])
        -> (minutesByDay: [String: Double], distanceByDay: [String: Double]) {
        var minutes: [String: Double] = [:]
        var distance: [String: Double] = [:]
        for session in sessions {
            minutes[session.day, default: 0] += session.minutes
            distance[session.day, default: 0] += session.distanceM ?? 0
        }
        return (minutes, distance)
    }

    // MARK: - Load

    /// Whether a set of sessions is totalled in raw TRIMP.
    ///
    /// TRIMP and Effort are different axes — a threshold hour is around 130 TRIMP and around 14 Effort —
    /// so adding one to the other yields a number in no unit at all. That is exactly what a part-measured
    /// history would produce while some sessions carry a measured trace and others only a stored Effort.
    /// The axis is therefore chosen ONCE per set: if any session carries TRIMP the totals are TRIMP and
    /// the unmeasured sessions are left out (they are missing data, not easy sessions); with no TRIMP at
    /// all every session falls back to its stored Effort, which keeps an older history readable.
    public static func totalsUseCardioLoad(_ sessions: [CardioSessionMetrics]) -> Bool {
        sessions.contains { $0.cardioLoad != nil }
    }

    /// The one additive figure for a session under that decision, or nil when it carries none.
    public static func additiveLoad(_ session: CardioSessionMetrics, usingCardioLoad: Bool) -> Double? {
        usingCardioLoad ? session.cardioLoad : session.strain
    }

    /// Heart-rate-derived cardio load over seven days against the wearer's own 28-day level.
    ///
    /// Each session contributes raw TRIMP where the window was measured; a history recorded before the
    /// measured lane existed falls back to stored Effort for ALL of its sessions rather than mixing the
    /// two axes (see `totalsUseCardioLoad`). Moving time is deliberately kept beside this rather than
    /// used as load: sixty easy minutes and sixty threshold minutes are equal duration and very
    /// different cardiovascular work. Strength rows have already been removed by `sessions(_:)`, so
    /// lifting does not leak into this comparison.
    ///
    /// The daily series is dense and zero-filled. Rest days therefore remain real zeros, and the result
    /// uses `TrainingLoad`'s signed percentage instead of importing team-sport ACWR colour bands.
    public static func cardioLoadTrend(_ sessions: [CardioSessionMetrics],
                                       asOf now: Date = Date(),
                                       tzOffsetSeconds: Int = 0) -> LoadTrend? {
        var effortByDay: [String: Double] = [:]
        let usesCardioLoad = totalsUseCardioLoad(sessions)
        for session in sessions {
            guard let effort = additiveLoad(session, usingCardioLoad: usesCardioLoad),
                  effort.isFinite, effort >= 0 else { continue }
            effortByDay[session.day, default: 0] += effort
        }
        let today = AnalyticsEngine.dayString(Int(now.timeIntervalSince1970), offsetSec: tzOffsetSeconds)
        return TrainingLoad.trend(dailyByDay: effortByDay, through: today)
    }

    // MARK: - One sport over time

    /// Every session of one sport, oldest first — the series a progression chart draws.
    ///
    /// Matched on the stored label exactly (case-insensitively), not on modality: "Running" and
    /// "Treadmill run" are both on foot and their paces are not comparable, so folding them into one
    /// curve would draw a decline every time the weather turned.
    public static func history(sport: String,
                               sessions: [CardioSessionMetrics]) -> [CardioSessionMetrics] {
        sessions
            .filter { $0.sport.caseInsensitiveCompare(sport) == .orderedSame }
            .sorted { $0.startTs < $1.startTs }
    }

    /// Which sports appear, with how many sessions — the list a picker offers, most-trained first.
    public static func sportFrequency(_ sessions: [CardioSessionMetrics]) -> [(sport: String, sessions: Int)] {
        var counts: [String: Int] = [:]
        for session in sessions { counts[session.sport, default: 0] += 1 }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (sport: $0.key, sessions: $0.value) }
    }

    // MARK: - Bests

    /// The measured bests for one sport.
    ///
    /// Ties keep the EARLIEST session, for the same reason the strength records do: a best was set the
    /// first time it was reached.
    public static func bests(sport: String, sessions: [CardioSessionMetrics]) -> CardioBests {
        let mine = history(sport: sport, sessions: sessions)
        var farthest: CardioBest?
        var longest: CardioBest?
        var byBand: [CardioDistanceBand: CardioBest] = [:]

        for session in mine {
            func best(_ value: Double) -> CardioBest {
                CardioBest(value: value, day: session.day, startTs: session.startTs,
                           sport: session.sport, distanceM: session.distanceM,
                           durationS: session.durationS)
            }
            if let d = session.distanceM, d >= CardioSessionMetrics.minimumDistanceM,
               d > (farthest?.value ?? 0) {
                farthest = best(d)
            }
            if let t = session.durationS, t >= CardioSessionMetrics.minimumDurationS,
               t > (longest?.value ?? 0) {
                longest = best(t)
            }
            if let pace = session.paceSecPerKm, let d = session.distanceM,
               let band = CardioDistanceBand.of(distanceM: d, modality: session.modality),
               pace < (byBand[band]?.value ?? .greatestFiniteMagnitude) {
                byBand[band] = best(pace)
            }
        }
        return CardioBests(farthest: farthest, longest: longest, fastestPaceByBand: byBand)
    }

    // MARK: - The wearer's own range

    /// Typical weekly cardio minutes as a p25…p75 band over the last `weeks` complete weeks, the anchor
    /// week excluded.
    ///
    /// Same shape, same reasoning and the same three-week floor as `StrengthSession.typicalWeeklySets`:
    /// NOOP has no evidence about anyone's correct weekly volume, only about what this person does.
    /// Weeks with no session at all are skipped rather than counted as zero.
    public static func typicalWeeklyMinutes(_ sessions: [CardioSessionMetrics],
                                            endingBefore anchorDay: String,
                                            weeks: Int = 8) -> ClosedRange<Double>? {
        guard let thisMonday = WeeklyDigestEngine.mondayOfWeek(containing: anchorDay) else { return nil }
        var values: [Double] = []
        var monday = WeeklyDigestEngine.addDays(thisMonday, -7)
        for _ in 0..<max(weeks, 1) {
            let summary = week(containing: monday, sessions: sessions)
            if summary.sessionCount > 0 { values.append(summary.minutes) }
            monday = WeeklyDigestEngine.addDays(monday, -7)
        }
        guard values.count >= 3 else { return nil }
        let sorted = values.sorted()
        let lo = StrengthSession.percentile(sorted, 0.25)
        let hi = StrengthSession.percentile(sorted, 0.75)
        guard hi > 0 else { return nil }
        return min(lo, hi)...max(lo, hi)
    }

    /// The beats-per-kilometre series for one sport, oldest first, over the sessions that carry one.
    ///
    /// Returned as points rather than a verdict. The caller draws a trend and says what it is; a single
    /// value means nothing, and this function has no way to know whether it was 30 °C that day.
    public static func beatsPerKmSeries(sport: String,
                                        sessions: [CardioSessionMetrics]) -> [(startTs: Int, day: String, value: Double)] {
        history(sport: sport, sessions: sessions).compactMap { session in
            session.beatsPerKm.map { (session.startTs, session.day, $0) }
        }
    }
}

/// One sport's part of a week's measured cardio load.
public struct CardioSportLoadShare: Equatable, Sendable {
    public let sport: String
    public let modality: CardioModality
    public let load: Double
    /// Of the week's measured load, 0…1.
    public let share: Double
}

extension CardioSession {
    private static func inWeek(containing anchorDay: String,
                               _ sessions: [CardioSessionMetrics]) -> [CardioSessionMetrics] {
        guard let monday = WeeklyDigestEngine.mondayOfWeek(containing: anchorDay) else { return [] }
        let sunday = WeeklyDigestEngine.addDays(monday, 6)
        return sessions.filter { $0.day >= monday && $0.day <= sunday }
    }

    /// Each sport's share of the week's measured load, largest first. Sessions without a measured load
    /// are left out of both sides, so a share never mixes measured and unmeasured work.
    public static func loadShareBySport(inWeekContaining anchorDay: String,
                                        sessions: [CardioSessionMetrics]) -> [CardioSportLoadShare] {
        var bySport: [String: (modality: CardioModality, load: Double)] = [:]
        for session in inWeek(containing: anchorDay, sessions) {
            guard let load = session.cardioLoad, load.isFinite, load > 0 else { continue }
            bySport[session.sport, default: (session.modality, 0)].load += load
        }
        let total = bySport.values.reduce(0) { $0 + $1.load }
        guard total > 0 else { return [] }
        return bySport.map { CardioSportLoadShare(sport: $0.key, modality: $0.value.modality,
                                                  load: $0.value.load, share: $0.value.load / total) }
            .sorted { $0.load != $1.load ? $0.load > $1.load : $0.sport < $1.sport }
    }

    /// One sport's pace over the week: total moving time over total distance, in seconds per kilometre,
    /// from the sessions that recorded both. Nil when none did.
    public static func weeklyPaceSecPerKm(sport: String, inWeekContaining anchorDay: String,
                                          sessions: [CardioSessionMetrics]) -> Double? {
        var seconds = 0.0, metres = 0.0
        for session in inWeek(containing: anchorDay, sessions)
        where session.sport.caseInsensitiveCompare(sport) == .orderedSame {
            guard let duration = session.durationS, duration > 0,
                  let distance = session.distanceM, distance > 0 else { continue }
            seconds += duration
            metres += distance
        }
        guard metres > 0 else { return nil }
        return seconds / (metres / 1000)
    }

    /// The week's average heart rate, weighted by each session's duration, over sessions carrying both.
    public static func weeklyAverageHr(inWeekContaining anchorDay: String,
                                       sessions: [CardioSessionMetrics]) -> Double? {
        var beats = 0.0, seconds = 0.0
        for session in inWeek(containing: anchorDay, sessions) {
            guard let hr = session.avgHr, hr > 0, let duration = session.durationS, duration > 0 else { continue }
            beats += Double(hr) * duration
            seconds += duration
        }
        return seconds > 0 ? beats / seconds : nil
    }

    /// The median weekly average heart rate over the preceding `weeks` weeks that have one. Nil below
    /// three such weeks, the same floor the usual weekly minutes use.
    public static func typicalWeeklyAverageHr(_ sessions: [CardioSessionMetrics],
                                              endingBefore anchorDay: String,
                                              weeks: Int = 8) -> Double? {
        guard let thisMonday = WeeklyDigestEngine.mondayOfWeek(containing: anchorDay) else { return nil }
        var values: [Double] = []
        var monday = WeeklyDigestEngine.addDays(thisMonday, -7)
        for _ in 0..<max(weeks, 1) {
            if let value = weeklyAverageHr(inWeekContaining: monday, sessions: sessions) { values.append(value) }
            monday = WeeklyDigestEngine.addDays(monday, -7)
        }
        guard values.count >= 3 else { return nil }
        return StrengthSession.percentile(values.sorted(), 0.5)
    }
}
