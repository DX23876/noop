import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// The cycle for Android, from the reading the iPhone runs (`CycleReading.swift`, linked through `Shared`): the
/// phase from the nights, the page's snapshot with the fertile-days estimate, the training pattern, and the day log.
/// Android only words and draws it. Awareness only; none of it changes a score.
public enum CoreCycle {
    public struct Window: Encodable { public var earliestDay: String, latestDay: String }
    public struct Phase: Encodable {
        public var phase: String, confidence: String, cycleDayLow: Int?, cycleDayHigh: Int?, cycleLengthDays: Int?
        public var nextPeriodWindow: Window?, shiftMarkers: [String], note: String, curve: [Double]
    }
    public struct Fertile: Encodable {
        public var firstDay: Int, lastDay: Int, basis: String, pastRiseDays: [Int], typicalRiseDay: Int?
        /// "before", "during" or "over" for today's cycle day, with the days until or the day of.
        public var status: String?, daysUntil: Int?, day: Int?, of: Int?
    }
    public struct Compare: Encodable {
        public var tempDelta: Double?, rhrDelta: Double?, hrvDelta: Double?, chargeNow: Double?, chargeBefore: Double?
        public var wakeNow: Double?, wakeBefore: Double?
    }
    public struct Temp: Encodable { public var day: Int, value: Double }
    public struct Snapshot: Encodable {
        public var cycleDay: Int?, dayRangeLow: Int?, dayRangeHigh: Int?, length: Int, phase: String?, shiftDay: Int?
        public var periodLength: Int, nextLow: Int?, nextHigh: Int?, temps: [Temp], startDay: String?
        public var periodDays: [String], compare: Compare?, cyclesSeen: Int, confidence: String?
        public var moodsThisPhase: [String: Int], fertile: Fertile?, fertileDays: [String], fertileStartDayAhead: String?
        /// The phase each day of the dial is drawn in, day 1 first (`CycleSnapshot.phase(onDay:)`).
        public var dayPhases: [String?]
    }
    public struct LogDay: Codable {
        public var flow: Int?
        public var symptoms: [String]
        public var moods: [String]
        public var ovulationTest: Bool
    }
    public struct Verdict: Encodable {
        /// "learning", "harder", "easier" or "noDifference".
        public var kind: String, rpeDelta: Double? = nil, volumeDrop: Double? = nil
    }
    public struct Pattern: Encodable {
        public var cyclesUsed: Int, progressCycles: Int, progressRated: Int
        public var minCycles: Int, minSessionsPerPhase: Int, rpeThreshold: Double
        /// Keyed by `CycleTrainingPattern.Phase` raw value: period, follicular, luteal.
        public var verdicts: [String: Verdict]
    }
    public struct Output: Encodable {
        public var today: String, starts: [String], todayLog: LogDay, result: Phase?, snapshot: Snapshot, pattern: Pattern?
    }

    /// The nights the phase engine reads: every merged day the store holds.
    static func days(reader: StoreReader, today: String) async -> [DailyMetric] {
        StoreReader.mergeDaily(imported: await reader.unionDailyMetrics(from: CycleTrackingStore.earliestDay, to: today),
                               computed: await reader.unionComputedDailyMetrics(from: CycleTrackingStore.earliestDay, to: today))
    }

    /// The phase alone, for the places that show it without the page (the Health signals, the Today card).
    public static func phase(reader: StoreReader, now: Date = Date()) async -> Phase? {
        let today = StoreReader.localDayKey(now)
        let starts = await CycleTrackingStore.periodStarts(store: reader.store)
        return CyclePhaseReading.classify(days: await days(reader: reader, today: today), loggedPeriodStarts: starts).map(phase)
    }

    public static func read(reader: StoreReader, showFertile: Bool, learning: Bool, dismissedWorkouts: [String],
                            now: Date = Date()) async -> Output {
        let today = StoreReader.localDayKey(now)
        let starts = await CycleTrackingStore.periodStarts(store: reader.store)
        let log = await CycleLog.read(store: reader.store, from: CycleSnapshot.add(-180, to: today) ?? today, to: today)
        let days = await days(reader: reader, today: today)
        let reading = CyclePhaseReading.classify(days: days, loggedPeriodStarts: starts)
        let snap = CycleSnapshot.make(result: reading?.result, starts: starts, log: log, days: days, today: today,
                                      showFertile: showFertile)
        var pattern: Pattern?
        if learning {
            let cycles = CycleSnapshot.cycles(starts: starts, log: log, result: reading?.result)
            pattern = output(await CyclePatternReading.learn(reader: reader, cycles: cycles, dismissedWorkouts: dismissedWorkouts))
        }
        return Output(today: today, starts: starts, todayLog: logDay(log[today] ?? CycleLog.Day()), result: reading.map(phase),
                      snapshot: snapshot(snap), pattern: pattern)
    }

    /// Saves today's notes, and a new period start when flow begins with none in the last ten days.
    public static func save(store: WhoopStore, day: String, log: LogDay, previous: LogDay, starts: [String]) async -> Bool {
        await CycleLog.saveLoggingStart(store: store, day: day, cycleDay(log), previous: cycleDay(previous), starts: starts)
    }

    static func phase(_ o: CyclePhaseReading.Output) -> Phase {
        let r = o.result
        return Phase(phase: r.phase.rawValue, confidence: r.confidence.rawValue, cycleDayLow: r.cycleDayLow,
                     cycleDayHigh: r.cycleDayHigh, cycleLengthDays: r.cycleLengthDays,
                     nextPeriodWindow: r.nextPeriodWindow.map { Window(earliestDay: $0.earliestDay, latestDay: $0.latestDay) },
                     shiftMarkers: r.shiftMarkers.map(\.day), note: r.note, curve: o.curve)
    }

    static func snapshot(_ s: CycleSnapshot) -> Snapshot {
        var fertile: Fertile?
        if let e = s.fertile {
            let basis: String
            switch e.basis {
            case .history: basis = "history"
            case .ovulationTest: basis = "ovulationTest"
            case .confirmedByRise: basis = "confirmedByRise"
            }
            var f = Fertile(firstDay: e.firstDay, lastDay: e.lastDay, basis: basis, pastRiseDays: e.pastRiseDays,
                            typicalRiseDay: e.typicalRiseDay)
            switch s.fertileStatus {
            case .before(let n)?: f.status = "before"; f.daysUntil = n
            case .during(let d, let of)?: f.status = "during"; f.day = d; f.of = of
            case .over?: f.status = "over"
            case nil: break
            }
            fertile = f
        }
        return Snapshot(cycleDay: s.cycleDay, dayRangeLow: s.dayRange?.lowerBound, dayRangeHigh: s.dayRange?.upperBound,
                        length: s.length, phase: s.phase?.rawValue, shiftDay: s.shiftDay, periodLength: s.periodLength,
                        nextLow: s.nextWindow?.lowerBound, nextHigh: s.nextWindow?.upperBound,
                        temps: s.temps.map { Temp(day: $0.day, value: $0.value) }, startDay: s.startDay,
                        periodDays: s.periodDays.sorted(),
                        compare: s.compare.map { c in Compare(tempDelta: c.tempDelta, rhrDelta: c.rhrDelta, hrvDelta: c.hrvDelta,
                                                              chargeNow: c.chargeNow, chargeBefore: c.chargeBefore,
                                                              wakeNow: c.wakeNow, wakeBefore: c.wakeBefore) },
                        cyclesSeen: s.cyclesSeen, confidence: s.engineConfidence?.rawValue, moodsThisPhase: s.moodsThisPhase,
                        fertile: fertile, fertileDays: s.fertileDays.sorted(), fertileStartDayAhead: s.fertileStartDayAhead,
                        dayPhases: (1...max(s.wheelDays, 1)).map { s.phase(onDay: $0)?.rawValue })
    }

    static func output(_ result: CycleTrainingPattern.Result) -> Pattern {
        var verdicts: [String: Verdict] = [:]
        for phase in CycleTrainingPattern.Phase.allCases {
            switch result.verdict(for: phase) {
            case .learning: verdicts[phase.rawValue] = Verdict(kind: "learning")
            case .harder(let r, let v): verdicts[phase.rawValue] = Verdict(kind: "harder", rpeDelta: r, volumeDrop: v)
            case .easier(let r, let v): verdicts[phase.rawValue] = Verdict(kind: "easier", rpeDelta: r, volumeDrop: v)
            case .noDifference: verdicts[phase.rawValue] = Verdict(kind: "noDifference")
            }
        }
        let progress = result.progress
        return Pattern(cyclesUsed: result.cyclesUsed, progressCycles: progress.cycles, progressRated: progress.rated,
                       minCycles: CycleTrainingPattern.minCycles, minSessionsPerPhase: CycleTrainingPattern.minSessionsPerPhase,
                       rpeThreshold: CycleTrainingPattern.rpeThreshold, verdicts: verdicts)
    }

    static func logDay(_ d: CycleLog.Day) -> LogDay {
        LogDay(flow: d.flow?.rawValue, symptoms: d.symptoms.sorted(), moods: d.moods.sorted(), ovulationTest: d.ovulationTest)
    }

    static func cycleDay(_ d: LogDay) -> CycleLog.Day {
        CycleLog.Day(flow: d.flow.flatMap(CycleLog.Flow.init(rawValue:)),
                     symptoms: Set(d.symptoms.filter(CycleLog.symptomIds.contains)),
                     moods: Set(d.moods.filter(CycleLog.moodIds.contains)), ovulationTest: d.ovulationTest)
    }
}
