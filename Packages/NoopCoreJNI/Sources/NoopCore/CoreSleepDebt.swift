import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// The Sleep tab's sleep-debt ledger on Android (parity plan 2.3), after `SleepModel.debtLedger` and
/// `SleepDebtLedgerCard`: the 14-night recency-weighted balance against the personalised need, separate naps
/// credited, over the same 120 days of daily rows the iPhone's cache holds (edited nights applied). Every line the
/// card shows arrives worded.
enum CoreSleepDebt {
    static let windowDays = 120

    struct Output: Encodable {
        var nightCount: Int
        var balanceMin: Double
        var needMin: Double
        var magnitudeMin: Double
        var isDebt: Bool
        var onTarget: Bool
        var deltas: [Double]
        var headline: String
        var tag: String
        var read: String
        var balanceText: String
        var needText: String
        /// "positive", "warning" or "critical" (`debtBalanceColor`).
        var tone: String
    }

    static func read(reader: StoreReader, now: Date = Date()) async -> Output {
        let offsetSec = TimeZone.current.secondsFromGMT()
        let nowTs = Int(now.timeIntervalSince1970)
        let from = StoreReader.localDayKey(now.addingTimeInterval(-Double(windowDays) * 86_400))
        let to = StoreReader.localDayKey(now.addingTimeInterval(86_400))
        let sessions = await reader.allSleepSessions(from: nowTs - (windowDays + 1) * 86_400, to: nowTs + 86_400)
        let days = StoreReader.applyingEditedSleepSessions(sessions, to: StoreReader.mergeDaily(
            imported: await reader.unionDailyMetrics(from: from, to: to),
            computed: await reader.unionComputedDailyMetrics(from: from, to: to),
            userEditedDays: StoreReader.userEditedDays(sessions)))
        let habitual = await reader.habitualMidsleepSec(from: nowTs - 4000 * 86_400, to: nowTs + 86_400, offsetSec: offsetSec)
        // `SleepModel.napSleepMinutesByDay`: asleep minutes outside each day's main-night group.
        var naps: [String: Double] = [:]
        for blocks in SleepNight.days(sessions) {
            guard let endTs = blocks.first?.endTs else { continue }
            let main = Set(SleepNight.mainGroup(blocks, offsetSec: offsetSec, habitualMidsleepSec: habitual).map(\.startTs))
            naps[StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(endTs)))] = blocks
                .filter { !main.contains($0.startTs) }
                .reduce(0) { $0 + SleepNight.asleepMinutes($1.stagesJSON, effectiveStartTs: $1.effectiveStartTs) }
        }
        // The newest night's stored need (AI-34), the one its Rest was scored with and the iPhone's Sleep
        // screen measures the ledger against (`SleepModel.currentNeedMin`).
        let traits = await reader.restTraits(from: from, to: to)
        let needMin = (days.map(\.day).max().map { traits.inputs(forDay: $0) }
            ?? AnalyticsEngine.Rest.Inputs.coldStart).needHours * 60.0
        let ledger = SleepDebt.ledger(
            series: days.map { (day: $0.day, totalSleepMin: SleepDebt.creditedSleepMin(mainSleepMin: $0.totalSleepMin,
                                                                                       napSleepMin: naps[$0.day] ?? 0)) },
            needHours: needMin / 60.0)
        return output(ledger)
    }

    /// `SleepDebtLedgerCard`'s wording and colour.
    static func output(_ ledger: SleepDebtLedger) -> Output {
        let onTarget = ledger.magnitudeMin < SleepDebt.onTargetBandMin
        let nights = ledger.nightCount
        let span = nights == 1 ? String(localized: "the last night") : String(localized: "the last \(nights) nights")
        let read: String
        if onTarget || !ledger.isDebt {
            read = String(localized: "You've effectively met your current sleep need across \(span).")
        } else {
            let mag = duration(ledger.magnitudeMin)
            read = String(localized: "Sleep about \(mag) more than your need tonight and this debt is gone. Short nights from longer ago count for less than recent ones.")
        }
        let tone = onTarget || !ledger.isDebt ? "positive" : (ledger.magnitudeMin < 180 ? "warning" : "critical")
        return Output(nightCount: nights, balanceMin: ledger.balanceMin, needMin: ledger.needMin,
                      magnitudeMin: ledger.magnitudeMin, isDebt: ledger.isDebt, onTarget: onTarget,
                      deltas: ledger.nights.map(\.deltaMin),
                      headline: onTarget ? String(localized: "On target") : "≈\(duration(ledger.magnitudeMin))",
                      tag: !onTarget && ledger.isDebt ? String(localized: "sleep debt") : String(localized: "balanced"),
                      read: read, balanceText: signed(ledger.balanceMin), needText: duration(ledger.needMin), tone: tone)
    }

    /// `debtSigned`: "+1h 20m", "−2h 10m", "0m".
    static func signed(_ minutes: Double) -> String {
        if abs(minutes) < 1 { return String(localized: "0m") }
        return "\(minutes >= 0 ? "+" : "−")\(duration(abs(minutes)))"
    }

    /// `durationText`: "Xm" or "Yh Zm".
    static func duration(_ minutes: Double) -> String {
        let m = max(0, Int(minutes.rounded()))
        if m < 60 { return String(localized: "\(m)m") }
        return String(localized: "\(m / 60)h \(m % 60)m")
    }
}
