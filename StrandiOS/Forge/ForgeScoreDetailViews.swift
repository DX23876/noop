#if os(iOS)
import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import StrandCore
import WhoopStore

/// The redesign's Effort page: the ring, today's target from the Coupled bands, what added to it today,
/// the last 14 days and how Effort is made. The value is the one the Today ring shows (passed in, so the
/// two can never disagree); the full metric history stays one tap away.
struct ForgeEffortDetailView: View {
    let effortStored: Double?
    let charge: Double?
    var onAsk: (String) -> Void = { _ in }

    @EnvironmentObject private var repo: Repository
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    @State private var todayWorkouts: [WorkoutRow] = []

    private var target: ClosedRange<Double>? { ForgeToday.effortTargetStored(charge: charge) }
    private var shown: Double? { effortStored.map { UnitFormatter.effortValue($0, scale: effortScale) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 8) {
                    OrganicScoreHeroClock(dataReady: true) { frame in
                        OrganicScoreRing(
                            model: OrganicScoreVisualModel.resolve(metric: .effort, value: shown,
                                                                   scaleMaximum: effortScale == .whoop ? 21 : 100),
                            tint: StrandPalette.organicEffort, score: shown,
                            decimals: effortScale == .whoop ? 1 : 0, frame: frame, diameter: 170, hitDiameter: 170)
                            .frame(width: 170, height: 170)
                    }
                    if let line = ForgeToday.summary(effortStored: effortStored, charge: charge, scale: effortScale) {
                        Text(line).font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                if let effortStored, let target {
                    ForgeEffortTargetBar(effort: effortStored, target: target, scale: effortScale)
                }

                if coachFeatureEnabled {
                    ForgeChip(title: String(localized: "How hard should I go today?"), systemImage: "sparkles",
                              prominent: true) {
                        onAsk(String(localized: "Look at my Charge and today's Effort so far, and tell me how hard I should still train today."))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForgeSectionTitle(title: "What added to it today")
                    if todayWorkouts.isEmpty {
                        Text("No workout yet today. Effort also counts everyday movement and heart rate through the day.")
                            .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary).padding(.horizontal, 4)
                    } else {
                        ForgeGroup {
                            ForEach(Array(todayWorkouts.enumerated()), id: \.offset) { index, row in
                                if index > 0 { ForgeRowDivider() }
                                NavigationLink(value: TabRoute.workoutDetail(startTs: row.startTs, sport: row.sport)) {
                                    ForgeRow(systemImage: "figure.mixed.cardio",
                                             tint: AppleInspiredColors.role(forSport: row.sport).color,
                                             title: WorkoutSource.localizedDisplaySport(row.sport),
                                             subtitle: String(localized: "\(Int((row.durationS ?? Double(row.endTs - row.startTs)) / 60)) min"),
                                             value: row.strain.map { ForgeToday.effortText($0, scale: effortScale) })
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                ForgeDailyChart(title: String(localized: "Last 14 days"),
                                points: repo.days.suffix(14).compactMap { d in
                                    d.strain.map { (d.day, UnitFormatter.effortValue($0, scale: effortScale)) }
                                },
                                maxValue: effortScale == .whoop ? 21 : 100, tint: ForgeColor.effort, bars: true)

                ForgeExplainer(title: "How Effort is made",
                               text: "Effort adds up how hard your heart worked through the day against your own resting and maximum heart rate, workouts included. The target comes from this morning's Charge: more Charge, more room. Everything is calculated on this iPhone.",
                               historyRoute: TabRoute.effort(DashboardEffortReadout(day: Repository.logicalDayKey(Date()),
                                                                                    value: effortStored)))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .training))
        .navigationTitle(Text(DomainTheme.effort.productName))
        .navigationBarTitleDisplayMode(.large)
        .task {
            let cal = Calendar.current
            todayWorkouts = (await repo.workoutRows(days: 2, reconcileHrCap: 0))
                .filter { cal.isDateInToday(Date(timeIntervalSince1970: TimeInterval($0.startTs))) }
                .sorted { $0.startTs > $1.startTs }
        }
    }
}

/// The redesign's Rest page: the ring, how last night measured against the wearer's usual, the nights
/// before, and how Rest is made. Reads the SAME sleep presentation model the Sleep screens use.
struct ForgeRestDetailView: View {
    let rest: Double?
    var onAsk: (String) -> Void = { _ in }

    @EnvironmentObject private var repo: Repository
    @Environment(\.sleepPresentationStore) private var sceneSleepStore
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    private var sleepStore: SleepPresentationStore { sceneSleepStore ?? repo.sleepPresentation }
    @State private var model: SleepModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 8) {
                    OrganicScoreHeroClock(dataReady: true) { frame in
                        OrganicScoreRing(
                            model: OrganicScoreVisualModel.resolve(metric: .rest, value: rest, scaleMaximum: 100),
                            tint: StrandPalette.organicRest, score: rest, decimals: 0, frame: frame,
                            diameter: 170, hitDiameter: 170)
                            .frame(width: 170, height: 170)
                    }
                    if let m = model {
                        Text("\(ForgeTodayView.hoursMinutes(m.night.stages.asleep)) h asleep, \(m.night.onsetText) to \(m.night.wakeText)")
                            .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                if let m = model {
                    ForgeSectionTitle(title: "What shaped it")
                    ForgeGroup {
                        factor(String(localized: "Hours against your need"), m.hoursVsNeeded, unit: "%")
                        ForgeRowDivider()
                        factor(String(localized: "Efficiency"), m.efficiency, unit: "%")
                        ForgeRowDivider()
                        factor(String(localized: "Consistency"), m.consistency, unit: "%")
                        ForgeRowDivider()
                        factor(String(localized: "Restorative sleep"), m.restorative, unit: "%")
                    }
                }

                if coachFeatureEnabled {
                    ForgeChip(title: String(localized: "Discuss last night with the coach"), systemImage: "sparkles",
                              prominent: true) {
                        onAsk(String(localized: "Look at my last night's sleep and tell me what stood out and what I could change tonight."))
                    }
                }

                ForgeDailyChart(title: String(localized: "Last 14 days"),
                                points: Array((model?.performance.series ?? []).suffix(14).enumerated()).map {
                                    (String($0.offset), $0.element)
                                },
                                maxValue: 100, tint: ForgeColor.rest, bars: true, indexed: true)

                ForgeExplainer(title: "How Rest is made",
                               text: "Rest weighs how long you slept against what you needed, how well you slept, how regular your times were and how much deep and REM sleep you got. Everything is calculated on this iPhone.",
                               historyRoute: TabRoute.metric(HeroRingMetric.rest))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .sleep))
        .navigationTitle(Text(DomainTheme.rest.productName))
        .navigationBarTitleDisplayMode(.large)
        .task {
            let revision = SleepPresentationRevision(repo: repo)
            model = (try? await sleepStore.presentation(repo: repo, revision: revision))?.model
        }
    }

    /// One factor: last night's value beside the wearer's usual, both from the sleep model.
    private func factor(_ label: String, _ metric: SleepModel.Metric, unit: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 16, weight: .semibold)).foregroundStyle(ForgeColor.text)
                if let typical = metric.typical {
                    Text("usually \(Int(typical.rounded())) %").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
            }
            Spacer()
            Text(metric.latest.map { "\(Int($0.rounded())) \(unit)" } ?? "–")
                .font(ForgeFont.rounded(19, .bold)).foregroundStyle(ForgeColor.text)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared pieces of the score pages

/// Today's Effort on a 0 to 100 track with the target band marked (the same track the evening note shows).
struct ForgeEffortTargetBar: View {
    let effort: Double
    let target: ClosedRange<Double>
    let scale: EffortScale

    var body: some View {
        let t = ForgeToday.targetText(target, scale: scale)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(ForgeColor.fill)
                    Capsule().fill(ForgeColor.effort.opacity(0.25))
                        .frame(width: w * (target.upperBound - target.lowerBound) / 100)
                        .offset(x: w * target.lowerBound / 100)
                    Circle().fill(ForgeColor.effort).frame(width: 12, height: 12)
                        .offset(x: max(0, min(w - 12, w * effort / 100 - 6)))
                }
            }
            .frame(height: 12)
            Text("Effort \(ForgeToday.effortText(effort, scale: scale)), target \(t.low) to \(t.high)")
                .font(.system(size: 12)).foregroundStyle(ForgeColor.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ForgeColor.fill))
        .accessibilityElement(children: .combine)
    }
}

/// A small chart card of one value per day (bars), keyed by day or by position.
struct ForgeDailyChart: View {
    let title: String
    let points: [(String, Double)]
    let maxValue: Double
    let tint: Color
    var bars = true
    /// When the keys are positions rather than day keys (a series without dates).
    var indexed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
            if points.count > 1 {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { index, p in
                        BarMark(x: .value("Day", index), y: .value("Value", p.1))
                            .foregroundStyle(tint.opacity(index == points.count - 1 ? 1 : 0.6))
                            .cornerRadius(4)
                    }
                }
                .chartYScale(domain: 0...maxValue)
                .chartXAxis(.hidden)
                .frame(height: 140)
            } else {
                Text("Not enough days yet.").font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
            }
        }
        .forgeCard(radius: 22, padding: 14)
    }
}

/// "How X is made" with a link to the full history.
struct ForgeExplainer<Route: Hashable>: View {
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    let historyRoute: Route

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
            Text(text).font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink(value: historyRoute) {
                Text("Full history").font(.system(size: 16, weight: .semibold)).foregroundStyle(ForgeColor.accent)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 4)
    }
}
#endif
