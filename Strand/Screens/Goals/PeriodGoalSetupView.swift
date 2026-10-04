import SwiftUI
import StrandDesign
import StrandAnalytics

/// Creating weekly and monthly goals (design §8.2, Q14).
///
/// The very first goal is set up step by step: period, what, how much, fine-tuning, preview. After that,
/// "+" opens a list of suggestions with the wearer's own recommended values, where one tap adds a goal;
/// "Customize" leads into the step-by-step path with the choice pre-filled. Start packs add two or three
/// goals at once. Everything here is arithmetic on the wearer's data and works without the coach.
struct PeriodGoalSetupView: View {
    var initialPeriod: PeriodGoal.Period?

    @EnvironmentObject private var repo: Repository
    @ObservedObject private var store = PeriodGoalStore.shared
    @ObservedObject private var tracking = GoalTrackingStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var inputs: PeriodGoalInputs?
    @State private var guided = false
    @State private var period: PeriodGoal.Period = .week
    @State private var preset: PeriodMetric?
    @State private var addedIds: Set<String> = []

    var body: some View {
        Group {
            if guided || store.goals.isEmpty {
                GuidedPeriodGoalSetup(initialPeriod: initialPeriod ?? period, preset: preset,
                                      inputs: inputs ?? tracking.periodInputs) { dismiss() }
            } else {
                quickList
            }
        }
        .task {
            if let initialPeriod { period = initialPeriod }
            inputs = await tracking.loadFullPeriodInputs(repo: repo)
        }
    }

    // MARK: - Quick list

    private var effectiveInputs: PeriodGoalInputs { inputs ?? tracking.periodInputs }

    private var quickList: some View {
        ScreenScaffold(title: "New goal", subtitle: "Suggestions from your own data. One tap adds one.") {
            Picker("Period", selection: $period) {
                Text("Weekly").tag(PeriodGoal.Period.week)
                Text("Monthly").tag(PeriodGoal.Period.month)
            }
            .pickerStyle(.segmented)

            NoopCard(padding: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Suggested for you").strandOverline()
                    ForEach(suggestions, id: \.metric) { item in suggestionRow(item) }
                }
            }

            StartPacksView(period: period, inputs: effectiveInputs)

            Button { guided = true } label: {
                Label("Set up step by step", systemImage: "list.number")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)

            NavigationLink {
                CoachGoalOnboardingFlow(pushed: true)
            } label: {
                Label("A long-term goal instead", systemImage: "flag")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private struct Suggestion {
        let metric: PeriodMetric
        let goal: PeriodGoal
        let usual: Double?
        let exists: Bool
    }

    /// Available metrics, most relevant first; those already tracked over this period sink to the end.
    private var suggestions: [Suggestion] {
        let now = Date()
        let calendar = TrainingPreferences.weekCalendar
        let order: [PeriodMetric] = [.workouts, .stepDays, .sleepNights, .trainingMinutes, .distance, .workingSets,
                                     .sleepAverage, .zoneMinutes, .restDays, .activeEnergy, .hydrationDays]
        let items: [Suggestion] = order.compactMap { metric in
            guard PeriodGoalTracker.availability(metric, inputs: effectiveInputs, now: now, calendar: calendar)
                    == .available else { return nil }
            var goal = PeriodGoal(metric: metric, period: period, target: metric.defaultTarget(for: period),
                                  threshold: metric.defaultThreshold)
            let rec = PeriodGoalTracker.recommendation(for: goal, inputs: effectiveInputs, now: now, calendar: calendar)
            if let rec { goal.target = rec.recommended.value }
            return Suggestion(metric: metric, goal: goal, usual: rec?.usual, exists: store.canAdd(goal) != nil)
        }
        return items.filter { !$0.exists } + items.filter(\.exists)
    }

    private func suggestionRow(_ item: Suggestion) -> some View {
        let key = "\(item.metric.rawValue)-\(period.rawValue)"
        let added = addedIds.contains(key)
        return HStack(spacing: 10) {
            Image(systemName: item.metric.icon)
                .foregroundStyle(goalIdentityColor(item.metric, appleColors: true))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(GoalFormat.title(item.goal))
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    if item.exists { Text("Already a goal") }
                    else if let usual = item.usual {
                        Text("Your usual: \(GoalFormat.amount(usual, item.metric))")
                    } else {
                        Text(item.metric.blurb.localizedCatalogValue)
                    }
                }
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 6)
            if !item.exists {
                Button {
                    preset = item.metric
                    guided = true
                } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityLabel(Text("Customize"))
                Button {
                    store.commit(item.goal, today: Repository.localDayKey(Date()))
                    addedIds.insert(key)
                    StrandHaptic.commit.play()
                    Task { await tracking.refresh(repo: repo) }
                } label: {
                    Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(added ? StrandPalette.statusPositive : StrandPalette.accent)
                }
                .buttonStyle(.plain)
                .disabled(added)
                .accessibilityLabel(added ? Text("Added") : Text("Add \(GoalFormat.title(item.goal))"))
            }
        }
    }
}

// MARK: - Guided setup

struct GuidedPeriodGoalSetup: View {
    let initialPeriod: PeriodGoal.Period
    let preset: PeriodMetric?
    let inputs: PeriodGoalInputs
    let onDone: () -> Void

    @EnvironmentObject private var repo: Repository
    @ObservedObject private var store = PeriodGoalStore.shared
    @ObservedObject private var tracking = GoalTrackingStore.shared
    @ObservedObject private var longTerm = CoachGoalStore.shared
    @StateObject private var journal = JournalCatalogStore()

    private enum Step: Int, CaseIterable { case period, metric, amount, fineTune, preview }
    @State private var step: Step = .period
    @State private var draft = PeriodGoal(metric: .workouts, period: .week, target: 3)
    @State private var level: Int = 1          // 0 easy, 1 recommended, 2 ambitious, 3 own value
    @State private var sportText = ""
    @State private var restDays: Set<Int> = Set(TrainingPreferences.restWeekdays)
    @State private var onlyThisPeriod = false
    @State private var showLongTerm = false
    @State private var configured = false
    @State private var limitMessage: String?

    private var calendar: Calendar { TrainingPreferences.weekCalendar }

    var body: some View {
        ScreenScaffold(title: title, subtitle: subtitle) {
            progressDots
            switch step {
            case .period:   periodStep
            case .metric:   metricStep
            case .amount:   amountStep
            case .fineTune: fineTuneStep
            case .preview:  previewStep
            }
            navigationButtons
        }
        .navigationDestination(isPresented: $showLongTerm) { CoachGoalOnboardingFlow(pushed: true) }
        .onAppear(perform: configure)
    }

    private func configure() {
        guard !configured else { return }
        configured = true
        draft.period = initialPeriod
        if let preset {
            select(preset)
            step = .amount
        }
    }

    private var title: LocalizedStringKey {
        switch step {
        case .period:   return "What kind of goal?"
        case .metric:   return "What do you want to reach?"
        case .amount:   return "How much?"
        case .fineTune: return "Fine-tune"
        case .preview:  return "This is how it will look"
        }
    }

    private var subtitle: LocalizedStringKey? {
        switch step {
        case .period:   return "Weekly goals shape your week. Monthly goals give it room."
        case .metric:   return "Only what NOOP can measure from your data."
        case .amount:   return "Read from your last weeks. The recommended level sits a little above your usual."
        case .fineTune: return "Optional. Skip it if you like."
        case .preview:  return "Exactly the row Today will show."
        }
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule().fill(s.rawValue <= step.rawValue ? StrandPalette.accent : StrandPalette.hairline)
                    .frame(height: 4)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Step \(step.rawValue + 1) of \(Step.allCases.count)"))
    }

    // MARK: Step 1

    private var periodStep: some View {
        VStack(spacing: 10) {
            bigChoice(icon: "calendar.badge.clock", title: "This week, every week",
                      detail: "Repeats every week until you change it.", selected: draft.period == .week) {
                draft.period = .week
                advance()
            }
            bigChoice(icon: "calendar", title: "This month, every month",
                      detail: "More room: a slow week can be made up.", selected: draft.period == .month) {
                draft.period = .month
                advance()
            }
            bigChoice(icon: "flag.checkered", title: "Long-term",
                      detail: "A target with a date: a race, a weight, a habit.", selected: false) {
                showLongTerm = true
            }
        }
    }

    private func bigChoice(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).foregroundStyle(StrandPalette.accent).frame(width: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text(detail).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(StrandPalette.textTertiary).accessibilityHidden(true)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                .fill(StrandPalette.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                .strokeBorder(selected ? StrandPalette.accent : StrandPalette.hairline, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Step 2

    private var metricStep: some View {
        let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]
        return VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(PeriodMetric.allCases) { metric in metricTile(metric) }
            }
            if draft.metric == .habitDays { habitPicker }
        }
    }

    private func metricTile(_ metric: PeriodMetric) -> some View {
        let availability = PeriodGoalTracker.availability(metric, inputs: inputs, now: Date(), calendar: calendar)
        let available = availability == .available
        let selected = draft.metric == metric
        return Button {
            select(metric)
            if metric != .habitDays { advance() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: metric.icon).font(.title3)
                    .foregroundStyle(available ? goalIdentityColor(metric, appleColors: true) : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                Text(metric.label.localizedCatalogValue).font(StrandFont.subhead)
                    .foregroundStyle(available ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                if case .unavailable(let reason) = availability {
                    Text(reason.localizedCatalogValue).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(metric.blurb.localizedCatalogValue).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous)
                .fill(StrandPalette.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous)
                .strokeBorder(selected ? StrandPalette.accent : StrandPalette.hairline, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityElement(children: .combine)
    }

    private var habitPicker: some View {
        NoopCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Which habit?").strandOverline()
                let items = journal.items.filter { !$0.hidden }
                if items.isEmpty {
                    Text("Your journal has no habits yet. Add one in Journal first.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
                Picker("Habit", selection: Binding(get: { draft.habitKey ?? "" },
                                                   set: { draft.habitKey = $0.isEmpty ? nil : $0 })) {
                    Text("Choose").tag("")
                    ForEach(items) { item in Text(item.displayName ?? item.canonical).tag(item.canonical) }
                }
                Picker("Goal", selection: $draft.habitWantsYes) {
                    Text("Do it").tag(true)
                    Text("Avoid it").tag(false)
                }
                .pickerStyle(.segmented)
                Text(draft.habitWantsYes ? "Counts days you log it with yes." : "Counts days you log it with no.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func select(_ metric: PeriodMetric) {
        draft.metric = metric
        draft.threshold = metric.defaultThreshold
        draft.sportFilter = metric == .distance ? ["Running"] : []
        sportText = draft.sportFilter.joined(separator: ", ")
        draft.target = recommendation?.recommended.value ?? metric.defaultTarget(for: draft.period)
        level = recommendation == nil ? 3 : 1
    }

    // MARK: Step 3

    private var recommendation: PeriodRecommendation? {
        PeriodGoalTracker.recommendation(for: draft, inputs: inputs, now: Date(), calendar: calendar)
    }

    private var history: [Double] {
        PeriodGoalTracker.historyTotals(for: draft, inputs: inputs, now: Date(), calendar: calendar)
    }

    private var amountStep: some View {
        let rec = recommendation
        let metric = draft.metric
        return VStack(alignment: .leading, spacing: 10) {
            if metric.hasThreshold { thresholdControl }
            if metric.hasSportFilter { sportControl }
            if let rec {
                Text("Your last \(rec.easy.periods) \(draft.period == .week ? String(localized: "weeks") : String(localized: "months")): usually \(GoalFormat.amount(rec.usual, metric))")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                levelCard(0, title: "Easy", value: rec.easy, note: nil)
                levelCard(1, title: "Recommended", value: rec.recommended,
                          note: String(localized: "A little above your usual"))
                levelCard(2, title: "Ambitious", value: rec.ambitious, note: nil)
            } else {
                Text("Not enough history yet to recommend a value. After two \(draft.period == .week ? String(localized: "weeks") : String(localized: "months")) NOOP will suggest one.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            NoopCard(padding: 14) {
                Stepper(value: Binding(get: { GoalFormat.display(draft.target, metric) },
                                       set: { draft.target = GoalFormat.stored($0, metric); level = 3 }),
                        in: displayRange, step: metric.step(for: draft.period)) {
                    HStack {
                        Text(level == 3 ? "Your own value" : "Or set your own")
                        Spacer()
                        Text(GoalFormat.amount(draft.target, metric)).monospacedDigit()
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .font(StrandFont.footnote)
                }
            }
            if let guideline = metric.guideline(for: draft.period) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "book.closed").foregroundStyle(StrandPalette.textSecondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(guideline.text.localizedCatalogValue)
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                        Text(guideline.source).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var displayRange: ClosedRange<Double> {
        let r = draft.metric.range(for: draft.period)
        return GoalFormat.display(r.lowerBound, draft.metric)...GoalFormat.display(r.upperBound, draft.metric)
    }

    private var thresholdControl: some View {
        NoopCard(padding: 14) {
            if draft.metric == .stepDays {
                Stepper(value: Binding(get: { draft.threshold ?? 8_000 }, set: { draft.threshold = $0; refreshLevels() }),
                        in: 2_000...30_000, step: 500) {
                    Text("A day counts from \(Int(draft.threshold ?? 8_000).formatted()) steps").font(StrandFont.footnote)
                }
            } else {
                Stepper(value: Binding(get: { draft.threshold ?? 7 }, set: { draft.threshold = $0; refreshLevels() }),
                        in: 4...11, step: 0.5) {
                    Text("A night counts from \((draft.threshold ?? 7).formatted(.number.precision(.fractionLength(0...1)))) h")
                        .font(StrandFont.footnote)
                }
            }
        }
    }

    private var sportControl: some View {
        NoopCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Sports, e.g. Running (empty = all)", text: $sportText)
                    .onSubmit(applySports)
                    .onChange(of: sportText) { _ in applySports() }
                let recent = Array(Set(inputs.workouts.suffix(80).map(\.sport))).sorted().prefix(6)
                if !recent.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(recent), id: \.self) { sport in
                                Button(sport) {
                                    var parts = draft.sportFilter
                                    if let i = parts.firstIndex(of: sport) { parts.remove(at: i) } else { parts.append(sport) }
                                    sportText = parts.joined(separator: ", ")
                                    applySports()
                                }
                                .font(StrandFont.caption)
                                .buttonStyle(.bordered)
                                .tint(draft.sportFilter.contains(sport) ? StrandPalette.accent : StrandPalette.textTertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func applySports() {
        draft.sportFilter = sportText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        refreshLevels()
    }

    private func refreshLevels() {
        guard let rec = recommendation, level < 3 else { return }
        draft.target = [rec.easy, rec.recommended, rec.ambitious][level].value
    }

    private func levelCard(_ index: Int, title: LocalizedStringKey, value: PeriodRecommendation.Level,
                           note: String?) -> some View {
        let selected = level == index
        return Button {
            level = index
            draft.target = value.value
            StrandHaptic.selection.play()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(StrandFont.subhead.weight(selected ? .semibold : .regular))
                    Text(GoalFormat.amount(value.value, draft.metric)).font(StrandFont.subhead).monospacedDigit()
                    Spacer()
                    Text("\(value.hits) of \(value.periods)")
                        .font(StrandFont.caption)
                        .foregroundStyle(value.hits * 3 < value.periods ? StrandPalette.statusWarningForeground
                                                                          : StrandPalette.textSecondary)
                }
                .foregroundStyle(StrandPalette.textPrimary)
                LevelHistoryColumns(values: history, line: value.value)
                Text(note ?? String(localized: "Reached in \(value.hits) of your last \(value.periods)"))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous)
                .fill(StrandPalette.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous)
                .strokeBorder(selected ? StrandPalette.accent : StrandPalette.hairline, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Step 4

    private var fineTuneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if draft.metric.usesRestDays {
                NoopCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your rest days").strandOverline()
                        RestDaysPicker(selection: $restDays)
                        Text("Training goals spread their pace over the other days. This applies to all of them; a single goal can differ in its details.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            NoopCard(padding: 14) {
                Toggle(draft.period == .week ? "Only this week" : "Only this month", isOn: $onlyThisPeriod)
                    .font(StrandFont.footnote)
            }
            if !longTerm.activeGoals.isEmpty {
                NoopCard(padding: 14) {
                    Picker("Serves a long-term goal", selection: $draft.parentGoalId) {
                        Text("None").tag(UUID?.none)
                        ForEach(longTerm.activeGoals) { goal in
                            Text(goal.title.isEmpty ? goal.kind.label.localizedCatalogValue : goal.title).tag(Optional(goal.id))
                        }
                    }
                    .font(StrandFont.footnote)
                }
            }
        }
    }

    // MARK: Step 5

    private var previewSnapshot: PeriodGoalSnapshot? {
        var goal = finalDraft
        goal.targetHistory = [.init(fromDay: Repository.localDayKey(Date()), target: goal.target)]
        return PeriodGoalTracker.snapshots(goals: [goal], inputs: inputs, parents: longTerm.goals, frozen: [],
                                           corrections: [], now: Date(), calendar: calendar).first
    }

    private var finalDraft: PeriodGoal {
        var goal = draft
        goal.oneOffPeriodStart = onlyThisPeriod
            ? PeriodGoalTracker.periodDays(goal.period, containing: Repository.localDayKey(Date()), calendar: calendar).first
            : nil
        return goal
    }

    private var previewStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = previewSnapshot {
                NoopCard(padding: 14) { PeriodGoalRow(snapshot: snapshot) }
            }
            if let warning = volumeWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarningForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let limitMessage {
                Text(limitMessage).font(StrandFont.footnote).foregroundStyle(StrandPalette.statusCritical)
            }
        }
    }

    /// A volume goal well above the wearer's usual gets a gentle note, never a block (the same posture as
    /// the long-term safety gate).
    private var volumeWarning: String? {
        guard [.trainingMinutes, .distance, .workingSets, .zoneMinutes].contains(draft.metric),
              let usual = recommendation?.usual, usual > 0, draft.target > usual * 1.1 else { return nil }
        let percent = Int(((draft.target / usual - 1) * 100).rounded())
        return String(localized: "That is \(percent) % above your usual. Raising volume by about 10 % a week is easier on the body.")
    }

    // MARK: Navigation

    private var navigationButtons: some View {
        HStack {
            if step != .period {
                Button("Back") { withAnimation(StrandMotion.fade) { step = Step(rawValue: step.rawValue - 1) ?? .period } }
                    .buttonStyle(.plain).foregroundStyle(StrandPalette.accent)
            }
            Spacer()
            switch step {
            case .period:
                EmptyView()
            case .metric:
                if draft.metric == .habitDays {
                    Button("Next") { advance() }.buttonStyle(.borderedProminent).disabled(draft.habitKey == nil)
                }
            case .amount, .fineTune:
                Button("Next") { advance() }.buttonStyle(.borderedProminent)
            case .preview:
                Button("Create goal", action: create).buttonStyle(.borderedProminent)
            }
        }
        .font(StrandFont.subhead)
        .padding(.top, 6)
    }

    private func advance() {
        withAnimation(StrandMotion.fade) { step = Step(rawValue: step.rawValue + 1) ?? .preview }
    }

    private func create() {
        let goal = finalDraft
        if let error = store.canAdd(goal) {
            switch error {
            case .limitReached:
                limitMessage = String(localized: "You have reached your limit of \(GoalPrefs.periodLimit) weekly and monthly goals. Raise it in goal settings or end one.")
            case .duplicate:
                limitMessage = String(localized: "You already track this over the same period.")
            }
            return
        }
        if draft.metric.usesRestDays { TrainingPreferences.setRestWeekdays(Array(restDays)) }
        store.commit(goal, today: Repository.localDayKey(Date()))
        StrandHaptic.commit.play()
        Task { await tracking.refresh(repo: repo) }
        onDone()
    }
}

/// The wearer's recent periods as small columns with a line at a level: how often that level would
/// have been reached, without reading a number.
struct LevelHistoryColumns: View {
    let values: [Double]
    let line: Double

    var body: some View {
        let top = max(line * 1.3, values.max() ?? 0, 0.0001)
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(values.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(values[i] >= line - 1e-9 ? StrandPalette.statusPositive : StrandPalette.hairlineStrong)
                            .frame(height: max(2, geo.size.height * CGFloat(values[i] / top)))
                            .frame(maxWidth: .infinity)
                    }
                }
                Path { p in
                    let y = geo.size.height * CGFloat(1 - line / top)
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
                .stroke(StrandPalette.textSecondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .frame(height: 30)
        .accessibilityHidden(true)
    }
}

// MARK: - Start packs (§11.3)

struct StartPacksView: View {
    let period: PeriodGoal.Period
    let inputs: PeriodGoalInputs

    @EnvironmentObject private var repo: Repository
    @ObservedObject private var store = PeriodGoalStore.shared
    @ObservedObject private var tracking = GoalTrackingStore.shared
    @State private var openPack: Pack?

    struct Pack: Identifiable {
        let id: String
        let title: String
        let icon: String
        let goals: [PeriodGoal]
    }

    private var packs: [Pack] {
        let now = Date()
        let calendar = TrainingPreferences.weekCalendar
        func make(_ metric: PeriodMetric, sports: [String] = []) -> PeriodGoal? {
            guard PeriodGoalTracker.availability(metric, inputs: inputs, now: now, calendar: calendar) == .available
            else { return nil }
            var goal = PeriodGoal(metric: metric, period: period, target: metric.defaultTarget(for: period),
                                  threshold: metric.defaultThreshold, sportFilter: sports)
            if let rec = PeriodGoalTracker.recommendation(for: goal, inputs: inputs, now: now, calendar: calendar) {
                goal.target = rec.recommended.value
            }
            return goal
        }
        return [
            Pack(id: "fit", title: String(localized: "Stay fit"), icon: "figure.mixed.cardio",
                 goals: [make(.workouts), make(.stepDays)].compactMap { $0 }),
            Pack(id: "run", title: String(localized: "Build running"), icon: "figure.run",
                 goals: [make(.workouts, sports: ["Running"]), make(.distance, sports: ["Running"])].compactMap { $0 }),
            Pack(id: "sleep", title: String(localized: "Sleep better"), icon: "moon.stars.fill",
                 goals: [make(.sleepNights), make(.restDays)].compactMap { $0 }),
            Pack(id: "strength", title: String(localized: "Strength"), icon: "dumbbell.fill",
                 goals: [make(.workouts, sports: ["Strength"]), make(.workingSets)].compactMap { $0 }),
            Pack(id: "recovery", title: String(localized: "Recovery"), icon: "leaf.fill",
                 goals: [make(.restDays), make(.sleepNights)].compactMap { $0 }),
        ].filter { $0.goals.count >= 2 }
    }

    var body: some View {
        let available = packs
        if !available.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Start packs").strandOverline().padding(.horizontal, 2)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(available) { pack in
                            Button { openPack = pack } label: { packCard(pack) }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .sheet(item: $openPack) { pack in StartPackSheet(pack: pack) }
        }
    }

    private func packCard(_ pack: Pack) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(pack.title, systemImage: pack.icon).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
            ForEach(pack.goals) { goal in
                Text(GoalFormat.title(goal)).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("Look").font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.accent)
        }
        .frame(width: 220, height: 120, alignment: .topLeading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous)
            .fill(StrandPalette.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous)
            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }
}

struct StartPackSheet: View {
    let pack: StartPacksView.Pack
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var store = PeriodGoalStore.shared
    @ObservedObject private var tracking = GoalTrackingStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<UUID> = []
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(pack.goals) { goal in
                        Toggle(isOn: Binding(get: { chosen.contains(goal.id) },
                                             set: { if $0 { chosen.insert(goal.id) } else { chosen.remove(goal.id) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(GoalFormat.title(goal))
                                if store.canAdd(goal) != nil {
                                    Text("Already a goal").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                }
                            }
                        }
                        .disabled(store.canAdd(goal) != nil)
                    }
                } footer: {
                    Text("Values are read from your last weeks. You can change each goal later.")
                }
                if let message { Section { Text(message).foregroundStyle(StrandPalette.statusCritical) } }
            }
            .navigationTitle(pack.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(chosen.isEmpty)
                }
            }
            .onAppear { chosen = Set(pack.goals.filter { store.canAdd($0) == nil }.map(\.id)) }
        }
    }

    private func add() {
        let today = Repository.localDayKey(Date())
        for goal in pack.goals where chosen.contains(goal.id) {
            if store.canAdd(goal) == .limitReached {
                message = String(localized: "You have reached your limit of \(GoalPrefs.periodLimit) weekly and monthly goals.")
                break
            }
            if store.canAdd(goal) == nil { store.commit(goal, today: today) }
        }
        StrandHaptic.commit.play()
        Task { await tracking.refresh(repo: repo) }
        if message == nil { dismiss() }
    }
}

// MARK: - Quick edit (Today's context menu)

struct PeriodGoalEditSheet: View {
    let goalId: UUID
    let onChange: () -> Void
    @ObservedObject private var store = PeriodGoalStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var target: Double = 1
    @State private var threshold: Double?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                if let goal = store.goal(id: goalId) {
                    Section {
                        Stepper(value: Binding(get: { GoalFormat.display(target, goal.metric) },
                                               set: { target = GoalFormat.stored($0, goal.metric) }),
                                in: GoalFormat.display(goal.metric.range(for: goal.period).lowerBound, goal.metric)
                                    ... GoalFormat.display(goal.metric.range(for: goal.period).upperBound, goal.metric),
                                step: goal.metric.step(for: goal.period)) {
                            HStack {
                                Text("Target")
                                Spacer()
                                Text(GoalFormat.amount(target, goal.metric)).foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                        if goal.metric == .stepDays {
                            Stepper(value: Binding(get: { threshold ?? 8_000 }, set: { threshold = $0 }),
                                    in: 2_000...30_000, step: 500) {
                                Text("A day counts from \(Int(threshold ?? 8_000).formatted()) steps")
                            }
                        } else if goal.metric == .sleepNights {
                            Stepper(value: Binding(get: { threshold ?? 7 }, set: { threshold = $0 }), in: 4...11, step: 0.5) {
                                Text("A night counts from \((threshold ?? 7).formatted(.number.precision(.fractionLength(0...1)))) h")
                            }
                        }
                    } footer: {
                        Text("Applies from this \(GoalFormat.periodWord(goal.period)) on; earlier ones keep their target.")
                    }
                }
            }
            .navigationTitle("Change goal")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .onAppear {
                guard !loaded, let goal = store.goal(id: goalId) else { return }
                loaded = true
                target = goal.target
                threshold = goal.threshold
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let index = store.goals.firstIndex(where: { $0.id == goalId }) else { dismiss(); return }
        store.setTarget(goalId, target, today: Repository.localDayKey(Date()))
        if store.goals[index].threshold != threshold { store.goals[index].threshold = threshold }
        StrandHaptic.commit.play()
        onChange()
        dismiss()
    }
}
