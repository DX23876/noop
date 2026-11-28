#if os(iOS)
import Foundation
import StrandCore
import WhoopStore

/// The Food page's notes, goal state and badges (owner, 2026-11-21). Every figure comes from the core's one
/// resolver for it (`FoodQuality`, `FoodGoalState`, `FoodBadges`), read from the food log when the page loads, so
/// a corrected entry corrects them all.
extension ForgeFoodModel {
    /// The diet form decides whether fibre stands in for whole grains.
    var scoreOptions: FoodScore.Options { .forDiet(plan?.form) }

    /// Losing weight is the only goal that warns while logging.
    var losingWeight: Bool { plan?.goal == .lose }

    /// The goals a day is held to: the day's calorie and protein goal, the diet form's carbohydrate cap, the floor.
    func goals(for day: String) -> FoodGoalState.Goals? {
        guard let kcal = calories(for: day)?.kcal else { return nil }
        return .init(kcal: kcal, proteinG: macroGoals(for: day)?.proteinG, carbCapG: plan?.form.carbCapG,
                     floorKcal: FoodGoalState.floorKcal(basalKcal: basalKcal, male: male, goalKcal: kcal))
    }

    func loadQuality(store: WhoopStore) async {
        let today = Repository.localDayKey(.now)
        let all = (try? await store.foodLogEntries(from: "2000-01-01", to: today)) ?? []
        allEntries = all
        for id in Set(all.compactMap(\.foodId)) where !id.hasPrefix("bls:") && factsById[id] == nil {
            if let item = await FoodLibrary.item(store: store, id: id) { factsById[id] = item.scoreFacts }
        }
        let options = scoreOptions
        let usual = FoodQuality.usualKcal(entries: all, before: day) ?? calories?.kcal
        dayNote = FoodQuality.day(day, entries: all, facts: factsById, male: male, options: options, usualKcal: usual,
                                  today: today)
        weekNote = FoodQuality.period(span: FoodQuality.weekSpan, lastDay: day, entries: all, facts: factsById,
                                      male: male, options: options, today: today)
        monthNote = FoodQuality.period(span: FoodQuality.monthSpan, lastDay: day, entries: all, facts: factsById,
                                       male: male, options: options, today: today)
        weekTrend = (0..<8).reversed().compactMap { back -> FoodQuality.Note? in
            guard let last = FoodQuality.shifted(day, by: -7 * back, calendar: .current) else { return nil }
            return FoodQuality.period(span: FoodQuality.weekSpan, lastDay: last, entries: all, facts: factsById,
                                      male: male, options: options, today: today)
        }
        if let goals = goals(for: day), let totals = summary?.totals, !(summary?.entries.isEmpty ?? true) {
            goalDay = FoodGoalState.day(kcal: totals[.energyKcal] ?? 0, proteinG: totals[.proteinG] ?? 0,
                                        carbsG: totals[.carbsG] ?? 0, goals: goals)
        } else {
            goalDay = nil
        }
        let weekDays = Dictionary(grouping: all.filter { entry in
            guard let first = FoodQuality.shifted(day, by: -6, calendar: .current) else { return false }
            return entry.day >= first && entry.day <= day && entry.day < today
        }, by: \.day)
        goalWeek = goals(for: day).flatMap { goals in
            FoodGoalState.week(dailyKcal: weekDays.values.map { $0.reduce(0) { $0 + ($1.totals["energy_kcal"] ?? 0) } },
                               goals: goals)?.energy
        }
        badges = FoodBadges.summary(entries: all, facts: factsById, male: male, options: options,
                                    usualFallbackKcal: calories?.kcal, today: today)
        // The reminders carry their words, so they are planned again from the log as it now stands.
        FoodReminders.refresh(model: self)
    }

    // MARK: Notifications' content

    /// Tomorrow morning's look back on today (the week's on a Monday, the month's on the first), from the same
    /// resolvers the page reads. `newBadges` are those earned and not yet announced.
    func tomorrowRecap(today: String) -> FoodNotice.Recap? {
        guard let tomorrow = FoodQuality.shifted(today, by: 1, calendar: .current) else { return nil }
        let kind = FoodNotice.morningKind(today: tomorrow)
        let options = scoreOptions
        let note: FoodQuality.Note?
        var previous: FoodQuality.Note?
        var goal: FoodGoalState.Energy?
        switch kind {
        case .day:
            let usual = FoodQuality.usualKcal(entries: allEntries, before: today) ?? calories(for: today)?.kcal
            note = try? FoodQuality.day(today, entries: allEntries, facts: factsById, male: male, options: options,
                                        usualKcal: usual, today: tomorrow).get()
            let eaten = allEntries.filter { $0.day == today }
            let totals = NutrientAmounts.sum(eaten.map { NutrientAmounts(stored: $0.totals) })
            if !eaten.isEmpty, let goals = goals(for: today) {
                goal = FoodGoalState.day(kcal: totals[.energyKcal] ?? 0, proteinG: totals[.proteinG] ?? 0,
                                         carbsG: totals[.carbsG] ?? 0, goals: goals).energy
            }
        case .week, .month:
            let span = kind == .week ? FoodQuality.weekSpan : FoodQuality.monthSpan
            note = FoodQuality.period(span: span, lastDay: today, entries: allEntries, facts: factsById, male: male,
                                      options: options, today: tomorrow)
            if let before = FoodQuality.shifted(today, by: -span, calendar: .current) {
                previous = FoodQuality.period(span: span, lastDay: before, entries: allEntries, facts: factsById,
                                              male: male, options: options, today: tomorrow)
            }
        }
        return FoodNotice.recap(kind: kind, note: note, previous: previous, goal: goal, badges: unseenBadges)
    }

    /// What one more meal could still close today, or nil.
    func eveningGap(today: String) -> FoodNotice.Gap? {
        let eaten = allEntries.filter { $0.day == today }
        let protein = eaten.reduce(0) { $0 + ($1.totals["protein_g"] ?? 0) }
        return FoodNotice.eveningGap(proteinEatenG: protein, proteinGoalG: macroGoals(for: today)?.proteinG,
                                     vegetableGrams: FoodNotice.vegetableGrams(eaten, facts: factsById))
    }

    // MARK: Badges seen

    /// Badges already celebrated, so each is celebrated once.
    static let seenBadgesKey = "food.badges.seen"

    /// Earned badges not celebrated yet, newest last.
    var unseenBadges: [FoodBadges.Earned] {
        let seen = Set(UserDefaults.standard.stringArray(forKey: Self.seenBadgesKey) ?? [])
        return (badges?.earned ?? []).filter { !seen.contains(FoodText.badgeKey($0.badge)) }
    }

    func markBadgesSeen() {
        let keys = (badges?.earned ?? []).map { FoodText.badgeKey($0.badge) }
        UserDefaults.standard.set(keys, forKey: Self.seenBadgesKey)
        // Tomorrow's look back was planned with these badges as new; plan it again without them.
        FoodReminders.refresh(model: self)
    }
}
#endif
