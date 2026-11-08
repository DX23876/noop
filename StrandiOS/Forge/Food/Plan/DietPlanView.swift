#if os(iOS)
import SwiftUI
import StrandCore

/// The plan page under Nutrition (decision 2026-11-09): what the plan is, where it is heading, this week's look,
/// and every choice open to change. It replaces the old energy plan page in the redesign; the burn's derivation
/// stays one tap deeper.
struct DietPlanView: View {
    let model: ForgeFoodModel
    @EnvironmentObject private var repo: Repository
    @State private var editing = false
    @State private var confirmEnd = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let plan = model.plan, let r = model.planResult {
                    header(plan, r)
                    DietWeekCard(model: model)
                    if !plan.hideNumbers, r.goal != .maintain, let forecast = model.forecast() {
                        FoodSectionHeader(title: String(localized: "Where it is heading"))
                        VStack(alignment: .leading, spacing: 8) {
                            DietForecastChart(forecast: forecast, goalKg: r.goalWeightKg)
                            if let line = DietForecastText.goal(forecast, hasGoal: r.goalWeightKg != nil) { Text(line).font(.subheadline) }
                            Text("A band, not a promise. Forge redraws it every week with your real weight.")
                                .font(.footnote).foregroundStyle(ForgeColor.secondary)
                        }
                        .forgeCard(padding: 14)
                    }
                    FoodSectionHeader(title: String(localized: "Every day"))
                    numbers(plan, r)
                    FoodSectionHeader(title: String(localized: "Foods that suit it"))
                    fits(plan)
                    ForEach(r.notes, id: \.self) { n in
                        Label(DietText.note(n), systemImage: "info.circle").font(.footnote).foregroundStyle(ForgeColor.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).forgeCard(padding: 12)
                    }
                    actions(plan)
                } else {
                    empty
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .today))
        .navigationTitle("Plan")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) { DietPlannerView(model: model, start: model.plan).environmentObject(repo) }
        .confirmationDialog("End the plan?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End plan", role: .destructive) { model.savePlan(nil) }
        } message: {
            Text("Your goal goes back to your usual burn. Your logged food stays.")
        }
    }

    private func header(_ plan: DietPlan, _ r: DietTargets.Result) -> some View {
        ZStack(alignment: .bottomLeading) {
            Image(DietArt.form(plan.form)).resizable().scaledToFill()
                .frame(maxWidth: .infinity).frame(height: 190).clipped()
                .overlay { LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(DietText.goal(r.goal)).font(ForgeFont.rounded(28, .bold)).foregroundStyle(ForgeColor.onDarkPhoto)
                Text(subtitle(plan, r)).font(.subheadline).foregroundStyle(ForgeColor.onDarkPhotoSecondary)
            }
            .padding(16)
        }
        .clipShape(.rect(cornerRadius: ForgeRadius.card))
        .padding(.top, 8)
    }

    private func subtitle(_ plan: DietPlan, _ r: DietTargets.Result) -> String {
        var parts = [DietText.form(plan.form)]
        if let a = plan.addon { parts.append(DietText.addon(a)) }
        if r.goal != .maintain && !plan.hideNumbers { parts.append(String(localized: "\(DietText.percent(r.pacePercent)) a week")) }
        parts.append(plan.mode == .simple ? String(localized: "Simple") : String(localized: "Advanced"))
        return parts.joined(separator: " · ")
    }

    private func numbers(_ plan: DietPlan, _ r: DietTargets.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !plan.hideNumbers {
                HStack(alignment: .firstTextBaseline) {
                    Text(FoodText.kcal(r.averageKcal)).font(ForgeFont.rounded(34, .bold)).monospacedDigit()
                    Text("kcal a day").foregroundStyle(ForgeColor.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        DietEffortDots(effort: Int(r.effortScore.rounded()))
                        Text(DietText.effort(r.effort)).font(.caption).foregroundStyle(DietText.effortTint(r.effortScore))
                    }
                }
                if let fast = r.fastingDayKcal {
                    Text("Eating days \(FoodText.kcal(r.eatingDayKcal)) kcal, fasting days \(FoodText.kcal(fast)) kcal")
                        .font(.footnote).foregroundStyle(ForgeColor.secondary)
                }
                if r.adjustmentKcal != 0 {
                    Text(r.adjustmentKcal < 0 ? String(localized: "Forge has lowered it by \(FoodText.kcal(-r.adjustmentKcal)) kcal so far, from your trend.")
                                              : String(localized: "Forge has raised it by \(FoodText.kcal(r.adjustmentKcal)) kcal so far, from your trend."))
                        .font(.footnote).foregroundStyle(ForgeColor.secondary)
                }
            }
            HStack(spacing: 0) {
                macro(String(localized: "Protein"), r.proteinG, ForgeColor.protein)
                macro(String(localized: "Carbs"), r.carbsG, ForgeColor.carbs)
                macro(String(localized: "Fat"), r.fatG, ForgeColor.fat)
            }
            NavigationLink { EnergyPlanView() } label: {
                HStack { Text("How your burn is worked out"); Spacer(); Image(systemName: "chevron.right") }
                    .font(.subheadline).foregroundStyle(ForgeColor.accent)
            }
        }
        .forgeCard(padding: 14)
    }

    private func macro(_ name: String, _ grams: Double, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) { Circle().fill(tint).frame(width: 8, height: 8); Text(name).font(.footnote).foregroundStyle(ForgeColor.secondary) }
            Text("\(FoodText.grams(grams)) g").font(ForgeFont.rounded(18, .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private func fits(_ plan: DietPlan) -> some View {
        let good = plan.form.suits.filter { plan.form.fit($0, addon: plan.addon) > 0 }
        let rare = Array(Set(plan.form.keepsRare + (plan.addon?.leavesOut ?? []))).sorted { $0.rawValue < $1.rawValue }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Often").font(.subheadline.weight(.semibold))
            motifRow(good)
            Text(plan.addon == nil ? String(localized: "Now and then") : String(localized: "Now and then, or not at all"))
                .font(.subheadline.weight(.semibold))
            motifRow(rare)
            Text("Foods that suit your plan carry a small leaf when you add them. Nothing is forbidden.")
                .font(.footnote).foregroundStyle(ForgeColor.secondary)
        }
        .forgeCard(padding: 14)
    }

    private func motifRow(_ motifs: [FoodGroupMotif]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(motifs, id: \.self) { m in
                    VStack(spacing: 4) {
                        Image(FoodMealPicture.assetName(m)).resizable().scaledToFill()
                            .frame(width: 72, height: 54).clipShape(.rect(cornerRadius: 10))
                        Text(FoodText.motif(m)).font(.caption2).foregroundStyle(ForgeColor.secondary).lineLimit(1)
                    }
                    .frame(width: 76)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func actions(_ plan: DietPlan) -> some View {
        VStack(spacing: 10) {
            DietCheckRow(title: String(localized: "Hide weight and numbers"), isOn: Binding(get: { plan.hideNumbers }, set: { on in
                var next = plan; next.hideNumbers = on; model.savePlan(next)
            }))
            Button { editing = true } label: {
                Text("Change plan").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(ForgeColor.onAccent).background(ForgeColor.accent, in: .capsule)
            }
            .buttonStyle(.plain)
            Button("End plan", role: .destructive) { confirmEnd = true }.frame(minHeight: 44)
        }
        .padding(.top, 8)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 16) {
            DietExplainCard(image: DietArt.explain("path"), title: DietText.explainStartTitle, text: DietText.explainStart)
            Button { editing = true } label: {
                Text("Plan your diet").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(ForgeColor.onAccent).background(ForgeColor.accent, in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }
}

/// This week's look at the plan: what Forge changed (with undo) or proposes, or why it holds still.
struct DietWeekCard: View {
    let model: ForgeFoodModel

    var body: some View {
        if let week = model.planWeek {
            VStack(alignment: .leading, spacing: 8) {
                Label("This week", systemImage: "calendar").font(.subheadline.weight(.semibold)).foregroundStyle(ForgeColor.secondary)
                if let hold = week.hold {
                    Text(DietText.hold(hold)).font(.body)
                } else {
                    Text(message(week)).font(.body)
                    HStack {
                        if model.planWeekApplied {
                            Button("Undo") { model.declinePlanChange() }.buttonStyle(.bordered)
                        } else {
                            Button("Change it") { model.acceptPlanChange() }.buttonStyle(.borderedProminent).tint(ForgeColor.accent)
                            Button("Keep my goal") { model.declinePlanChange() }.buttonStyle(.bordered)
                        }
                    }
                }
                if let trend = week.trendKgPerWeek, !(model.plan?.hideNumbers ?? false) {
                    Text("Trend \(DietText.kg(trend)) a week, planned \(DietText.kg(week.plannedKgPerWeek)).")
                        .font(.footnote).foregroundStyle(ForgeColor.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .forgeCard(padding: 14)
        }
    }

    private func message(_ week: DietAdjust.Outcome) -> String {
        let amount = FoodText.kcal(abs(week.changeKcal))
        let slower = week.changeKcal < 0
        if model.planWeekApplied {
            return slower ? String(localized: "Your weight moved slower than planned, so your goal is \(amount) kcal lower from today.")
                          : String(localized: "Your weight moved faster than planned, so your goal is \(amount) kcal higher from today.")
        }
        return slower ? String(localized: "Your weight moved slower than planned. Lower your goal by \(amount) kcal?")
                      : String(localized: "Your weight moved faster than planned. Raise your goal by \(amount) kcal?")
    }
}

/// The plan in one line at the top of Nutrition; a tap opens the plan page. Without a plan it invites to make one.
struct DietPlanLine: View {
    let model: ForgeFoodModel
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(model.plan.map { DietArt.form($0.form) } ?? DietArt.explain("path")).resizable().scaledToFill()
                    .frame(width: 40, height: 40).clipShape(.circle).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(ForgeColor.text)
                    Text(detail).font(.footnote).foregroundStyle(ForgeColor.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(ForgeColor.secondary)
            }
            .padding(10)
            .background(ForgeColor.fill.opacity(0.6), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        guard let plan = model.plan, let r = model.planResult else { return String(localized: "Plan your diet") }
        if r.goal == .maintain || plan.hideNumbers { return DietText.goal(r.goal) }
        return String(localized: "\(DietText.goal(r.goal)) · \(DietText.percent(r.pacePercent)) a week")
    }

    private var detail: String {
        guard let plan = model.plan else { return String(localized: "Goal, pace, way of eating and a forecast") }
        var parts = [DietText.form(plan.form)]
        if let week = model.planWeek {
            parts.append(week.hold == .onPlan ? String(localized: "on plan") : week.hold == nil ? String(localized: "new goal this week") : String(localized: "watching"))
        }
        return parts.joined(separator: " · ")
    }
}
#endif
