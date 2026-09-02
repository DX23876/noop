import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

/// A reference-matched alternative to Today: a Coach card, the CHARGE/EFFORT/REST hero rings, a 14-day
/// three-line trend chart, four configurable metric slots, and the most recent workout. Built to sit
/// alongside Classic and Liquid (`TodayDashboardStyle`), not to replace them — everything here reads
/// the SAME `Repository`/`DailyMetric` data the other two Today screens already load; only the layout
/// differs.
///
/// Deliberately screenshot-faithful over "improved": where a spacing or a choice looks unusual, it is
/// reproducing the reference rather than a judgement call.
struct TrendsDashboardView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var updateStore: UpdateStore
    @EnvironmentObject private var coach: AICoachEngine
    @EnvironmentObject private var router: NavRouter
    @EnvironmentObject private var model: AppModel
    // Deliberately NO `@EnvironmentObject live: LiveState` here — see the leaf-isolation note in
    // TodayView: a connected strap publishes `LiveState` ~1 Hz, and observing it at this level would
    // re-evaluate the WHOLE dashboard body on every heart-rate tick. The one thing on this screen that
    // shows live values, `DashboardBatteryButton`, owns its own `LiveState` and re-renders alone.
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal
    @ObservedObject private var goalStore = CoachGoalStore.shared
    @ObservedObject private var goalTracking = GoalTrackingStore.shared

    // Phase-1 opt-in extras (see DashboardExtraSectionsPrefs) — off by default, so a dashboard nobody
    // touches these settings on renders exactly as before.
    @AppStorage(DashboardLayoutPrefs.orderKey("trends")) private var layoutOrderRaw = ""
    @AppStorage(DashboardLayoutPrefs.hiddenKey("trends")) private var layoutHiddenRaw = ""

    @AppStorage(TrendsMetricSlotsPrefs.slot1Key) private var slot1Raw = TrendsMetricSlotsPrefs.defaultSlots[0].rawValue
    @AppStorage(TrendsMetricSlotsPrefs.slot2Key) private var slot2Raw = TrendsMetricSlotsPrefs.defaultSlots[1].rawValue
    @AppStorage(TrendsMetricSlotsPrefs.slot3Key) private var slot3Raw = TrendsMetricSlotsPrefs.defaultSlots[2].rawValue
    @AppStorage(TrendsMetricSlotsPrefs.slot4Key) private var slot4Raw = TrendsMetricSlotsPrefs.defaultSlots[3].rawValue
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    private var slots: [DashboardCard] {
        [slot1Raw, slot2Raw, slot3Raw, slot4Raw].map { DashboardCard(rawValue: $0) ?? .hrv }
    }

    @State private var displayDay: DailyMetric?
    @State private var recentDays: [DailyMetric] = []
    @State private var restByDay: [String: Double] = [:]
    @State private var restSeriesTail: (day: String, value: Double)?
    @State private var appleDays: [AppleDaily] = []
    @State private var latestWorkout: WorkoutRow?
    @State private var latestWorkoutHR: [Double] = []
    @State private var recentWorkouts: [WorkoutRow] = []
    @State private var journalLoggedDays: Set<String>?
    @State private var todayEnergySummary: DailyEnergySummary?
    @State private var fitnessAgeToday: Double?
    @State private var vo2maxToday: Double?
    @State private var vitalityToday: Double?
    @State private var stressToday: Double?
    @State private var hydrationTotalML: Double?
    @State private var resolvedWeightKg: Double?
    /// The per-field vitals carry the dashboard cards use — see `DashboardVitalCarry`.
    @State private var vitalCarry = DashboardVitalCarry()
    @State private var showCoach = false
    @State private var showUpdatesInbox = false
    @State private var showSettings = false
    @State private var showExtraSections = false
    @State private var showPlan = false
    @State private var showLiveSession = false
    @AppStorage(DashboardArrangeHint.seenKey("trends")) private var arrangeHintSeen = false
    @State private var showArrangeHint = false
    // The SAME dwell/snooze bookkeeping both Today screens use — one wearer, one card, so switching
    // styles must not restart the dwell or resurrect a message hidden an hour ago.
    @AppStorage(DashboardMomentum.Keys.lastKind) private var momentumLastKind = ""
    @AppStorage(DashboardMomentum.Keys.lastAt) private var momentumLastAt: Double = 0
    @AppStorage(DashboardMomentum.Keys.snoozed) private var momentumSnoozedRaw = ""
    @AppStorage(DashboardMomentum.Keys.stepGoal) private var momentumStepGoal = 0
    @State private var selectedDayOffset = 0

    /// Scroll-to-top target for an at-root Today re-tap, the same zero-height anchor Liquid Today uses.
    private static let topAnchorID = "trendsDashboardTop"

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                Color.clear.frame(height: 0).id(Self.topAnchorID)
                header
                // Pinned ABOVE the reorderable block, exactly where Classic and Liquid Today pin them:
                // a raised health alert or a running workout must not be reorderable below the fold.
                // Every card here renders NOTHING when it has nothing to report, so the reference
                // layout this screen matches is unchanged on an ordinary day.
                HealthAlertBanner()
                // #105-class regression: the workout-in-progress card was dropped by the liquid rewrite
                // and restored; these two dashboards then shipped without it. Same shared leaf, so all
                // four Today screens (and Android's WorkoutInProgressCard) cannot drift apart.
                ActiveWorkoutIndicatorSection()
                MorningSuggestionCard(showPlan: $showPlan)
                ForEach(layoutSections) { section in dashboardSection(section) }
                // Below the metric sections on purpose: once accepted, the committed session is an
                // ambient reminder rather than a demand for the top of the screen (Liquid's rationale).
                PlanTodayCard(showPlan: $showPlan)
                // Self-gates on the auto-detect toggle AND on an unsaved, un-dismissed window, so it
                // renders nothing by default. Without it the setting can be on and never show anything.
                AutoWorkoutCard()
            }
            .padding(.horizontal, NoopMetrics.screenPadding)
            .padding(.top, NoopMetrics.screenPadding)
            // The native floating tab bar is translucent and deliberately overlays scroll content.
            // Reserve enough scroll tail that the last optional dashboard card can be brought fully
            // above it instead of looking like a large, clipped/empty block.
            .padding(.bottom, 104)
        }
        // Parity with every other scrollable root (ScreenScaffold's `onRefresh`, Liquid's own pull):
        // this screen was the one Today style with no way to pull for fresh data.
        .refreshable { await repo.refresh() }
        #if os(iOS)
        // Scroll-to-top on an at-root Today re-tap; iOS-only — the tab shell is the only driver.
        .onChange(of: scrollToTopSignal) { _, _ in
            withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo(Self.topAnchorID, anchor: .top) }
        }
        #endif
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .simultaneousGesture(daySwipeGesture)
        // The visible-section set joins the id because `load()` now skips the reads that only feed a
        // hidden section: showing one has to re-run the load that fills it, or it would render empty
        // until the next refresh.
        .task(id: "\(repo.refreshSeq)-\(selectedDayOffset)-\(layoutSectionsKey)") { await load() }
        .coachCover(isPresented: $showCoach, coach: coach)
        // Honour a one-shot "open Live Session" request (the coach chat's action chip, or a deep link).
        // Fires on the flag itself, not on appear, so it still works when Today is already the active
        // tab — the same contract `LiquidTodayView.consumeLiveSessionRequest()` implements.
        .onChangeCompat(of: router.presentLiveSession) { present in
            guard present else { return }
            router.presentLiveSession = false
            showLiveSession = true
        }
        .liveSessionCover(isPresented: $showLiveSession)
        // Told once, on the screen the gesture belongs to. The flag is written as the sheet is raised, so
        // swiping it away still counts as having been told.
        .onAppear {
            guard !arrangeHintSeen else { return }
            arrangeHintSeen = true
            showArrangeHint = true
        }
        .dashboardArrangeHint(dashboard: "trends", isPresented: $showArrangeHint)
        .sheet(isPresented: $showPlan) { CoachPlanView().environmentObject(coach) }
        .sheet(isPresented: $showUpdatesInbox) { UpdatesInboxView(onClose: { showUpdatesInbox = false }) }
        .sheet(isPresented: $showExtraSections) {
            DashboardExtraSectionsSheet(dashboard: "trends", title: String(localized: "Dashboard sections"))
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        #if os(iOS)
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showSettings = false }.foregroundStyle(StrandPalette.accent)
                        }
                        #else
                        ToolbarItem {
                            Button("Done") { showSettings = false }.foregroundStyle(StrandPalette.accent)
                        }
                        #endif
                    }
            }
        }
        }
    }

    private var layoutSections: [DashboardLayoutSection] {
        let order = DashboardLayoutPrefs.order(layoutOrderRaw, dashboard: "trends")
        let hidden = DashboardLayoutPrefs.hidden(layoutHiddenRaw, dashboard: "trends")
        return order.filter { !hidden.contains($0) }
    }

    /// Stable identity of the VISIBLE section set, for the load `.task` id. Reordering alone must not
    /// re-run the load (nothing about the data changes), so this is sorted rather than positional.
    private var layoutSectionsKey: String {
        layoutSections.map(\.rawValue).sorted().joined(separator: ",")
    }

    @ViewBuilder private func dashboardSection(_ section: DashboardLayoutSection) -> some View {
        switch section {
        case .coach: coachCard
        case .hero: heroRings
        case .trendsChart: trendsCard
        case .metricStrip:
            TrendsMetricStrip(cards: slots, day: displayDay,
                              appleDay: appleDays.last(where: { $0.day == displayDay?.day }),
                              resolvedValue: trendMetricValueText)
        case .activity: activitySection
        case .goals: if selectedDayOffset == 0 { goalsSection }
        case .energyDetail: energyDetailSection
        case .journal: if selectedDayOffset == 0 { journalSection }
        case .menstrualCycle: if selectedDayOffset == 0 { menstrualCycleSection }
        case .workoutsList:
            // "More workouts" means more than the one `.activity` already shows — but only when
            // `.activity` is actually visible. With it hidden, dropping the first row silently lost the
            // MOST RECENT workout, the one row the section exists to surface.
            let extras = Self.moreWorkouts(recentWorkouts, activityVisible: layoutSections.contains(.activity))
            if !extras.isEmpty {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    Text("More workouts").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    ForEach(Array(extras.enumerated()), id: \.offset) { _, workout in
                        workoutRow(workout, hr: [])
                    }
                }
            }
        case .overview, .focus, .health: EmptyView()
        default:
            DashboardSupplementSections(dashboard: "trends", compact: false, day: displayDay,
                                        appleDay: appleDays.last(where: { $0.day == selectedDayKey }),
                                        dayKey: selectedDayKey, isToday: selectedDayOffset == 0, only: section,
                                        resolvedValue: trendMetricValueText)
        }
    }

    // MARK: - Loading

    private func load() async {
        let allDays = repo.days
        // One pass over the day list, not two: `recentDays` is the tail of the same scoped slice the
        // stress model reads below.
        let scopedDays = allDays.filter { $0.day <= selectedDayKey }
        recentDays = Array(scopedDays.suffix(120))
        displayDay = selectedDayOffset == 0
            ? (repo.today ?? allDays.last(where: { $0.day == selectedDayKey }))
            : allDays.last(where: { $0.day == selectedDayKey })
        let sections = layoutSections

        // Rest is its own scored series ("sleep_performance"), not derived from raw sleep minutes — the
        // SAME accessor and fallback rule (`TodayView.freshRestScore`) Today's own Rest ring uses, so
        // this screen can never disagree with Today about what Rest is for the same night.
        //
        // Read over a BOUNDED window rather than `exploreSeries`' 4000-day default: the chart needs 14
        // days back from the selected one, and the tail is only ever the today-carry, which
        // `freshRestScore` discards once it is older than `TodayView.carryFreshnessDays` (2). Beyond
        // this window a full-history read cannot change what is drawn — only what it costs to draw.
        async let appleDaysA = repo.appleDailyRows(days: max(30, selectedDayOffset + 7))
        async let restSeriesA = repo.exploreSeries(key: "sleep_performance", source: Repository.whoopSource,
                                                   days: max(30, selectedDayOffset + 30))
        async let energySummariesA = repo.energySummaries(days: max(30, selectedDayOffset + 2), profile: Repository.analyticsProfile(profile))
        async let fitnessAgeSeriesA = repo.exploreSeries(key: "fitness_age", source: Repository.whoopSource, days: 120)
        async let vo2maxSeriesA = repo.exploreSeries(key: "vo2max_est", source: Repository.whoopSource, days: 120)
        async let vitalitySeriesA = repo.exploreSeries(key: "vitality", source: Repository.whoopSource, days: 120)
        async let stressStoredA = repo.series(key: "stress", source: Repository.whoopSource, days: 120)
        async let hydrationA = repo.hydrationTotal(day: selectedDayKey)
        async let weightSummaryA = repo.weightTrendSummary(days: 91)

        vitalCarry = DashboardVitalCarry.resolve(days: allDays,
                                                 todayKey: displayDay?.day ?? selectedDayKey,
                                                 isToday: selectedDayOffset == 0)
        appleDays = await appleDaysA
        let restSeries = await restSeriesA
        restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        restSeriesTail = restSeries.last
        todayEnergySummary = (await energySummariesA).last(where: { $0.day == selectedDayKey })
        fitnessAgeToday = latestBanked(await fitnessAgeSeriesA, asOf: selectedDayKey)
        vo2maxToday = latestBanked(await vo2maxSeriesA, asOf: selectedDayKey)
        vitalityToday = latestBanked(await vitalitySeriesA, asOf: selectedDayKey)
        stressToday = StressModel(days: scopedDays, stored: await stressStoredA)?.score
        hydrationTotalML = await hydrationA
        resolvedWeightKg = WeightSeries.displayWeight(summary: await weightSummaryA,
                                                       profileWeightKg: profile.weightKg).kg

        // Workouts feed `.activity` (shown by default) and the optional `.workoutsList`; skip the read
        // entirely when neither is visible. The per-workout HR fetch behind the sparkline is narrower
        // still — only `.activity` draws one, so hiding it drops a 400-sample query per load.
        if sections.contains(.activity) || sections.contains(.workoutsList) {
            let allWorkouts = (await repo.workoutRows(days: max(14, selectedDayOffset + 2), reconcileHrCap: 0))
                .sorted { $0.startTs > $1.startTs }
            // "Recent activity" on Today means recent, not "only if one happened after midnight".
            // Historical pages remain strictly scoped to their selected calendar day.
            let workouts = selectedDayOffset == 0 ? allWorkouts : allWorkouts.filter {
                Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs))) == selectedDayKey
            }
            latestWorkout = workouts.first
            recentWorkouts = Array(workouts.prefix(5))
            if sections.contains(.activity), let w = workouts.first {
                let hr = await repo.hrSamples(from: w.startTs, to: w.endTs, limit: 400)
                latestWorkoutHR = hr.map { Double($0.bpm) }
            } else {
                latestWorkoutHR = []
            }
        } else {
            latestWorkout = nil
            recentWorkouts = []
            latestWorkoutHR = []
        }

        // Hidden by default — see the Overview twin's note on why this is gated rather than always read.
        if sections.contains(.journal) {
            let journalKeys = Self.journalDayKeys(anchor: selectedLogicalDay)
            journalLoggedDays = await repo.nativeJournalDays(from: journalKeys.first ?? "", to: journalKeys.last ?? "")
        } else {
            journalLoggedDays = nil
        }

        // Publish the Momentum feed. Until now nothing on this screen did, so a wearer whose Today is a
        // dashboard had an empty MomentumStore forever — the section rendered its "open Momentum"
        // fallback and never a message. Done at the end of load(), after the values it reads are set.
        let steps = DailyStepsReading.resolve(
            strapSteps: displayDay?.steps,
            appleSteps: appleDays.last(where: { $0.day == selectedDayKey })?.steps,
            estimatedSteps: nil)
        DashboardMomentum.publish(
            context: DashboardMomentum.context(displayDay: displayDay, allDays: allDays,
                                               dayKey: selectedDayKey, isToday: selectedDayOffset == 0,
                                               steps: steps, stepGoal: momentumStepGoal, model: model),
            allDays: allDays,
            snoozedRaw: momentumSnoozedRaw, lastKind: momentumLastKind, lastAt: momentumLastAt,
            retrospective: selectedDayOffset != 0)
    }

    private static func journalDayKeys(days: Int = 7, anchor: Date = Date()) -> [String] {
        let cal = Calendar.current
        return (0..<days).reversed().map { n in
            Repository.localDayKey(cal.date(byAdding: .day, value: -n, to: anchor) ?? anchor)
        }
    }

    private var selectedLogicalDay: Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: base) ?? base
    }

    private var selectedDayKey: String {
        if selectedDayOffset == 0, let key = repo.today?.day { return key }
        return Repository.localDayKey(selectedLogicalDay)
    }

    private var earliestDayOffset: Int {
        TodayView.maxDayOffset(earliestDayKey: repo.freshness.earliestDay,
                               todayKey: Repository.logicalDayKey(Date()))
    }

    /// The Rest score for a given day, with the same today-only, freshness-gated carry Today's own Rest
    /// ring uses (`TodayView.freshRestScore`) — never a bare `totalSleepMin / 8h` guess.
    private func restScore(for day: DailyMetric?, isToday: Bool) -> Double? {
        TodayView.freshRestScore(todayValue: day.flatMap { restByDay[$0.day] },
                                 lastDay: restSeriesTail?.day, lastValue: restSeriesTail?.value,
                                 isTodaySelected: isToday, todayKey: Repository.logicalDayKey(Date()))
    }

    private func trendMetricValueText(_ card: DashboardCard) -> String {
        switch card {
        case .fitnessAge:
            return fitnessAgeToday.map { "\(Int($0.rounded()))" } ?? "—"
        case .calories:
            return EnergyDisplay.totalText(todayEnergySummary)
        case .vo2max:
            return vo2maxToday.map { String(format: "%.1f", locale: AppLanguage.activeLocale, $0) } ?? "—"
        case .vitality:
            return vitalityToday.map { "\(Int($0.rounded()))" } ?? "—"
        case .stress:
            return stressToday.map { String(format: "%.1f", locale: AppLanguage.activeLocale, $0) } ?? "—"
        case .hydration:
            return HydrationGoal.cardValueString(totalML: hydrationTotalML ?? 0,
                                                  goalML: repo.hydrationGoalML(profileSex: profile.sex))
        case .weight:
            guard let kg = resolvedWeightKg else { return "—" }
            return UnitFormatter.massFromKilograms(kg, system: unitSystem)
        // The three sparse columns carry, exactly as Today's own dashboard cards do: a nil here means
        // "no reading on this row", not "nobody measured".
        case .bloodOxygen:
            return vitalCarry.spo2Pct(displayDay).map {
                String(format: "%.0f%%", locale: AppLanguage.activeLocale, $0)
            } ?? "—"
        case .respiratory:
            return vitalCarry.respRateBpm(displayDay).map {
                String(format: "%.1f", locale: AppLanguage.activeLocale, $0)
            } ?? "—"
        case .skinTemp:
            return vitalCarry.skinTempDevC(displayDay).map {
                String(format: "%+.1f°", locale: AppLanguage.activeLocale, $0)
            } ?? "—"
        default:
            return TrendsMetricStrip.valueText(card, day: displayDay,
                                                appleDay: appleDays.last(where: { $0.day == selectedDayKey }))
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("N O O P")
                    .font(StrandFont.rounded(20, weight: .bold))
                    .tracking(6)
                    .foregroundStyle(StrandPalette.textPrimary)
                    // Dashboard sections deliberately have no visible edit affordance. Long-pressing
                    // the wordmark is the shared, discoverable-enough shortcut for both custom layouts.
                    .contentShape(Rectangle())
                    .onLongPressGesture { showExtraSections = true }
                Spacer()
                DashboardBatteryButton(size: 36)
                headerIconButton(systemName: "plus", badge: 0) { router.requestQuickActions() }
                    .accessibilityLabel("Quick actions")
                    .accessibilityHint("Start a workout, log your journal, or breathe")
                headerIconButton(systemName: updateStore.unreadCount > 0 ? "bell.badge" : "bell",
                                 badge: updateStore.unreadCount) { showUpdatesInbox = true }
                headerIconButton(systemName: "slider.horizontal.3", badge: 0) { showSettings = true }
            }
            Text(Self.dateFormatter.string(from: selectedLogicalDay))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) * 1.5,
                  abs(value.translation.width) > 50 else { return }
            let maxOffset = earliestDayOffset
            let next = min(max(0, selectedDayOffset + (value.translation.width < 0 ? 1 : -1)), maxOffset)
            guard next != selectedDayOffset else { return }
            withAnimation(StrandMotion.interactive) { selectedDayOffset = next }
        }
    }

    private func headerIconButton(systemName: String, badge: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(StrandPalette.surfaceInset))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(min(badge, 99))")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Circle().fill(StrandPalette.statusCritical))
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }()

    // MARK: - Coach card

    /// Shared with Overview (`DashboardCoachCard`) so the two dashboards cannot drift into two different
    /// Coach greetings or two different recommendation sentences.
    private var coachCard: some View {
        DashboardCoachCard(day: displayDay) { showCoach = true }
    }


    // MARK: - Hero rings

    private var heroRings: some View {
        let d = displayDay
        return HStack(spacing: 16) {
            heroRing(label: "CHARGE", systemImage: "bolt.heart.fill", score: d?.recovery,
                    color: d?.recovery.map { StrandPalette.chargeRingColor($0) } ?? StrandPalette.textTertiary,
                    route: .metricSourced(key: "recovery", source: Repository.whoopSource))
            heroRing(label: "EFFORT", systemImage: "figure.run",
                    score: d?.strain,
                    displayValue: d?.strain.map { UnitFormatter.effortValue($0, scale: effortScale) },
                    decimals: effortScale == .whoop ? 1 : 0, color: StrandPalette.effortColor,
                    route: .metricSourced(key: "strain", source: Repository.whoopSource))
            heroRing(label: "REST", systemImage: "moon.stars.fill",
                    score: restScore(for: d, isToday: selectedDayOffset == 0), color: StrandPalette.restColor,
                    route: .metricSourced(key: "sleep_performance", source: Repository.whoopSource))
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func heroRing(label: String, systemImage: String, score: Double?, displayValue: Double? = nil,
                          decimals: Int = 0, color: Color, route: TabRoute) -> some View {
        NavigationLink(value: route) { VStack(spacing: 6) {
            if let score {
                GlowRing(fraction: score / 100, value: displayValue ?? score,
                         format: { decimals == 0 ? "\(Int($0.rounded()))"
                                   : String(format: "%.\(decimals)f", locale: AppLanguage.activeLocale, $0) },
                         color: color, diameter: 92, lineWidth: 9)
                    .overlay(alignment: .top) {
                        Image(systemName: systemImage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(color)
                            .padding(.top, 16)
                    }
            } else {
                ZStack {
                    Circle().stroke(StrandPalette.textPrimary.opacity(0.10),
                                    style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    Text("—").font(GlowRing.centerFont(diameter: 92)).foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(width: 92, height: 92)
            }
            Text(verbatim: label)
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Trends card

    private var trendsCard: some View {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -13, to: selectedLogicalDay) ?? selectedLogicalDay
        let cutoffKey = Repository.localDayKey(cutoffDate)
        let recent = recentDays.filter { $0.day >= cutoffKey && $0.day <= selectedDayKey }
        // The legend is the selected day's value, not merely the newest older sample. Otherwise a
        // data gap can make the legend show numbers while the same day's hero rings correctly show —.
        let last = recent.last(where: { $0.day == selectedDayKey })
        return Button { router.openTrends() } label: { NoopCard(padding: NoopMetrics.cardPadding) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your trends").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text("14-day trend").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        trendLegendRow(color: StrandPalette.chargeColor, label: "Charge", value: last?.recovery)
                        trendLegendRow(color: StrandPalette.effortColor, label: "Effort",
                                      value: last?.strain.map { UnitFormatter.effortValue($0, scale: effortScale) },
                                      decimals: effortScale == .whoop ? 1 : 0)
                        trendLegendRow(color: StrandPalette.restColor, label: "Rest",
                                      value: last.flatMap { restByDay[$0.day] })
                    }
                    .frame(width: 92, alignment: .leading)
                    TrendsMultiLineChart(days: recent, restByDay: restByDay,
                                         domain: cutoffDate...selectedLogicalDay)
                        .frame(height: 100)
                }
                if let first = recent.first {
                    HStack {
                        Text(Self.axisFormatter.string(from: Self.date(first.day) ?? Date()))
                        Spacer()
                        if hasTrendDataGap(recent) {
                            Label("No data", systemImage: "exclamationmark.circle")
                                .labelStyle(.titleAndIcon)
                        }
                        Spacer()
                        Text(selectedDayOffset == 0 ? String(localized: "Today")
                             : Self.axisFormatter.string(from: selectedLogicalDay))
                    }
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.leading, 104)
                }
            }
        } }.buttonStyle(.plain)
    }

    /// A broken chart line is intentional when an entire calendar day is missing: joining the two
    /// samples would invent a health measurement. Make that honest gap explicit so it does not read
    /// as a rendering defect.
    private func hasTrendDataGap(_ days: [DailyMetric]) -> Bool {
        let dates = days.compactMap { Self.date($0.day) }.sorted()
        guard dates.count > 1 else { return false }
        return zip(dates, dates.dropFirst()).contains { previous, next in
            Calendar.current.dateComponents([.day], from: previous, to: next).day != 1
        }
    }

    // `label` is a plain `String`, rendered `verbatim`, matching `heroRing`'s own deliberate choice
    // (Charge/Effort/Rest as fixed WHOOP-style terms, never localized) — the catalog happens to carry a
    // German translation for the plain word "Charge" from elsewhere in the app, which made this legend
    // read "Energie"/"Belastung"/"Erholung" while the rings right above it stayed "CHARGE"/"EFFORT"/
    // "REST": the same screen naming the same three metrics two different ways.
    private func trendLegendRow(color: Color, label: String, value: Double?, decimals: Int = 0) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(verbatim: label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 0)
            Text(value.map { decimals == 0 ? "\(Int($0.rounded()))"
                            : String(format: "%.\(decimals)f", locale: AppLanguage.activeLocale, $0) } ?? "—")
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private static let axisFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()

    private static func date(_ key: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.date(from: key)
    }

    // MARK: - Activity

    @ViewBuilder
    private var activitySection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack {
                Text("Recent activity").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                NavigationLink(value: TabRoute.workouts) {
                    Text("View all").font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                }
            }
            if let w = latestWorkout {
                workoutRow(w, hr: latestWorkoutHR)
            } else {
                Text("No workouts recorded recently.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    /// The rows "More workouts" should render, given whether `.activity` (which already shows the most
    /// recent one) is visible. Pure and non-private so the hidden-`.activity` case is pinned by a test
    /// rather than re-derived by eye: this section used to `dropFirst()` unconditionally, which made the
    /// newest workout vanish entirely for anyone who hid `.activity` and showed this instead.
    static func moreWorkouts(_ workouts: [WorkoutRow], activityVisible: Bool) -> [WorkoutRow] {
        activityVisible ? Array(workouts.dropFirst()) : workouts
    }

    /// One workout row — factored out of `activitySection` so the "just the latest" default and the
    /// opt-in `showWorkoutsListExtra` multi-row list ([DashboardExtraSection.workoutsList]) share the
    /// exact same row instead of two near-duplicate layouts. `hr` is empty for anything but the newest
    /// row — fetching full heart-rate samples for every one of 5 workouts on every load isn't worth the
    /// cost for a sparkline nobody asked to see on older rows.
    private func workoutRow(_ w: WorkoutRow, hr: [Double]) -> some View {
        NavigationLink(value: TabRoute.workoutDetail(startTs: w.startTs, sport: w.sport)) {
        NoopCard(padding: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(StrandPalette.chargeColor.opacity(0.3), lineWidth: 2)
                    Image(systemName: sportSymbol(w.sport))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.chargeColor)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.sport).font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                    Text(activitySubtitle(w)).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    HStack(spacing: 3) {
                        Image(systemName: "clock").font(.system(size: 10))
                        Text(activityTimeText(w)).font(StrandFont.caption)
                    }
                    .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    if hr.count >= 5 {
                        Sparkline(values: hr, gradient: Gradient(colors: [StrandPalette.chargeColor]),
                                 lineWidth: 1.5, showsArea: false, showsHover: false)
                            .frame(width: 64, height: 20)
                    }
                    if let kcal = w.energyKcal {
                        Text("\(Int(kcal.rounded())) kcal").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Goals (opt-in, DashboardExtraSection.goals)

    // Plain `UUID` isn't `Identifiable` in this SDK — a Bool + a separately-held id sidesteps
    // `.sheet(item:)`'s Identifiable requirement instead of wrapping one UUID in a throwaway type.
    @State private var goalJourneyId: UUID?
    @State private var showGoalJourney = false

    private var rankedGoalSnapshots: [GoalTrackingSnapshot] {
        goalTracking.snapshots
            .filter { $0.goal.status == .active }
            .sorted { lhs, rhs in
                if lhs.health.rawValue != rhs.health.rawValue { return lhs.health.rawValue < rhs.health.rawValue }
                return lhs.sortDate < rhs.sortDate
            }
    }

    @ViewBuilder
    private var goalsSection: some View {
        let ranked = rankedGoalSnapshots
        if !ranked.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Goals").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                NoopCard(padding: NoopMetrics.cardPadding) {
                    GoalTrackingTile(snapshots: ranked, weekActions: goalTracking.weekActions,
                                     onOpenGoal: { goalJourneyId = $0; showGoalJourney = true })
                }
            }
            .sheet(isPresented: $showGoalJourney) {
                if let id = goalJourneyId { NavigationStack { JourneyView(goalId: id) } }
            }
        }
    }

    // MARK: - Energy detail (opt-in, DashboardExtraSection.energyDetail)

    @ViewBuilder
    private var energyDetailSection: some View {
        if let e = todayEnergySummary {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Energy").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                NoopCard(padding: NoopMetrics.cardPadding) {
                    HStack {
                        energyStat(label: "Basal", kcal: e.basalBurnedSoFar)
                        Divider().overlay(StrandPalette.hairline).frame(height: 32)
                        energyStat(label: "Active", kcal: e.activeBurnedSoFar)
                        Divider().overlay(StrandPalette.hairline).frame(height: 32)
                        energyStat(label: "Total", kcal: e.totalBurnedSoFar)
                    }
                }
            }
        }
    }

    private func energyStat(label: LocalizedStringKey, kcal: Double?) -> some View {
        VStack(spacing: 3) {
            Text(kcal.map { "\(Int($0.rounded()))" } ?? "—")
                .font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Journal (opt-in, DashboardExtraSection.journal)

    @ViewBuilder
    private var journalSection: some View {
        if let logged = journalLoggedDays {
            let keys = Self.journalDayKeys(anchor: selectedLogicalDay)
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                HStack {
                    Text("Journal").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text("\(logged.count)/\(keys.count)").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
                NoopCard(padding: NoopMetrics.cardPadding) {
                    Button { router.openJournal() } label: {
                        HStack(spacing: 6) {
                            ForEach(keys, id: \.self) { key in
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(logged.contains(key) ? StrandPalette.metricAmber : StrandPalette.textPrimary.opacity(0.1))
                                    .frame(height: 24)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Menstrual cycle (opt-in, DashboardExtraSection.menstrualCycle)

    @AppStorage(AppModel.cycleAwarenessKey) private var cycleEnabled = false
    @AppStorage(AppModel.cycleAwarenessHiddenKey) private var cycleHidden = false

    private var shouldShowCycle: Bool {
        !cycleHidden && (profile.cycleAwarenessApplies || cycleEnabled)
    }

    @ViewBuilder
    private var menstrualCycleSection: some View {
        if shouldShowCycle {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Menstrual cycle").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                NoopCard(padding: NoopMetrics.cardPadding) {
                    HStack {
                        Text(model.cyclePhase.map { cyclePhaseTitle($0.phase) }
                             ?? String(localized: "Learning your pattern"))
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        if let result = model.cyclePhase, let lo = result.cycleDayLow, let hi = result.cycleDayHigh {
                            (lo == hi ? Text("~day \(lo)") : Text("~day \(lo)-\(hi)"))
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
            }
        }
    }

    // Same wording `MenstrualCycleHomeCard.phaseTitle` uses — one vocabulary for the cycle phase name,
    // not a second guess at what to call each `CyclePhaseEngine.Phase`.
    private func cyclePhaseTitle(_ phase: CyclePhaseEngine.Phase) -> String {
        switch phase {
        case .follicular:    return String(localized: "Follicular")
        case .periOvulatory: return String(localized: "Mid-cycle shift")
        case .luteal:        return String(localized: "Luteal")
        case .unknown:       return String(localized: "No clear pattern")
        case .learning:      return String(localized: "Learning your pattern")
        }
    }

    private func activitySubtitle(_ w: WorkoutRow) -> String {
        let minutes = Int(((w.durationS ?? Double(w.endTs - w.startTs)) / 60).rounded())
        if let strain = w.strain {
            let format = String(localized: "%lld min · %.1f effort")
            return String(format: format, locale: AppLanguage.activeLocale, Int64(minutes), strain)
        }
        return String(format: String(localized: "%lld min"), locale: AppLanguage.activeLocale, Int64(minutes))
    }

    private func activityTimeText(_ w: WorkoutRow) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(w.startTs))
        let cal = Calendar.current
        let dayWord = cal.isDateInToday(date) ? String(localized: "Today")
            : cal.isDateInYesterday(date) ? String(localized: "Yesterday")
            : DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
        let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        return "\(dayWord), \(time)"
    }
}
