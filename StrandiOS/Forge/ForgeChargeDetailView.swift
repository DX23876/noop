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
}

extension View {
    func forgeRouteDestinations(coach: AICoachEngine, onAsk: @escaping (String) -> Void) -> some View {
        navigationDestination(for: ForgeRoute.self) { route in
            switch route {
            case .charge: ForgeChargeDetailView(onAsk: onAsk)
            case .effort(let stored, let charge): ForgeEffortDetailView(effortStored: stored, charge: charge, onAsk: onAsk)
            case .rest(let rest): ForgeRestDetailView(rest: rest, onAsk: onAsk)
            case .weeklyReport: ForgeWeeklyReportView(onAsk: onAsk, coach: coach)
            }
        }
    }
}

/// The redesign's Charge page: the ring, "Why N %?" with every driver against the wearer's own usual,
/// the last 14 days, and how Charge is made. The drivers are `ChargeBreakdownFormat.compute`, the SAME
/// composition the shipped Today's breakdown sheet reads, against the SAME row the ring shows.
struct ForgeChargeDetailView: View {
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

    var body: some View {
        let pct = display.pct
        let breakdown = ChargeBreakdownFormat.compute(row: row, baselines: repo.chargeBaselines, restScore: rest)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForgeDetailHeader(overline: nil, title: DomainTheme.charge.productName, scrolledPast: $scrolledPast)
                VStack(spacing: 10) {
                    OrganicScoreHeroClock(dataReady: true) { frame in
                        OrganicScoreRing(
                            model: OrganicScoreVisualModel.resolve(metric: .charge, value: pct, scaleMaximum: 100),
                            tint: pct.map { StrandPalette.chargeRingColor($0) } ?? StrandPalette.organicMissing,
                            score: pct, decimals: 0, frame: frame, diameter: 170, hitDiameter: 170)
                            .frame(width: 170, height: 170)
                    }
                    ForgeScoreCaption(name: DomainTheme.charge.productName, tint: ForgeColor.chargeInk,
                                      detail: pct.map { ChargeBand.of(score: $0).word.lowercased(with: AppLanguage.activeLocale) })
                    if let caption = display.carriedCaption {
                        Text(caption).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    }
                    if let target = ForgeToday.effortTargetStored(charge: pct) {
                        let t = ForgeToday.targetText(target, scale: UnitPrefs.currentEffortScale())
                        Text("Today's Effort target: \(t.low) to \(t.high).")
                            .font(.system(size: 17)).foregroundStyle(ForgeColor.text)
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
                        ForgeBadge(text: ChargeBreakdownFormat.tierTag(breakdown.confidence), tone: .neutral)
                    }
                    .padding(.horizontal, 4)
                    VStack(spacing: 0) {
                        ForEach(Array(breakdown.drivers.enumerated()), id: \.offset) { index, driver in
                            if index > 0 { Rectangle().fill(ForgeColor.separator).frame(height: 0.5) }
                            ForgeWhyRow(label: driver.label, value: driver.valueText, delta: driver.deltaPoints,
                                        usual: driver.baselineText.isEmpty ? nil : driver.baselineText)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text(ChargeBreakdownFormat.driverAccessibilityLabel(driver)))
                        }
                    }
                    .forgeCard(radius: 22, padding: 14)
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
                               text: "Charge compares last night's heart rate variability, resting heart rate, breathing and sleep with your own usual values. Everything is calculated on this iPhone.")
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
