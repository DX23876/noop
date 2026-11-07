#if os(iOS)
import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Routes that only exist in the redesign. Registered on the redesign's tab stacks next to `TabRoute`.
enum ForgeRoute: Hashable {
    case charge
    /// Effort as the Today ring shows it, with the Charge its target comes from.
    case effort(stored: Double?, charge: Double?)
    case rest(Double?)
    case weeklyReport
    /// Training › Strength and its body map.
    case strength
    case muscles
    case workouts
    case weekPlan
    case search
    /// The redesigned AgeLess page. Routing this case to `AgeLessScreen()` restores the shipped page.
    case ageless
    /// One of the Health tab's focus areas.
    case focus(ForgeFocusArea)
    /// One workout's detail page, straight from a list (the shipped route goes through the old list first).
    case workout(startTs: Int, sport: String)
    /// The cycle page: dial, logging, phase cards, nightly temperature and calendar.
    case cycle
}

extension View {
    func forgeRouteDestinations(coach: AICoachEngine, onAsk: @escaping (String) -> Void) -> some View {
        navigationDestination(for: ForgeRoute.self) { route in
            switch route {
            case .charge: ForgeChargeDetailView(onAsk: onAsk)
            case .effort(let stored, let charge): ForgeEffortDetailView(effortStored: stored, charge: charge, onAsk: onAsk)
            case .rest(let rest): ForgeRestDetailView(rest: rest, onAsk: onAsk)
            case .weeklyReport: ForgeWeeklyReportView(onAsk: onAsk, coach: coach)
            case .strength: ForgeStrengthView()
            case .muscles: ForgeMusclesView()
            case .workouts: ForgeWorkoutsView()
            case .weekPlan: ForgeWeekPlanView(onAsk: onAsk)
            case .search: ForgeSearchView()
            case .ageless: ForgeAgeLessView()
            case .focus(let area): ForgeFocusView(area: area)
            case .workout(let startTs, let sport): ForgeWorkoutDetailHost(startTs: startTs, sport: sport)
            case .cycle: ForgeCycleView()
            }
        }
    }
}

/// The redesign's Charge page: the ring, "Why N %?" with every driver against the wearer's own usual,
/// the last 14 days, and how Charge is made. The drivers are `ChargeBreakdownFormat.compute`, the SAME
/// composition the shipped Today's breakdown sheet reads, against the SAME row the ring shows.
struct ForgeChargeDetailView: View {
    /// How sure the breakdown is, in words: the shipped chip abbreviates it ("REL.", "EST.").
    static func confidenceWord(_ c: ScoreConfidence) -> String {
        switch c {
        case .calibrating: return String(localized: "Calibrating")
        case .building: return String(localized: "Still building")
        case .solid: return String(localized: "Reliable")
        }
    }

    var onAsk: (String) -> Void = { _ in }

    @EnvironmentObject private var repo: Repository
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    @State private var rest: Double?
    @State private var scrolledPast = false
    @State private var rowWidth: CGFloat = 0

    private var todayKey: String { Repository.logicalDayKey(Date()) }
    private var displayDay: DailyMetric? {
        repo.today ?? repo.days.last(where: { $0.day == todayKey })
    }
    private var display: ChargeDisplay {
        ChargeDisplay.resolve(days: repo.days, displayDay: displayDay, selectedDayKey: todayKey, isToday: true)
    }
    /// The row the ring shows: today's own, else the carried last-scored night.
    private var row: DailyMetric? {
        let calibrating: Bool = { if case .calibrating = display { return true } else { return false } }()
        return TodayView.lastScoredRecoveryDay(days: repo.days, selectedDayKey: todayKey, isToday: true,
                                               todayScored: displayDay?.recovery != nil,
                                               isCalibrating: calibrating) ?? displayDay
    }

    /// The night's figure for a driver, read from a day row, by the driver's label.
    private static func driverFigure(_ label: String, _ d: DailyMetric) -> Double? {
        switch label {
        case "Heart rate variability": return d.avgHrv
        case "Resting heart rate": return d.restingHr.map(Double.init)
        case "Respiratory rate": return d.respRateBpm
        case "Skin temperature": return d.skinTempDevC
        default: return nil
        }
    }

    /// A driver's usual range, as the prototype drew it: the middle half (25 % to 75 %) of the 30 nights
    /// before the shown one, the night's figure placed on a track around it. Nil under 7 nights, where the
    /// row keeps its single usual value.
    private func usualRange(_ label: String) -> (text: String, position: Double, band: ClosedRange<Double>)? {
        guard let row, let value = Self.driverFigure(label, row) else { return nil }
        let before = repo.days.filter { $0.day < row.day }.suffix(30).compactMap { Self.driverFigure(label, $0) }
        guard let q = ForgeToday.middleHalf(before) else { return nil }
        let placed = ForgeToday.place(value, low: q.low, high: q.high)
        let decimals = label == "Resting heart rate" || label == "Heart rate variability" ? 0 : 1
        func f(_ x: Double) -> String {
            x.formatted(.number.precision(.fractionLength(decimals)).locale(AppLanguage.activeLocale))
        }
        let unit: String = switch label {
        case "Heart rate variability": " ms"
        case "Resting heart rate": " bpm"
        case "Respiratory rate": " /min"
        default: " °C"
        }
        let span = String(localized: "\(f(q.low)) to \(f(q.high))")
        return (String(localized: "usually \(span + unit)"), placed.position, placed.band)
    }

    var body: some View {
        let pct = display.pct
        let breakdown = ChargeBreakdownFormat.compute(row: row, baselines: repo.chargeBaselines, restScore: rest)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Which night the score is from, in the overline as Effort ("Today") and Rest ("Last night")
                // name theirs; a carried score names its date there instead of again under the ring.
                ForgeDetailHeader(overline: display.carriedCaption ?? String(localized: "Last night"),
                                  title: DomainTheme.charge.productName, scrolledPast: $scrolledPast)
                VStack(spacing: 10) {
                    OrganicScoreHeroClock(dataReady: true) { frame in
                        ScoreRing(
                            model: OrganicScoreVisualModel.resolve(metric: .charge, value: pct, scaleMaximum: 100),
                            tint: pct.map { _ in StrandPalette.chargeColor } ?? StrandPalette.organicMissing,
                            score: pct, decimals: 0, frame: frame, diameter: 170, hitDiameter: 170, namesBand: false)
                            .frame(width: 170, height: 170)
                    }
                    ForgeScoreCaption(name: DomainTheme.charge.productName, tint: ForgeColor.chargeInk,
                                      detail: pct.map { ChargeBand.of(score: $0).word.lowercased(with: AppLanguage.activeLocale) })
                    // Only today's own Charge sets today's target; a carried one names its night in the overline.
                    if display.carriedCaption == nil, let target = ForgeToday.effortTargetStored(charge: pct) {
                        let t = ForgeToday.targetText(target, scale: UnitPrefs.currentEffortScale())
                        Text("Today's Effort target: \(t.low) to \(t.high).")
                            .font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.effortInk)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)

                if let breakdown {
                    HStack(alignment: .firstTextBaseline) {
                        Text(pct.map { value -> LocalizedStringKey in
                            let figure = "\(Int(value.rounded())) %"
                            return "Why \(figure)?"
                        } ?? "What shaped it")
                            .font(ForgeFont.section).foregroundStyle(ForgeColor.text)
                        Spacer()
                        ForgeBadge(text: Self.confidenceWord(breakdown.confidence), tone: .neutral)
                    }
                    .padding(.horizontal, 4)
                    VStack(spacing: 0) {
                        ForEach(Array(breakdown.drivers.enumerated()), id: \.offset) { index, driver in
                            if index > 0 { Rectangle().fill(ForgeColor.separator).frame(height: 0.5) }
                            let range = usualRange(driver.label)
                            ForgeWhyRow(label: driver.label, value: ForgeToday.driverValue(driver.valueText), delta: driver.deltaPoints,
                                        usual: range?.text ?? (driver.baselineText.isEmpty ? nil : ForgeToday.driverUsual(driver.baselineText)),
                                        track: range.map { ($0.position, nil) }, band: range?.band)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text(ChargeBreakdownFormat.driverAccessibilityLabel(driver)))
                        }
                    }
                    .forgeCard(radius: ForgeRadius.card, padding: 14)
                } else if case .calibrating(let nights) = display {
                    ForgeTabHero(overline: String(localized: "Calibrating"),
                                 headline: ChargeBreakdownFormat.calibrationCountdown(nightsRemaining: nights))
                }

                if coachFeatureEnabled {
                    HStack(spacing: 8) {
                        ForgeChip(title: String(localized: "What can I improve?")) {
                            onAsk(String(localized: "Look at what shaped my Charge today and tell me the one thing I could improve."))
                        }
                    }
                }

                ForgeDailyChart(title: String(localized: "Last 14 days"),
                                points: repo.days.suffix(14).compactMap { d in d.recovery.map { (d.day, $0) } },
                                maxValue: 100, tint: ForgeColor.charge, bars: false,
                                history: TabRoute.metric(HeroRingMetric.charge))

                ForgeExplainer(title: "How Charge is made",
                               text: "Charge compares last night's heart rate variability, resting heart rate, breathing, skin temperature and sleep with your own usual values. Everything is calculated on this iPhone.") { ExplainerScoreInputs.charge }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .today))
        .forgeDetailBar(title: DomainTheme.charge.productName, showsTitle: scrolledPast)
        .task {
            rest = DashboardRestScore.value(day: todayKey, days: repo.days, importedSleep: repo.importedSleep)
        }
    }
}
#endif
