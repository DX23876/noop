import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// The two pills under Today's hero on Android (parity plan 2.3), as `LiquidTodayView.synthesisSection` shows them:
/// the day's readiness verdict, with the Strength and Cardio lanes as context exactly as
/// `Repository.refreshReadinessLoadContext` builds it, and the wearer's own activity status (`ActivityStatusStore`),
/// which goals, Momentum and the coach read from the same UserDefaults key.
enum CoreTodayStatus {
    struct Output: Encodable {
        /// `ReadinessEngine.Level` raw value: primed, balanced, strained, rundown or insufficient.
        var level: String
        /// `ActivityStatus.State` raw value: active, sick, injured or onBreak.
        var activity: String
        var validUntil: Int?
    }

    static func read(reader: StoreReader, maxHR: Double, sex: String, dismissedWorkoutSpans: [String],
                     now: Int = Int(Date().timeIntervalSince1970)) async -> Output {
        let offset = TimeZone.current.secondsFromGMT()
        let today = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now)))
        let lookback = TrainingLoadLanes.lookbackDays
        let from = now - lookback * 86_400
        let fusion = await TrainingSessionResolver.read(reader: reader, from: from, to: now + 86_400,
                                                        dismissedDetectedSpans: dismissedWorkoutSpans)
        let strength = await StrengthHistoryReader.read(store: reader.store, days: lookback, now: now) { fusion }
        let resolution = await CardioLoadPricing.price(fusion.sessions, reader: reader, maxHR: maxHR, sex: sex,
                                                       dataRevision: 0, cache: CardioLoadCache(),
                                                       budget: CardioLoadPricing.cardioLoadSessionBudget,
                                                       recompute: false).resolution
        let context = TrainingLoadLanes.readinessContext(
            strengthWorkouts: strength.workouts,
            cardio: TrainingLoadLanes.cardioSeries(sessions: fusion.sessions, resolution: resolution, tzOffsetSeconds: offset),
            today: today, tzOffsetSeconds: offset)
        let days = await CoreRead.dailyRows(
            from: StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now - 400 * 86_400))), to: today,
            reader: reader)
        let readiness = ReadinessEngine.evaluate(days: days, today: today, loadContext: context)
        let status = ActivityStatusStore.load()
        return Output(level: readiness.level.rawValue, activity: status.state.rawValue,
                      validUntil: status.validUntil.map { Int($0.timeIntervalSince1970) })
    }

    /// Sets the wearer's status for one of the sheet's durations (`SharedActivityStatusSheet`); `active` clears it.
    static func setActivity(state raw: String, duration: String, customUntil: Int?, now: Date = Date()) -> Bool {
        guard let state = ActivityStatus.State(rawValue: raw) else { return false }
        let choice: ActivityStatus.Duration
        switch duration {
        case "today": choice = .today
        case "threeDays": choice = .threeDays
        case "thisWeek": choice = .thisWeek
        case "custom":
            guard let customUntil else { return false }
            choice = .custom(Date(timeIntervalSince1970: TimeInterval(customUntil)))
        default: choice = .untilChanged
        }
        let until = state == .active ? nil : choice.validUntil(from: now)
        ActivityStatusStore.save(ActivityStatus(state: state, validUntil: until, setAt: now))
        return true
    }
}
