#if os(iOS)
import SwiftUI
import StrandCore
import WhoopStore

/// The diet planner (decision 2026-11-09): a guided walk from the goal to a forecast, one question a step, every
/// choice with a picture and a "why". The simple mode asks what common apps ask and sets the numbers itself; the
/// advanced mode opens every dial. The same safety lines hold in both (`DietTargets`).
struct DietPlannerView: View {
    let model: ForgeFoodModel
    var start: DietPlan?
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DietPlan
    @State private var step = 0
    @State private var likesRules = false
    @State private var suggestions: [DietSuggest.Suggestion] = []
    @State private var recent: [FoodLogEntryLite] = []
    @State private var goalWeightText = ""

    private enum Step: Int, CaseIterable { case welcome, goal, weight, pace, life, form, addon, numbers, summary }

    init(model: ForgeFoodModel, start: DietPlan? = nil) {
        self.model = model
        self.start = start
        let weight = model.currentWeightKg ?? start?.startWeightKg ?? 80
        _draft = State(initialValue: start ?? DietPlan(startDay: Repository.localDayKey(.now), startWeightKg: weight))
        _goalWeightText = State(initialValue: start?.goalWeightKg.map { String(format: "%.1f", $0) } ?? "")
    }

    private var person: DietPerson {
        model.person ?? DietPerson(weightKg: draft.startWeightKg, heightCm: nil, age: nil, male: nil)
    }
    private var burn: Double { model.planBurnKcal ?? person.weightKg * 30 }
    private var result: DietTargets.Result {
        DietTargets.resolve(draft, person: person, burnKcal: burn, kcalPerKg: model.kcalPerKg)
    }
    private var current: Step { Step(rawValue: step) ?? .welcome }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ProgressView(value: Double(step + 1), total: Double(Step.allCases.count)).tint(ForgeColor.accent)
                    content
                }
                .padding(16)
                .padding(.bottom, 120)
                .animation(.smooth, value: step)
            }
            .background(ForgeBackground(tab: .today))
            .safeAreaInset(edge: .bottom) { footer }
            .navigationTitle("Plan your diet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if step > 0 {
                    ToolbarItem(placement: .topBarLeading) { Button("Back", systemImage: "chevron.left") { step -= 1 }.labelStyle(.iconOnly) }
                }
            }
            .task { await loadRecent() }
            .onChange(of: draft.keep) { refreshSuggestions() }
            .onChange(of: draft.strength) { refreshSuggestions() }
            .onChange(of: likesRules) { refreshSuggestions() }
            .onChange(of: draft.mode) { refreshSuggestions(); clampToMode() }
            .sensoryFeedback(.selection, trigger: step)
        }
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch current {
        case .welcome: welcome
        case .goal: goalStep
        case .weight: weightStep
        case .pace: paceStep
        case .life: lifeStep
        case .form: formStep
        case .addon: addonStep
        case .numbers: numbersStep
        case .summary: summaryStep
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            DietExplainCard(image: DietArt.explain("path"), title: DietText.explainStartTitle, text: DietText.explainStart)
            title("How much do you want to set yourself?")
            HStack(spacing: 12) {
                DietChoiceCard(image: DietArt.goal(.maintain), title: String(localized: "Simple"),
                               detail: String(localized: "A few questions. Forge sets calories and macros and adjusts them every week."),
                               selected: draft.mode == .simple) { draft.mode = .simple }
                DietChoiceCard(image: DietArt.form(.highProtein), title: String(localized: "Advanced"),
                               detail: String(localized: "Every dial: pace, macros, fasting forms, diet breaks. Also settings Forge does not suggest."),
                               selected: draft.mode == .advanced) { draft.mode = .advanced }
            }
        }
    }

    private var goalStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("What is your goal?")
            ForEach(DietPlan.Goal.allCases, id: \.self) { g in
                DietChoiceCard(image: DietArt.goal(g), title: DietText.goal(g), detail: DietText.goalDetail(g),
                               selected: draft.goal == g) {
                    draft.goal = g
                    if draft.pacePercent == 0 || g == .gain { draft.pacePercent = DietPlan.Pace.normal.percent(for: g) }
                }
            }
            if person.male != true {
                Toggle("I am pregnant or nursing", isOn: $draft.pregnantOrNursing).forgeCard(padding: 12)
            }
        }
    }

    private var weightStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Where do you start?")
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Today", value: DietText.kg(person.weightKg))
                LabeledContent("Usual burn", value: "\(FoodText.kcal(burn)) kcal")
                Text("Forge takes these from your weigh-ins and from what your strap measured over the last weeks.")
                    .font(.footnote).foregroundStyle(ForgeColor.secondary)
            }
            .forgeCard(padding: 12)
            if draft.goal != .maintain {
                title("A goal weight? It is optional.")
                HStack {
                    TextField("For example 90", text: $goalWeightText).keyboardType(.decimalPad)
                        .onChange(of: goalWeightText) { draft.goalWeightKg = Double(goalWeightText.replacingOccurrences(of: ",", with: ".")) }
                    Text("kg").foregroundStyle(ForgeColor.secondary)
                }
                .font(.title3).forgeCard(padding: 12)
                if result.notes.contains(.goalWeightRaised), let g = result.goalWeightKg {
                    notice(String(localized: "The lowest healthy weight for your height is about \(DietText.kg(g)). Forge plans to that."))
                }
            }
        }
    }

    private var paceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if draft.goal == .maintain {
                title("No pace needed")
                Text("Holding your weight means eating about as much as you burn. Forge keeps an eye on the trend.")
                    .foregroundStyle(ForgeColor.secondary)
            } else {
                title("How fast?")
                if draft.mode == .simple {
                    ForEach(DietPlan.Pace.allCases, id: \.self) { p in
                        let pct = p.percent(for: draft.goal)
                        DietChoiceCard(image: DietArt.goal(draft.goal), title: DietText.pace(p),
                                       detail: String(localized: "\(DietText.percent(pct)) of your weight a week, for you about \(DietText.kg(person.weightKg * pct / 100))."),
                                       selected: abs(draft.pacePercent - pct) < 0.01) { draft.pacePercent = pct }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(DietText.percent(draft.pacePercent)) a week")
                            Spacer()
                            Text(DietText.kg(person.weightKg * draft.pacePercent / 100)).foregroundStyle(ForgeColor.secondary)
                        }
                        .font(.headline)
                        Slider(value: $draft.pacePercent, in: 0.1...DietPlan.paceLimit(goal: draft.goal, mode: .advanced), step: 0.05)
                            .tint(ForgeColor.food)
                    }
                    .forgeCard(padding: 12)
                }
                ForEach(result.notes.filter { $0 == .paceAboveRecommended }, id: \.self) { notice(DietText.note($0)) }
                if draft.goal == .lose {
                    DietExplainCard(image: DietArt.explain("pace"), title: DietText.explainPaceTitle, text: DietText.explainPace)
                }
            }
        }
    }

    private var lifeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("What would you not give up?")
            Text("Forge suggests ways of eating that keep these.").font(.footnote).foregroundStyle(ForgeColor.secondary)
            DietChips(items: DietPlan.Keep.allCases, label: DietText.keep, isOn: { draft.keep.contains($0) }) { k in
                if let i = draft.keep.firstIndex(of: k) { draft.keep.remove(at: i) } else { draft.keep.append(k) }
            }
            Toggle("Clear rules are easier for me than moderation", isOn: $likesRules).forgeCard(padding: 12)
            Toggle("I do strength training", isOn: $draft.strength).forgeCard(padding: 12)
        }
    }

    private var formStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("How do you want to eat?")
            if !suggestions.isEmpty {
                Text("Suggested for you").font(.subheadline.weight(.semibold)).foregroundStyle(ForgeColor.secondary)
                ForEach(suggestions, id: \.form) { s in formCard(s.form, badge: DietText.reason(s.reason)) }
            }
            DietExplainCard(image: DietArt.form(.mediterranean), title: DietText.explainFormsTitle, text: DietText.explainForms)
            Text("All ways of eating").font(.subheadline.weight(.semibold)).foregroundStyle(ForgeColor.secondary)
            ForEach(DietForm.allCases.filter { f in
                (draft.mode == .advanced || !f.advancedOnly) && !suggestions.contains { $0.form == f }
            }, id: \.self) { formCard($0, badge: nil) }
        }
    }

    private func formCard(_ f: DietForm, badge: String?) -> some View {
        let detail = [DietText.formWhy(f), DietText.formWatch(f)].compactMap { $0 }.joined(separator: " ")
        return DietChoiceCard(image: DietArt.form(f), title: DietText.form(f), detail: detail, badge: badge,
                              effort: f.effort, selected: draft.form == f) {
            draft.form = f
            if let addon = draft.addon, !addon.fits(f) { draft.addon = nil }
        }
    }

    private var addonStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Anything you leave out?")
            ForEach([DietAddon?.none] + DietAddon.allCases.map { Optional($0) }, id: \.self) { a in
                let blocked = a.map { !$0.fits(draft.form) } ?? false
                DietChoiceCard(image: DietArt.addon(a), title: DietText.addon(a),
                               detail: blocked ? String(localized: "Does not go with keto.") : DietText.addonDetail(a),
                               selected: draft.addon == a) { if !blocked { draft.addon = a } }
                    .opacity(blocked ? 0.4 : 1)
            }
        }
    }

    private var numbersStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Your numbers")
            numbersCard
            if draft.mode == .advanced { advancedDials }
            ForEach(result.notes.filter { $0 != .goalWeightRaised && $0 != .paceAboveRecommended }, id: \.self) { notice(DietText.note($0)) }
        }
    }

    private var numbersCard: some View {
        let r = result
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(FoodText.kcal(r.averageKcal)).font(ForgeFont.rounded(40, .bold)).monospacedDigit()
                    .contentTransition(.numericText())
                Text("kcal a day").foregroundStyle(ForgeColor.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    DietEffortDots(effort: Int(r.effortScore.rounded()))
                    Text(DietText.effort(r.effort)).font(.caption).foregroundStyle(DietText.effortTint(r.effortScore))
                }
            }
            if let fast = r.fastingDayKcal, let days = r.fastingDaysPerWeek {
                Text("Eating days \(FoodText.kcal(r.eatingDayKcal)) kcal · \(days.formatted(.number.precision(.fractionLength(0...1)))) fasting days a week at \(FoodText.kcal(fast)) kcal")
                    .font(.footnote).foregroundStyle(ForgeColor.secondary)
            }
            HStack(spacing: 0) {
                macro(String(localized: "Protein"), r.proteinG, ForgeColor.protein)
                macro(String(localized: "Carbs"), r.carbsG, ForgeColor.carbs)
                macro(String(localized: "Fat"), r.fatG, ForgeColor.fat)
            }
            Text(r.dailyDeltaKcal < 0
                 ? String(localized: "Your usual burn is \(FoodText.kcal(r.burnKcal)) kcal. The plan eats \(FoodText.kcal(-r.dailyDeltaKcal)) less a day.")
                 : r.dailyDeltaKcal > 0 ? String(localized: "Your usual burn is \(FoodText.kcal(r.burnKcal)) kcal. The plan eats \(FoodText.kcal(r.dailyDeltaKcal)) more a day.")
                 : String(localized: "Your usual burn is \(FoodText.kcal(r.burnKcal)) kcal. The plan eats as much."))
                .font(.footnote).foregroundStyle(ForgeColor.secondary)
        }
        .forgeCard(padding: 14)
        .animation(.smooth, value: r.averageKcal)
    }

    private func macro(_ name: String, _ grams: Double, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) { Circle().fill(tint).frame(width: 8, height: 8); Text(name).font(.footnote).foregroundStyle(ForgeColor.secondary) }
            Text("\(FoodText.grams(grams)) g").font(ForgeFont.rounded(18, .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var advancedDials: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Who steers", selection: $draft.steering) {
                Text("Forge adjusts").tag(DietPlan.Steering.coached)
                Text("Calories only").tag(DietPlan.Steering.caloriesOnly)
                Text("Only me").tag(DietPlan.Steering.manual)
            }
            .pickerStyle(.segmented)
            if draft.steering == .manual {
                dial(String(localized: "Calories a day"), value: Binding(get: { draft.fixedKcal ?? result.averageKcal },
                                                                         set: { draft.fixedKcal = $0 }),
                     range: 1_200...6_000, step: 25, text: { "\(FoodText.kcal($0)) kcal" })
            }
            dial(String(localized: "Protein per kg"), value: Binding(get: { draft.proteinPerKg ?? DietTargets.proteinPerKg(goal: draft.goal, strength: draft.strength) + draft.form.proteinBonusPerKg },
                                                                     set: { draft.proteinPerKg = $0 }),
                 range: 1.2...2.4, step: 0.1, text: { String(format: "%.1f g", $0) })
            if draft.form.carbCapG == nil {
                dial(String(localized: "Carbs of the rest"), value: Binding(get: { draft.carbShareOfRest ?? draft.form.carbShareOfRest },
                                                                            set: { draft.carbShareOfRest = $0 }),
                     range: 0.2...0.8, step: 0.05, text: { DietText.percent($0 * 100) })
            }
            if draft.goal == .lose {
                Stepper(value: Binding(get: { draft.dietBreakEveryWeeks ?? 0 }, set: { draft.dietBreakEveryWeeks = $0 == 0 ? nil : $0 }),
                        in: 0...12) {
                    Text(draft.dietBreakEveryWeeks.map { String(localized: "A week at maintenance every \($0) weeks") } ?? String(localized: "No diet breaks"))
                }
            }
        }
        .forgeCard(padding: 12)
    }

    private func dial(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                      text: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(label); Spacer(); Text(text(value.wrappedValue)).monospacedDigit().foregroundStyle(ForgeColor.secondary) }
            Slider(value: value, in: range, step: step).tint(ForgeColor.accent)
        }
    }

    private var summaryStep: some View {
        let r = result
        let forecast = DietForecast.project(startKg: person.weightKg, goalKg: r.goalWeightKg, intakeKcal: r.averageKcal,
                                            burnKcal: r.burnKcal, kcalPerKg: model.kcalPerKg ?? DietTargets.defaultKcalPerKg,
                                            dietBreakEveryWeeks: draft.dietBreakEveryWeeks)
        return VStack(alignment: .leading, spacing: 12) {
            title("Your plan")
            Text("\(DietText.goal(r.goal)) · \(DietText.form(draft.form))\(draft.addon.map { " · " + DietText.addon($0) } ?? "")")
                .font(.headline)
            if r.goal != .maintain {
                VStack(alignment: .leading, spacing: 8) {
                    DietForecastChart(forecast: forecast, goalKg: r.goalWeightKg)
                    if let line = DietForecastText.goal(forecast, hasGoal: r.goalWeightKg != nil) {
                        Text(line).font(.subheadline)
                    }
                    Text("A band, not a promise. Forge redraws it every week with your real weight.")
                        .font(.footnote).foregroundStyle(ForgeColor.secondary)
                }
                .forgeCard(padding: 12)
            }
            numbersCard
            ForEach(r.notes, id: \.self) { notice(DietText.note($0)) }
            Toggle("Hide weight and numbers", isOn: $draft.hideNumbers).forgeCard(padding: 12)
            DietExplainCard(image: DietArt.explain("hold"), title: DietText.explainHoldTitle, text: DietText.explainHold)
        }
    }

    // MARK: Footer and helpers

    private var footer: some View {
        HStack(spacing: 12) {
            if current == .pace || current == .form || current == .addon || current == .numbers {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(FoodText.kcal(result.averageKcal)) kcal").font(.headline).monospacedDigit()
                    Text(DietText.effort(result.effort)).font(.caption).foregroundStyle(DietText.effortTint(result.effortScore))
                }
            }
            Spacer()
            Button(action: next) {
                Text(current == .summary ? String(localized: "Start my plan") : String(localized: "Next"))
                    .font(.headline).foregroundStyle(ForgeColor.onAccent)
                    .padding(.horizontal, 28).frame(minHeight: 50)
                    .background(ForgeColor.accent, in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func next() {
        if current == .summary {
            var plan = draft
            plan.startWeightKg = person.weightKg
            if start == nil || start?.goal != plan.goal || start?.form != plan.form { plan.startDay = Repository.localDayKey(.now) }
            model.savePlan(plan)
            dismiss()
        } else {
            step += 1
        }
    }

    private func title(_ text: LocalizedStringKey) -> some View {
        Text(text).font(ForgeFont.rounded(26, .bold)).foregroundStyle(ForgeColor.text)
    }

    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(.footnote).foregroundStyle(ForgeColor.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).forgeCard(padding: 12)
    }

    private func clampToMode() {
        let limit = DietPlan.paceLimit(goal: draft.goal, mode: draft.mode)
        if draft.pacePercent > limit { draft.pacePercent = limit }
        if draft.mode == .simple && draft.form.advancedOnly { draft.form = .balanced }
        if draft.mode == .simple { draft.steering = .coached }
    }

    private func loadRecent() async {
        guard let store = await repo.storeHandle(),
              let from = Calendar.current.date(byAdding: .day, value: -14, to: .now) else { refreshSuggestions(); return }
        let entries = (try? await store.foodLogEntries(from: Repository.localDayKey(from), to: Repository.localDayKey(.now))) ?? []
        recent = entries.map(FoodLogEntryLite.init)
        refreshSuggestions()
    }

    private func refreshSuggestions() {
        suggestions = DietSuggest.top(entries: recent, keep: draft.keep, likesRules: likesRules, strength: draft.strength, mode: draft.mode)
    }
}

/// Chips that wrap to the next line, for picking several answers.
struct DietChips<Item: Hashable>: View {
    let items: [Item]
    let label: (Item) -> String
    let isOn: (Item) -> Bool
    let toggle: (Item) -> Void

    var body: some View {
        DietFlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button { toggle(item) } label: {
                    Text(label(item)).font(.subheadline)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .foregroundStyle(isOn(item) ? ForgeColor.onAccent : ForgeColor.text)
                        .background(isOn(item) ? ForgeColor.accent : ForgeColor.fill, in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn(item) ? .isSelected : [])
            }
        }
    }
}
#endif
