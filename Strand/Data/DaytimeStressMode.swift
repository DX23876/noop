import Foundation
import StrandAnalytics

/// The one foreground-surface resolver for daytime-stress scoring.
///
/// Stress detail and Today's hosted Stress card both call this funnel. With the personal lens off it
/// returns immediately, preserving the historical day-relative path without trailing-history reads.
/// Background widget publishing deliberately does not opt in: a display preference must not turn an
/// unprompted periodic publisher into 30 days of raw reads.
enum DaytimeStressMode {
    private static let baselineHistoryDays = 30

    @MainActor
    static func selected(repo: Repository, startOfToday: Date,
                         calendar: Calendar = .current,
                         personalBaseline: Bool) async -> DaytimeStress.ScoringMode {
        guard personalBaseline else { return .dayRelative }

        var aggregates: [(hr: Double?, rmssd: Double?)] = []
        aggregates.reserveCapacity(baselineHistoryDays)
        // Oldest -> newest so the EWMA fold replays history in order. Reduce each day immediately:
        // the fold needs two Doubles per day, not 30 days of raw HR and R-R retained together (#2107).
        for back in stride(from: baselineHistoryDays, through: 1, by: -1) {
            guard let dayStart = calendar.date(byAdding: .day, value: -back, to: startOfToday),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let from = Int(dayStart.timeIntervalSince1970)
            let to = Int(dayEnd.timeIntervalSince1970) - 1
            let dayTz = TimeZone.current.secondsFromGMT(for: dayStart)
            let dayHR = await repo.hrSamples(from: from, to: to, limit: 200_000)
            guard !dayHR.isEmpty else { continue }
            let dayRR = await repo.rrIntervals(from: from, to: to, limit: 200_000)
            aggregates.append(
                DaytimeStress.dayDaytimeAggregate(hr: dayHR, rr: dayRR, tzOffsetSeconds: dayTz)
            )
        }
        return DaytimeStress.scoringModeFromAggregates(aggregates)
    }
}
