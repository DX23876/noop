#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandCore
import StrandTraining
import WhoopStore

/// The redesign's Training tab (2026-11): this week at a glance, starting a session, routines, recent
/// activities and the analysis screens. The full planner (schedule, library, imports, past sessions) is
/// still the shipped Training hub, one tap away under "Plan and library", so no feature is lost.
struct ForgeTrainingView: View {
    let onProfile: () -> Void
    let onStartWorkout: () -> Void
    var onAsk: (String) -> Void = { _ in }
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var session: ActiveSessionController
    @StateObject private var hub = TrainingHubModel()
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal
    @AppStorage("training.weekStartsOn") private var weekStartRaw = TrainingWeekStart.monday.rawValue
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    private var distanceSystem: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric, override: distanceSystemRaw)
    }

    @State private var recent: [WorkoutRow] = []
    @State private var vo2max: [Double] = []

    private var weekStart: TrainingWeekStart { TrainingWeekStart(rawValue: weekStartRaw) ?? .monday }

    /// The days of the current training week, first day first.
    private var weekDays: [Date] {
        var cal = Calendar.current
        cal.firstWeekday = weekStart == .monday ? 2 : 1
        let today = cal.startOfDay(for: Date())
        let start = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private var weekWorkouts: [WorkoutRow] {
        guard let first = weekDays.first else { return [] }
        return recent.filter { Date(timeIntervalSince1970: TimeInterval($0.startTs)) >= first }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForgeLargeHeader(title: "Training", onProfile: onProfile).id("forge-training-top")
                    VStack(alignment: .leading, spacing: 14) {
                        weekHero
                        startRow
                        if coachFeatureEnabled {
                            ForgeChip(title: String(localized: "Plan today with the coach"), systemImage: "sparkles",
                                      prominent: true) {
                                onAsk(String(localized: "Look at my Charge, this week's training and my routines, and suggest what I should train today."))
                            }
                        }
                        GoalsContextCard(context: .training)
                        routines
                        recentActivities
                        analysis
                        tools
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 6)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .onChange(of: scrollToTopSignal) { _, _ in
                withAnimation(.smooth) { proxy.scrollTo("forge-training-top", anchor: .top) }
            }
        }
        .background(ForgeBackground(tab: .training))
        .refreshable { await repo.refresh() }
        .task(id: "\(repo.refreshSeq)|\(weekStartRaw)") { await load() }
        .onChange(of: session.hasLiveSession) { _, live in
            if !live { Task { await load(force: true) } }
        }
    }

    // MARK: Week

    private var weekHero: some View {
        let workouts = weekWorkouts
        let minutes = workouts.reduce(0.0) { $0 + ($1.durationS ?? Double(max($1.endTs - $1.startTs, 0))) / 60 }
        let cal = Calendar.current
        return VStack(alignment: .leading, spacing: 4) {
            Text("This week").font(.system(size: 15, weight: .medium)).foregroundStyle(ForgeColor.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(workouts.isEmpty ? String(localized: "No workouts yet")
                                      : String(localized: "\(workouts.count) workouts"))
                    .font(.system(size: 28, weight: .bold)).foregroundStyle(ForgeColor.text)
                if !workouts.isEmpty {
                    Text(Self.duration(minutes)).font(.system(size: 17, weight: .medium))
                        .foregroundStyle(ForgeColor.secondary)
                }
            }
            HStack(spacing: 0) {
                ForEach(weekDays, id: \.self) { day in
                    let done = workouts.contains { cal.isDate(Date(timeIntervalSince1970: TimeInterval($0.startTs)), inSameDayAs: day) }
                    let isToday = cal.isDateInToday(day)
                    VStack(spacing: 5) {
                        Circle()
                            .fill(done ? ForgeColor.effort : ForgeColor.fill)
                            .overlay(Circle().strokeBorder(isToday ? ForgeColor.text : .clear, lineWidth: 1.5))
                            .frame(width: 30, height: 30)
                            .overlay {
                                if done {
                                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                        Text(day, format: .dateTime.weekday(.narrow).locale(AppLanguage.activeLocale))
                            .font(.system(size: 12, weight: isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? ForgeColor.text : ForgeColor.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(day.formatted(.dateTime.weekday(.wide).locale(AppLanguage.activeLocale))))
                    .accessibilityValue(Text(done ? String(localized: "Trained") : String(localized: "No workout")))
                }
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 4)
    }

    static func duration(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total < 60 { return String(localized: "\(total) min") }
        return String(localized: "\(total / 60) h \(String(format: "%02d", total % 60)) min")
    }

    /// Quick starts as in the prototype: start a session (the shared start sheet picks the activity),
    /// the interval timer, or live heart rate.
    private var startRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Button(action: onStartWorkout) {
                    Label("Start workout", systemImage: "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ForgeColor.onAccent)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(ForgeColor.accent))
                }
                .buttonStyle(.plain)
                quickChip("Intervals", "timer", MoreDestination.intervals)
                quickChip("Live", "heart.fill", MoreDestination.live)
                quickChip("Breathe", "wind", MoreDestination.breathe)
            }
        }
        .scrollIndicators(.hidden)
    }

    private func quickChip(_ title: LocalizedStringKey, _ image: String, _ destination: MoreDestination) -> some View {
        NavigationLink(value: destination) {
            Label(title, systemImage: image)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ForgeColor.text)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Capsule().fill(ForgeColor.fill))
        }
        .buttonStyle(.plain)
    }

    // MARK: Routines

    @ViewBuilder private var routines: some View {
        if hub.loaded, !hub.plan.routines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Routines").font(ForgeFont.section).foregroundStyle(ForgeColor.text)
                    Spacer()
                    NavigationLink(value: MoreDestination.training) {
                        Text("All").font(.system(size: 17)).foregroundStyle(ForgeColor.accent)
                    }
                }
                .padding(.horizontal, 4).padding(.top, 14)
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(hub.plan.routines) { routine in
                            Button { session.requestStrength(routines: [routine]) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Image(systemName: "dumbbell.fill")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(ForgeColor.effort)
                                    Spacer(minLength: 10)
                                    Text(routine.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(ForgeColor.text)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text("\(routine.exercises.count) exercises")
                                        .font(ForgeFont.caption)
                                        .foregroundStyle(ForgeColor.secondary)
                                }
                                .frame(width: 128, height: 118, alignment: .topLeading)
                                .forgeCard(radius: 20, padding: 12)
                            }
                            .buttonStyle(LiquidPressStyle())
                            .accessibilityLabel(Text("Start \(routine.title)"))
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: Recent

    @ViewBuilder private var recentActivities: some View {
        let rows = Array(recent.prefix(5))
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent activities").font(ForgeFont.section).foregroundStyle(ForgeColor.text)
                Spacer()
                NavigationLink(value: TabRoute.workouts) {
                    Text("All").font(.system(size: 17)).foregroundStyle(ForgeColor.accent)
                }
            }
            .padding(.horizontal, 4).padding(.top, 14)
            if rows.isEmpty {
                Text("Workouts you record or import appear here.")
                    .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary).padding(.horizontal, 4)
            } else {
                ForgeGroup {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { ForgeRowDivider() }
                        NavigationLink(value: TabRoute.workoutDetail(startTs: row.startTs, sport: row.sport)) {
                            ForgeRow(systemImage: "figure.mixed.cardio",
                                     tint: AppleInspiredColors.role(forSport: row.sport).color,
                                     title: WorkoutSource.localizedDisplaySport(row.sport),
                                     subtitle: detail(row),
                                     value: row.strain.map { ForgeToday.effortText($0, scale: effortScale) },
                                     unit: row.strain == nil ? nil : DomainTheme.effort.productName)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func detail(_ row: WorkoutRow) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
        var parts = [LiquidTodayView.workoutDayText(start)]
        let secs = row.durationS ?? Double(max(row.endTs - row.startTs, 0))
        parts.append(String(localized: "\(Int(secs / 60)) min"))
        if let dm = row.distanceM, dm > 0 { parts.append(UnitFormatter.distanceFromMeters(dm, system: distanceSystem)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Analysis and tools

    private var analysis: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForgeSectionTitle(title: "Your training")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                NavigationLink(value: TabRoute.metric("vo2max_est")) {
                    ForgeMetricTile(label: String(localized: "VO₂max"),
                                    value: vo2max.last.map { String(format: "%.0f", $0) },
                                    unit: "ml/kg/min", trend: Array(vo2max.suffix(30)), tint: ForgeColor.charge)
                }
                NavigationLink(value: TabRoute.workouts) {
                    ForgeMetricTile(label: String(localized: "Last 30 days"), value: "\(recent.count)",
                                    unit: String(localized: "workouts"),
                                    trend: nil, tint: ForgeColor.effort)
                }
            }
            .buttonStyle(LiquidPressStyle())
            ForgeGroup {
                NavigationLink(value: TabRoute.trainingLoad) {
                    ForgeRow(systemImage: "chart.bar.fill", tint: .red, title: String(localized: "Training load"),
                             subtitle: String(localized: "Both lanes against your usual"))
                }
                ForgeRowDivider()
                NavigationLink(value: TabRoute.strength) {
                    ForgeRow(systemImage: "dumbbell.fill", tint: .orange, title: String(localized: "Strength"),
                             subtitle: String(localized: "Exercises, volume and muscle groups"))
                }
                ForgeRowDivider()
                NavigationLink(value: TabRoute.cardio) {
                    ForgeRow(systemImage: "figure.run", tint: .green, title: String(localized: "Endurance"),
                             subtitle: String(localized: "Runs, rides, swims and rows"))
                }
                ForgeRowDivider()
                NavigationLink(value: TabRoute.goals) {
                    ForgeRow(systemImage: "flag.fill", tint: .blue, title: String(localized: "Goals"),
                             subtitle: String(localized: "This week, this month, long term"))
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForgeSectionTitle(title: "Tools")
            ForgeGroup {
                NavigationLink(value: MoreDestination.training) {
                    ForgeRow(systemImage: "calendar", tint: ForgeColor.accent, title: String(localized: "Plan and library"),
                             subtitle: String(localized: "Schedule, routines, imports, past sessions"))
                }
                ForgeRowDivider()
                NavigationLink(value: MoreDestination.intervals) {
                    ForgeRow(systemImage: "timer", tint: .orange, title: String(localized: "Interval timer"),
                             subtitle: String(localized: "Rounds and breaks"))
                }
                ForgeRowDivider()
                NavigationLink(value: MoreDestination.breathe) {
                    ForgeRow(systemImage: "wind", tint: .teal, title: String(localized: "Breathe"),
                             subtitle: String(localized: "Guided breathing"))
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Load

    private func load(force: Bool = false) async {
        await hub.load(repo: repo, session: session, weekStartsOn: weekStart, force: force)
        recent = (await repo.workoutRows(days: 30, reconcileHrCap: 0)).sorted { $0.startTs > $1.startTs }
        vo2max = (await repo.exploreSeries(key: "vo2max_est", source: Repository.whoopSource, days: 120)).map(\.value)
    }
}
#endif
