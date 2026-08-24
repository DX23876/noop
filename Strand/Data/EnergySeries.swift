import Foundation
import StrandAnalytics
import WhoopStore

// EnergySeries.swift — the single place the app asks "how much did I burn?".
//
// The same shape as `WeightSeries.swift`, for the same reason: energy arrives from several stores
// that disagree about what they measure, and every screen reading them directly would eventually
// read them differently. `EnergyEngine` (StrandAnalytics, pure) owns the arithmetic; this file only
// gathers the inputs it needs out of the repository and hands back the summaries.
//
// What is gathered, and from where:
//   • `AppleDaily.activeKcal` / `.basalKcal` — Apple's split, per day (`repo.appleDailyRows()`).
//   • `DailyMetric.activeKcalEst` — the strap's whole-day HR estimate, already on `repo.days`. A
//     TOTAL for worn time, NOT an "active" figure; `EnergyEngine`'s header explains the trap.
//   • `appleStepHour` (v42's neighbour, migration v41) — hours of the day that carry any steps, the
//     movement-coverage signal. Read once for the whole window rather than per day.
//
// The existing daily-metric row also persists the number of HR seconds behind the strap estimate;
// this lets the engine top up only the unobserved basal portion without double-counting worn time.

extension Repository {

    /// Energy summaries for the trailing `days`, oldest first. One entry per day that has ANY input;
    /// a day nobody measured is simply absent rather than present with zeroes.
    ///
    /// `profile` is passed in rather than read here because `ProfileStore` is a `@MainActor`
    /// observable the caller already holds, and the BMR must come from the same profile the rest of
    /// the screen is showing.
    func energySummaries(days: Int = 30, profile: UserProfile) async -> [DailyEnergySummary] {
        let todayKey = Self.localDayKey(Date())
        let now = Date()

        let appleRows = await appleDailyRows(days: days)
        let appleByDay = Dictionary(appleRows.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
        let stepHoursByDay = await hoursWithStepsByDay(days: days)

        let calendar = Calendar.current
        let cutoffDate = calendar.date(byAdding: .day, value: -max(0, days), to: now) ?? now
        let cutoff = Self.dayString(cutoffDate)
        let strapDays = self.days.filter { $0.day >= cutoff }
        let strapByDay = Dictionary(strapDays.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })

        // TODAY is always included, even with no inputs at all. Without this the engine's
        // `.profileOnly` branch is unreachable in practice: a day with no Apple row and no strap row
        // produced no summary, so the card that exists to say "nothing recorded yet, here is your
        // estimated basal rate" simply never appeared. Past days stay data-driven — an empty card for
        // every unworn day last month would be noise, not honesty.
        let allDays = Set(appleByDay.keys).union(strapByDay.keys).union([todayKey]).sorted()
        return allDays.map { day in
            let apple = appleByDay[day]
            let strap = strapByDay[day]
            let inputs = EnergyEngine.DayInputs(
                day: day,
                appleActiveKcal: apple?.activeKcal,
                appleBasalKcal: apple?.basalKcal,
                strapTotalKcal: strap?.activeKcalEst,
                strapCoverageSeconds: strap?.energyCoverageSeconds,
                // Apple's own step total first (a phone counts all day), else the strap's.
                steps: apple?.steps ?? strap?.steps,
                hoursWithSteps: stepHoursByDay[day])
            return EnergyEngine.summarize(
                inputs,
                profile: profile,
                context: Self.energyDayContext(day: day, now: now, calendar: calendar))
        }
    }

    /// Today's summary, or nil when the day has produced nothing at all yet.
    func todayEnergy(profile: UserProfile) async -> DailyEnergySummary? {
        let todayKey = Self.localDayKey(Date())
        return await energySummaries(days: 2, profile: profile).last { $0.day == todayKey }
    }

    /// How many distinct hours of each day carry a step count — the movement-coverage signal.
    ///
    /// One windowed read for the whole range rather than a query per day: this runs on a Today load,
    /// beside a dozen other reads, and 30 round-trips for a caption would be the wrong trade.
    private func hoursWithStepsByDay(days: Int) async -> [String: Int] {
        guard let store = await storeHandle() else { return [:] }
        let calendar = Calendar.current
        let now = Date()
        let fromDate = calendar.date(byAdding: .day, value: -max(0, days), to: now) ?? now
        let toDate = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let from = Int(fromDate.timeIntervalSince1970)
        let to = Int(toDate.timeIntervalSince1970)
        guard let rows = try? await store.appleStepHours(deviceId: Self.appleHealthSource,
                                                         fromTs: from, toTs: to) else { return [:] }
        var byDay: [String: Set<Int>] = [:]
        for row in rows where row.steps > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(row.ts))
            let hour = Calendar.current.component(.hour, from: date)
            byDay[Self.localDayKey(date), default: []].insert(hour)
        }
        return byDay.mapValues(\.count)
    }

    /// Real local-day bounds for the energy engine. Calendar arithmetic is essential here: daylight-
    /// saving transitions produce 23- and 25-hour days, for which a fixed 86,400 denominator makes both
    /// basal accrual and the active-energy projection wrong.
    nonisolated static func energyDayContext(day: String, now: Date = Date(),
                                             calendar: Calendar = .current) -> EnergyEngine.DayContext {
        var parseCalendar = calendar
        parseCalendar.locale = Locale(identifier: "en_US_POSIX")
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let start = parseCalendar.date(from: DateComponents(
                calendar: parseCalendar, timeZone: parseCalendar.timeZone,
                year: parts[0], month: parts[1], day: parts[2])),
              let end = parseCalendar.date(byAdding: .day, value: 1, to: start) else {
            return .completePastDay
        }
        let duration = end.timeIntervalSince(start)
        let isToday = parseCalendar.isDate(now, inSameDayAs: start)
        return EnergyEngine.DayContext(isToday: isToday,
                                       dayDurationSeconds: duration,
                                       elapsedSeconds: isToday ? now.timeIntervalSince(start) : duration)
    }

    /// The `UserProfile` the analytics package expects, from the app's `ProfileStore`. One conversion
    /// site, so the BMR behind the energy card and the BMR behind a workout's calories are the same
    /// person. Main-actor isolated because `ProfileStore` is — callers read it where they already
    /// hold the profile, which is on the main actor anyway.
    @MainActor
    static func analyticsProfile(_ profile: ProfileStore) -> UserProfile {
        UserProfile(weightKg: profile.weightKg,
                    heightCm: profile.heightCm,
                    age: Double(profile.age),
                    sex: profile.sex)
    }
}
