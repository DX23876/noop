import SwiftUI
import WhoopStore
import StrandDesign
import StrandAnalytics

/// Setting a long-term goal from the catalog (plan §9): area, template, value and time, the weekly goal
/// that drives it, a preview. Every number on the way is read from the wearer's own data and can be
/// changed. "Own goal" leads to the older flow, which holds a goal without measuring it.
struct LongTermGoalSetupView: View {
    var onDone: () -> Void = {}
    /// False when `onDone` closes the screen this one was pushed from: that pop takes this page with
    /// it, and a second pop in the same moment is dropped, leaving the wearer on the screen before.
    var dismissesItself = true
    /// Set when an AgeLess lever opens the setup: it starts on the value step with this template and the
    /// lever's step pre-filled (`AgeLessGoalLink`), and Back leaves instead of returning to the catalog.
    var prefill: AgeLessGoalPrefill? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var goals = CoachGoalStore.shared
    @ObservedObject private var periodStore = PeriodGoalStore.shared
    @ObservedObject private var tracking = GoalTrackingStore.shared

    private enum Step: Int, CaseIterable { case area, template, value, weekly, preview }
    private typealias WeeklyChoice = LongTermGoalDraft.WeeklyChoice

    @State private var step: Step = .area
    @State private var area: GoalCatalogArea?
    @State private var template: GoalTemplate?
    @State private var sportIndex = 0
    @State private var target: Double = 0
    @State private var baseline: Double = 0
    @State private var countFromYearStart = true
    @State private var endDate = Date()
    @State private var hasDate = false
    @State private var targetDate = Date()
    @State private var openEnded = true
    @State private var fixedWeeks = 12
    @State private var weeklyOn = true
    @State private var weeklyTarget: Double = 3
    @State private var weeklyChoice: WeeklyChoice = .workouts
    @State private var title = ""
    /// The last name `nameAfterHabit` gave, so a later pick may replace it but never a typed one.
    @State private var autoTitle = ""
    @State private var motivation = ""
    @State private var riskReason = ""

    @State private var threshold: Double = 0
    @State private var band: Double = 1
    @State private var habitKey: String?
    @State private var habitWantsYes = true

    @State private var inputs = PeriodGoalInputs()
    @State private var series: [LongTermMetric: [GoalMilestones.Sample]] = [:]
    @State private var currentWeight: Double?
    @State private var loaded = false
    @State private var replaceCandidateId: UUID?
    @State private var replaceOffer: ReplaceOffer?
    @State private var showLimit = false
    @State private var showRisk = false
    @StateObject private var journal = JournalCatalogStore()
    @State private var importedQuestions: [String] = []

    private var calendar: Calendar { TrainingPreferences.weekCalendar }
    private var now: Date { Date() }

    var body: some View {
        ScreenScaffold(title: stepTitle, subtitle: stepSubtitle, topBackground: liquidScaffoldSky()) {
            progressDots
            switch step {
            // A lever's prefill lands on the value step once the data is in; until then nothing to pick.
            case .area where prefill != nil: ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            case .area: areaStep
            case .template: templateStep
            case .value: valueStep
            case .weekly: weeklyStep
            case .preview: previewStep
            }
            navigation
        }
        .task { await load() }
        // `item:` hands the sheet the goal it asks about; a Bool sheet reads the id from before the tap.
        .sheet(item: $replaceOffer) { offer in
            ReplaceGoalSheet(existingTitle: goals.goal(id: offer.id)?.title,
                             canKeepBoth: goals.hasRoom(),
                             onReplace: { replaceOffer = nil; create(replacing: offer.id) },
                             onKeepBoth: { replaceOffer = nil; create(replacing: nil) },
                             onCancel: { replaceOffer = nil; replaceCandidateId = nil })
        }
        .alert("You're at the limit", isPresented: $showLimit) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Close or set aside a goal first, or raise the limit in the goal settings.")
        }
        .alert("This pace is faster than recommended", isPresented: $showRisk) {
            TextField("Why it's right for you", text: $riskReason)
            Button("Save anyway") { commitChecked(replacing: replaceCandidateId, acknowledging: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(safety?.warning ?? "")
        }
    }

    // MARK: - Loading and the numbers it gives

    private func load() async {
        guard !loaded else { return }
        loaded = true
        inputs = await tracking.loadFullPeriodInputs(repo: repo)
        importedQuestions = Array(Set(await repo.importedJournalEntries().map(\.question))).sorted()
        series = await tracking.loadLevelSeries(repo: repo, metrics: [.restingHr, .sleepHeartRate, .vo2max, .bodyFat,
                                                                      .leanMass, .waist, .sleepConsistency])
        let weights = await repo.weightDailyValues(days: GoalMeasure.weightWindowDays)
        // The last weigh-in, the same number the goal page will show as its start: a trend lags the scale.
        currentWeight = weights.last { GoalMeasure.isPlausible($0.value, cfg: GoalMeasure.weightTrend) }?.value
        if let prefill { applyPrefill(prefill) }
    }

    /// Opens the value step on the lever's template with its target, once the data the suggestion reads is in.
    private func applyPrefill(_ prefill: AgeLessGoalPrefill) {
        guard let item = GoalCatalog.template(prefill.template) else { return }
        area = item.area
        template = item
        sportIndex = 0
        suggest()
        let rhythm = item.shape == .consistency
        target = AgeLessGoalLink.target(prefill, goalCurrent: rhythm ? recentAgeLessPerWeek : currentLevel,
                                        step: rhythm ? perWeekStep.step : levelStep.step,
                                        range: rhythm ? perWeekStep.range : levelStep.range)
        suggestWeekly()
        step = .value
    }

    /// The setup's state as the shared draft (`LongTermGoalDraft`), which owns every suggestion and the goal it
    /// builds; the view keeps the state it binds its controls to.
    private var draft: LongTermGoalDraft {
        LongTermGoalDraft(template: template, sportIndex: sportIndex, target: target, baseline: baseline,
                          countFromYearStart: countFromYearStart, endDate: endDate, hasDate: hasDate,
                          targetDate: targetDate, openEnded: openEnded, fixedWeeks: fixedWeeks, weeklyOn: weeklyOn,
                          weeklyTarget: weeklyTarget, weeklyChoice: weeklyChoice, title: title, motivation: motivation,
                          threshold: threshold, band: band, habitKey: habitKey, habitWantsYes: habitWantsYes,
                          inputs: inputs, series: series, currentWeight: currentWeight,
                          profileWeightKg: ProfileStore.persistedWeightKg, now: now, calendar: calendar)
    }

    /// Takes back what a draft suggestion changed.
    private func apply(_ d: LongTermGoalDraft) {
        target = d.target; baseline = d.baseline; endDate = d.endDate; hasDate = d.hasDate
        targetDate = d.targetDate; openEnded = d.openEnded; weeklyOn = d.weeklyOn; weeklyTarget = d.weeklyTarget
        weeklyChoice = d.weeklyChoice; title = d.title; threshold = d.threshold; band = d.band
        habitKey = d.habitKey; habitWantsYes = d.habitWantsYes
    }

    private var metric: LongTermMetric? { draft.metric }
    private var weeklyMetric: PeriodMetric? { draft.weeklyMetric }
    private var sportFilter: [String] { draft.sportFilter }
    private func matchingRows() -> [WorkoutRow] { draft.matchingRows() }
    private var recentPerWeek: Double { draft.recentPerWeek }
    private var recentSessionsPerWeek: Double { draft.recentSessionsPerWeek }
    private var yearStart: Date { draft.yearStart }
    private var countFrom: Date { draft.countFrom }
    private var collectedSoFar: Double { draft.collectedSoFar }
    private var weeksToEnd: Double { draft.weeksToEnd }
    private var bestLast12Weeks: Double? { draft.bestLast12Weeks }
    private var currentLevel: Double? { draft.currentLevel }
    private var hasMeasuredStart: Bool { draft.hasMeasuredStart }
    private var levelStep: (step: Double, range: ClosedRange<Double>) { draft.levelStep }
    private var recentAgeLessPerWeek: Double? { draft.recentAgeLessPerWeek }
    private var hasLiftingLog: Bool { draft.hasLiftingLog }
    private var recentKmPerWeek: Double { draft.recentKmPerWeek }
    private var shape: GoalShape? { draft.shape }
    private var perWeekStep: (step: Double, range: ClosedRange<Double>) { draft.perWeekStep }
    private var safety: GoalSafetyGate.Assessment? { draft.safety }
    private func suggestedPerWeek() -> Double { draft.suggestedPerWeek() }
    private func sumStep(_ value: Double) -> Double { draft.sumStep(value) }
    private func safeDate() -> Date { draft.safeDate() }
    private func suggest() { var d = draft; d.suggest(); apply(d) }
    private func resuggestSum() { var d = draft; d.resuggestSum(); apply(d) }
    private func suggestWeekly() { var d = draft; d.suggestWeekly(); apply(d) }


    private func attemptCreate() {
        guard let template else { return }
        // Several goals of one area are fine (VO2max beside HRV); the question is only worth asking
        // when the same thing would be measured twice.
        if let existing = draft.sameMeasureGoal(template, goals: goals, periods: periodStore) {
            replaceCandidateId = existing.id
            replaceOffer = ReplaceOffer(id: existing.id)
        } else if !goals.hasRoom() {
            showLimit = true
        } else {
            create(replacing: nil)
        }
    }

    private func create(replacing: UUID?) {
        replaceCandidateId = replacing
        if safety?.requiresReason == true {
            showRisk = true
            return
        }
        commitChecked(replacing: replacing, acknowledging: false)
    }

    private func commitChecked(replacing: UUID?, acknowledging: Bool) {
        let ack: CoachGoal.RiskAcknowledgement? = acknowledging
            ? CoachGoalRisk.acknowledgement(verdict: safety?.verdict.rawValue ?? "veryAggressive", reason: riskReason)
            : nil
        guard draft.commit(goals: goals, periods: periodStore, replacing: replacing, acknowledgedRisk: ack) != nil
        else { return }
        StrandHaptic.commit.play()
        Task { await tracking.refresh(repo: repo) }
        onDone()
        if dismissesItself { dismiss() }
    }

    // MARK: - Steps

    private var stepTitle: LocalizedStringKey {
        switch step {
        case .area: return "What do you want to work on?"
        case .template: return "Pick a goal"
        case .value:
            switch template?.shape {
            case .sum?, .best?, .target?: return "How much, and by when?"
            default: return "What are you aiming for?"
            }
        case .weekly: return "Your weekly goal"
        case .preview: return "This is your goal"
        }
    }

    private var stepSubtitle: LocalizedStringKey? {
        switch step {
        case .area: return "Every goal here is measured from your own data."
        case .template: return "Greyed goals say what they still need."
        case .value: return "Suggested from your recent weeks. Change anything."
        case .weekly: return "The week is where a long-term goal is made."
        case .preview: return "You can change it later."
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

    private var areaStep: some View {
        let areas = GoalCatalogArea.allCases.filter { a in GoalCatalog.offered.contains { $0.area == a } }
        let weight = currentWeight ?? (ProfileStore.persistedWeightKg > 0 ? ProfileStore.persistedWeightKg : nil)
        return VStack(alignment: .leading, spacing: 16) {
            if loaded {
                LongTermStartPacksRow(packs: LongTermStartPack.packs(inputs: inputs, weight: weight)) {
                    onDone()
                    if dismissesItself { dismiss() }
                }
            }
            areaGrid(areas)
        }
    }

    private func areaGrid(_ areas: [GoalCatalogArea]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(areas) { a in
                tile(icon: a.icon, title: a.title.localizedCatalogValue, selected: area == a) {
                    area = a
                    template = nil
                    step = .template
                }
            }
            NavigationLink { CoachGoalOnboardingFlow(pushed: true) } label: {
                tileLabel(icon: "sparkles", title: String(localized: "Own goal"), selected: false)
            }
            .buttonStyle(.plain)
        }
    }

    private var templateStep: some View {
        VStack(spacing: 10) {
            ForEach(GoalCatalog.offered.filter { $0.area == area }) { item in
                let availability = GoalCatalog.availability(item.id, inputs: inputs, series: series,
                                                            hasWeight: currentWeight != nil || ProfileStore.persistedWeightKg > 0)
                Button {
                    guard availability == .available else { return }
                    template = item
                    sportIndex = 0
                    suggest()
                    step = .value
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: item.icon).font(.title3).foregroundStyle(StrandPalette.accent)
                            .frame(width: 30).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title.localizedCatalogValue).font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            if case .unavailable(let reason) = availability {
                                Text(reason.localizedCatalogValue).font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            } else {
                                Text(item.blurb.localizedCatalogValue).font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                        .fill(StrandPalette.surfaceRaised))
                    .overlay(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    .opacity(availability == .available ? 1 : StrandPalette.disabledOpacity)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var valueStep: some View {
        if let template {
            VStack(alignment: .leading, spacing: 14) {
                if !template.sportChoices.isEmpty {
                    Picker("Sport", selection: $sportIndex) {
                        ForEach(template.sportChoices.indices, id: \.self) { index in
                            Text(template.sportChoices[index].label.localizedCatalogValue).tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: sportIndex) { _ in suggest() }
                }
                switch template.shape {
                case .sum: sumValue
                case .best: bestValue
                case .target: targetValue
                case .maintain: maintainValue
                case .consistency: rhythmValue
                case .average: averageValue
                }
            }
        }
    }

    private var sumValue: some View {
        NoopCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                if let metric {
                    stepperRow("Target", value: $target, step: sumStep(target), range: sumStep(0)...100_000_000,
                               text: LongTermFormat.value(target, metric))
                    Toggle("Count from the start of the year", isOn: $countFromYearStart)
                        .onChange(of: countFromYearStart) { _ in resuggestSum(); suggestWeekly() }
                    GoalDateField(label: "By", selection: $endDate, from: now.addingTimeInterval(7 * 86_400))
                        .onChange(of: endDate) { _ in suggestWeekly() }
                    factLine(String(localized: "So far: \(LongTermFormat.value(collectedSoFar, metric))"))
                    factLine(String(localized: "Your average: \(LongTermFormat.value(recentPerWeek, metric))/week"))
                    let needed = max(0, target - collectedSoFar) / weeksToEnd
                    factLine(String(localized: "Needed: \(LongTermFormat.value(needed, metric))/week"))
                    if metric == .distanceTotal {
                        factLine(String(localized: "Only workouts with a distance count: from your phone, a watch or a file. A workout only the strap recorded has none."))
                    }
                }
            }
        }
    }

    private var bestValue: some View {
        NoopCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                stepperRow("Distance", value: $target, step: 0.5, range: 1...200,
                           text: LongTermFormat.value(target, .longestDistance))
                HStack {
                    ForEach([5.0, 10, 21.1, 42.2], id: \.self) { km in
                        Button(LongTermFormat.value(km, .longestDistance)) { target = km }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                factLine(String(localized: "Your longest in the last 12 weeks: \(bestLast12Weeks.map { LongTermFormat.value($0, .longestDistance) } ?? "–")"))
                if let best = bestLast12Weeks, best >= target {
                    Label("You already managed this lately. Aim further?", systemImage: "exclamationmark.circle")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarningForeground)
                }
                if template?.id == .event {
                    GoalDateField(label: "Race day", selection: $targetDate, from: now.addingTimeInterval(14 * 86_400))
                } else {
                    Toggle("Reach it by a date", isOn: $hasDate)
                    if hasDate {
                        GoalDateField(label: "By", selection: $targetDate, from: now.addingTimeInterval(14 * 86_400))
                    }
                }
            }
        }
    }

    private var targetValue: some View {
        NoopCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                if let metric {
                    // The start is what was measured, not a choice: only without any reading is it set by hand.
                    if hasMeasuredStart {
                        HStack {
                            Text("Start").font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                            Spacer()
                            Text(verbatim: LongTermFormat.value(baseline, metric))
                                .font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                        }
                    } else {
                        stepperRow("Start", value: $baseline, step: levelStep.step, range: levelStep.range,
                                   text: LongTermFormat.value(baseline, metric))
                    }
                    stepperRow("Target", value: $target, step: levelStep.step, range: levelStep.range,
                               text: LongTermFormat.value(target, metric))
                    if metric == .weight {
                        factLine(currentWeight == nil ? String(localized: "No weigh-in yet: the start is from your profile.")
                                                      : String(localized: "Start from your weight trend."))
                    } else if metric == .vo2max {
                        factLine(currentLevel == nil ? String(localized: "In ml/kg/min. No reading yet: set the start yourself.")
                                                     : String(localized: "In ml/kg/min, from your recent readings."))
                    } else if metric == .restingHr {
                        factLine(String(localized: "Measured as the average of your last 28 nights. The goal counts as reached once that average holds at the target."))
                    } else {
                        factLine(currentLevel == nil ? String(localized: "No reading yet: set the start yourself.")
                                                     : String(localized: "Start from your recent readings."))
                    }
                    Toggle("Reach it by a date", isOn: $hasDate)
                        .onChange(of: hasDate) { on in if on { targetDate = safeDate() } }
                    if hasDate {
                        GoalDateField(label: "By", selection: $targetDate, from: now.addingTimeInterval(14 * 86_400))
                        if let warning = safety?.warning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarningForeground)
                        }
                    } else {
                        factLine(String(localized: "Without a date the page shows your pace and when you reach the next mark."))
                    }
                }
            }
        }
    }

    private var maintainValue: some View {
        NoopCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                stepperRow("Weight", value: $target, step: 0.5, range: 30...400,
                           text: LongTermFormat.value(target, .weight))
                stepperRow("Band", value: $band, step: 0.5, range: 0.5...5,
                           text: String(localized: "± \(LongTermFormat.value(band, .weight))"))
                factLine(String(localized: "On track when four in five weigh-ins of the last four weeks are inside the band."))
            }
        }
    }

    private var rhythmValue: some View {
        NoopCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                if let weeklyMetric {
                    stepperRow("Per week", value: $target, step: perWeekStep.step, range: perWeekStep.range,
                               text: LongTermFormat.perWeek(target, weeklyMetric))
                    switch weeklyMetric {
                    case .stepDays:
                        stepperRow("Steps a day", value: $threshold, step: 1_000, range: 2_000...30_000,
                                   text: Int(threshold).formatted())
                    case .sleepNights:
                        stepperRow("Sleep a night", value: $threshold, step: 0.25, range: 5...10,
                                   text: LongTermFormat.hoursAndMinutes(threshold))
                    case .habitDays:
                        habitPicker
                    case .workouts:
                        factLine(String(localized: "Your average lately: \(LongTermFormat.number(recentSessionsPerWeek)) a week"))
                    default:
                        EmptyView()
                    }
                    Toggle("Keep it going without an end", isOn: $openEnded)
                    if openEnded {
                        factLine(String(localized: "Judged over a rolling 12 weeks from the first week on: on track from 80 % of weeks kept."))
                    } else {
                        Stepper(value: $fixedWeeks, in: 4...52) {
                            Text("For \(fixedWeeks) weeks").font(StrandFont.body)
                        }
                    }
                }
            }
        }
    }

    private var habitPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The journal's own list: starter questions, imported ones and custom ones. `items` alone
            // holds only edited or custom entries, so a fresh journal looked empty here.
            let items = journal.resolvedItems(imported: importedQuestions)
            if items.isEmpty {
                factLine(String(localized: "Your journal has no habits yet. Add one in Journal first."))
            }
            Picker("Habit", selection: Binding(get: { habitKey ?? "" }, set: { habitKey = $0.isEmpty ? nil : $0; nameAfterHabit() })) {
                Text("Choose").tag("")
                ForEach(items) { item in Text(item.displayName ?? item.canonical).tag(item.canonical) }
            }
            Picker("Goal", selection: $habitWantsYes) {
                Text("Do it").tag(true)
                Text("Avoid it").tag(false)
            }
            .pickerStyle(.segmented)
            .onChange(of: habitWantsYes) { _ in nameAfterHabit() }
        }
    }

    /// "Keep a journal habit" says nothing on the list: the name follows the habit picked, until the
    /// wearer types one of their own.
    private func nameAfterHabit() {
        guard let template, template.id == .journalHabit else { return }
        let generic = template.title.localizedCatalogValue
        guard title.isEmpty || title == generic || title == autoTitle else { return }
        guard let key = habitKey else { title = generic; return }
        let name = journal.displayName(for: key)
        title = habitWantsYes ? String(localized: "Do: \(name)") : String(localized: "Avoid: \(name)")
        autoTitle = title
    }

    private var averageValue: some View {
        NoopCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                if let metric {
                    stepperRow(metric == .paceAverage ? "Pace" : "Average", value: $target, step: levelStep.step,
                               range: levelStep.range, text: LongTermFormat.value(target, metric))
                    let last = metric == .paceAverage ? String(localized: "Your pace over the last 8 weeks")
                                                      : String(localized: "Your last 28 days")
                    factLine("\(last): \(currentLevel.map { LongTermFormat.value($0, metric) } ?? "–")")
                    if metric == .paceAverage {
                        factLine(String(localized: "Counts runs of 3 km or more: total time over total distance."))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var weeklyStep: some View {
        if let template {
            NoopCard(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    if let weekly = template.id.weeklyMetric {
                        factLine(String(localized: "This goal is measured by its weekly goal: \(LongTermFormat.perWeek(target, weekly)). Each week you keep counts."))
                    } else if template.id == .sleepConsistency {
                        factLine(String(localized: "Regularity is judged night by night against the four nights before, so this goal needs no weekly goal."))
                    } else {
                        Toggle("Add a weekly goal", isOn: $weeklyOn)
                        if weeklyOn { weeklyControls(template) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func weeklyControls(_ template: GoalTemplate) -> some View {
        switch template.id {
        case .distanceTotal, .timeTotal, .workoutsTotal:
            let weekly: PeriodMetric = template.id == .distanceTotal ? .distance
                : template.id == .timeTotal ? .trainingMinutes : .workouts
            stepperRow("This week", value: $weeklyTarget, step: weekly == .trainingMinutes ? 10 : 1, range: 1...5_000,
                       text: LongTermFormat.perWeek(weeklyTarget, weekly))
            factLine(String(localized: "It follows the long-term goal: each new week gets what is still needed, never more than 10 % above your recent running weeks (20 % for other sports)."))
        case .stepsTotal:
            stepperRow("Days of 8,000 steps", value: $weeklyTarget, step: 1, range: 1...7,
                       text: LongTermFormat.perWeek(weeklyTarget, .stepDays))
        case .stepsAverage:
            stepperRow("Step days", value: $weeklyTarget, step: 1, range: 1...7,
                       text: String(localized: "\(LongTermFormat.number(weeklyTarget)) days from \(LongTermFormat.value(target, .stepsAverage)) steps"))
        case .longest, .event:
            stepperRow("Per week", value: $weeklyTarget, step: 1, range: 1...300,
                       text: LongTermFormat.value(weeklyTarget, .distanceTotal))
        case .weightLose, .weightMaintain:
            Picker("Weekly goal", selection: $weeklyChoice) {
                Text("Workouts").tag(WeeklyChoice.workouts)
                Text("Step days").tag(WeeklyChoice.stepDays)
            }
            .pickerStyle(.segmented)
            .onChange(of: weeklyChoice) { choice in weeklyTarget = choice == .workouts ? 3 : 5 }
            stepperRow(weeklyChoice == .workouts ? "Workouts" : "Days of 8,000 steps",
                       value: $weeklyTarget, step: 1, range: 1...7,
                       text: LongTermFormat.number(weeklyTarget))
            factLine(String(localized: "Weight swings a kilo or two within a week, so the week counts what you do, not the scale."))
        case .weightGain, .leanMass:
            if hasLiftingLog {
                stepperRow("Working sets", value: $weeklyTarget, step: 5, range: 5...300,
                           text: LongTermFormat.perWeek(weeklyTarget, .workingSets))
            } else {
                stepperRow("Workouts", value: $weeklyTarget, step: 1, range: 1...14,
                           text: LongTermFormat.perWeek(weeklyTarget, .workouts))
            }
        case .bodyFat, .waist:
            stepperRow("Workouts", value: $weeklyTarget, step: 1, range: 1...14,
                       text: LongTermFormat.perWeek(weeklyTarget, .workouts))
        case .vo2max, .restingHr, .sleepHeartRate:
            stepperRow("Zone 2+ minutes", value: $weeklyTarget, step: 10, range: 30...1_200,
                       text: LongTermFormat.perWeek(weeklyTarget, .zoneMinutes))
            factLine(String(localized: "Time in zone 2 and above is what moves aerobic fitness. The WHO suggests 150 minutes a week."))
        case .sleepAverage:
            stepperRow("Nights", value: $weeklyTarget, step: 1, range: 1...7,
                       text: String(localized: "\(LongTermFormat.number(weeklyTarget)) nights from \(LongTermFormat.hoursAndMinutes(max(5, target - 0.5)))"))
        case .hrvAverage, .recoveryAverage:
            stepperRow("Nights", value: $weeklyTarget, step: 1, range: 1...7,
                       text: String(localized: "\(LongTermFormat.number(weeklyTarget)) nights from \(LongTermFormat.hoursAndMinutes(7))"))
            factLine(String(localized: "Nothing moves HRV and recovery as reliably as enough sleep, so the week counts nights of 7 hours or more."))
        case .paceAverage:
            stepperRow("Runs", value: $weeklyTarget, step: 1, range: 1...14,
                       text: LongTermFormat.perWeek(weeklyTarget, .workouts))
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var previewStep: some View {
        if let template {
            VStack(alignment: .leading, spacing: 14) {
                GoalHeroCard(title: title.isEmpty ? template.title.localizedCatalogValue : title,
                             stateWord: String(localized: "Starting"), stateSymbol: "hourglass",
                             stateTone: .neutral, icon: template.icon, iconTint: StrandPalette.accent,
                             heroValue: previewValue, heroCaption: previewCaption,
                             stats: [], compact: true) {
                    LongTermGoalScene()
                }
                NoopCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Name", text: $title)
                        TextField("Why it matters to you (optional, stays on this device)", text: $motivation,
                                  axis: .vertical)
                            .lineLimit(1...3)
                    }
                    .font(StrandFont.body)
                }
                Button { attemptCreate() } label: {
                    Text("Set goal").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var previewValue: String {
        guard let template, let metric else { return "" }
        switch template.shape {
        case .best: return LongTermFormat.value(target, .longestDistance)
        case .consistency: return template.id.weeklyMetric.map { LongTermFormat.perWeek(target, $0) } ?? ""
        case .maintain: return String(localized: "\(LongTermFormat.value(target, metric)) ± \(LongTermFormat.value(band, metric))")
        case .sum, .target, .average: return LongTermFormat.value(target, metric)
        }
    }

    private var previewCaption: String? {
        guard let template else { return nil }
        switch template.shape {
        case .sum: return String(localized: "by \(LongTermFormat.shortDate(endDate))")
        case .best, .target:
            if hasDate { return String(localized: "by \(LongTermFormat.shortDate(targetDate))") }
            return metric == .vo2max ? "ml/kg/min" : nil
        case .consistency: return LongTermFormat.dayBar(template.id.weeklyMetric ?? .workouts, threshold: threshold)
        case .average: return String(localized: "target, as a 28-day average")
        case .maintain: return nil
        }
    }

    // MARK: - Pieces

    private var navigation: some View {
        HStack {
            if step != .area {
                Button("Back") {
                    if prefill != nil, step == .value { dismiss() }
                    else if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
                }
            }
            Spacer()
            if step == .value || step == .weekly {
                Button("Next") {
                    if let next = Step(rawValue: step.rawValue + 1) { step = next }
                }
                .buttonStyle(.borderedProminent)
                .disabled(target <= 0 || (template?.id == .journalHabit && habitKey == nil))
            }
        }
        .padding(.top, 4)
    }

    private func tile(icon: String, title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(icon: icon, title: title, selected: selected) }
            .buttonStyle(.plain)
    }

    private func tileLabel(icon: String, title: String, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
            Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
            .fill(StrandPalette.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
            .strokeBorder(selected ? StrandPalette.accent : StrandPalette.hairline, lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }

    private func stepperRow(_ label: LocalizedStringKey, value: Binding<Double>, step: Double,
                            range: ClosedRange<Double>, text: String) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(label).font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text(verbatim: text).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }

    private func factLine(_ text: String) -> some View {
        Text(verbatim: text).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A date row whose picker rises from the bottom as a sheet with the system calendar, instead of the
/// compact picker's popover that opens over the card it sits in.
private struct GoalDateField: View {
    let label: LocalizedStringKey
    @Binding var selection: Date
    let from: Date
    @State private var open = false

    var body: some View {
        HStack {
            Text(label).font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Button { open = true } label: {
                Text(selection, format: .dateTime.day().month(.abbreviated).year())
                    .font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
            }
            .buttonStyle(.bordered)
        }
        .sheet(isPresented: $open) {
            VStack(spacing: 12) {
                DatePicker("", selection: $selection, in: from..., displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                Button { open = false } label: { Text("Done").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(20)
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #else
            .frame(minWidth: 340, minHeight: 420)
            #endif
        }
    }
}

/// The existing goal a new one would replace, as a sheet item.
private struct ReplaceOffer: Identifiable {
    let id: UUID
}

/// The question before a second goal of a kind: a sheet from the bottom that names the goal it would
/// close, since "a goal of this type" alone does not say which one.
private struct ReplaceGoalSheet: View {
    let existingTitle: String?
    let canKeepBoth: Bool
    let onReplace: () -> Void
    let onKeepBoth: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Replace your existing goal?").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Group {
                if let existingTitle {
                    Text("“\(existingTitle)” measures the same kind of thing. Replacing it closes that goal but keeps its history.")
                } else {
                    Text("A goal of this type is already active. Replacing it closes the old goal but keeps its history.")
                }
            }
            .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                if canKeepBoth {
                    Button(action: onKeepBoth) { Text("Keep both").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                }
                Button(action: onReplace) { Text("Replace it").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                Button("Cancel", action: onCancel)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .controlSize(.large)
        }
        .padding(24)
        #if os(iOS)
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 380)
        #endif
    }
}
