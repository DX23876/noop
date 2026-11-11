import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// The cycle page's two shared reads for Android (iOS `ForgeCycleView`): the rough fertile-days estimate
/// (`FertileWindow`) and whether the wearer's own training differs by phase (`CycleTrainingPattern`), from the same
/// strength sessions and whole-session ratings iOS learns from. Awareness only; neither changes a score.
public enum CoreCycle {
    public struct Fertile: Encodable {
        public var firstDay: Int, lastDay: Int, basis: String, pastRiseDays: [Int], typicalRiseDay: Int?
        /// "before", "during" or "over" for the given cycle day, with the days until or the day of.
        public var status: String?, daysUntil: Int?, day: Int?, of: Int?
    }

    public static func fertile(pastRiseDays: [Int], currentRiseDay: Int?, positiveTestDay: Int?, cycleDay: Int?) -> Fertile? {
        guard let e = FertileWindow.estimate(pastRiseDays: pastRiseDays, currentRiseDay: currentRiseDay,
                                             positiveTestDay: positiveTestDay) else { return nil }
        let basis: String
        switch e.basis {
        case .history: basis = "history"
        case .ovulationTest: basis = "ovulationTest"
        case .confirmedByRise: basis = "confirmedByRise"
        }
        var out = Fertile(firstDay: e.firstDay, lastDay: e.lastDay, basis: basis, pastRiseDays: e.pastRiseDays,
                          typicalRiseDay: e.typicalRiseDay)
        if let cycleDay {
            switch FertileWindow.status(e, cycleDay: cycleDay) {
            case .before(let n): out.status = "before"; out.daysUntil = n
            case .during(let d, let of): out.status = "during"; out.day = d; out.of = of
            case .over: out.status = "over"
            }
        }
        return out
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

    /// iOS `ForgeCycleView.learnPattern`: a year of strength sessions, each with its whole-session rating where one
    /// lies within half an hour, else the mean set RPE; ratings with no strength session count on their own.
    public static func pattern(reader: StoreReader, cycles: [CycleTrainingPattern.Cycle], dismissed: [String],
                               now: Int = Int(Date().timeIntervalSince1970)) async -> Pattern {
        let days = 365
        let fusion = await TrainingSessionResolver.read(reader: reader, from: now - days * 86_400, to: now + 86_400,
                                                        dismissedDetectedSpans: dismissed)
        let history = await StrengthHistoryReader.read(store: reader.store, days: days, now: now) { fusion }
        let summaries = history.workouts.map { StrengthSession.summarize($0, templates: history.templates) }
        let rated = await SessionRPEEntry.read(store: reader.store, from: now - 400 * 86_400, to: now)
        func day(_ ts: Int) -> String { StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(ts))) }
        var used = Set<String>()
        var sessions: [CycleTrainingPattern.Session] = []
        for s in summaries {
            let match = rated.first { abs($0.startTs - s.startTs) <= 1_800 }
            if let match { used.insert(match.id) }
            sessions.append(.init(day: day(s.startTs), rpe: match?.rpe ?? s.meanRpe,
                                  volumeKg: s.volumeLoadKg > 0 ? s.volumeLoadKg : nil, kind: s.title))
        }
        for r in rated where !used.contains(r.id) { sessions.append(.init(day: day(r.startTs), rpe: r.rpe)) }
        return output(CycleTrainingPattern.analyse(sessions: sessions, cycles: cycles))
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
}
