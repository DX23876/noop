#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandCore
import WhoopStore
import StrandTraining

/// The redesigned Today (2026-11, "New design (preview)"): the three organic rings at the top with today's
/// Effort target, what is still planned for later, then one timeline of what happened, newest first.
///
/// Every number is read through the same resolvers the shipped Today uses (`ChargeDisplay`,
/// `DashboardRestScore`/`freshRestScore`, `LiveEffort` floored by `effectiveEffort`), so the two designs can
/// never disagree about a score. The timeline is assembled by `ForgeTimeline` from stored rows and works
/// fully with the coach off; coach notes only join it when the coach is on.
struct ForgeTodayView: View {
    @ObservedObject var coach: AICoachEngine
    let onProfile: () -> Void
    let onLog: () -> Void
    let onWorkout: () -> Void
    let onCoach: () -> Void
    let onSleep: () -> Void
    /// Opens Coach settings (memory, usage, data access) on the Today stack.
    var onCoachSettings: () -> Void = {}
    /// Sends a quick reply or question to the coach (inline consent handled by the shell).
    var onAsk: (String) -> Void = { _ in }

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var router: NavRouter
    @EnvironmentObject private var session: ActiveSessionController
    /// Routines the training plan schedules for today, shown under Later Today.
    @State private var plannedRoutines: [TrainingRoutine] = []
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceSystem: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric, override: distanceSystemRaw)
    }
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false

    @State private var snapshot = Snapshot()
    @State private var showPlan = false
    @State private var showCoachSheet = false
    @State private var rowWidth: CGFloat = 0
    @State private var whyEntry: ForgeTimeline.Entry?
    /// True once the rings have scrolled out of view; a compact glass bar then keeps the three scores.
    @State private var heroHidden = false
    /// Bumped by a tap on the pinned bar: back to the rings.
    @State private var backToTop = 0

    struct Snapshot: Equatable {
        var loaded = false
        var charge: ChargeDisplay = .noData
        var rest: Double?
        var effortStored: Double?
        var effortDay = ""
        var timeline: [ForgeTimeline.Day] = []
        var workouts: [String: WorkoutRow] = [:]
        var sleeps: [Int: CachedSleepSession] = [:]
        var notes: [String: ChatMessage] = [:]
        /// The Charge drivers for the row the ring shows, bound under the morning note.
        var drivers: [ChargeDriver] = []
        /// The weight trend's 30-day change, shown under a weigh-in.
        var weightChange30d: Double?
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForgeLargeHeader(title: "Today", onProfile: onProfile) {
                        Button(action: onLog) {
                            Image(systemName: "plus")
                                .font(.system(.body, weight: .semibold))
                                .foregroundStyle(ForgeColor.text)
                                .frame(width: 36, height: 36)
                                .forgeGlassCapsule()
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Log"))
                        ForgeSearchButton()
                        NavigationLink(value: ForgeRoute.weeklyReport) {
                            Image(systemName: "calendar")
                                .font(.system(.body, weight: .semibold))
                                .foregroundStyle(ForgeColor.text)
                                .frame(width: 36, height: 36)
                                .forgeGlassCapsule()
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(Text("Weekly report"))
                    }
                    .id("forge-today-top")
                    VStack(alignment: .leading, spacing: 14) {
                        HealthAlertBanner()
                        ActiveWorkoutIndicatorSection()
                        ActivitySuggestionPrompt()
                        MorningSuggestionCard(showPlan: $showPlan)
                        if snapshot.loaded && repo.days.isEmpty {
                            // First run: nothing recorded or imported yet. The same calm state Health and
                            // Live show, with the one next step.
                            WearableConnectionStateCard(
                                title: "No biometrics yet",
                                detail: "Connect a wearable to begin collecting live vitals and history. Existing records can still be imported from Data Sources.",
                                actionTitle: "Connect a device",
                                action: { router.openDevices() })
                        }
                        hero
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: ForgeHeroBottomKey.self,
                                                       value: geo.frame(in: .named("forge-today")).maxY)
                            })
                        ForgeCycleSummaryCard(showsLogButtons: false)
                        laterToday
                        timeline
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 6)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(name: "forge-today")
            .onPreferenceChange(ForgeHeroBottomKey.self) { bottom in
                let hidden = bottom < 40
                if hidden != heroHidden { withAnimation(.easeOut(duration: 0.2)) { heroHidden = hidden } }
            }
            .overlay(alignment: .top) {
                if heroHidden {
                    ZStack(alignment: .top) {
                        // Fades the timeline out under the status bar and the bar, so text never runs
                        // behind the clock unsoftened.
                        LinearGradient(colors: [ForgeColor.canvas, ForgeColor.canvas.opacity(0.85),
                                                ForgeColor.canvas.opacity(0)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 64)
                            .ignoresSafeArea(edges: .top)
                            .allowsHitTesting(false)
                        pinnedBar
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onChange(of: scrollToTopSignal) { _, _ in
                withAnimation(.smooth) { proxy.scrollTo("forge-today-top", anchor: .top) }
            }
            .onChange(of: backToTop) { _, _ in
                withAnimation(.smooth) { proxy.scrollTo("forge-today-top", anchor: .top) }
            }
        }
        .background(ForgeBackground(tab: .today))
        .refreshable { await repo.refresh(); await load(force: true) }
        .task(id: reloadKey) { await load(force: false) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load(force: true) } }
        }
        .coachDashboardPresentations(showCoach: $showCoachSheet, showPlan: $showPlan)
        .sheet(item: $whyEntry) { entry in
            ForgeCoachWhySheet(entry: entry, message: entry.sourceId.flatMap { snapshot.notes[$0] },
                               onCoachSettings: {
                                   whyEntry = nil
                                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onCoachSettings() }
                               })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// Re-read when the day list, today's stored row or the coach transcript moves.
    private var reloadKey: String {
        let lastNote = coach.conversations.last?.messages.last?.id.uuidString ?? ""
        return "\(repo.days.count)|\(repo.today?.day ?? "")|\(repo.today?.strain ?? -1)|\(repo.today?.recovery ?? -1)|\(lastNote)|\(coachFeatureEnabled)"
    }

    // MARK: - Hero

    private var chargeScore: Double? { snapshot.loaded ? snapshot.charge.pct : nil }
    private var effortScore: Double? { snapshot.effortStored.map { UnitFormatter.effortValue($0, scale: effortScale) } }
    private var effortTarget: ClosedRange<Double>? { ForgeToday.effortTargetStored(charge: chargeScore) }

    /// The rings on their own, as in the first Forge boards: three equal rings with their names, no card, no
    /// sentence and no buttons, and room below before the rest of the day. Log moved to the header; a workout
    /// starts from the Training tab.
    private var hero: some View {
        let diameter = LiquidHeroRingLayout.diameter(rowWidth: rowWidth) * 0.92
        let hit = LiquidHeroRingLayout.hitDiameter(rowWidth: rowWidth)
        return OrganicScoreHeroClock(dataReady: snapshot.loaded || effortScore != nil) { frame in
            HStack(alignment: .top, spacing: 0) {
                ringCell(metric: .charge, label: DomainTheme.charge.productName, score: chargeScore,
                         tint: chargeScore.map { StrandPalette.chargeRingColor($0) } ?? StrandPalette.organicMissing,
                         caption: nil, frame: frame, diameter: diameter, hit: hit,
                         route: ForgeRoute.charge)
                ringCell(metric: .effort, label: DomainTheme.effort.productName, score: effortScore,
                         tint: StrandPalette.organicEffort, caption: nil,
                         frame: frame, diameter: diameter, hit: hit,
                         maxValue: effortScale == .whoop ? 21 : 100, decimals: effortScale == .whoop ? 1 : 0,
                         route: ForgeRoute.effort(stored: snapshot.effortStored, charge: chargeScore))
                ringCell(metric: .rest, label: DomainTheme.rest.productName, score: snapshot.loaded ? snapshot.rest : nil,
                         tint: StrandPalette.organicRest, caption: nil,
                         frame: frame, diameter: diameter, hit: hit,
                         route: ForgeRoute.rest(snapshot.loaded ? snapshot.rest : nil))
            }
        }
        .frame(maxWidth: .infinity)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { rowWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in rowWidth = w }
        })
        .padding(.top, 8)
        .padding(.bottom, 22)
    }

    /// The three scores in one glass bar while the rings are scrolled away. Tapping returns to the top.
    private var pinnedBar: some View {
        HStack(spacing: 18) {
            pinnedValue(DomainTheme.charge.productName, chargeScore.map { "\(Int($0.rounded()))" }, ForgeColor.charge)
            pinnedValue(DomainTheme.effort.productName,
                        snapshot.effortStored.map { ForgeToday.effortText($0, scale: effortScale) }, ForgeColor.effort)
            pinnedValue(DomainTheme.rest.productName,
                        (snapshot.loaded ? snapshot.rest : nil).map { "\(Int($0.rounded()))" }, ForgeColor.rest)
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .liquidGlass(in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { backToTop += 1 }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Back to the rings"))
    }

    private func pinnedValue(_ label: String, _ value: String?, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(value ?? "–").font(ForgeFont.rounded(16, .bold)).foregroundStyle(ForgeColor.text)
            Text(label).font(.system(.caption)).foregroundStyle(ForgeColor.secondary)
        }
    }

    /// The ring's name in its domain colour, as in the prototype.
    private static func labelTint(_ metric: OrganicScoreMetric) -> Color {
        switch metric {
        case .charge: return ForgeColor.chargeInk
        case .effort: return ForgeColor.effortInk
        case .rest: return ForgeColor.restInk
        }
    }

    private func ringCell<Route: Hashable>(metric: OrganicScoreMetric, label: String, score: Double?, tint: Color,
                                           caption: String?, frame: OrganicScoreFrame, diameter: CGFloat, hit: CGFloat,
                                           maxValue: Double = 100, decimals: Int = 0, route: Route) -> some View {
        let model = OrganicScoreVisualModel.resolve(metric: metric, value: score, scaleMaximum: maxValue)
        return NavigationLink(value: route) {
            VStack(spacing: 2) {
                OrganicScoreRing(model: model, tint: tint, score: score, decimals: decimals, frame: frame,
                                 diameter: diameter, hitDiameter: hit)
                    .frame(width: hit, height: diameter)
                Text(label)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Self.labelTint(metric))
                    .lineLimit(1).minimumScaleFactor(0.8)
                if let caption {
                    Text(caption)
                        .font(.system(.caption))
                        .foregroundStyle(ForgeColor.secondary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(spoken(score: score, maxValue: maxValue, decimals: decimals, caption: caption)))
        .accessibilityHint(Text("Opens the trend and readings"))
        .accessibilityAddTraits(.isButton)
    }

    private func spoken(score: Double?, maxValue: Double, decimals: Int, caption: String?) -> String {
        guard let score else { return String(localized: "no data yet") }
        var parts: [String] = []
        if maxValue == 100 {
            parts.append(String(localized: "\(Int(score.rounded())) percent"))
        } else {
            let number = String(format: "%.\(decimals)f", locale: AppLanguage.activeLocale, score)
            parts.append(String(localized: "\(number) out of \(Int(maxValue))"))
        }
        if let caption { parts.append(caption) }
        return parts.joined(separator: ", ")
    }

    // MARK: - Later today

    private struct LaterItem: Identifiable {
        let id: String
        /// nil for a planned routine, which has a day but no time.
        let time: Date?
        let title: String
        let systemImage: String
        let tint: Color
        let action: () -> Void
    }

    private var laterItems: [LaterItem] {
        let now = Date()
        var items: [LaterItem] = []
        if let bed = ForgeToday.plannedBedtime(now: now), bed > now,
           bed.timeIntervalSince(now) < 16 * 3600 {
            items.append(LaterItem(id: "bedtime", time: bed, title: String(localized: "Bedtime"),
                                   systemImage: "moon.fill", tint: ForgeColor.rest, action: onSleep))
        }
        // Planned routines first (no time of their own), then the timed items in order.
        let routines = plannedRoutines.map { routine in
            LaterItem(id: "routine-\(routine.id)", time: nil, title: routine.title, systemImage: "dumbbell.fill",
                      tint: ForgeColor.effort, action: { session.requestStrength(routines: [routine]) })
        }
        return routines + items.sorted { ($0.time ?? .distantPast) < ($1.time ?? .distantPast) }
    }

    /// Sunday evening: the week is complete enough to read back.
    private var showsWeeklyChip: Bool {
        let cal = Calendar.current
        return cal.component(.weekday, from: Date()) == 1 && cal.component(.hour, from: Date()) >= 17
    }

    @ViewBuilder private var laterToday: some View {
        let items = laterItems
        if !items.isEmpty || showsWeeklyChip {
            VStack(alignment: .leading, spacing: 8) {
                ForgeSectionTitle(title: "Later Today")
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        if showsWeeklyChip {
                            NavigationLink(value: ForgeRoute.weeklyReport) {
                                laterChip(time: nil, systemImage: "doc.text.fill", tint: ForgeColor.accent,
                                          title: String(localized: "Weekly report"))
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(items) { item in
                            Button(action: item.action) {
                                laterChip(time: item.time, systemImage: item.systemImage, tint: item.tint, title: item.title)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// One "Later Today" chip as in the prototype: time, a tinted round icon, the title.
    private func laterChip(time: Date?, systemImage: String, tint: Color, title: String) -> some View {
        HStack(spacing: 10) {
            if let time {
                Text(time, format: .dateTime.hour().minute().locale(AppLanguage.activeLocale))
                    .font(.system(.subheadline, weight: .medium).monospacedDigit())
                    .foregroundStyle(ForgeColor.secondary)
            }
            Image(systemName: systemImage)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.opacity(0.18)))
            Text(title)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(ForgeColor.text)
                .lineLimit(1)
        }
        .padding(.leading, time == nil ? 10 : 16)
        .padding(.trailing, 18)
        .frame(minHeight: 54)
        .forgeCard(radius: 27, padding: 0)
        .fixedSize()
    }

    // MARK: - Timeline

    private static let timeWidth: CGFloat = 42

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            nowMarker
            if snapshot.loaded && snapshot.timeline.isEmpty {
                Text("Workouts, nights and notes from the coach appear here as the day goes on.")
                    .font(ForgeFont.body)
                    .foregroundStyle(ForgeColor.secondary)
                    .padding(.leading, Self.timeWidth + 28)
                    .padding(.vertical, 12)
            }
            ForEach(Array(snapshot.timeline.enumerated()), id: \.element.id) { index, day in
                if index > 0 || !Calendar.current.isDateInToday(day.date) {
                    dayDivider(day.date)
                }
                ForEach(day.entries) { entry in
                    railRow(time: entry.date, accent: { if case .coach = entry.kind { return true } else { return false } }()) {
                        entryCard(entry)
                    }
                }
            }
        }
        .padding(.top, 10)
    }

    private var nowMarker: some View {
        HStack(spacing: 8) {
            Text(Date(), format: .dateTime.hour().minute().locale(AppLanguage.activeLocale))
                .font(.system(.footnote, weight: .semibold).monospacedDigit())
                .foregroundStyle(ForgeColor.accent)
                .fixedSize()
                .frame(width: Self.timeWidth, alignment: .trailing)
            Circle().fill(ForgeColor.accent).frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(ForgeColor.card, lineWidth: 2))
            Text("Now")
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(ForgeColor.onAccent)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(ForgeColor.accent))
            Spacer()
        }
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    private func dayDivider(_ date: Date) -> some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: Self.timeWidth, height: 1)
            Circle().fill(ForgeColor.text).frame(width: 9, height: 9)
            Text(dayTitle(date)).font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
            Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(AppLanguage.activeLocale))
                .font(.system(.subheadline)).foregroundStyle(ForgeColor.secondary)
            Spacer()
        }
        .padding(.vertical, 10)
        .accessibilityAddTraits(.isHeader)
    }

    private func dayTitle(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return String(localized: "Today") }
        if cal.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return date.formatted(.dateTime.weekday(.wide).locale(AppLanguage.activeLocale))
    }

    private func railRow<Content: View>(time: Date, accent: Bool = false,
                                        @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(time, format: .dateTime.hour().minute().locale(AppLanguage.activeLocale))
                .font(.system(.footnote, weight: .medium).monospacedDigit())
                .foregroundStyle(ForgeColor.tertiary)
                .fixedSize()
                .frame(width: Self.timeWidth, alignment: .trailing)
                .padding(.top, 15)
                .accessibilityHidden(true)
            // One continuous rail: the line runs the full row height, the dot sits on it at the card's
            // first line, so consecutive rows join into a single thread.
            ZStack(alignment: .top) {
                Rectangle().fill(ForgeColor.separator).frame(width: 2).frame(maxHeight: .infinity)
                // Coach notes get the accent dot; everything else a hollow ring, as in the prototype.
                Circle().fill(accent ? ForgeColor.accent : ForgeColor.canvas)
                    .overlay(Circle().strokeBorder(accent ? ForgeColor.accent : ForgeColor.tertiary, lineWidth: 2))
                    .frame(width: 12, height: 12)
                    .padding(.top, 17)
            }
            .frame(width: 12)
            .accessibilityHidden(true)
            content()
                .padding(.bottom, 10)
        }
    }

    @ViewBuilder private func entryCard(_ entry: ForgeTimeline.Entry) -> some View {
        switch entry.kind {
        case .coach(let origin): coachCard(entry, origin: origin)
        case .workout: workoutCard(entry)
        case .wake: wakeCard(entry)
        case .weight: weightCard(entry)
        }
    }

    private func coachLabel(_ entry: ForgeTimeline.Entry, origin: ForgeTimeline.CoachNote.Origin) -> String {
        if let kicker = entry.kicker { return String(localized: "Coach · \(kicker)") }
        switch origin {
        case .brief: return String(localized: "Coach · morning")
        case .checkIn: return String(localized: "Coach · check-in")
        case .nudge: return String(localized: "Coach")
        case .weeklyReview: return String(localized: "Coach · weekly review")
        }
    }

    private func coachCard(_ entry: ForgeTimeline.Entry, origin: ForgeTimeline.CoachNote.Origin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(coachLabel(entry, origin: origin), systemImage: "waveform.path.ecg")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(ForgeColor.accent)
                Spacer()
                Button { whyEntry = entry } label: {
                    Image(systemName: "info.circle")
                        .font(.system(.subheadline))
                        .foregroundStyle(ForgeColor.tertiary)
                        .frame(width: 32, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Why am I seeing this?"))
            }
            Text(entry.title)
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(ForgeColor.text)
                .fixedSize(horizontal: false, vertical: true)
            if !entry.detail.isEmpty {
                Text(Self.markdown(entry.detail))
                    .font(ForgeFont.body)
                    .foregroundStyle(ForgeColor.secondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            noteFigures(entry, origin: origin)
            FlowRows(spacing: 8) {
                if coachFeatureEnabled {
                    ForEach(quickReplies(entry, origin: origin), id: \.self) { reply in
                        ForgeChip(title: reply) { onAsk(reply) }
                    }
                }
                ForgeChip(title: String(localized: "Reply"), systemImage: "square.and.pencil", prominent: true,
                          action: onCoach)
            }
            .padding(.top, 2)
        }
        .forgeCard(radius: 22, padding: 14)
        .contentShape(Rectangle())
        .onTapGesture(perform: onCoach)
        .accessibilityElement(children: .contain)
    }

    /// The coach's emphasis rendered (bold figures), never raw asterisks.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// Short answers offered under a note, as in the prototype. Each is sent as the person's reply.
    private func quickReplies(_ entry: ForgeTimeline.Entry, origin: ForgeTimeline.CoachNote.Origin) -> [String] {
        if entry.kicker == String(localized: "After your workout") {
            return [String(localized: "How long should I rest?"), String(localized: "That was hard")]
        }
        if entry.kicker == String(localized: "Evening recap") {
            return [String(localized: "Plan tomorrow")]
        }
        switch origin {
        case .brief: return [String(localized: "Yes, push today"), String(localized: "Rather easy")]
        case .weeklyReview: return [String(localized: "Plan next week")]
        case .checkIn, .nudge: return [String(localized: "Tell me more")]
        }
    }

    // MARK: Figures under a coach note (read on the device, never written by the model)

    @ViewBuilder private func noteFigures(_ entry: ForgeTimeline.Entry, origin: ForgeTimeline.CoachNote.Origin) -> some View {
        if origin == .brief || origin == .checkIn, !snapshot.drivers.isEmpty,
           Calendar.current.isDateInToday(entry.date) {
            VStack(spacing: 6) {
                ForEach(Array(snapshot.drivers.prefix(3).enumerated()), id: \.offset) { _, driver in
                    HStack(spacing: 8) {
                        Text(driver.label).font(.system(.subheadline)).foregroundStyle(ForgeColor.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer()
                        Text(driver.valueText).font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                        ForgeDirection(delta: driver.deltaPoints)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(ChargeBreakdownFormat.driverAccessibilityLabel(driver)))
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ForgeColor.fill))
        } else if entry.kicker == String(localized: "After your workout"), let row = workoutBefore(entry.date) {
            NavigationLink(value: ForgeRoute.workout(startTs: row.startTs, sport: row.sport)) {
                HStack(spacing: 10) {
                    WorkoutTypeIcon(workoutType: row.sport, size: 15, weight: .semibold,
                                    color: AppleInspiredColors.role(forSport: row.sport).color)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(ForgeColor.fill))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(WorkoutSource.localizedDisplaySport(row.sport))
                            .font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                        Text(workoutDetail(row)).font(.system(.caption)).foregroundStyle(ForgeColor.secondary)
                    }
                    Spacer()
                    if let strain = row.strain {
                        Text(ForgeToday.effortText(strain, scale: effortScale))
                            .font(ForgeFont.rounded(20, .bold)).foregroundStyle(ForgeColor.text)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ForgeColor.fill))
            }
            .buttonStyle(.plain)
            if let zones = WorkoutZones.percents(row.zonesJSON) {
                ForgeZoneBar(percents: zones,
                             minutes: (row.durationS ?? Double(max(row.endTs - row.startTs, 0))) / 60)
            }
        } else if entry.kicker == String(localized: "Evening recap"), let effort = snapshot.effortStored,
                  let target = effortTarget, Calendar.current.isDateInToday(entry.date) {
            ForgeEffortTargetBar(effort: effort, target: target, scale: effortScale)
        }
    }

    /// The newest workout that ended up to six hours before a note: the session a post-workout note is about.
    private func workoutBefore(_ date: Date) -> WorkoutRow? {
        snapshot.workouts.values
            .filter { row in
                let end = Date(timeIntervalSince1970: TimeInterval(row.endTs))
                return end <= date && date.timeIntervalSince(end) <= ForgeCoachNotes.workoutWindow
            }
            .max(by: { $0.endTs < $1.endTs })
    }

    @ViewBuilder private func workoutCard(_ entry: ForgeTimeline.Entry) -> some View {
        if let row = entry.sourceId.flatMap({ snapshot.workouts[$0] }) {
            let tint = AppleInspiredColors.role(forSport: row.sport).color
            NavigationLink(value: ForgeRoute.workout(startTs: row.startTs, sport: row.sport)) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(tint.opacity(0.18))
                        WorkoutTypeIcon(workoutType: row.sport, size: 17, weight: .semibold, color: tint)
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WorkoutSource.localizedDisplaySport(row.sport))
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(ForgeColor.text)
                            .lineLimit(1)
                        Text(workoutDetail(row))
                            .font(ForgeFont.caption)
                            .foregroundStyle(ForgeColor.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if let strain = row.strain {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(ForgeToday.effortText(strain, scale: effortScale))
                                .font(ForgeFont.rounded(22, .bold))
                                .foregroundStyle(ForgeColor.text)
                            Text(DomainTheme.effort.productName)
                                .font(.system(.caption2))
                                .foregroundStyle(ForgeColor.secondary)
                        }
                    }
                }
                .forgeCard(radius: 22, padding: 14)
            }
            .buttonStyle(LiquidPressStyle())
        }
    }

    /// A weigh-in with its time (only entries that record one reach the timeline).
    private func weightCard(_ entry: ForgeTimeline.Entry) -> some View {
        NavigationLink(value: TabRoute.weight) {
            HStack(spacing: 12) {
                Image(systemName: "figure.stand")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(ForgeColor.rest)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(ForgeColor.rest.opacity(0.18)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Weight logged").font(.system(.body, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    if let change = snapshot.weightChange30d {
                        Text("\(UnitFormatter.massFromKilograms(change, system: UnitSystem(rawValue: unitSystemRaw) ?? .metric).replacingOccurrences(of: "-", with: "−")) in 30 days")
                            .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    }
                }
                Spacer(minLength: 6)
                if let kg = entry.value {
                    Text(UnitFormatter.massFromKilograms(kg, system: UnitSystem(rawValue: unitSystemRaw) ?? .metric))
                        .font(ForgeFont.rounded(20, .bold)).foregroundStyle(ForgeColor.text)
                }
            }
            .forgeCard(radius: 22, padding: 14)
        }
        .buttonStyle(LiquidPressStyle())
    }

    private func workoutDetail(_ row: WorkoutRow) -> String {
        var parts: [String] = []
        let secs = row.durationS ?? Double(max(row.endTs - row.startTs, 0))
        parts.append(String(localized: "\(Int(secs / 60)) min"))
        if let dm = row.distanceM, dm > 0 { parts.append(UnitFormatter.distanceFromMeters(dm, system: distanceSystem)) }
        if parts.count < 2, let k = row.energyKcal, k > 0 { parts.append("\(Int(k.rounded())) kcal") }
        return parts.joined(separator: " · ")
    }

    private func wakeCard(_ entry: ForgeTimeline.Entry) -> some View {
        let session = snapshot.sleeps[Int(entry.date.timeIntervalSince1970)]
        let start = session.map { Date(timeIntervalSince1970: TimeInterval($0.effectiveStartTs)) }
        return Button(action: onSleep) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(ForgeColor.rest.opacity(0.18))
                    Image(systemName: "sun.horizon.fill")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(ForgeColor.rest)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Woke up")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(ForgeColor.text)
                    if let start {
                        Text("\(start.formatted(.dateTime.hour().minute().locale(AppLanguage.activeLocale))) to \(entry.date.formatted(.dateTime.hour().minute().locale(AppLanguage.activeLocale)))")
                            .font(ForgeFont.caption)
                            .foregroundStyle(ForgeColor.secondary)
                    }
                }
                Spacer(minLength: 6)
                if let minutes = entry.value, minutes > 0 {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(Self.hoursMinutes(minutes))
                            .font(ForgeFont.rounded(22, .bold))
                            .foregroundStyle(ForgeColor.text)
                        Text("h asleep")
                            .font(.system(.caption2))
                            .foregroundStyle(ForgeColor.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 10) {
                if let stages = session.flatMap({ SleepView.decodeStages($0.stagesJSON) }) {
                    ForgeStageStrip(deep: stages.deep, rem: stages.rem, light: stages.light, awake: stages.awake)
                }
            }
            .forgeCard(radius: 22, padding: 14)
        }
        .buttonStyle(LiquidPressStyle())
    }

    /// The moment the note policy judges against. DEBUG `--forge-notes-at HH:MM` pins it to that time of
    /// today, so the after-workout and evening notes can be exercised in the simulator outside their hours.
    private static func notesClock(_ now: Date) -> Date {
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--forge-notes-at"), i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").compactMap { Int($0) }
            if parts.count == 2,
               let pinned = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now) {
                return pinned
            }
        }
        #endif
        return now
    }

    #if DEBUG
    private static func demoCoachNotes(now: Date) -> [ForgeTimeline.CoachNote] {
        let cal = Calendar.current
        func at(_ hour: Int, _ minute: Int, daysAgo: Int = 0) -> Date {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? now
        }
        return [
            .init(id: "demo-evening", date: at(20, 55), text: String(localized: "Evening recap") + "\n\nStrong day, inside your Effort target. Strength took most of it; bed by 23:00 keeps tomorrow's Charge up.", origin: .nudge),
            .init(id: "demo-workout", date: at(11, 5), text: String(localized: "After your workout") + "\n\nSteady walk, heart rate stayed easy. Good recovery work after yesterday's strength session.", origin: .nudge),
            .init(id: "demo-brief", date: at(7, 52), text: "Well recovered, push a bit today. HRV is above your usual range and resting heart rate is low. A harder session fits.", origin: .brief),
            .init(id: "demo-weekly", date: at(21, 30, daysAgo: 1), text: String(localized: "Weekly review") + "\n\nFive sessions this week, the plan is on track. Sleep held at about seven and a half hours.", origin: .weeklyReview),
        ].filter { $0.date <= now }
    }
    #endif

    /// Today's routines from the training plan, unless a strength session was already recorded today.
    private static func plannedRoutines(repo: Repository, now: Date, workouts: [WorkoutRow]) async -> [TrainingRoutine] {
        let cal = Calendar.current
        let trainedToday = workouts.contains {
            cal.isDate(Date(timeIntervalSince1970: TimeInterval($0.startTs)), inSameDayAs: now)
                && $0.sport.localizedCaseInsensitiveContains("strength")
        }
        guard !trainedToday else { return [] }
        let plan = await repo.nativeTrainingPlan()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let weekdayIndex = cal.component(.weekday, from: now)
        let weekday = TrainingWeekday(rawValue: weekdayIndex == 1 ? 7 : weekdayIndex - 1) ?? .monday
        return plan.routines(day: f.string(from: now), weekday: weekday)
    }

    static func hoursMinutes(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Load

    private func load(force: Bool) async {
        let now = Date()
        let allDays = repo.days
        let todayKey = Repository.logicalDayKey(now)
        let displayDay = repo.today ?? allDays.last(where: { $0.day == todayKey })
        var next = Snapshot()
        next.charge = ChargeDisplay.resolve(days: allDays, displayDay: displayDay, selectedDayKey: todayKey, isToday: true)
        let restSeries = await repo.exploreSeries(key: "sleep_performance", source: Repository.whoopSource, days: 30)
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        next.rest = DashboardRestScore.value(day: todayKey, days: allDays, importedSleep: repo.importedSleep)
            ?? TodayView.freshRestScore(todayValue: displayDay.flatMap { restByDay[$0.day] },
                                        lastDay: restSeries.last?.day, lastValue: restSeries.last?.value,
                                        isTodaySelected: true, todayKey: todayKey)
        next.effortDay = todayKey
        let calibrating: Bool = { if case .calibrating = next.charge { return true } else { return false } }()
        let chargeRow = TodayView.lastScoredRecoveryDay(days: allDays, selectedDayKey: todayKey, isToday: true,
                                                        todayScored: displayDay?.recovery != nil,
                                                        isCalibrating: calibrating) ?? displayDay
        next.drivers = ChargeBreakdownFormat.compute(row: chargeRow, baselines: repo.chargeBaselines,
                                                     restScore: next.rest)?.drivers ?? []

        let workouts = await repo.workoutRows(days: 3, reconcileHrCap: 0)
        plannedRoutines = await Self.plannedRoutines(repo: repo, now: now, workouts: workouts)
        let nowTs = Int(now.timeIntervalSince1970)
        let sleeps = await repo.sleepSessions(from: nowTs - 3 * 86_400, to: nowTs)

        var input = ForgeTimeline.Input()
        // Weigh-ins that carry their own time (NOOP's own entries; Apple's daily cells have none).
        for w in await repo.weightEntries(days: 3) {
            if let at = w.takenAt { input.weights.append(.init(date: at, kg: w.value)) }
        }
        next.weightChange30d = await repo.weightTrendSummary(days: 91)?.change30dKg
        for w in workouts {
            let id = "\(w.startTs)|\(w.sport)"
            next.workouts[id] = w
            input.workouts.append(.init(id: id, start: Date(timeIntervalSince1970: TimeInterval(w.startTs)),
                                        end: Date(timeIntervalSince1970: TimeInterval(w.endTs)), sport: w.sport,
                                        effort: w.strain, distanceM: w.distanceM, energyKcal: w.energyKcal))
        }
        for s in sleeps {
            let asleep = SleepNight.asleepMinutes(s.stagesJSON, effectiveStartTs: s.effectiveStartTs)
            // A main night, not a nap fragment: naps get their own entry later (Sleep tab).
            guard asleep >= 180 else { continue }
            next.sleeps[s.endTs] = s
            input.sleeps.append(.init(start: Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs)),
                                      end: Date(timeIntervalSince1970: TimeInterval(s.endTs)),
                                      minutesAsleep: asleep, rest: nil))
        }
        if coachFeatureEnabled {
            let cutoff = now.addingTimeInterval(-3 * 86_400)
            for conversation in coach.conversations {
                for m in conversation.messages where m.role == .assistant && m.date >= cutoff {
                    let origin: ForgeTimeline.CoachNote.Origin
                    switch m.origin {
                    case .brief: origin = .brief
                    case .checkIn: origin = .checkIn
                    case .nudge: origin = .nudge
                    case .weeklyReview: origin = .weeklyReview
                    case .reply: continue
                    }
                    input.coach.append(.init(id: m.id.uuidString, date: m.date, text: m.text, origin: origin))
                    next.notes[m.id.uuidString] = m
                }
            }
        }
        #if DEBUG
        // `--demo-coach`: canned notes so screenshots show coach cards without a provider key. Shown only,
        // never written to the transcript.
        if CommandLine.arguments.contains("--demo-coach") {
            input.coach += Self.demoCoachNotes(now: now)
        }
        #endif
        next.timeline = ForgeTimeline.build(input, now: now, days: 2, dayKey: { Repository.logicalDayKey($0) })
        next.loaded = true

        // The heaviest read last, as on the shipped Today: Effort floors at the stored row, so the live
        // refinement can only raise the ring, never pull it back.
        snapshot = next
        let live = await LiveEffort.today(repo: repo, profile: profile, restingHr: displayDay?.restingHr)
        let effort = StrainScorer.effectiveEffort(live: live, stored: displayDay?.day == todayKey ? displayDay?.strain : nil)
        guard !Task.isCancelled else { return }
        snapshot.effortStored = effort
        // A due note (after a workout, in the evening) is written now, the same moment the brief uses.
        // When it lands, the transcript changes and `reloadKey` brings it into the timeline.
        if coachFeatureEnabled {
            Task { await coach.runForgeNotesIfDue(workouts: workouts, now: Self.notesClock(now)) }
        }
    }
}
/// Where the rings card ends in the Today scroll view, to pin the compact bar once it is gone.
private struct ForgeHeroBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}
#endif
