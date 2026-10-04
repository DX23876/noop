import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - The "My goals" pieces (plan §17e)
//
// The goals page reads like the goal settings of the early fitness bands: a list sorted by daily,
// weekly, monthly and long-term, name on the left, value on the right, how long it runs underneath.
// Above it, large rings for today's daily goals; below it, badges and personal records.

/// One goal in the list: icon, name, a line under it, the target on the right.
struct GoalListRow: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String?
    var subtitleTint: Color = StrandPalette.textSecondary
    let value: String
    var valueIsOff = false
    /// A slim progress line under the text (sums and counts). nil draws none.
    var progress: Double?
    /// Day dots instead of a line, for "days with …" goals: which days counted, not just how many.
    var dots: [DayDotStrip.Day]?
    /// Small columns against a target line, for an average (a mean can fall, so it never fills up).
    var columns: (values: [Double?], target: Double)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(valueIsOff ? StrandPalette.textTertiary : tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill((valueIsOff ? StrandPalette.textTertiary : tint).opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(valueIsOff ? StrandPalette.textSecondary : StrandPalette.textPrimary)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle).font(StrandFont.caption).foregroundStyle(subtitleTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let dots {
                    DayDotStrip(days: dots, tint: tint, diameter: 11)
                        .padding(.top, 2)
                } else if let columns {
                    TargetColumns(values: columns.values, target: columns.target, tint: tint, height: 22)
                        .padding(.top, 2)
                } else if let progress {
                    PaceTrack(fraction: progress, tint: tint, height: 4)
                        .padding(.top, 2)
                }
            }
            // The text column fills the row (so the progress line runs its full width); the value keeps
            // exactly the width it needs.
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(valueIsOff ? StrandFont.subhead : StrandFont.subhead.weight(.semibold))
                .foregroundStyle(valueIsOff ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.right").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Daily rings

/// Today's measured daily goals as rings, laid out by how many there are (plan §17f):
/// one goal is one large ring; two or three nest inside each other like activity rings, with a legend;
/// from four on, the first three nest and every goal keeps a small ring in the legend.
/// A ring fills in its goal's colour; a met goal gets a star. With motivation on, the legend carries the
/// streak and one cheering line closes the block.
struct DailyGoalRings: View {
    let occurrences: [GoalActionOccurrence]
    var motivation: GoalMotivationSnapshot?
    /// Outer diameter: about 120 on the goals page, 92 on Today.
    var diameter: CGFloat = 120

    @AppStorage(AppleInspiredColorsPrefs.enabledKey)
    private var appleColors = AppleInspiredColorsPrefs.defaultEnabled

    /// The rings in their fixed order (steps, active kcal, sleep).
    private var ringed: [GoalActionOccurrence] {
        GoalSpotlight.make(todayActions: occurrences, periodSnapshots: [], longTerm: [], pinnedLongTerm: []).rings
    }

    var body: some View {
        let items = ringed
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                if items.count == 1, let only = items.first {
                    singleRing(only)
                } else {
                    nested(Array(items.prefix(3)))
                }
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(items) { legendRow($0, showsMiniRing: items.count > 3) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let line = cheerLine(items) {
                Label(line.text, systemImage: line.symbol)
                    .font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(line.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func fraction(_ o: GoalActionOccurrence) -> Double {
        min(1, max(0, o.isCompleted ? 1 : (o.fraction ?? 0)))
    }

    private func tint(_ o: GoalActionOccurrence) -> Color { o.identityColor(appleColors: appleColors) }

    /// Two or three rings, one inside the other: the outer is the first goal.
    private func nested(_ items: [GoalActionOccurrence]) -> some View {
        let line = diameter * 0.11
        let gap = line * 0.25
        return ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, o in
                let size = diameter - CGFloat(index) * 2 * (line + gap)
                ZStack {
                    Circle().stroke(tint(o).opacity(0.18), lineWidth: line)
                    Circle().trim(from: 0, to: fraction(o))
                        .stroke(tint(o), style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.6), value: fraction(o))
                }
                .frame(width: size - line, height: size - line)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    private func singleRing(_ o: GoalActionOccurrence) -> some View {
        let line = diameter * 0.12
        return ZStack {
            Circle().stroke(tint(o).opacity(0.18), lineWidth: line)
            Circle().trim(from: 0, to: fraction(o))
                .stroke(tint(o), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: fraction(o))
            VStack(spacing: 0) {
                Image(systemName: icon(o)).font(.system(size: diameter * 0.17, weight: .semibold))
                    .foregroundStyle(tint(o))
                Text("\(Int((fraction(o) * 100).rounded())) %")
                    .font(.system(size: diameter * 0.15, weight: .bold, design: .rounded))
                    .foregroundStyle(StrandPalette.textPrimary).monospacedDigit()
            }
            if o.isCompleted { star.offset(x: diameter * 0.36, y: -diameter * 0.36) }
        }
        .frame(width: diameter - line, height: diameter - line)
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    private var star: some View {
        Image(systemName: "star.fill")
            .font(.system(size: max(11, diameter * 0.13), weight: .bold))
            .foregroundStyle(StrandPalette.statusWarning)
            .padding(3)
            .background(Circle().fill(StrandPalette.surfaceRaised))
    }

    private func legendRow(_ o: GoalActionOccurrence, showsMiniRing: Bool) -> some View {
        HStack(spacing: 7) {
            if showsMiniRing {
                ZStack {
                    Circle().stroke(tint(o).opacity(0.2), lineWidth: 3)
                    Circle().trim(from: 0, to: fraction(o))
                        .stroke(tint(o), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 14, height: 14)
            } else {
                Circle().fill(tint(o)).frame(width: 9, height: 9)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(valueLine(o))
                        .font(diameter >= 110 ? StrandFont.subhead.weight(.semibold) : StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.75)
                    if o.isCompleted {
                        Image(systemName: "star.fill").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(StrandPalette.statusWarning)
                    }
                }
                HStack(spacing: 6) {
                    Text(targetLine(o)).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    if let streak = motivation?.streaks[o.action.id]?.current, streak >= 2 {
                        Label(String(localized: "\(streak) days"), systemImage: "flame.fill")
                            .font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(AppleInspiredColorRole.orange.color)
                            .labelStyle(.titleAndIcon).lineLimit(1)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(o.action.title). \(o.detailLine)"))
    }

    private func icon(_ o: GoalActionOccurrence) -> String {
        switch o.action.requirement {
        case .steps: return "figure.walk"
        case .sleep: return "moon.stars.fill"
        case .activeCalories: return "flame.fill"
        case .workout: return "figure.mixed.cardio"
        case .manual: return "checkmark"
        }
    }

    private func valueLine(_ o: GoalActionOccurrence) -> String { o.ringValueText }
    private func targetLine(_ o: GoalActionOccurrence) -> String { o.ringTargetText }

    /// One line to cheer on: a new record beats everything, then the goal closest to done.
    private func cheerLine(_ ringed: [GoalActionOccurrence]) -> (text: String, symbol: String, tint: Color)? {
        guard let motivation else { return nil }
        if motivation.newStepRecordToday, let steps = motivation.todaySteps {
            return (String(localized: "New record: \(steps.formatted()) steps today"), "trophy.fill",
                    AppleInspiredColorRole.orange.color)
        }
        if !ringed.isEmpty, ringed.allSatisfy(\.isCompleted) {
            return (String(localized: "All daily goals done"), "star.fill", StrandTone.positive.foregroundColor)
        }
        let open = ringed.filter { !$0.isCompleted && ($0.fraction ?? 0) >= 0.5 }
            .max { ($0.fraction ?? 0) < ($1.fraction ?? 0) }
        guard let open, let measured = open.measured, let target = open.measuredTarget else { return nil }
        let left = max(0, target - measured)
        switch open.action.requirement {
        case .steps:
            let steps = Int(left.rounded())
            return (String(localized: "\(steps.formatted()) steps to go, about \(MomentumBuilder.walkMinutes(steps)) min of walking"),
                    "figure.walk", StrandPalette.accent)
        case .activeCalories:
            return (String(localized: "\(Int(left.rounded()).formatted()) kcal to go, you're nearly there"),
                    "flame.fill", StrandPalette.accent)
        default:
            return nil
        }
    }
}

extension GoalActionOccurrence {
    /// Today's reading as the ring legend shows it: "7,328", "6.1 h".
    var ringValueText: String {
        guard let measured else { return "–" }
        switch action.requirement {
        case .sleep: return String(localized: "\(measured.formatted(.number.precision(.fractionLength(1)))) h")
        default: return Int(measured.rounded()).formatted()
        }
    }

    /// The target under it: "of 10,000 steps".
    var ringTargetText: String {
        guard let target = measuredTarget else { return "" }
        switch action.requirement {
        case .steps: return String(localized: "of \(Int(target).formatted()) steps")
        case .sleep: return String(localized: "of \(target.formatted(.number.precision(.fractionLength(0...1)))) h sleep")
        case .activeCalories: return String(localized: "of \(Int(target).formatted()) kcal")
        default: return ""
        }
    }

    /// The identity colour key of what the goal measures, for surfaces that resolve colours themselves
    /// (the widget extension).
    var colorKey: String {
        switch action.requirement {
        case .steps: return PeriodMetric.stepDays.colorKey
        case .sleep: return PeriodMetric.sleepNights.colorKey
        case .activeCalories: return PeriodMetric.activeEnergy.colorKey
        case .workout: return PeriodMetric.workouts.colorKey
        case .manual: return ""
        }
    }

    var ringSymbol: String {
        switch action.requirement {
        case .steps: return "figure.walk"
        case .sleep: return "moon.stars.fill"
        case .activeCalories: return "flame.fill"
        case .workout: return "figure.mixed.cardio"
        case .manual: return "checkmark"
        }
    }
}

// MARK: - Editing a daily goal

/// The small window behind a daily goal in the list: a value wheel, how long it runs, on which days.
/// Opens for the fixed slots (steps, active calories, sleep), set or not yet set.
struct DailyGoalSheet: View {
    enum Slot: String, Identifiable, CaseIterable {
        case steps, activeCalories, sleep
        var id: String { rawValue }

        var title: String {
            switch self {
            case .steps: return String(localized: "Steps")
            case .activeCalories: return String(localized: "Active calories")
            case .sleep: return String(localized: "Sleep")
            }
        }
        var icon: String {
            switch self {
            case .steps: return "figure.walk"
            case .activeCalories: return "flame.fill"
            case .sleep: return "moon.stars.fill"
            }
        }
        var metric: PeriodMetric {
            switch self {
            case .steps: return .stepDays
            case .activeCalories: return .activeEnergy
            case .sleep: return .sleepNights
            }
        }
        var values: [Double] {
            switch self {
            case .steps: return stride(from: 2_000.0, through: 40_000, by: 500).map { $0 }
            case .activeCalories: return stride(from: 100.0, through: 2_000, by: 50).map { $0 }
            case .sleep: return stride(from: 5.0, through: 10, by: 0.25).map { $0 }
            }
        }
        var defaultValue: Double {
            switch self {
            case .steps: return 10_000
            case .activeCalories: return 500
            case .sleep: return 7.5
            }
        }
        func format(_ value: Double) -> String {
            switch self {
            case .steps: return String(localized: "\(Int(value).formatted()) steps")
            case .activeCalories: return String(localized: "\(Int(value).formatted()) kcal")
            case .sleep: return String(localized: "\(value.formatted(.number.precision(.fractionLength(0...2)))) h")
            }
        }
        func requirement(_ value: Double) -> GoalAction.Requirement {
            switch self {
            case .steps: return .steps(minimum: Int(value))
            case .activeCalories: return .activeCalories(minimum: Int(value))
            case .sleep: return .sleep(minimumHours: value)
            }
        }
        func value(of requirement: GoalAction.Requirement) -> Double? {
            switch (self, requirement) {
            case (.steps, .steps(let m)): return Double(m)
            case (.activeCalories, .activeCalories(let m)): return Double(m)
            case (.sleep, .sleep(let h)): return h
            default: return nil
            }
        }

        /// The standalone daily goal filling this slot, if one is set and running.
        func current(in actions: [GoalAction], today: String) -> GoalAction? {
            actions.first { $0.isActive && $0.goalIds.isEmpty && !$0.hasEnded(today: today)
                && value(of: $0.requirement) != nil }
        }
    }

    enum Runs: String, CaseIterable, Identifiable {
        case ongoing, untilDate, todayOnly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ongoing: return String(localized: "Ongoing")
            case .untilDate: return String(localized: "Until a date")
            case .todayOnly: return String(localized: "Today only")
            }
        }
    }

    let slot: Slot
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = GoalActionStore.shared
    @ObservedObject private var tracking = GoalTrackingStore.shared
    @AppStorage(AppleInspiredColorsPrefs.enabledKey) private var appleColors = AppleInspiredColorsPrefs.defaultEnabled

    @State private var value: Double = 0
    @State private var runs: Runs = .ongoing
    @State private var endDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var weekdays: Set<Int> = Set(1...7)
    @State private var loaded = false

    private var today: String { Repository.localDayKey(Date()) }
    private var existing: GoalAction? { slot.current(in: store.actions, today: today) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    valuePicker
                    if let hint = usualHint {
                        Text(hint).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How long it runs").strandOverline()
                        Picker("How long it runs", selection: $runs) {
                            ForEach(Runs.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if runs == .untilDate {
                            DatePicker("Last day", selection: $endDate, in: Date()..., displayedComponents: .date)
                                .font(StrandFont.footnote)
                        }
                    }
                    if runs != .todayOnly {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("On these days").strandOverline()
                            RestDaysPicker(selection: $weekdays)
                        }
                    }
                    if existing != nil {
                        Button(role: .destructive) { turnOff() } label: {
                            Label("Turn this goal off", systemImage: "xmark.circle")
                                .font(StrandFont.footnote.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(StrandPalette.statusCritical)
                    }
                }
                .padding(20)
            }
            .navigationTitle(slot.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save).disabled(runs != .todayOnly && weekdays.isEmpty)
                }
            }
            .onAppear(perform: load)
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    @ViewBuilder
    private var valuePicker: some View {
        let tint = goalIdentityColor(slot.metric, appleColors: appleColors)
        VStack(spacing: 4) {
            Image(systemName: slot.icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(tint)
            #if os(iOS)
            Picker(slot.title, selection: $value) {
                ForEach(slot.values, id: \.self) { Text(slot.format($0)).tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(height: 140)
            #else
            Picker(slot.title, selection: $value) {
                ForEach(slot.values, id: \.self) { Text(slot.format($0)).tag($0) }
            }
            .labelsHidden()
            #endif
            Text(slot == .sleep ? String(localized: "a night") : String(localized: "a day"))
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    /// The wearer's own usual over recent weeks, so the number on the wheel is a choice, not a guess.
    private var usualHint: String? {
        let inputs = tracking.periodInputs
        let days = inputs.days.suffix(28)
        let values: [Double]
        switch slot {
        case .steps: values = days.compactMap { $0.steps.map(Double.init) }
        case .sleep: values = days.compactMap { $0.totalSleepMin.map { $0 / 60 } }
        case .activeCalories: values = inputs.activeKcalByDay.sorted { $0.key < $1.key }.suffix(28).map(\.value)
        }
        guard values.count >= 7 else { return nil }
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        return String(localized: "Usually \(slot.format(slot == .sleep ? (median * 4).rounded() / 4 : (median / 100).rounded() * 100))")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let existing {
            value = slot.value(of: existing.requirement) ?? slot.defaultValue
            if case .weekdays(let days) = existing.schedule { weekdays = Set(days) }
            if let endsOn = existing.endsOn {
                if endsOn == today { runs = .todayOnly }
                else {
                    runs = .untilDate
                    endDate = PeriodGoalTracker.date(endsOn, calendar: .autoupdatingCurrent) ?? endDate
                }
            }
        } else {
            value = slot.defaultValue
        }
        if !slot.values.contains(value) {
            value = slot.values.min { abs($0 - value) < abs($1 - value) } ?? slot.defaultValue
        }
    }

    private func save() {
        let endsOn: String?
        switch runs {
        case .ongoing: endsOn = nil
        case .untilDate: endsOn = Repository.localDayKey(endDate)
        case .todayOnly: endsOn = today
        }
        let schedule: GoalAction.Schedule = (runs == .todayOnly || weekdays.count == 7) ? .daily : .weekdays(weekdays.sorted())
        store.upsert(GoalAction(id: existing?.id ?? UUID(),
                                title: existing?.title ?? defaultTitle,
                                requirement: slot.requirement(value), schedule: schedule, goalIds: [],
                                createdAt: existing?.createdAt ?? Date(), endsOn: endsOn))
        StrandHaptic.commit.play()
        onSave()
        dismiss()
    }

    private var defaultTitle: String {
        switch slot {
        case .steps: return String(localized: "Daily steps")
        case .activeCalories: return String(localized: "Active calories")
        case .sleep: return String(localized: "Sleep")
        }
    }

    /// Off keeps the goal and its history (it moves to the ended goals); it can be set again any time.
    private func turnOff() {
        guard var action = existing else { return }
        action.endsOn = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
        store.upsert(action)
        onSave()
        dismiss()
    }
}

// MARK: - Badges

extension GoalMotivation.Badge {
    var title: String {
        switch family {
        case .dailySteps: return String(localized: "\(threshold.formatted()) steps in a day")
        case .lifetimeSteps: return String(localized: "\(threshold.formatted()) steps in total")
        case .stepStreak: return String(localized: "\(threshold) days in a row")
        case .weeksReached:
            return threshold == 1 ? String(localized: "First weekly goal reached")
                                  : String(localized: "\(threshold) weekly goals reached")
        case .workouts: return String(localized: "\(threshold) workouts")
        }
    }

    /// The short figure on the medal.
    var shortValue: String {
        threshold >= 1_000 ? threshold.formatted(.number.notation(.compactName)) : "\(threshold)"
    }
}

extension GoalMotivation.BadgeFamily {
    var title: String {
        switch self {
        case .dailySteps: return String(localized: "Steps in a day")
        case .lifetimeSteps: return String(localized: "Steps in total")
        case .stepStreak: return String(localized: "Step goal streaks")
        case .weeksReached: return String(localized: "Weekly goals reached")
        case .workouts: return String(localized: "Workouts")
        }
    }
    var symbol: String {
        switch self {
        case .dailySteps: return "figure.walk"
        case .lifetimeSteps: return "map.fill"
        case .stepStreak: return "flame.fill"
        case .weeksReached: return "calendar.badge.checkmark"
        case .workouts: return "figure.run"
        }
    }
    func tint(appleColors: Bool) -> Color {
        guard appleColors else { return StrandPalette.accent }
        switch self {
        case .dailySteps: return AppleInspiredColorRole.teal.color
        case .lifetimeSteps: return AppleInspiredColorRole.green.color
        case .stepStreak: return AppleInspiredColorRole.orange.color
        case .weeksReached: return AppleInspiredColorRole.indigo.color
        case .workouts: return AppleInspiredColorRole.pink.color
        }
    }
}

/// A badge as a medal: filled in its family's colour once earned, an outline with the figure while ahead.
struct BadgeMedal: View {
    let badge: GoalMotivation.Badge
    var diameter: CGFloat = 58
    var showsCaption = true

    @AppStorage(AppleInspiredColorsPrefs.enabledKey)
    private var appleColors = AppleInspiredColorsPrefs.defaultEnabled

    var body: some View {
        let tint = badge.family.tint(appleColors: appleColors)
        VStack(spacing: 5) {
            ZStack {
                if badge.isEarned {
                    Circle().fill(tint)
                    Circle().strokeBorder(StrandPalette.onDarkPrimary.opacity(0.35), lineWidth: 2).padding(4)
                    VStack(spacing: 0) {
                        Image(systemName: badge.family.symbol)
                            .font(.system(size: diameter * 0.3, weight: .bold))
                        Text(badge.shortValue)
                            .font(.system(size: diameter * 0.17, weight: .heavy, design: .rounded))
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .foregroundStyle(StrandPalette.onDarkPrimary)
                } else {
                    Circle().strokeBorder(StrandPalette.hairlineStrong, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    VStack(spacing: 0) {
                        Image(systemName: badge.family.symbol)
                            .font(.system(size: diameter * 0.28, weight: .semibold))
                        Text(badge.shortValue)
                            .font(.system(size: diameter * 0.16, weight: .bold, design: .rounded))
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(width: diameter, height: diameter)
            if showsCaption {
                Text(badge.title)
                    .font(StrandFont.caption)
                    .foregroundStyle(badge.isEarned ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .multilineTextAlignment(.center).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let day = badge.earnedOn, let date = PeriodGoalTracker.date(day, calendar: .autoupdatingCurrent) {
                    Text(date.formatted(.dateTime.day().month(.abbreviated).year()))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(badge.isEarned ? String(localized: "Badge: \(badge.title)")
                                                : String(localized: "Badge ahead: \(badge.title)")))
    }
}

/// "New badge" at the top of the goals page; dismissing it marks the badges as seen.
struct NewBadgeBanner: View {
    let badges: [GoalMotivation.Badge]
    let onSeen: () -> Void

    var body: some View {
        NoopCard(padding: 14, tint: StrandPalette.accent) {
            HStack(spacing: 14) {
                if let first = badges.first { BadgeMedal(badge: first, diameter: 54, showsCaption: false) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(badges.count == 1 ? String(localized: "New badge") : String(localized: "\(badges.count) new badges"))
                        .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text(badges.prefix(3).map(\.title).joined(separator: " · "))
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    NavigationLink(value: GoalsRoute.badges) {
                        Text("See all badges").font(StrandFont.footnote.weight(.semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(StrandPalette.accent)
                    .simultaneousGesture(TapGesture().onEnded(onSeen))
                }
                Spacer(minLength: 0)
                Button(action: onSeen) {
                    Image(systemName: "xmark").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Hide"))
            }
        }
    }
}

/// The badges card on the goals page: the latest earned, and the next one with how far it is.
struct BadgesCard: View {
    let motivation: GoalMotivationSnapshot

    private var next: (badge: GoalMotivation.Badge, fraction: Double)? {
        GoalMotivation.BadgeFamily.allCases
            .compactMap { GoalMotivation.nextBadge(in: $0, badges: motivation.badges,
                                                   progressValue: motivation.progressValue(for: $0)) }
            .max { $0.fraction < $1.fraction }
    }

    var body: some View {
        NoopCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Badges").strandOverline()
                    Text("\(motivation.earned.count)/\(motivation.badges.count)")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                    NavigationLink(value: GoalsRoute.badges) {
                        HStack(spacing: 3) {
                            Text("All").font(StrandFont.caption)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(StrandPalette.accent)
                    }
                    .buttonStyle(.plain)
                }
                if motivation.earned.isEmpty {
                    Text("Your first badge comes with your first 10,000-step day or your first reached weekly goal.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(motivation.earned.prefix(3)) { badge in
                            BadgeMedal(badge: badge, diameter: 56).frame(maxWidth: .infinity)
                        }
                    }
                }
                if let next {
                    Divider().overlay(StrandPalette.hairline)
                    HStack(spacing: 12) {
                        BadgeMedal(badge: next.badge, diameter: 40, showsCaption: false)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "Next: \(next.badge.title)"))
                                .font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                            PaceTrack(fraction: next.fraction, tint: next.badge.family.tint(appleColors: true), height: 6)
                        }
                    }
                }
            }
        }
    }
}

/// Personal bests, one line each.
struct RecordsCard: View {
    let motivation: GoalMotivationSnapshot

    var body: some View {
        let r = motivation.records
        NoopCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Personal records").strandOverline()
                if let day = r.bestStepDay {
                    record("trophy.fill", String(localized: "Best day"), String(localized: "\(day.steps.formatted()) steps"), date: day.day)
                }
                if let week = r.bestStepWeek {
                    record("calendar", String(localized: "Best week"), String(localized: "\(week.steps.formatted()) steps"), date: week.start)
                }
                if let week = r.mostWorkoutsWeek {
                    record("figure.run", String(localized: "Most workouts in a week"), "\(week.count)", date: week.start)
                }
                if r.longestStepStreak > 0 {
                    record("flame.fill", String(localized: "Longest step streak"), String(localized: "\(r.longestStepStreak) days"), date: nil)
                }
                if r.bestStepDay == nil && r.mostWorkoutsWeek == nil {
                    Text("Records appear once there are steps or workouts on record.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private func record(_ symbol: String, _ label: String, _ value: String, date: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(StrandFont.footnote).foregroundStyle(AppleInspiredColorRole.orange.color)
                .frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                if let date, let d = PeriodGoalTracker.date(date, calendar: .autoupdatingCurrent) {
                    Text(d.formatted(.dateTime.day().month(.abbreviated).year()))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer()
            Text(value).font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Every badge, by family: earned ones in colour with their date, the rest as outlines.
struct GoalBadgesView: View {
    @ObservedObject private var tracking = GoalTrackingStore.shared

    var body: some View {
        ScreenScaffold(title: "Badges", subtitle: "Earned from your own data, on this device.") {
            if let motivation = tracking.motivation {
                ForEach(GoalMotivation.BadgeFamily.allCases, id: \.self) { family in
                    let items = motivation.badges.filter { $0.family == family }
                    NoopCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(family.title).strandOverline()
                                Spacer()
                                Text("\(items.filter(\.isEarned).count)/\(items.count)")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10, alignment: .top)],
                                      spacing: 14) {
                                ForEach(items) { BadgeMedal(badge: $0, diameter: 60) }
                            }
                        }
                    }
                }
            } else {
                Text("Badges are switched off in the goal settings.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .onAppear {
            if let motivation = tracking.motivation { GoalPrefs.markBadgesSeen(motivation.earned.map(\.id)) }
        }
    }
}
