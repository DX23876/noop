#if os(iOS)
import SwiftUI
import StrandCore

/// Seven small plates for the week: calories against the goal outside, protein, carbohydrate and fat inside, the
/// weekday under each. A tap shows that day. A day without a log is a faint ring with no fill.
struct FoodWeekStrip: View {
    let week: [ForgeFoodModel.WeekDay]
    let shownDay: String
    /// Each day's own goals: a fasting day or an active day has its own, so no plate is measured against another day's.
    let calorieGoal: (String) -> Double?
    let macroGoals: (String) -> FoodTargets.Macros?
    let select: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(week) { day in
                Button { select(day.day) } label: { column(day) }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Text(label(day)))
                    .accessibilityAddTraits(day.day == shownDay ? .isSelected : [])
            }
        }
    }

    private func column(_ day: ForgeFoodModel.WeekDay) -> some View {
        let shown = day.day == shownDay
        let kcalGoal = calorieGoal(day.day), macros = macroGoals(day.day)
        return VStack(spacing: 6) {
            FoodMiniPlate(kcal: share(day.totals[.energyKcal], kcalGoal),
                          macros: [share(day.totals[.proteinG], macros?.proteinG),
                                   share(day.totals[.carbsG], macros?.carbsG),
                                   share(day.totals[.fatG], macros?.fatG)])
                .opacity(day.logged ? 1 : 0.45)
            Text(weekday(day.day)).font(.caption.weight(shown ? .bold : .regular))
                .foregroundStyle(shown ? ForgeColor.text : ForgeColor.secondary)
            Circle().fill(shown ? ForgeColor.food : .clear).frame(width: 4, height: 4)
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
    }

    private func share(_ value: Double?, _ goal: Double?) -> Double {
        guard let value, let goal, goal > 0 else { return 0 }
        return value / goal
    }

    private func weekday(_ day: String) -> String {
        guard let date = WeightSeries.date(forDay: day) else { return "" }
        return date.formatted(.dateTime.weekday(.abbreviated).locale(AppLanguage.activeLocale))
    }

    private func label(_ day: ForgeFoodModel.WeekDay) -> String {
        let name = WeightSeries.date(forDay: day.day)?.formatted(.dateTime.weekday(.wide).locale(AppLanguage.activeLocale)) ?? day.day
        guard day.logged else { return String(localized: "\(name), nothing logged") }
        return String(localized: "\(name), \(FoodText.kcal(day.totals[.energyKcal])) kcal")
    }
}

/// A plate of four thin rings, small enough for a week in one row. Plain strokes without glow: seven of them
/// side by side stay calm.
struct FoodMiniPlate: View {
    let kcal: Double
    let macros: [Double]
    var size: CGFloat = 40

    private let tints = [ForgeColor.protein, ForgeColor.carbs, ForgeColor.fat]

    var body: some View {
        ZStack {
            ring(kcal, ForgeColor.food, diameter: size, line: 4.5)
            ForEach(Array(macros.prefix(3).enumerated()), id: \.offset) { index, share in
                ring(share, tints[index], diameter: size - 10 - CGFloat(index) * 8, line: 3)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func ring(_ share: Double, _ tint: Color, diameter: CGFloat, line: CGFloat) -> some View {
        ZStack {
            Circle().stroke(tint.opacity(ForgeOpacity.wash), lineWidth: line)
            Circle().trim(from: 0, to: min(1, max(0, share)))
                .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter - line, height: diameter - line)
    }
}
#endif
