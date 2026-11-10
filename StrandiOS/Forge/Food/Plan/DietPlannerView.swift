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

    private enum Step: Int, CaseIterable { case welcome, goal, weight, pace, life, form, addon, training, numbers, journey, summary }

    /// The training-day step is for recomposition, and for anyone in the advanced mode; the simple mode skips it.
    /// Holding in the simple mode has no training-day shift, so it skips that step.
    private func skipped(_ s: Step) -> Bool { s == .training && draft.goal == .maintain && draft.mode == .simple }
    /// Recomposition needs at least two planned training days before the planner goes on.
    private var blocked: Bool {
        current == .training && draft.goal == .recomp
            && (draft.trainingWeekdays ?? []).count < 2 && model.plannedTrainingDaysThisWeek.count < 2
    }

    init(model: ForgeFoodModel, start: DietPlan? = nil) {
        self.model = model
        self.start = start
        let weight = model.currentWeightKg ?? start?.startWeightKg ?? 80
        var initial = start ?? DietPlan(startDay: Repository.localDayKey(.now), startWeightKg: weight)
        #if DEBUG
        // `--demo-planner STEP [advanced]` opens the planner at a step, for screenshots.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--demo-planner"), i + 1 < args.count, let s = Int(args[i + 1]) {
            _step = State(initialValue: s)
            if args.contains("advanced") { initial.mode = .advanced }
            if s >= 3, initial.goalWeightKg == nil { initial.goalWeightKg = (weight * 0.9).rounded() }
        }
        #endif
        _draft = State(initialValue: initial)
    }

    private var person: DietPerson {
        model.person ?? DietPerson(weightKg: draft.startWeightKg, heightCm: nil, age: nil, male: nil)
    }
    private var burn: Double { model.planBurnKcal ?? person.weightKg * 30 }
    private var result: DietTargets.Result {
        DietTargets.resolve(draft, person: person, burnKcal: burn, kcalPerKg: model.kcalPerKg)
    }
    private var current: Step { Step(rawValue: step) ?? .welcome }

    /// Losing: from the lowest healthy weight (or 60 % of today) to today; gaining: today to a quarter more.
    private var goalRange: ClosedRange<Double> {
        let w = person.weightKg
        if draft.goal == .gain { return w...(w * 1.25) }
        let low = max(person.lowestGoalWeightKg ?? w * 0.6, w * 0.4)
        return min(low, w - 1)...w
    }

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
                ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } }
                if step > 0 {
                    ToolbarItem(placement: .topBarLeading) { Button("Back", systemImage: "chevron.left", action: back).labelStyle(.iconOnly) }
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
        case .training: trainingStep
        case .numbers: numbersStep
        case .journey: journeyStep
        case .summary: summaryStep
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            DietExplainCard(image: DietArt.explain("path"), title: DietText.explainStartTitle, text: DietText.explainStart)
            title("How much do you want to set yourself?")
            HStack(spacing: 12) {
                DietChoiceCard(image: DietArt.goal(.maintain, male: person.male), title: String(localized: "Simple"),
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
                DietChoiceCard(image: DietArt.goal(g, male: person.male), title: DietText.goal(g), detail: DietText.goalDetail(g),
                               selected: draft.goal == g) {
                    draft.goal = g
                    if g == .recomp || g == .gain {
                        // Gaining and recomposition build muscle: they need strength training.
                        draft.strength = true
                        if draft.trainingWeekdays == nil, !model.usualTrainingWeekdays.isEmpty { draft.trainingWeekdays = model.usualTrainingWeekdays }
                    }
                    if g == .recomp {
                        // Recomposition has no goal weight or pace.
                        draft.goalWeightKg = nil
                    } else if draft.pacePercent == 0 || g == .gain {
                        draft.pacePercent = DietPlan.Pace.normal.percent(for: g)
                    }
                }
            }
            if person.male != true {
                DietCheckRow(title: String(localized: "I am pregnant or nursing"), isOn: $draft.pregnantOrNursing)
            }
        }
    }

    private var weightStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(DietArt.goal(draft.goal, male: person.male), why: String(localized: "Your weight and your burn set every number that follows."))
            title("Where do you start?")
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Today", value: DietText.kg(person.weightKg))
                LabeledContent("Usual burn", value: "\(FoodText.kcal(burn)) kcal")
                Text("Forge takes these from your weigh-ins and from what your strap measured over the last weeks.")
                    .font(.footnote).foregroundStyle(ForgeColor.secondary)
            }
            .forgeCard(padding: 12)
            if draft.goal != .maintain && draft.goal != .recomp {
                title("A goal weight? It is optional.")
                VStack(alignment: .leading, spacing: 10) {
                    // Two plain choices rather than a switch: which one is on reads at a glance.
                    HStack(spacing: 8) {
                        choicePill(String(localized: "No goal weight"), on: draft.goalWeightKg == nil) { draft.goalWeightKg = nil }
                        choicePill(String(localized: "Set a goal weight"), on: draft.goalWeightKg != nil) {
                            if draft.goalWeightKg == nil {
                                draft.goalWeightKg = goalRange.clamp((person.weightKg * (draft.goal == .lose ? 0.9 : 1.05) * 2).rounded() / 2)
                            }
                        }
                    }
                    if let goal = draft.goalWeightKg {
                        HStack(alignment: .firstTextBaseline) {
                            Text(DietText.kg(goal)).font(ForgeFont.rounded(30, .bold)).monospacedDigit()
                            Spacer()
                            Text(goal < person.weightKg ? String(localized: "\(DietText.kg(person.weightKg - goal)) less") : String(localized: "\(DietText.kg(goal - person.weightKg)) more"))
                                .foregroundStyle(ForgeColor.secondary)
                        }
                        Slider(value: Binding(get: { goal }, set: { draft.goalWeightKg = ($0 * 2).rounded() / 2 }), in: goalRange)
                            .tint(ForgeColor.food)
                    }
                }
                .forgeCard(padding: 12)
                if result.notes.contains(.goalWeightRaised), let g = result.goalWeightKg {
                    notice(String(localized: "The lowest healthy weight for your height is about \(DietText.kg(g)). Forge plans to that."))
                }
            }
        }
    }

    private var paceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if draft.goal == .recomp {
                recompStep
            } else if draft.goal == .maintain {
                title("No pace needed")
                Text("Holding your weight means eating about as much as you burn. Forge keeps an eye on the trend.")
                    .foregroundStyle(ForgeColor.secondary)
            } else {
                title("How fast?")
                if draft.mode == .simple {
                    ForEach(DietPlan.Pace.allCases, id: \.self) { p in
                        let pct = p.percent(for: draft.goal)
                        DietChoiceCard(image: DietArt.goal(draft.goal, male: person.male), title: DietText.pace(p),
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
            header(DietArt.explain("hold"), why: String(localized: "The plan you keep up beats the strictest one. Forge suggests ways of eating around your life."))
            title("What would you not give up?")
            Text("Forge suggests ways of eating that keep these.").font(.footnote).foregroundStyle(ForgeColor.secondary)
            DietChips(items: DietPlan.Keep.allCases, label: DietText.keep, isOn: { draft.keep.contains($0) }) { k in
                if let i = draft.keep.firstIndex(of: k) { draft.keep.remove(at: i) } else { draft.keep.append(k) }
            }
            DietCheckRow(title: String(localized: "Clear rules are easier for me than moderation"), isOn: $likesRules)
            if draft.goal == .lose || draft.goal == .maintain {
                DietCheckRow(title: String(localized: "I do strength training"), isOn: $draft.strength)
            }
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
            header(DietArt.form(draft.form), why: String(localized: "Forge works these out from your burn, your goal and your way of eating."))
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
            if let split = DietTargets.trainingAndRestKcal(plan: draft, result: r, training: model.training, day: Repository.localDayKey(.now)) {
                Text("Training days \(FoodText.kcal(split.training)) kcal · rest days \(FoodText.kcal(split.rest)) kcal")
                    .font(.footnote).foregroundStyle(ForgeColor.secondary)
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
                                            dietBreakEveryWeeks: DietProgram.dietBreakEveryWeeks(draft))
        return VStack(alignment: .leading, spacing: 12) {
            title("Your plan")
            Text("\(DietText.goal(r.goal)) · \(DietText.form(draft.form))\(draft.addon.map { " · " + DietText.addon($0) } ?? "")")
                .font(.headline)
            if r.goal != .maintain && r.goal != .recomp {
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
            DietCheckRow(title: String(localized: "Hide weight and numbers"), isOn: $draft.hideNumbers)
            if r.goal == .recomp {
                DietExplainCard(image: DietArt.recomp, title: DietText.explainRecompTitle, text: DietText.explainRecomp, sources: DietText.recompSources)
            } else {
                DietExplainCard(image: DietArt.explain("hold"), title: DietText.explainHoldTitle, text: DietText.explainHold)
            }
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
            .disabled(blocked)
            .opacity(blocked ? 0.4 : 1)
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
            while skipped(current), step < Step.allCases.count - 1 { step += 1 }
        }
    }

    private func back() {
        step -= 1
        while skipped(current), step > 0 { step -= 1 }
    }

    // MARK: Journey

    /// A step's picture and the one sentence on why Forge asks, above the question.
    private func header(_ image: String, why: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(image).resizable().scaledToFill()
                .frame(maxWidth: .infinity).frame(height: 140).clipped()
                .clipShape(.rect(cornerRadius: ForgeRadius.inner))
                .accessibilityHidden(true)
            Label(why, systemImage: "questionmark.circle").font(.footnote).foregroundStyle(ForgeColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// How the plan runs through the weeks, before the numbers are confirmed: the same weeks the forecast and the
    /// program use.
    private var journeyStep: some View {
        let r = result
        let breaks = DietProgram.dietBreakEveryWeeks(draft)
        let forecast = DietForecast.project(startKg: person.weightKg, goalKg: r.goalWeightKg, intakeKcal: r.averageKcal,
                                            burnKcal: r.burnKcal, kcalPerKg: model.kcalPerKg ?? DietTargets.defaultKcalPerKg,
                                            dietBreakEveryWeeks: breaks)
        var stops: [(icon: String, when: String, what: String)] = []
        stops.append(("flag.fill", String(localized: "Today"), String(localized: "You start with your numbers and log what you eat.")))
        if r.goal != .maintain {
            stops.append(("drop.fill", String(localized: "Weeks 1 and 2"), String(localized: "Water moves your weight up and down. Forge does not judge these weeks yet.")))
        }
        stops.append(("checkmark.circle.fill", String(localized: "From week 3, every week"),
                      r.goal == .maintain || r.goal == .recomp
                      ? String(localized: "Forge checks that your weight stays in its band and moves your calories a little when it does not.")
                      : String(localized: "Forge compares your trend with the plan and moves your calories by at most 150 kcal.")))
        if draft.effectiveDayShift > 0 {
            stops.append(("dumbbell.fill", String(localized: "Every training day"), String(localized: "More carbohydrate on training days, a little less on rest days.")))
        }
        if let every = breaks, r.goal == .lose {
            stops.append(("pause.circle.fill", String(localized: "Every \(every + 1) weeks"), String(localized: "A week at maintenance: you eat what you burn, your body and head get a rest.")))
        }
        if r.goal == .recomp {
            stops.append(("chart.line.uptrend.xyaxis", String(localized: "Over months"), String(localized: "Body fat or your waist goes down, your lifts go up, the scale barely moves.")))
        } else if r.goalWeightKg != nil, let weeks = forecast.goalWeeks {
            stops.append(("mountain.2.fill", String(localized: "In about \(weeks.lowerBound) to \(weeks.upperBound) weeks"),
                          String(localized: "You reach your goal. Forge steps down to holding over a week instead of simply lifting your calories.")))
        }
        return VStack(alignment: .leading, spacing: 16) {
            header(DietArt.goal(r.goal, male: person.male), why: String(localized: "So you know what to expect, and when."))
            title("How your plan runs")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Image(systemName: stop.icon).font(.body).foregroundStyle(ForgeColor.accent)
                                .frame(width: 32, height: 32).background(ForgeColor.fill, in: .circle)
                            if index < stops.count - 1 {
                                Rectangle().fill(ForgeColor.separator).frame(width: 2).frame(minHeight: 24)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stop.when).font(.subheadline.weight(.semibold)).foregroundStyle(ForgeColor.text)
                            Text(stop.what).font(.subheadline).foregroundStyle(ForgeColor.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.bottom, 14)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .forgeCard(padding: 14)
        }
    }

    // MARK: Recomposition and training days

    /// Recomposition in place of the pace: how long the wearer has trained, their body fat, how well it fits.
    @ViewBuilder private var recompStep: some View {
        title("How long have you trained?")
        DietChips(items: DietPlan.Experience.allCases, label: DietText.experience, isOn: { draft.experience == $0 }) { e in
            draft.experience = e
        }
        VStack(alignment: .leading, spacing: 6) {
            if let bf = person.bodyFatPercent {
                LabeledContent("Body fat", value: "\(bf.formatted(.number.precision(.fractionLength(0...1)).locale(AppLanguage.activeLocale))) %")
                Text("Forge reckons your protein on your weight without fat.").font(.footnote).foregroundStyle(ForgeColor.secondary)
            } else {
                Text("No body fat measurement yet. Forge reckons protein on your weight; a reading from Apple Health or the tape measure on the Body page makes it more precise.")
                    .font(.footnote).foregroundStyle(ForgeColor.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .forgeCard(padding: 12)
        notice(DietText.recompFit(draft.experience, bodyFat: person.bodyFatPercent, male: person.male))
        if draft.mode == .advanced {
            dial(String(localized: "Under your burn"), value: Binding(get: { draft.recompDeficitPercent ?? 5 }, set: { draft.recompDeficitPercent = $0 }),
                 range: 0...15, step: 1, text: { "\(Int($0)) %" })
                .forgeCard(padding: 12)
        }
        DietExplainCard(image: DietArt.recomp, title: DietText.explainRecompTitle, text: DietText.explainRecomp, sources: DietText.recompSources)
    }

    /// The planned training days, proposed from the log, and (advanced) how much moves to them.
    private var trainingStep: some View {
        let order = (0..<7).map { (Calendar.current.firstWeekday - 1 + $0) % 7 + 1 }
        return VStack(alignment: .leading, spacing: 12) {
            header(DietArt.goal(draft.goal == .maintain ? .recomp : draft.goal, male: person.male),
                   why: String(localized: "Training days use more energy. Forge puts more carbohydrate where your body needs it."))
            title("When do you train?")
            Text(draft.goal == .recomp
                 ? String(localized: "At least two days a week. Training days get more carbohydrate, rest days a little less; the week stays the same.")
                 : String(localized: "Training days can get more carbohydrate and rest days a little less; the week stays the same."))
                .font(.footnote).foregroundStyle(ForgeColor.secondary)
            let fromPlanner = model.plannedTrainingDaysThisWeek
            if !fromPlanner.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("From your training plan", systemImage: "calendar").font(.subheadline.weight(.semibold))
                    Text(fromPlanner.compactMap(WeightSeries.date(forDay:)).map { DietText.weekday(Calendar.current.component(.weekday, from: $0)) }
                            .joined(separator: ", "))
                        .font(ForgeFont.rounded(20, .bold)).foregroundStyle(ForgeColor.text)
                    Text("Forge follows your training plan week by week. Move a session there, and the extra calories move with it.")
                        .font(.footnote).foregroundStyle(ForgeColor.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .forgeCard(padding: 12)
                Text("For weeks without a training plan:").font(.subheadline.weight(.semibold)).foregroundStyle(ForgeColor.secondary)
            }
            DietChips(items: order, label: DietText.weekday, isOn: { (draft.trainingWeekdays ?? []).contains($0) }) { w in
                var days = draft.trainingWeekdays ?? []
                if let i = days.firstIndex(of: w) { days.remove(at: i) } else { days.append(w) }
                draft.trainingWeekdays = days.sorted()
            }
            let usual = model.usualTrainingWeekdays
            if !usual.isEmpty, usual != (draft.trainingWeekdays ?? []) {
                Button(String(localized: "Use the days from your log: \(usual.map(DietText.weekday).joined(separator: ", "))")) {
                    draft.trainingWeekdays = usual
                }
                .font(.subheadline)
            }
            Text("A day with logged strength training counts as a training day too.")
                .font(.footnote).foregroundStyle(ForgeColor.secondary)
            if (draft.trainingWeekdays ?? []).count == 7 {
                notice(String(localized: "With every day a training day there is no rest day to move calories from, so all days stay the same."))
            }
            if draft.mode == .advanced, draft.form.fasting == nil {
                dial(String(localized: "Moved to training days"),
                     value: Binding(get: { draft.dayShift ?? (draft.goal == .recomp ? 0.10 : 0) }, set: { draft.dayShift = $0 }),
                     range: 0...0.25, step: 0.01, text: { DietText.percent($0 * 100) })
                    .forgeCard(padding: 12)
            } else if draft.form.fasting != nil {
                notice(String(localized: "A fasting form keeps its own days, so nothing moves between training and rest days."))
            }
        }
    }

    private func title(_ text: LocalizedStringKey) -> some View {
        Text(text).font(ForgeFont.rounded(26, .bold)).foregroundStyle(ForgeColor.text)
    }

    private func choicePill(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(on ? ForgeColor.onAccent : ForgeColor.text)
                .background(on ? ForgeColor.accent : ForgeColor.fill, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
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

private extension ClosedRange where Bound == Double {
    func clamp(_ v: Double) -> Double { Swift.min(upperBound, Swift.max(lowerBound, v)) }
}

/// A yes-or-no answer as a row with a check: the whole row is the button, the check says which it is.
struct DietCheckRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 12) {
                Text(title).font(.body).foregroundStyle(ForgeColor.text).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(isOn ? ForgeColor.accent : ForgeColor.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .forgeCard(padding: 12)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
#endif
