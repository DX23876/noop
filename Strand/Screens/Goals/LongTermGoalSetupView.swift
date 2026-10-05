import SwiftUI
import WhoopStore
import StrandDesign
import StrandAnalytics

/// Setting a long-term goal from the catalog (plan §9): area, template, value and time, the weekly goal
/// that drives it, a preview. Every number on the way is read from the wearer's own data and can be
/// changed. "Own goal" leads to the older flow, which holds a goal without measuring it.
struct LongTermGoalSetupView: View {
    var onDone: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var goals = CoachGoalStore.shared
    @ObservedObject private var periodStore = PeriodGoalStore.shared
    @ObservedObject private var tracking = GoalTrackingStore.shared

    private enum Step: Int, CaseIterable { case area, template, value, weekly, preview }
    private enum WeeklyChoice: String, CaseIterable { case workouts, stepDays }

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
    @State private var motivation = ""
    @State private var riskReason = ""

    @State private var inputs = PeriodGoalInputs()
    @State private var currentWeight: Double?
    @State private var loaded = false
    @State private var replaceCandidateId: UUID?
    @State private var showReplace = false
    @State private var showLimit = false
    @State private var showRisk = false

    private var calendar: Calendar { TrainingPreferences.weekCalendar }
    private var now: Date { Date() }

    var body: some View {
        ScreenScaffold(title: stepTitle, subtitle: stepSubtitle, topBackground: liquidScaffoldSky()) {
            progressDots
            switch step {
            case .area: areaStep
            case .template: templateStep
            case .value: valueStep
            case .weekly: weeklyStep
            case .preview: previewStep
            }
            navigation
        }
        .task { await load() }
        .confirmationDialog("Replace your existing goal?", isPresented: $showReplace, titleVisibility: .visible) {
            Button("Replace it") { create(replacing: replaceCandidateId) }
            if goals.hasRoom() { Button("Keep both") { create(replacing: nil) } }
            Button("Cancel", role: .cancel) { replaceCandidateId = nil }
        } message: {
            Text("A goal of this type is already active. Replacing it closes the old goal but keeps its history.")
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
        let weights = await repo.weightDailyValues(days: GoalMeasure.weightWindowDays)
        currentWeight = GoalMeasure.smoothedTrend(weights.map(\.value), cfg: GoalMeasure.weightTrend)?.value
    }

    private var sportFilter: [String] {
        guard let template, template.sportChoices.indices.contains(sportIndex) else { return [] }
        return template.sportChoices[sportIndex].filter
    }

    private func matchingRows() -> [WorkoutRow] {
        inputs.workouts.filter { GoalActionEvaluator.matches($0, any: sportFilter) }
    }

    /// Kilometres (or sessions) per week over the last four complete weeks, in the chosen sports.
    private func recentWeekly(_ amount: (WorkoutRow) -> Double?) -> Double {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let from = calendar.date(byAdding: .weekOfYear, value: -4, to: weekStart) ?? weekStart
        let total = matchingRows().filter {
            let date = Date(timeIntervalSince1970: Double($0.startTs))
            return date >= from && date < weekStart
        }.compactMap(amount).reduce(0, +)
        return total / 4
    }

    private var recentKmPerWeek: Double { recentWeekly { ($0.distanceM ?? 0) / 1_000 } }
    private var recentSessionsPerWeek: Double { recentWeekly { _ in 1 } }

    private var yearStart: Date {
        Calendar.autoupdatingCurrent.date(from: Calendar.autoupdatingCurrent.dateComponents([.year], from: now)) ?? now
    }

    private var countFrom: Date { countFromYearStart ? yearStart : Calendar.autoupdatingCurrent.startOfDay(for: now) }

    private var collectedSoFar: Double {
        let from = countFrom.timeIntervalSince1970
        return matchingRows().filter { Double($0.startTs) >= from }.reduce(0) { $0 + ($1.distanceM ?? 0) / 1_000 }
    }

    private var weeksToEnd: Double { max(1, endDate.timeIntervalSince(now) / (7 * 86_400)) }

    private var bestLast12Weeks: Double? {
        let from = now.addingTimeInterval(-84 * 86_400).timeIntervalSince1970
        return matchingRows().filter { Double($0.startTs) >= from }.compactMap(\.distanceM).max().map { $0 / 1_000 }
    }

    private var sleepMean28: Double? {
        let nights = inputs.days.sorted { $0.day < $1.day }.suffix(28).compactMap(\.totalSleepMin)
        return nights.count >= 7 ? nights.reduce(0, +) / Double(nights.count) / 60 : nil
    }

    /// Sets the value step's numbers from the data, once per template.
    private func suggest() {
        guard let template else { return }
        title = template.title.localizedCatalogValue
        switch template.id {
        case .distanceTotal:
            let thisYearEnd = Calendar.autoupdatingCurrent.date(byAdding: DateComponents(year: 1, day: -1), to: yearStart) ?? now
            endDate = thisYearEnd.timeIntervalSince(now) > 56 * 86_400
                ? thisYearEnd : Calendar.autoupdatingCurrent.date(byAdding: .month, value: 6, to: now) ?? now
            resuggestSum()
        case .longest:
            let best = bestLast12Weeks ?? 0
            baseline = best
            target = [5.0, 10, 15, 21.1, 42.2].first { $0 > best } ?? (best + 5).rounded()
            hasDate = false
        case .weightLose:
            baseline = currentWeight.map { ($0 * 10).rounded() / 10 } ?? ProfileStore.persistedWeightKg
            target = max(30, (baseline - 5).rounded())
            hasDate = false
            targetDate = safeDate()
        case .trainingWeekly:
            target = recentSessionsPerWeek > 0 ? min(14, (recentSessionsPerWeek + 1).rounded()) : 3
            openEnded = true
        case .sleepAverage:
            baseline = sleepMean28 ?? 7
            target = min(10, max(7.5, ((baseline + 0.25) * 4).rounded(.up) / 4))
        default:
            break
        }
        suggestWeekly()
    }

    private func resuggestSum() {
        let already = countFromYearStart ? collectedSoFar : 0
        let projected = already + recentKmPerWeek * weeksToEnd
        let step: Double = projected >= 200 ? 50 : 10
        target = max(step, (projected / step).rounded(.up) * step)
    }

    /// The date a weight change reaches at 0.5 kg a week, a pace the safety gate calls conservative.
    private func safeDate() -> Date {
        let weeks = max(4, abs(baseline - target) / 0.5)
        return now.addingTimeInterval(weeks * 7 * 86_400)
    }

    private func suggestWeekly() {
        guard let template else { return }
        weeklyOn = true
        switch template.id {
        case .distanceTotal:
            let already = countFromYearStart ? collectedSoFar : 0
            weeklyTarget = max(1, ((target - already) / weeksToEnd).rounded())
        case .longest:
            weeklyTarget = max(5, recentKmPerWeek.rounded())
        case .weightLose:
            weeklyChoice = .workouts
            weeklyTarget = 3
        case .trainingWeekly:
            weeklyTarget = target
        case .sleepAverage:
            weeklyTarget = 5
        default:
            break
        }
    }

    // MARK: - The goal it makes

    private var shape: GoalShape? { template?.shape }

    private func buildGoal(weeklyGoalId: UUID?) -> CoachGoal? {
        guard let template else { return nil }
        var spec = GoalMeasureSpec(metric: template.id.metric, sportFilter: sportFilter)
        var goalBaseline: Double? = baseline
        var date: Date? = hasDate ? targetDate : nil
        switch template.id {
        case .distanceTotal:
            spec.countFrom = countFrom
            goalBaseline = 0
            date = endDate
        case .trainingWeekly:
            goalBaseline = recentSessionsPerWeek
            spec.weeklyGoalId = weeklyGoalId
            spec.adherenceWeeks = LongTermGoalMath.adherenceWindowWeeks
            spec.adherenceTarget = LongTermGoalMath.adherenceTarget
            if !openEnded { spec.fixedEnd = now.addingTimeInterval(Double(fixedWeeks) * 7 * 86_400) }
            date = spec.fixedEnd
        case .sleepAverage:
            date = nil
        default:
            break
        }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return CoachGoal(kind: template.id.kind, title: name.isEmpty ? template.title.localizedCatalogValue : name,
                         baseline: goalBaseline, target: target, targetDate: date,
                         motivation: motivation.trimmingCharacters(in: .whitespacesAndNewlines),
                         templateId: template.id.rawValue, measure: spec)
    }

    private var safety: GoalSafetyGate.Assessment? {
        guard template?.id == .weightLose, hasDate, let goal = buildGoal(weeklyGoalId: nil) else { return nil }
        return GoalSafetyGate.assess(goal: goal, bodyWeightKg: currentWeight ?? ProfileStore.persistedWeightKg)
    }

    private func weeklyDraft(parentId: UUID) -> PeriodGoal? {
        guard let template else { return nil }
        switch template.id {
        case .distanceTotal:
            guard weeklyOn else { return nil }
            return PeriodGoal(metric: .distance, period: .week, target: weeklyTarget, sportFilter: sportFilter,
                              parentGoalId: parentId, followsParent: true)
        case .longest:
            guard weeklyOn else { return nil }
            return PeriodGoal(metric: .distance, period: .week, target: weeklyTarget, sportFilter: sportFilter,
                              parentGoalId: parentId)
        case .weightLose:
            guard weeklyOn else { return nil }
            return weeklyChoice == .workouts
                ? PeriodGoal(metric: .workouts, period: .week, target: weeklyTarget, parentGoalId: parentId)
                : PeriodGoal(metric: .stepDays, period: .week, target: weeklyTarget,
                             threshold: PeriodMetric.stepDays.defaultThreshold, parentGoalId: parentId)
        case .trainingWeekly:
            return PeriodGoal(metric: .workouts, period: .week, target: target, sportFilter: sportFilter,
                              parentGoalId: parentId)
        case .sleepAverage:
            guard weeklyOn else { return nil }
            return PeriodGoal(metric: .sleepNights, period: .week, target: weeklyTarget,
                              threshold: max(5, target - 0.5), parentGoalId: parentId)
        default:
            return nil
        }
    }

    // MARK: - Saving

    private func attemptCreate() {
        guard let template else { return }
        switch goals.canAdd(kind: template.id.kind) {
        case .kindAlreadyActive(let existingId)?:
            replaceCandidateId = existingId
            showReplace = true
        case .tooManyActive?:
            showLimit = true
        case nil:
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
        let parentId = UUID()
        let today = Repository.localDayKey(now)
        var weekly = weeklyDraft(parentId: parentId)
        // The same weekly slot already tracked: that goal is linked instead of a second one beside it.
        if let draft = weekly, case .duplicate(let existingId)? = periodStore.canAdd(draft) {
            if periodStore.goal(id: existingId)?.parentGoalId == nil {
                periodStore.link(existingId, to: parentId)
                weekly = periodStore.goal(id: existingId)
            } else {
                weekly = nil
            }
        } else if let draft = weekly, periodStore.canAdd(draft) == nil {
            periodStore.commit(draft, today: today)
        } else {
            weekly = nil
        }
        guard var goal = buildGoal(weeklyGoalId: weekly?.id) else { return }
        goal = CoachGoal(id: parentId, kind: goal.kind, title: goal.title, baseline: goal.baseline,
                         target: goal.target, targetDate: goal.targetDate, motivation: goal.motivation,
                         templateId: goal.templateId, measure: goal.measure)
        let ack: CoachGoal.RiskAcknowledgement? = acknowledging
            ? CoachGoalRisk.acknowledgement(verdict: safety?.verdict.rawValue ?? "veryAggressive", reason: riskReason)
            : nil
        goals.commit(goal, replacing: replacing, acknowledgedRisk: ack)
        StrandHaptic.commit.play()
        Task { await tracking.refresh(repo: repo) }
        onDone()
        dismiss()
    }

    // MARK: - Steps

    private var stepTitle: LocalizedStringKey {
        switch step {
        case .area: return "What do you want to work on?"
        case .template: return "Pick a goal"
        case .value: return "How much, and by when?"
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
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
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
                let availability = GoalCatalog.availability(item.id, workouts: inputs.workouts, days: inputs.days)
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
                switch template.id {
                case .distanceTotal: sumValue
                case .longest: bestValue
                case .weightLose: weightValue
                case .trainingWeekly: rhythmValue
                case .sleepAverage: sleepValue
                default: EmptyView()
                }
            }
        }
    }

    private var sumValue: some View {
        NoopCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                stepperRow("Target", value: $target, step: target >= 200 ? 50 : 10, range: 10...20_000,
                           text: LongTermFormat.value(target, .distanceTotal))
                Toggle("Count from the start of the year", isOn: $countFromYearStart)
                    .onChange(of: countFromYearStart) { _ in resuggestSum(); suggestWeekly() }
                DatePicker("By", selection: $endDate, in: now.addingTimeInterval(7 * 86_400)..., displayedComponents: .date)
                    .onChange(of: endDate) { _ in suggestWeekly() }
                factLine(String(localized: "So far: \(LongTermFormat.value(countFromYearStart ? collectedSoFar : 0, .distanceTotal))"))
                factLine(String(localized: "Your average: \(LongTermFormat.value(recentKmPerWeek, .distanceTotal))/week"))
                let needed = max(0, target - (countFromYearStart ? collectedSoFar : 0)) / weeksToEnd
                factLine(String(localized: "Needed: \(LongTermFormat.value(needed, .distanceTotal))/week"))
                factLine(String(localized: "Only workouts with a distance count: from your phone, a watch or a file. A workout only the strap recorded has none."))
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
                Toggle("Reach it by a date", isOn: $hasDate)
                if hasDate {
                    DatePicker("By", selection: $targetDate, in: now.addingTimeInterval(14 * 86_400)..., displayedComponents: .date)
                }
            }
        }
    }

    private var weightValue: some View {
        NoopCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                stepperRow("Start", value: $baseline, step: 0.5, range: 30...400,
                           text: LongTermFormat.value(baseline, .weight))
                stepperRow("Target", value: $target, step: 0.5, range: 30...400,
                           text: LongTermFormat.value(target, .weight))
                factLine(currentWeight == nil ? String(localized: "No weigh-in yet: the start is from your profile.")
                                              : String(localized: "Start from your weight trend."))
                Toggle("Reach it by a date", isOn: $hasDate)
                    .onChange(of: hasDate) { on in if on { targetDate = safeDate() } }
                if hasDate {
                    DatePicker("By", selection: $targetDate, in: now.addingTimeInterval(14 * 86_400)..., displayedComponents: .date)
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

    private var rhythmValue: some View {
        NoopCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                stepperRow("Per week", value: $target, step: 1, range: 1...14,
                           text: String(localized: "\(LongTermFormat.number(target))× / week"))
                factLine(String(localized: "Your average lately: \(LongTermFormat.number(recentSessionsPerWeek)) a week"))
                Toggle("Keep it going without an end", isOn: $openEnded)
                if openEnded {
                    factLine(String(localized: "Judged over your last 12 weeks: on track from 80 % of weeks kept."))
                } else {
                    Stepper(value: $fixedWeeks, in: 4...52) {
                        Text("For \(fixedWeeks) weeks").font(StrandFont.body)
                    }
                }
            }
        }
    }

    private var sleepValue: some View {
        NoopCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                stepperRow("Average", value: $target, step: 0.25, range: 5...10,
                           text: LongTermFormat.hoursAndMinutes(target))
                factLine(String(localized: "Your last 28 nights: \(sleepMean28.map(LongTermFormat.hoursAndMinutes) ?? "–")"))
            }
        }
    }

    @ViewBuilder
    private var weeklyStep: some View {
        if let template {
            NoopCard(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    if template.id == .trainingWeekly {
                        factLine(String(localized: "This goal is measured by its weekly goal: \(LongTermFormat.number(target)) a week. Each week you keep counts."))
                    } else {
                        Toggle("Add a weekly goal", isOn: $weeklyOn)
                        if weeklyOn {
                            switch template.id {
                            case .distanceTotal:
                                stepperRow("This week", value: $weeklyTarget, step: 1, range: 1...500,
                                           text: LongTermFormat.value(weeklyTarget, .distanceTotal))
                                factLine(String(localized: "It follows the long-term goal: each new week gets what is still needed, never more than 10 % above your recent running weeks (20 % for other sports)."))
                            case .longest:
                                stepperRow("Per week", value: $weeklyTarget, step: 1, range: 1...300,
                                           text: LongTermFormat.value(weeklyTarget, .distanceTotal))
                            case .weightLose:
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
                            case .sleepAverage:
                                stepperRow("Nights", value: $weeklyTarget, step: 1, range: 1...7,
                                           text: String(localized: "\(LongTermFormat.number(weeklyTarget)) nights from \(LongTermFormat.hoursAndMinutes(max(5, target - 0.5)))"))
                            default:
                                EmptyView()
                            }
                        }
                    }
                }
            }
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
        guard let template else { return "" }
        switch template.id {
        case .distanceTotal: return LongTermFormat.value(target, .distanceTotal)
        case .longest: return LongTermFormat.value(target, .longestDistance)
        case .weightLose: return LongTermFormat.value(target, .weight)
        case .trainingWeekly: return String(localized: "\(LongTermFormat.number(target))× / week")
        case .sleepAverage: return LongTermFormat.hoursAndMinutes(target)
        default: return ""
        }
    }

    private var previewCaption: String? {
        guard let template else { return nil }
        switch template.id {
        case .distanceTotal: return String(localized: "by \(LongTermFormat.shortDate(endDate))")
        case .weightLose, .longest: return hasDate ? String(localized: "by \(LongTermFormat.shortDate(targetDate))") : nil
        default: return nil
        }
    }

    // MARK: - Pieces

    private var navigation: some View {
        HStack {
            if step != .area {
                Button("Back") {
                    if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
                }
            }
            Spacer()
            if step == .value || step == .weekly {
                Button("Next") {
                    if let next = Step(rawValue: step.rawValue + 1) { step = next }
                }
                .buttonStyle(.borderedProminent)
                .disabled(target <= 0)
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
