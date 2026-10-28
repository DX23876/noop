import Foundation
import StrandAnalytics

/// The habitual wake time the daily check-in follows in its "When I wake up" mode: the end of each recent main
/// night (`SleepStageTotals.mainNightGroupIndices`), then the median over at least three of them. Pure, so the
/// Apple app (`CoachCheckIn`) and the Android core compute the same minute from the same nights.
enum CoachCheckInWake {
    static let nights = 14

    /// The day's MAIN-NIGHT wake minute-of-day, for each of the most recent `nights` distinct local days
    /// that have one — mirroring the exact selector `AnalyticsEngine.analyzeDay` and the Sleep tab hero use
    /// so a nap sharing a day with the real night never contributes its own wake time, and a night split by
    /// a short wake still resolves to ONE wake time (the winning bridged group's latest `end`). Blocks are
    /// bucketed by the LOCAL day their `end` falls on — the SAME attribution `analyzeDay` uses
    /// (`tsInDay($0.end)`), so a night ending just after midnight buckets with its wake, not its bedtime
    /// (day keys sort lexicographically = chronologically, so no `Calendar` arithmetic is needed to pick
    /// "the most recent N"). Each timestamp uses ITS OWN UTC offset (so a window spanning a DST change
    /// still maps every wake to the wall-clock minute the user saw). Pure and database-free; the caller
    /// supplies already-fetched blocks. `offsetSec` defaults to the real `TimeZone.current` but is
    /// injectable so tests can pin a deterministic (or DST-transitioning) offset without depending on the
    /// machine's system timezone.
    static func mainNightWakeMinutes(
        blocks: [(start: Int, end: Int)], nights: Int, habitualMidsleepSec: Int?,
        offsetSec: (Int) -> Int = { ts in
            TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(ts)))
        }
    ) -> [Int] {
        guard !blocks.isEmpty else { return [] }
        var byDay: [String: [(start: Int, end: Int)]] = [:]
        for b in blocks {
            guard b.end > b.start else { continue }
            byDay[AnalyticsEngine.dayString(b.end, offsetSec: offsetSec(b.end)), default: []].append(b)
        }
        let recentDays = byDay.keys.sorted().suffix(nights)

        var wakeMinutes: [Int] = []
        for day in recentDays {
            guard let dayBlocks = byDay[day] else { continue }
            let dayOffset = offsetSec(dayBlocks.map(\.end).max() ?? 0)
            let nightBlocks = dayBlocks.map { SleepStageTotals.NightBlock(start: $0.start, end: $0.end) }
            guard let groupIdx = SleepStageTotals.mainNightGroupIndices(
                nightBlocks, offsetSec: dayOffset, habitualMidsleepSec: habitualMidsleepSec) else { continue }
            let wakeEnd = groupIdx.map { dayBlocks[$0].end }.max() ?? 0
            let secondsPerDay = 86_400
            let wakeOffset = offsetSec(wakeEnd)
            let localSec = (((wakeEnd + wakeOffset) % secondsPerDay) + secondsPerDay) % secondsPerDay
            wakeMinutes.append(localSec / 60)
        }
        return wakeMinutes
    }

    /// The habitual wake time (minutes since midnight) as the MEDIAN of recent nights' local wake minutes,
    /// or nil below `minimumNights` — a habit the reminder can rely on, not a guess off one or two nights.
    ///
    /// Median rather than mean on purpose: it shrugs off the odd 04:00 alarm or 11:00 lie-in that would
    /// drag an average away from the time the user actually wakes on a normal day. Pure and database-free
    /// so it unit-tests without a strap or store. Wake times realistically cluster in the morning and
    /// don't straddle midnight, so a plain minute-of-day median needs no circular-statistics handling.
    static func habitualWakeMinutes(fromLocalMinutes minutes: [Int],
                                                minimumNights: Int = 3) -> Int? {
        let valid = minutes.filter { (0..<24 * 60).contains($0) }.sorted()
        guard valid.count >= minimumNights else { return nil }
        let mid = valid.count / 2
        if valid.count % 2 == 1 {
            return valid[mid]
        }
        return (valid[mid - 1] + valid[mid]) / 2
    }
}
