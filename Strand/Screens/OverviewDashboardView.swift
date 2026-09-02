import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// A reference-matched alternative to Today: "Heute im Überblick" (Erholung/Belastung/Schlaf rings with
/// a state word and a sentence), an overall-status chip, a "Heute wichtig" row of three small cards, and
/// a "Deine Gesundheit" list. Sits alongside Classic/Liquid/Trends (`TodayDashboardStyle`); reads the
/// same `Repository` data, only the layout differs.
///
/// Deliberately screenshot-faithful over "improved" — see `TrendsDashboardView`'s header comment for the
/// same note; it applies here too.
struct OverviewDashboardView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var updateStore: UpdateStore
    @EnvironmentObject private var coach: AICoachEngine
    @EnvironmentObject private var router: NavRouter
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @ObservedObject private var goalTracking = GoalTrackingStore.shared
    @AppStorage("momentum.stepGoal") private var stepGoal = 0

    @AppStorage(DashboardLayoutPrefs.orderKey("overview")) private var layoutOrderRaw = ""
    @AppStorage(DashboardLayoutPrefs.hiddenKey("overview")) private var layoutHiddenRaw = ""
    @AppStorage(AppModel.cycleAwarenessKey) private var cycleEnabled = false
    @AppStorage(AppModel.cycleAwarenessHiddenKey) private var cycleHidden = false
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    // Same source TodayView/LiquidTodayView's own Effort rings read (Units.swift) — the Belastung ring
    // shows whichever scale the user picked in Settings (0…100 or WHOOP's 0…21), never an invented one.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @AppStorage(OverviewHealthCardsPrefs.selectionKey) private var healthCardsRaw = ""
    @AppStorage(OverviewFocusPrefs.slotKeys[0]) private var focusSlot1Raw = OverviewFocusPrefs.defaults[0].rawValue
    @AppStorage(OverviewFocusPrefs.slotKeys[1]) private var focusSlot2Raw = OverviewFocusPrefs.defaults[1].rawValue
    @AppStorage(OverviewFocusPrefs.slotKeys[2]) private var focusSlot3Raw = OverviewFocusPrefs.defaults[2].rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    @State private var displayDay: DailyMetric?
    @State private var recentDays: [DailyMetric] = []
    @State private var appleDays: [AppleDaily] = []
    @State private var restScore: Double?
    @State private var fitnessAgeToday: Double?
    @State private var vo2maxToday: Double?
    @State private var vitalityToday: Double?
    @State private var stressToday: Double?
    @State private var hydrationTotalML: Double?
    @State private var todayEnergySummary: DailyEnergySummary?
    @State private var resolvedWeightKg: Double?
    @State private var showCoach = false
    @State private var showUpdatesInbox = false
    @State private var showAllMetrics = false
    @State private var showExtraSections = false
    @State private var recentWorkouts: [WorkoutRow] = []
    @State private var journalLoggedDays: Set<String>?
    @State private var goalJourneyId: UUID?
    @State private var showGoalJourney = false
    @State private var selectedDayOffset = 0
    @State private var showDayPicker = false
    @State private var showStepGoalSetting = false

    private var healthCards: [DashboardCard] { OverviewHealthCardsPrefs.decode(healthCardsRaw) }
    private var focusItems: [OverviewFocusItem] {
        [focusSlot1Raw, focusSlot2Raw, focusSlot3Raw].enumerated().map { index, raw in
            OverviewFocusItem(rawValue: raw) ?? OverviewFocusPrefs.defaults[index]
        }
    }

    /// The reference packs everything — three rings, three focus cards, a six-row list — onto one
    /// screen with no scrolling. `NoopMetrics.sectionSpacing`/`.cardPadding` (26pt / 16pt) are tuned for
    /// Classic/Liquid's roomier cards; this screen uses its own tighter scale to match.
    private static let sectionSpacing: CGFloat = 11
    private static let cardPadding: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            // The reference sits its header much closer to the status bar than the default safe-area
            // inset + `NoopMetrics.screenPadding` (16pt) allows. Ignoring the top safe area and adding
            // back a SMALLER fixed inset (rather than the device's full notch/Dynamic-Island height)
            // gets the ~25–30pt reduction the reference wants without drawing under the status bar.
            let topInset = max(NoopMetrics.screenPadding, proxy.safeAreaInsets.top + 16)
            ScrollView {
                VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                    header
                    ForEach(layoutSections) { section in dashboardSection(section) }
                }
                .padding(.horizontal, NoopMetrics.screenPadding)
                .padding(.top, topInset)
                // Keep the final optional section scrollable above the native floating tab bar.
                // Without this tail, the bar covers the last card and leaves what looks like a gap.
                .padding(.bottom, 104)
            }
            .ignoresSafeArea(edges: .top)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .simultaneousGesture(daySwipeGesture)
        .task(id: "\(repo.refreshSeq)-\(selectedDayOffset)") { await load() }
        .coachCover(isPresented: $showCoach, coach: coach)
        .sheet(isPresented: $showUpdatesInbox) { UpdatesInboxView(onClose: { showUpdatesInbox = false }) }
        .sheet(isPresented: $showExtraSections) {
            DashboardExtraSectionsSheet(dashboard: "overview", title: String(localized: "Dashboard sections"))
        }
        .sheet(isPresented: $showDayPicker) { dashboardDayPicker }
        .sheet(isPresented: $showStepGoalSetting) { DashboardStepGoalSheet() }
    }

    private var layoutSections: [DashboardLayoutSection] {
        let order = DashboardLayoutPrefs.order(layoutOrderRaw, dashboard: "overview")
        let hidden = DashboardLayoutPrefs.hidden(layoutHiddenRaw, dashboard: "overview")
        return order.filter { !hidden.contains($0) }
    }

    @ViewBuilder private func dashboardSection(_ section: DashboardLayoutSection) -> some View {
        switch section {
        case .overview: overviewCard
        case .focus: importantRow
        case .health: healthList
        case .goals: if selectedDayOffset == 0 { goalsSection }
        case .workoutsList: workoutsListSection
        case .energyDetail: energyDetailSection
        case .journal: if selectedDayOffset == 0 { journalSection }
        case .menstrualCycle: if selectedDayOffset == 0 { menstrualCycleSection }
        case .coach, .hero, .trendsChart, .metricStrip, .activity: EmptyView()
        default:
            DashboardSupplementSections(dashboard: "overview", compact: true, day: displayDay,
                                        appleDay: appleDays.last(where: { $0.day == selectedDayKey }),
                                        dayKey: selectedDayKey, isToday: selectedDayOffset == 0, only: section)
        }
    }

    // MARK: - Loading

    private func load() async {
        let allDays = repo.days
        let todayKey = Repository.logicalDayKey(Date())
        displayDay = selectedDayOffset == 0
            ? (repo.today ?? allDays.last(where: { $0.day == selectedDayKey }))
            : allDays.last(where: { $0.day == selectedDayKey })
        recentDays = Array(allDays.filter { $0.day <= selectedDayKey }.suffix(90))
        appleDays = await repo.appleDailyRows(days: max(30, selectedDayOffset + 7))
        let restSeries = await repo.exploreSeries(key: "sleep_performance", source: Repository.whoopSource)
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        restScore = TodayView.freshRestScore(
            todayValue: displayDay.flatMap { restByDay[$0.day] },
            lastDay: restSeries.last?.day, lastValue: restSeries.last?.value,
            isTodaySelected: selectedDayOffset == 0, todayKey: todayKey)

        // Cheap, direct Repository reads (same source TodayView's own dashboard cards use) — not the
        // full Fitness-Age/Energy engines, which need per-view calibration state this screen doesn't
        // carry. Real numbers, not fabricated: a gap still reads "—" in the list below.
        async let fitnessAgeSeriesA = repo.exploreSeries(key: "fitness_age", source: "my-whoop", days: 120)
        async let vo2maxSeriesA = repo.exploreSeries(key: "vo2max_est", source: "my-whoop", days: 120)
        async let vitalitySeriesA = repo.exploreSeries(key: "vitality", source: "my-whoop", days: 120)
        async let stressStoredA = repo.series(key: "stress", source: "my-whoop", days: 120)
        async let hydrationA = repo.hydrationTotal(day: selectedDayKey)
        async let energySummariesA = repo.energySummaries(days: 30, profile: Repository.analyticsProfile(profile))
        async let weightSummaryA = repo.weightTrendSummary(days: 91)
        fitnessAgeToday = (await fitnessAgeSeriesA).last(where: { $0.day == selectedDayKey })?.value
        vo2maxToday = (await vo2maxSeriesA).last(where: { $0.day == selectedDayKey })?.value
        vitalityToday = (await vitalitySeriesA).last(where: { $0.day == selectedDayKey })?.value
        let scopedDays = allDays.filter { $0.day <= selectedDayKey }
        stressToday = StressModel(days: scopedDays, stored: await stressStoredA)?.score
        hydrationTotalML = await hydrationA
        todayEnergySummary = (await energySummariesA).last(where: { $0.day == selectedDayKey })
        resolvedWeightKg = WeightSeries.displayWeight(summary: await weightSummaryA,
                                                       profileWeightKg: profile.weightKg).kg

        // Cheap, only meaningfully used when their extra section is toggled on — loaded unconditionally
        // so flipping a toggle doesn't need its own reload path.
        let allWorkouts = (await repo.workoutRows(days: max(14, selectedDayOffset + 2), reconcileHrCap: 0))
            .sorted { $0.startTs > $1.startTs }
        recentWorkouts = (selectedDayOffset == 0 ? allWorkouts : allWorkouts.filter {
            Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs))) == selectedDayKey
        }).prefix(3).map { $0 }
        let journalKeys = Self.journalDayKeys(anchor: selectedLogicalDay)
        journalLoggedDays = await repo.nativeJournalDays(from: journalKeys.first ?? "", to: journalKeys.last ?? "")
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

    private var dayPickerBinding: Binding<Date> {
        Binding(get: { selectedLogicalDay }, set: { picked in
            selectedDayOffset = min(earliestDayOffset,
                TodayView.pickedDayOffset(pickedDate: picked, anchorLogicalDay: Repository.logicalDay(Date())))
        })
    }

    private var dashboardDayPicker: some View {
        NavigationStack {
            DatePicker("Choose day", selection: dayPickerBinding,
                       in: ...Repository.logicalDay(Date()), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Dashboard day")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDayPicker = false } } }
        }
        .presentationDetents([.medium])
    }

    /// The real value behind a "Deine Gesundheit" row. Covers everything `TrendsMetricStrip.valueText`
    /// deliberately punts on (fitness age, calories, weight) with the SAME cheap Repository reads
    /// `TodayView`'s own dashboard cards use — see the type doc on why this list, unlike the Trends
    /// strip, needs those three resolved rather than shown as "—".
    private func healthValueText(_ card: DashboardCard) -> String {
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
        default:
            return TrendsMetricStrip.valueText(card, day: displayDay, appleDay: appleDays.last(where: { $0.day == displayDay?.day }))
        }
    }

    private var todaySteps: Int? {
        displayDay?.steps ?? appleDays.last(where: { $0.day == displayDay?.day })?.steps
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
        HStack {
            Text("N O O P")
                .font(StrandFont.rounded(16, weight: .bold))
                .tracking(5)
                .foregroundStyle(StrandPalette.textPrimary)
                // Keep customization off the visible control row; this mirrors Trends and preserves
                // the reference header's + as a real quick-action entry point.
                .contentShape(Rectangle())
                .onLongPressGesture { showExtraSections = true }
            Spacer()
            HStack(spacing: 6) {
                DashboardBatteryButton(size: 28)
                headerIconButton(systemName: "plus", tint: StrandPalette.textPrimary) {
                    router.requestQuickActions()
                }
                headerIconButton(systemName: updateStore.unreadCount > 0 ? "bell.badge" : "bell",
                                 tint: StrandPalette.textPrimary, badge: updateStore.unreadCount) {
                    showUpdatesInbox = true
                }
                headerIconButton(systemName: "person.fill", tint: StrandPalette.textPrimary) { showCoach = true }
            }
        }
        Button { showDayPicker = true } label: {
            HStack(spacing: 4) {
                Text(selectedDayOffset == 0 ? String(localized: "Today")
                     : Self.headerDateFormatter.string(from: selectedLogicalDay))
                Text("·")
                Text("Swipe to change day")
                Image(systemName: "calendar").font(.system(size: 9, weight: .semibold))
            }
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .buttonStyle(.plain)
        }
    }

    private static let headerDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.activeLocale
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMM")
        return formatter
    }()

    private var batteryIcon: String {
        guard let value = live.batteryPct else { return "battery.0" }
        switch Int(value.rounded()) {
        case 76...: return (live.charging ?? false) ? "battery.100percent.bolt" : "battery.100percent"
        case 51...: return "battery.75percent"
        case 26...: return "battery.50percent"
        case 11...: return "battery.25percent"
        default: return "battery.0"
        }
    }

    private func headerIconButton(systemName: String, tint: Color, badge: Int = 0,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                // Dark/transparent glass circle with a thin outline — same pattern LiveWorkoutView's
                // own icon buttons use, rather than a solid fill.
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(StrandPalette.hairline, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(min(badge, 99))")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(2.5)
                            .background(Circle().fill(StrandPalette.statusCritical))
                            .offset(x: 3, y: -3)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Heute im Überblick

    private var overviewTone: StrandTone {
        let d = displayDay
        let charge = d?.recovery.map(ChargeBand.of(score:))
        let restOK = (restScore ?? 0) >= 70
        let effortOK = (d?.strain ?? 0) < 90   // 0-100 axis: only flag a genuinely maxed-out day
        if charge == .depleted || !effortOK { return .critical }
        if charge == .low || !restOK { return .warning }
        return .positive
    }

    @ViewBuilder
    private var overviewCard: some View {
        let d = displayDay
        NoopCard(padding: Self.cardPadding) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Today at a glance").strandOverline()
                HStack(alignment: .top, spacing: 0) {
                    NavigationLink(value: TabRoute.metricSourced(key: "recovery", source: Repository.whoopSource)) { overviewRing(label: "Recovery", value: d?.recovery,
                                color: d?.recovery.map { StrandPalette.chargeRingColor($0) } ?? StrandPalette.textTertiary,
                                mainFormat: { "\(Int($0.rounded()))" }, suffix: "%", denominatorCaption: nil,
                                // Same word tier `MomentumCard`'s recovery-state uses (#1405: a
                                // different axis from ReadinessEngine's training verdict — never
                                // "Primed" here, that word means something else on this screen).
                                word: d?.recovery != nil ? MomentumCopy.stateWord(d?.recovery) : nil,
                                detail: recoveryDetail(d)) }.buttonStyle(.plain)
                    Divider().overlay(StrandPalette.hairline).padding(.top, 22).padding(.bottom, 4)
                    NavigationLink(value: TabRoute.metricSourced(key: "strain", source: Repository.whoopSource)) { overviewRing(label: "Strain", value: d?.strain,
                                color: StrandPalette.effortColor,
                                // Real scale from Settings (0…100 or WHOOP 0…21) — the same source
                                // TodayView/LiquidTodayView's own Effort rings read (Units.swift). The
                                // denominator is the ring's true "out of X", never an invented one.
                                mainFormat: { UnitFormatter.effortDisplay($0, scale: effortScale) }, suffix: "",
                                denominatorCaption: "/\(UnitFormatter.effortScaleMax(effortScale))",
                                word: d?.strain.map { effortWord($0) },
                                detail: strainDetail(d)) }.buttonStyle(.plain)
                    Divider().overlay(StrandPalette.hairline).padding(.top, 22).padding(.bottom, 4)
                    NavigationLink(value: TabRoute.metricSourced(key: "sleep_performance", source: Repository.whoopSource)) { overviewRing(label: "Sleep", value: restScore,
                                color: StrandPalette.restColor,
                                mainFormat: { "\(Int($0.rounded()))" }, suffix: "%", denominatorCaption: nil,
                                word: restScore.map { restWord($0) },
                                detail: sleepDetail(d)) }.buttonStyle(.plain)
                }
                Divider().overlay(StrandPalette.hairline)
                NavigationLink(value: TabRoute.health) {
                    HStack(spacing: 6) {
                        Image(systemName: overviewTone == .positive ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(overviewTone.color)
                        Text(overviewSummaryText)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .font(StrandFont.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The overall chip's word. Honest about the alternative too — this is not always "alles im grünen
    /// Bereich"; a bad day says so.
    private var overviewSummaryText: String {
        switch overviewTone {
        case .positive: return String(localized: "Everything in the green")
        case .warning:  return String(localized: "One or two things need attention")
        default:        return String(localized: "Several signals need attention")
        }
    }

    /// A ring with a two-tier centre read-out (big value + smaller suffix, e.g. "85" + "%") and an
    /// optional tiny denominator caption tucked underneath (e.g. "/100"). `GlowRing`'s own `format`
    /// closure renders ONE string at ONE size, so it can't do the big/small split the reference wants —
    /// this draws `GlowRing` with an EMPTY format purely for its track/arc/spring animation, then
    /// overlays the composed centre text itself. `Text` concatenation (`+`) keeps each fragment's own
    /// font, which is what makes the size split possible without touching the shared `GlowRing.swift`
    /// (used by many other screens' hero rings).
    @ViewBuilder
    private func overviewRing(label: LocalizedStringKey, value: Double?, color: Color,
                              mainFormat: @escaping (Double) -> String, suffix: String,
                              denominatorCaption: String?, word: String?, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(label).font(StrandFont.footnote.weight(.semibold)).foregroundStyle(color)
            if let value {
                ZStack {
                    GlowRing(fraction: value / 100, value: value, format: { _ in "" },
                             color: color, diameter: Self.ringDiameter, lineWidth: 6)
                    VStack(spacing: 0) {
                        (Text(mainFormat(value)).font(StrandFont.rounded(Self.ringDiameter * 0.34, weight: .bold))
                            + Text(suffix).font(StrandFont.rounded(Self.ringDiameter * 0.15, weight: .semibold)))
                            .monospacedDigit()
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        if let denominatorCaption {
                            Text(denominatorCaption)
                                .font(StrandFont.rounded(max(8, Self.ringDiameter * 0.11), weight: .semibold))
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            } else {
                ZStack {
                    Circle().stroke(StrandPalette.textPrimary.opacity(0.10), style: StrokeStyle(lineWidth: 6))
                    Text("—").font(GlowRing.centerFont(diameter: Self.ringDiameter)).foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(width: Self.ringDiameter, height: Self.ringDiameter)
            }
            if let word {
                Text(word)
                    .font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Capsule().fill(color.opacity(0.16)))
            }
            Text(detail)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private static let ringDiameter: CGFloat = 74

    private func recoveryDetail(_ d: DailyMetric?) -> String {
        guard let s = d?.recovery else { return String(localized: "No score yet") }
        switch ChargeBand.of(score: s) {
        case .peak, .primed: return String(localized: "Recovered and ready to perform.")
        case .moderate:      return String(localized: "Moderate training suits today.")
        default:             return String(localized: "Favour an easy day.")
        }
    }

    private func effortWord(_ strain: Double) -> String {
        switch strain {
        case ..<30: return String(localized: "Light")
        case ..<60: return String(localized: "Moderate")
        default:    return String(localized: "High")
        }
    }

    private func strainDetail(_ d: DailyMetric?) -> String {
        guard let s = d?.strain else { return String(localized: "No load recorded yet") }
        return s < 60 ? String(localized: "Optimal training possible today.")
                      : String(localized: "Already a demanding day.")
    }

    private func restWord(_ score: Double) -> String {
        score >= 80 ? String(localized: "Good") : score >= 60 ? String(localized: "Fair") : String(localized: "Low")
    }

    private func sleepDetail(_ d: DailyMetric?) -> String {
        guard let m = d?.totalSleepMin else { return String(localized: "No sleep recorded") }
        let h = Int(m) / 60, mm = Int(m) % 60
        let quality = restScore.map { $0 >= 70 ? String(localized: "good") : String(localized: "limited") }
            ?? String(localized: "unscored")
        let regeneration = (restScore ?? 0) >= 70 ? String(localized: "Regeneration on track.")
                                                   : String(localized: "Regeneration still catching up.")
        let format = String(localized: "%lldh %lldm · quality %@\n%@")
        return String(format: format, locale: AppLanguage.activeLocale,
                      Int64(h), Int64(mm), quality, regeneration)
    }

    // MARK: - Heute wichtig

    private var importantRow: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text("Today's focus").strandOverline()
            HStack(alignment: .top, spacing: 10) {
                ForEach(focusItems) { focusMiniCard($0) }
            }
        }
    }

    @ViewBuilder private func focusMiniCard(_ item: OverviewFocusItem) -> some View {
        switch item {
        case .coach: coachMiniCard
        case .steps: activityMiniCard
        case .sleep: sleepInsightMiniCard
        default:
            let card = DashboardCard(rawValue: item.rawValue) ?? .hrv
            NavigationLink(value: card.detailRoute(day: displayDay,
                                                   appleDay: appleDays.last(where: { $0.day == selectedDayKey }))) {
                miniCard(icon: item.icon, tint: item.tint, title: LocalizedStringKey(item.title)) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(healthValueText(card)).font(StrandFont.number(16)).foregroundStyle(StrandPalette.textPrimary)
                        Text(card.unit).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        Spacer(minLength: 0)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var activityMiniCard: some View {
        let steps = todaySteps
        if stepGoal > 0 {
            NavigationLink(value: DashboardCard.steps.detailRoute(day: displayDay,
                                                                  appleDay: appleDays.last(where: { $0.day == selectedDayKey }))) {
                activityMiniCardContent(steps: steps, goal: stepGoal)
            }
            .buttonStyle(.plain)
        } else {
            Button { showStepGoalSetting = true } label: {
                activityMiniCardContent(steps: steps, goal: nil)
            }
            .buttonStyle(.plain)
        }
    }

    private func activityMiniCardContent(steps: Int?, goal: Int?) -> some View {
        let fraction = goal.flatMap { target in steps.map { min(1, Double($0) / Double(max(target, 1))) } } ?? 0
        return miniCard(icon: "figure.walk", tint: StrandPalette.chargeColor, title: "Activity") {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(steps.map { "\($0)" } ?? "—").font(StrandFont.number(16)).foregroundStyle(StrandPalette.textPrimary)
                }
                Text("Steps").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                if let goal {
                    solidProgressBar(fraction: fraction, tint: StrandPalette.chargeColor)
                    Text(String(format: String(localized: "Goal: %lld steps"),
                                locale: AppLanguage.activeLocale, Int64(goal)))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                } else {
                    Text("Set step goal")
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.chargeColor)
                    Text("Settings · Features")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    /// A single filled, rounded progress track — the reference's Activity-card bar. Deliberately a plain
    /// local view rather than a new StrandDesign component: this is the only place that needs it, and
    /// `PipBar`'s segmented-dot look (used everywhere else) is a different, intentional visual language.
    private func solidProgressBar(fraction: Double, tint: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.18))
                Capsule().fill(tint).frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 5)
    }

    private var sleepInsightMiniCard: some View {
        NavigationLink(value: TabRoute.sleep) { miniCard(icon: "moon.stars.fill", tint: StrandPalette.restColor, title: "Sleep insight") {
            VStack(alignment: .leading, spacing: 5) {
                Text(restScore.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(StrandFont.number(16)).foregroundStyle(StrandPalette.textPrimary)
                Text("Sleep quality").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                Text(restScore.map { $0 >= 70 ? String(localized: "Well rested") : String(localized: "Under-slept") } ?? "—")
                    .font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.restColor)
                Text("On track for today.").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        } }.buttonStyle(.plain)
    }

    private var coachMiniCard: some View {
        Button { showCoach = true } label: {
            miniCard(icon: "person.fill", tint: StrandPalette.accent, title: "Coach") {
                VStack(alignment: .leading, spacing: 5) {
                    Text(MomentumCopy.stateWord(displayDay?.recovery))
                        .font(StrandFont.footnote.weight(.bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(MomentumCopy.stateDetail(displayDay))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func miniCard<Content: View>(icon: String, tint: Color, title: LocalizedStringKey,
                                         @ViewBuilder content: @escaping () -> Content) -> some View {
        NoopCard(padding: 8, tint: tint) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    ZStack {
                        Circle().fill(tint.opacity(0.16))
                        Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                    }
                    .frame(width: 20, height: 20)
                    Text(title).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
                content()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Deine Gesundheit

    private var healthList: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text("Your health").strandOverline()
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(healthCards.enumerated()), id: \.element) { index, card in
                        if index > 0 { Divider().overlay(StrandPalette.hairline).padding(.leading, 40) }
                        OverviewHealthRow(card: card, valueText: healthValueText(card),
                                          day: displayDay, recentDays: recentDays)
                    }
                    Divider().overlay(StrandPalette.hairline)
                    NavigationLink(value: TabRoute.metricExplorer) {
                        HStack {
                            Spacer()
                            Text("Show all metrics")
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                            Spacer()
                        }
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    // MARK: - Goals (opt-in, DashboardExtraSection.goals)

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
                Text("Goals").strandOverline()
                NoopCard(padding: Self.cardPadding) {
                    GoalTrackingTile(snapshots: ranked, weekActions: goalTracking.weekActions,
                                     onOpenGoal: { goalJourneyId = $0; showGoalJourney = true })
                }
            }
            .sheet(isPresented: $showGoalJourney) {
                if let id = goalJourneyId { NavigationStack { JourneyView(goalId: id) } }
            }
        }
    }

    // MARK: - Workouts (opt-in, DashboardExtraSection.workoutsList)

    @ViewBuilder
    private var workoutsListSection: some View {
        if !recentWorkouts.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                HStack {
                    Text("Recent activity").strandOverline()
                    Spacer()
                    NavigationLink(value: TabRoute.workouts) {
                        Text("View all").font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                    }
                }
                VStack(spacing: 6) {
                    ForEach(Array(recentWorkouts.enumerated()), id: \.offset) { _, w in
                        NavigationLink(value: TabRoute.workoutDetail(startTs: w.startTs, sport: w.sport)) {
                        NoopCard(padding: 10) {
                            HStack(spacing: 8) {
                                ZStack {
                                    Circle().fill(StrandPalette.chargeColor.opacity(0.16))
                                    Image(systemName: sportSymbol(w.sport))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(StrandPalette.chargeColor)
                                }
                                .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(w.sport).font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                                    Text(workoutSubtitle(w)).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                                }
                                Spacer(minLength: 8)
                                if let kcal = w.energyKcal {
                                    Text("\(Int(kcal.rounded())) kcal").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                }
                            }
                        }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func workoutSubtitle(_ w: WorkoutRow) -> String {
        let minutes = Int(((w.durationS ?? Double(w.endTs - w.startTs)) / 60).rounded())
        let date = Date(timeIntervalSince1970: TimeInterval(w.startTs))
        let dayPrefix: String? = selectedDayOffset == 0 && !Calendar.current.isDateInToday(date)
            ? (Calendar.current.isDateInYesterday(date)
                ? String(localized: "Yesterday")
                : DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none))
            : nil
        if let strain = w.strain {
            let format = String(localized: "%lld min · %.1f effort")
            let base = String(format: format, locale: AppLanguage.activeLocale, Int64(minutes), strain)
            return dayPrefix.map { "\($0) · \(base)" } ?? base
        }
        let base = String(format: String(localized: "%lld min"), locale: AppLanguage.activeLocale, Int64(minutes))
        return dayPrefix.map { "\($0) · \(base)" } ?? base
    }

    // MARK: - Energy detail (opt-in, DashboardExtraSection.energyDetail)

    @ViewBuilder
    private var energyDetailSection: some View {
        if let e = todayEnergySummary {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Energy").strandOverline()
                NoopCard(padding: Self.cardPadding) {
                    HStack {
                        energyStat(label: "Basal", kcal: e.basalBurnedSoFar)
                        Divider().overlay(StrandPalette.hairline).frame(height: 28)
                        energyStat(label: "Active", kcal: e.activeBurnedSoFar)
                        Divider().overlay(StrandPalette.hairline).frame(height: 28)
                        energyStat(label: "Total", kcal: e.totalBurnedSoFar)
                    }
                }
            }
        }
    }

    private func energyStat(label: LocalizedStringKey, kcal: Double?) -> some View {
        VStack(spacing: 2) {
            Text(kcal.map { "\(Int($0.rounded()))" } ?? "—")
                .font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
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
                    Text("Journal").strandOverline()
                    Spacer()
                    Text("\(logged.count)/\(keys.count)").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
                NoopCard(padding: Self.cardPadding) {
                    Button { router.openJournal() } label: {
                        HStack(spacing: 5) {
                            ForEach(keys, id: \.self) { key in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(logged.contains(key) ? StrandPalette.metricAmber : StrandPalette.textPrimary.opacity(0.1))
                                    .frame(height: 18)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Menstrual cycle (opt-in, DashboardExtraSection.menstrualCycle)

    private var shouldShowCycle: Bool {
        !cycleHidden && (profile.cycleAwarenessApplies || cycleEnabled)
    }

    @ViewBuilder
    private var menstrualCycleSection: some View {
        if shouldShowCycle {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Menstrual cycle").strandOverline()
                NoopCard(padding: Self.cardPadding) {
                    HStack {
                        Text(model.cyclePhase.map { cyclePhaseTitle($0.phase) }
                             ?? String(localized: "Learning your pattern"))
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
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

    // Same wording `MenstrualCycleHomeCard.phaseTitle` uses.
    private func cyclePhaseTitle(_ phase: CyclePhaseEngine.Phase) -> String {
        switch phase {
        case .follicular:    return String(localized: "Follicular")
        case .periOvulatory: return String(localized: "Mid-cycle shift")
        case .luteal:        return String(localized: "Luteal")
        case .unknown:       return String(localized: "No clear pattern")
        case .learning:      return String(localized: "Learning your pattern")
        }
    }
}

/// One "Deine Gesundheit" row: icon tile, name, value, an optional status dot+word (only when the
/// underlying metric has a real baseline to judge — see `OverviewHealthStatus`), and a chevron.
private struct OverviewHealthRow: View {
    let card: DashboardCard
    let valueText: String
    let day: DailyMetric?
    let recentDays: [DailyMetric]

    var body: some View {
        NavigationLink(value: card.detailRoute(day: day, appleDay: nil)) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(TrendsMetricStrip.tint(card).opacity(0.16))
                    Image(systemName: card.icon).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TrendsMetricStrip.tint(card))
                }
                .frame(width: 22, height: 22)
                Text(card.title).font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(valueText)
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    if !card.unit.isEmpty {
                        Text(card.unit).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                if let status = OverviewHealthStatus.status(for: card, day: day, recentDays: recentDays) {
                    HStack(spacing: 4) {
                        Circle().fill(status.tone.color).frame(width: 5, height: 5)
                        Text(status.word).font(StrandFont.footnote).foregroundStyle(status.tone.color)
                    }
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

/// The same persisted goal exposed in Settings → Features, reachable directly from the Overview
/// activity tile when the user has deliberately left the goal unset.
private struct DashboardStepGoalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("momentum.stepGoal") private var stepGoal = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $stepGoal, in: 0...30_000, step: 500) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Daily step goal")
                            Text(stepGoal > 0
                                 ? String(format: String(localized: "%lld steps"),
                                          locale: AppLanguage.activeLocale, Int64(stepGoal))
                                 : String(localized: "Not set"))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                } footer: {
                    Text("When no goal is set, NOOP shows your steps without inventing a target.")
                }
            }
            .navigationTitle("Daily step goal")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }
}
