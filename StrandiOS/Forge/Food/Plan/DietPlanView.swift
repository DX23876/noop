#if os(iOS)
import SwiftUI
import StrandCore

/// The plan page under Nutrition (decision 2026-11-09): what the plan is, where it is heading, this week's look,
/// and every choice open to change. It replaces the old energy plan page in the redesign; the burn's derivation
/// stays one tap deeper.
struct DietPlanView: View {
    let model: ForgeFoodModel
    var onAsk: (String) -> Void = { _ in }
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    @AppStorage(DietPlanChange.storageKey) private var proposalRaw = ""
    @EnvironmentObject private var repo: Repository
    @State private var editing = false
    @State private var confirmEnd = false
    @State private var showProteinFoods = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let plan = model.plan, let r = model.planResult {
                    header(plan, r)
                    if !plan.hideNumbers, let progress = model.progress {
                        DietProgressCard(progress: progress,
                                         forecastLine: model.forecast().flatMap { DietForecastText.goal($0, hasGoal: r.goalWeightKg != nil) },
                                         male: model.person?.male)
                    }
                    DietWeekCard(model: model)
                    if let change = DietPlanChange.decode(proposalRaw), !change.isEmpty {
                        DietChangeCard(model: model, change: change, onDone: { proposalRaw = "" })
                    }
                    DietAdviceCard(model: model, proteinFoods: { showProteinFoods = true })
                    if coachFeatureEnabled {
                        Button { onAsk(coachPrompt(plan, r)) } label: {
                            Label("Talk it through with your coach", systemImage: "bubble.left.and.text.bubble.right.fill")
                                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered).tint(ForgeColor.accent)
                    }
                    if !plan.hideNumbers, r.goal != .maintain, r.goal != .recomp, let forecast = model.forecast() {
                        FoodSectionHeader(title: String(localized: "Where it is heading"))
                        VStack(alignment: .leading, spacing: 8) {
                            DietForecastChart(forecast: forecast, goalKg: r.goalWeightKg)
                            if let line = DietForecastText.goal(forecast, hasGoal: r.goalWeightKg != nil) { Text(line).font(.subheadline) }
                            Text("A band, not a promise. Forge redraws it every week with your real weight.")
                                .font(.footnote).foregroundStyle(ForgeColor.secondary)
                        }
                        .forgeCard(padding: 14)
                    }
                    if !plan.hideNumbers, plan.steering != .manual { DietBurnCard(model: model) }
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
        .sheet(isPresented: $showProteinFoods) {
            if let week = model.nutrients { FoodRecommendationsSheet(report: week) }
        }
        .sheet(isPresented: $editing) { DietPlannerView(model: model, start: model.plan).environmentObject(repo) }
        .confirmationDialog("End the plan?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End plan", role: .destructive) { model.savePlan(nil) }
        } message: {
            Text("Your goal goes back to your usual burn. Your logged food stays.")
        }
    }

    private func header(_ plan: DietPlan, _ r: DietTargets.Result) -> some View {
        // The picture stands without a veil and the words sit under it, so the daylight picture keeps them
        // readable as well as the night one does.
        VStack(alignment: .leading, spacing: 12) {
            Image(DietArt.goal(r.goal, male: model.person?.male)).resizable().scaledToFill()
                .frame(maxWidth: .infinity).frame(height: 190).clipped()
                .clipShape(.rect(cornerRadius: ForgeRadius.card))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(DietText.goal(r.goal)).font(ForgeFont.rounded(28, .bold)).foregroundStyle(ForgeColor.text)
                Text(subtitle(plan, r)).font(.subheadline).foregroundStyle(ForgeColor.secondary)
            }
            .padding(.horizontal, 4)
        }
        .padding(.top, 8)
    }

    /// The plan in plain words for the coach, so it answers about this plan and can propose a change to it.
    private func coachPrompt(_ plan: DietPlan, _ r: DietTargets.Result) -> String {
        var lines = [String(localized: "Look at my diet plan and tell me how it is going and what you would change.")]
        lines.append("Goal: \(r.goal.rawValue), way of eating: \(plan.form.rawValue), mode: \(plan.mode.rawValue).")
        lines.append("Average \(Int(r.averageKcal)) kcal a day, protein \(Int(r.proteinG)) g, carbs \(Int(r.carbsG)) g, fat \(Int(r.fatG)) g; usual burn \(Int(r.burnKcal)) kcal.")
        if r.goal == .lose || r.goal == .gain { lines.append("Pace \(r.pacePercent) % of body weight a week; goal weight \(r.goalWeightKg.map { String(Int($0)) } ?? "none").") }
        lines.append("Phase today: \(model.phase(for: Repository.localDayKey(.now)).rawValue). Adjustments so far: \(Int(r.adjustmentKcal)) kcal.")
        if let week = model.planWeek { lines.append("This week's check: \(week.hold?.rawValue ?? "changed \(Int(week.changeKcal)) kcal"), trend \(week.trendKgPerWeek.map { String(format: "%.2f", $0) } ?? "unknown") kg a week.") }
        if !model.advice.isEmpty { lines.append("Forge's suggestions this week: \(model.advice.map(\.kind.rawValue).joined(separator: ", ")).") }
        lines.append("If a change makes sense, propose it with propose_diet_change.")
        return lines.joined(separator: "\n")
    }

    private func subtitle(_ plan: DietPlan, _ r: DietTargets.Result) -> String {
        var parts = [DietText.form(plan.form)]
        if let a = plan.addon { parts.append(DietText.addon(a)) }
        if r.goal != .maintain && r.goal != .recomp && !plan.hideNumbers { parts.append(String(localized: "\(DietText.percent(r.pacePercent)) a week")) }
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
                if let split = DietTargets.trainingAndRestKcal(plan: plan, result: r, training: model.training, day: Repository.localDayKey(.now)) {
                    Text("Training days \(FoodText.kcal(split.training)) kcal · rest days \(FoodText.kcal(split.rest)) kcal")
                        .font(.footnote).foregroundStyle(ForgeColor.secondary)
                    Text((plan.trainingWeekdays ?? []).map(DietText.weekday).joined(separator: ", "))
                        .font(.footnote.weight(.semibold)).foregroundStyle(ForgeColor.effortInk)
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
            if plan.steering != .manual {
                DietCheckRow(title: String(localized: "More on active days"), isOn: Binding(get: { plan.activeDays == true }, set: { on in
                    model.setActiveDays(on)
                }))
                Text("When your strap measures more than your usual burn, half of the extra is added to the day, as carbohydrate.")
                    .font(.footnote).foregroundStyle(ForgeColor.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
            }
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
                Image(model.planResult.map { DietArt.goal($0.goal, male: model.person?.male) } ?? DietArt.explain("path")).resizable().scaledToFill()
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
        if r.goal == .maintain || r.goal == .recomp || plan.hideNumbers { return DietText.goal(r.goal) }
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
