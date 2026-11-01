#if os(iOS)
import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Routes that only exist in the redesign. Registered on the redesign's tab stacks next to `TabRoute`.
enum ForgeRoute: Hashable {
    case charge
    case weeklyReport
}

extension View {
    func forgeRouteDestinations(coach: AICoachEngine, onAsk: @escaping (String) -> Void) -> some View {
        navigationDestination(for: ForgeRoute.self) { route in
            switch route {
            case .charge: ForgeChargeDetailView(onAsk: onAsk)
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
                VStack(spacing: 8) {
                    OrganicScoreHeroClock(dataReady: true) { frame in
                        OrganicScoreRing(
                            model: OrganicScoreVisualModel.resolve(metric: .charge, value: pct, scaleMaximum: 100),
                            tint: pct.map { StrandPalette.chargeRingColor($0) } ?? StrandPalette.organicMissing,
                            score: pct, decimals: 0, frame: frame, diameter: 170, hitDiameter: 170)
                            .frame(width: 170, height: 170)
                    }
                    if let pct {
                        Text(ChargeBand.of(score: pct).word.capitalized(with: AppLanguage.activeLocale))
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(ForgeColor.chargeInk)
                    }
                    if let caption = display.carriedCaption {
                        Text(caption).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    }
                    if let target = ForgeToday.effortTargetStored(charge: pct) {
                        let t = ForgeToday.targetText(target, scale: UnitPrefs.currentEffortScale())
                        Text("Today's Effort target: \(t.low) to \(t.high).")
                            .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

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
                            driverRow(driver)
                        }
                    }
                    .forgeCard(radius: 22, padding: 14)
                } else if case .calibrating(let nights) = display {
                    ForgeTabHero(overline: String(localized: "Calibrating"),
                                 headline: ChargeBreakdownFormat.calibrationCountdown(nightsRemaining: nights))
                }

                if coachFeatureEnabled {
                    HStack(spacing: 8) {
                        ForgeChip(title: String(localized: "What can I improve?"), systemImage: "sparkles", prominent: true) {
                            onAsk(String(localized: "Look at what shaped my Charge today and tell me the one thing I could improve."))
                        }
                    }
                }

                lastDays

                VStack(alignment: .leading, spacing: 6) {
                    Text("How Charge is made").font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
                    Text("Charge compares last night's heart rate variability, resting heart rate, breathing and sleep with your own usual values. Everything is calculated on this iPhone.")
                        .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    NavigationLink(value: TabRoute.metric(HeroRingMetric.charge)) {
                        Text("Full history").font(.system(size: 16, weight: .semibold)).foregroundStyle(ForgeColor.accent)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .today))
        .navigationTitle(Text(DomainTheme.charge.productName))
        .navigationBarTitleDisplayMode(.large)
        .task {
            rest = DashboardRestScore.value(day: todayKey, days: repo.days, importedSleep: repo.importedSleep)
        }
    }

    private func driverRow(_ driver: ChargeDriver) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(driver.label).font(.system(size: 16, weight: .semibold)).foregroundStyle(ForgeColor.text)
                if !driver.baselineText.isEmpty {
                    Text(driver.baselineText).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
                Text(driver.verdict).font(ForgeFont.caption).foregroundStyle(ForgeColor.tertiary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(driver.valueText).font(ForgeFont.rounded(17, .bold)).foregroundStyle(ForgeColor.text)
                ForgeBadge(text: ChargeBreakdownFormat.chipLabel(deltaPoints: driver.deltaPoints),
                           tone: driver.deltaPoints > 0 ? .good : (driver.deltaPoints < 0 ? .attention : .neutral))
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ChargeBreakdownFormat.driverAccessibilityLabel(driver)))
    }

    private var lastDays: some View {
        let points = repo.days.suffix(14).compactMap { d -> (Date, Double)? in
            guard let r = d.recovery, let date = Self.dayParser.date(from: d.day) else { return nil }
            return (date, r)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Last 14 days").font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
            if points.count > 1 {
                Chart {
                    ForEach(points, id: \.0) { p in
                        LineMark(x: .value("Day", p.0), y: .value("Charge", p.1))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(ForgeColor.charge)
                        PointMark(x: .value("Day", p.0), y: .value("Charge", p.1))
                            .symbolSize(18)
                            .foregroundStyle(ForgeColor.charge)
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 3)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
                .frame(height: 150)
            } else {
                Text("Not enough nights yet.").font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
            }
        }
        .forgeCard(radius: 22, padding: 14)
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
#endif
