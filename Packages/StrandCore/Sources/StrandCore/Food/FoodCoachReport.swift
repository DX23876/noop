import Foundation
import WhoopStore

/// What the coach reads about the food log (owner, 2026-11-21, `backlog/ideas/food-score-coach-2026-11-21.md`):
/// one line per day for any span (energy, macros, the day's note and goal), the single entries for at most 14
/// days, the week's and the 28 days' note with their parts, the nutrient gaps over 28 days against the EFSA
/// references, and the streak and badges. Every figure comes from the resolver the Food page reads
/// (`FoodQuality`, `FoodGoalState`, `FoodBadges`, `FoodNutrientReport`), so the coach and the page can never
/// disagree. Plain text in the coach's KEY: value style, shared by both platforms.
public enum FoodCoachReport {
    /// Entries are listed for at most this many days per request; longer spans get the day lines only.
    public static let entryDaysLimit = 14

    public struct Context {
        public var facts: [String: FoodScore.FoodFacts]
        public var male: Bool?
        public var options: FoodScore.Options
        /// The goals a day was held to; nil where none is known (no calorie goal on this platform yet).
        public var goals: (String) -> FoodGoalState.Goals?
        public var references: [FoodNutrient: FoodReference.Value]
        public var dietLine: String?

        public init(facts: [String: FoodScore.FoodFacts] = [:], male: Bool?, options: FoodScore.Options = .init(),
                    goals: @escaping (String) -> FoodGoalState.Goals? = { _ in nil },
                    references: [FoodNutrient: FoodReference.Value] = [:], dietLine: String? = nil) {
            self.facts = facts; self.male = male; self.options = options; self.goals = goals
            self.references = references; self.dietLine = dietLine
        }
    }

    /// The report for `from`…`to` (both included). `all` is the whole log, so notes, the usual intake and the
    /// badges see the days before the span too.
    public static func text(all: [FoodLogEntry], from: String, to: String, includeEntries: Bool, today: String,
                            context: Context, calendar: Calendar = .current) -> String {
        let inSpan = all.filter { $0.day >= from && $0.day <= to }
        var lines = ["FOOD LOG \(from) to \(to) (today \(today)). Logged by the user in NOOP; amounts as logged."]
        lines.append("NOTES are 0 to 10 after the Alternate Healthy Eating Index with the owner's choices: a day scores its own food, but fish, nuts and pulses and meat over the 7 days ending on it; week and month add the amounts up first and score once, so they can differ from the day notes. A day counts from half the usual intake; PROVISIONAL means today is still being eaten. Describe links between food and other data as observations, never as causes.")
        if let diet = context.dietLine { lines.append("DIET_PLAN: \(diet)") }
        guard !all.isEmpty else {
            lines.append("NO_ENTRIES: the user has logged no food. Say so; do not guess what they eat.")
            return lines.joined(separator: "\n")
        }
        let byDay = Dictionary(grouping: inSpan, by: \.day)
        if byDay.isEmpty { lines.append("NO_ENTRIES_IN_SPAN") }
        for day in byDay.keys.sorted() {
            let entries = byDay[day]!
            let totals = NutrientAmounts.sum(entries.map { NutrientAmounts(stored: $0.totals) })
            var parts = ["\(day):", "kcal \(int(totals[.energyKcal]))", "protein \(int(totals[.proteinG])) g",
                         "carbs \(int(totals[.carbsG])) g", "fat \(int(totals[.fatG])) g", "fibre \(int(totals[.fiberG])) g"]
            let usual = FoodQuality.usualKcal(entries: all, before: day) ?? context.goals(day)?.kcal
            switch FoodQuality.day(day, entries: all, facts: context.facts, male: context.male, options: context.options,
                                   usualKcal: usual, today: today, calendar: calendar) {
            case .success(let note):
                parts.append("note \(one(note.score))\(note.provisional ? " PROVISIONAL" : "")\(note.uncertain ? " UNCERTAIN (\(percent(1 - note.placedShare)) of energy without a food group)" : "")")
            case .failure(let error):
                if case .tooLittle = error.reason { parts.append("no note (less than half the usual intake logged)") }
            }
            if let goals = context.goals(day) {
                let state = FoodGoalState.day(kcal: totals[.energyKcal] ?? 0, proteinG: totals[.proteinG] ?? 0,
                                              carbsG: totals[.carbsG] ?? 0, goals: goals)
                parts.append("goal \(int(goals.kcal)) kcal: \(state.energy.rawValue)"
                             + (state.proteinMet.map { $0 ? ", protein met" : ", protein under goal" } ?? "")
                             + (state.carbsWithinCap.map { $0 ? ", carbs within cap" : ", carbs over cap" } ?? ""))
            }
            lines.append(parts.joined(separator: " · "))
        }
        if includeEntries {
            let days = byDay.keys.sorted()
            if days.count > entryDaysLimit {
                lines.append("ENTRIES: not listed, the span has \(days.count) logged days (at most \(entryDaysLimit)). Ask for a shorter span.")
            } else {
                lines.append("ENTRIES:")
                for entry in inSpan.sorted(by: { $0.loggedAt < $1.loggedAt }) {
                    let time = Date(timeIntervalSince1970: TimeInterval(entry.loggedAt)).formatted(.dateTime.hour().minute())
                    let amount = entry.grams.map { "\(int($0)) g" } ?? "no amount"
                    let t = entry.totals
                    lines.append("- \(entry.day) \(time) \(entry.meal ?? "") \(entry.name) (\(amount)): \(int(t["energy_kcal"])) kcal, P \(int(t["protein_g"])) g, C \(int(t["carbs_g"])) g, F \(int(t["fat_g"])) g")
                }
            }
        }
        for span in [FoodQuality.weekSpan, FoodQuality.monthSpan] {
            guard let note = FoodQuality.period(span: span, lastDay: to, entries: all, facts: context.facts, male: context.male,
                                                options: context.options, today: today, calendar: calendar) else {
                lines.append("NOTE_\(span)_DAYS: none (too few logged days)")
                continue
            }
            let parts = note.parts.sorted { $0.points > $1.points }
                .map { "\($0.component.rawValue) \(one($0.points))/10 (\(one($0.amountPerDay)) a day)" }
            lines.append("NOTE_\(span)_DAYS ending \(to): \(one(note.score))/10 from \(note.loggedDays) logged days. Parts: \(parts.joined(separator: ", "))"
                         + (note.processedShare.map { ". Highly processed: \(percent($0)) of energy" } ?? ""))
        }
        if !context.references.isEmpty, let start = FoodQuality.shifted(to, by: -27, calendar: calendar) {
            let report = FoodNutrientReport.report(entries: all.filter { $0.day >= start && $0.day <= to }, from: start, to: to,
                                                   references: context.references)
            let gaps = report.rows.compactMap { row -> String? in
                guard let reference = row.reference, row.coverage >= 0.5 else { return nil }
                switch reference.kind {
                case .atLeast where row.average < reference.amount * 0.8:
                    return "\(row.nutrient.rawValue) \(two(row.average)) of at least \(two(reference.amount))"
                case .atMost where row.average > reference.amount:
                    return "\(row.nutrient.rawValue) \(two(row.average)) over the limit \(two(reference.amount))"
                default: return nil
                }
            }
            lines.append("NUTRIENTS_28_DAYS (average per logged day against EFSA/WHO, only nutrients most foods state): "
                         + (gaps.isEmpty ? "no gaps" : gaps.joined(separator: "; ")))
        }
        let summary = FoodBadges.summary(entries: all, facts: context.facts, male: context.male, options: context.options,
                                         usualFallbackKcal: context.goals(today)?.kcal, today: today)
        lines.append("STREAK: \(summary.streakDays) days logged in a row. BADGES: "
                     + (summary.earned.isEmpty ? "none yet" : summary.earned.map { "\($0.badge) (\($0.day))" }.joined(separator: ", ")))
        return lines.joined(separator: "\n")
    }

    private static func int(_ value: Double?) -> String { String(Int((value ?? 0).rounded())) }
    private static func one(_ value: Double) -> String { String(format: "%.1f", value) }
    private static func two(_ value: Double) -> String { String(format: value < 10 ? "%.2f" : "%.0f", value) }
    private static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded())) %" }
}
