#if os(iOS)
import SwiftUI
import StrandCore

/// The coach's proposed plan change (owner, 2026-11-10): what it changes, today's calories before and after, the coach's
/// reason, and the choice. Confirming applies it through `DietPlanChange` and the plan save, with every safety line.
struct DietChangeCard: View {
    let model: ForgeFoodModel
    let change: DietPlanChange
    let onDone: () -> Void

    private var next: DietPlan? {
        guard let plan = model.plan else { return nil }
        return change.apply(to: plan, today: today, weightKg: model.currentWeightKg ?? plan.startWeightKg)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your coach suggests", systemImage: "bubble.left.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(ForgeColor.secondary)
            ForEach(lines, id: \.self) { Label($0, systemImage: "arrow.right.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(ForgeColor.text) }
            if !change.rationale.isEmpty {
                Text(change.rationale).font(.subheadline).foregroundStyle(ForgeColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let plan = model.plan, let next, let before = model.plannedKcal(on: today, plan: plan),
               let after = model.plannedKcal(on: today, plan: next) {
                Text("Today: \(FoodText.kcal(before)) kcal → \(FoodText.kcal(after)) kcal")
                    .font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(ForgeColor.text)
            }
            HStack(spacing: 10) {
                Button("Apply") {
                    if let next { model.savePlan(next) }
                    onDone()
                }
                .buttonStyle(.borderedProminent).tint(ForgeColor.accent)
                Button("Not now", action: onDone).buttonStyle(.borderless).foregroundStyle(ForgeColor.secondary)
            }
            .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .forgeCard(padding: 14)
    }

    private var today: String { Repository.localDayKey(.now) }

    private var lines: [String] {
        var out: [String] = []
        if let g = change.goal { out.append(String(localized: "Goal: \(DietText.goal(g))")) }
        if let p = change.pacePercent { out.append(String(localized: "Pace: \(DietText.percent(p)) a week")) }
        if let f = change.form { out.append(String(localized: "Way of eating: \(DietText.form(f))")) }
        if let b = change.dietBreakEveryWeeks {
            out.append(b == 0 ? String(localized: "No diet breaks") : String(localized: "A week at maintenance every \(b) weeks"))
        }
        if let s = change.dayShift { out.append(String(localized: "Moved to training days: \(DietText.percent(s * 100))")) }
        if change.breakWeekNow == true { out.append(String(localized: "A break week from today")) }
        return out
    }
}
#endif
