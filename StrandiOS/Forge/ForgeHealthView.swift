#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandCore

/// The redesign's Health tab (2026-11): last night's vitals against the wearer's own range first, then
/// heart and stress, body and energy, and the long-term views (Trends moved here from its own tab).
///
/// The vitals come from `BodyVitalSigns.readings`, the same resolver the shipped Health screen draws its
/// tiles from, so both designs always agree on what is in range.
struct ForgeHealthView: View {
    let onProfile: () -> Void
    var onAsk: (String) -> Void = { _ in }
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @AppStorage(UnitPrefs.skinTempDisplayKey) private var skinTempDisplayRaw = ""
    @AppStorage(HealthspanFeature.defaultsKey) private var healthspanEnabled = false
    @State private var healthspan: HealthspanWeek?
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    @State private var hrvOverCountByDay: [String: Double] = [:]
    @State private var weightKg: Double?
    @State private var weightChange30d: Double?
    @State private var restByDay: [String: Double] = [:]
    @State private var energyKcal: Double?

    private var readings: [BodyVitalReading] {
        BodyVitalSigns.readings(
            sourceRows: repo.vitalMetricRows,
            temperatureUnit: UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw),
            spo2CandidateByDay: [:],
            hrvOverCountByDay: hrvOverCountByDay,
            skinTempPreferred: SkinTempDisplay.Kind(rawValue: skinTempDisplayRaw) ?? .absolute)
            // The raw optical reading is an experimental instrument; an empty one is noise on this tab.
            .filter { !($0.key == "spo2raw" && $0.value == nil) }
            // The prototype's order: HRV, resting heart rate, blood oxygen, breathing, then the rest.
            .sorted { Self.order($0.key) < Self.order($1.key) }
    }

    private func vitalTile(_ r: BodyVitalReading) -> some View {
        NavigationLink(value: TabRoute.metric(r.key == "spo2raw" ? "spo2" : r.key)) {
            ForgeMetricTile(label: Self.plainLabel(r), value: r.value.map(r.format), unit: r.unit,
                            trend: r.sparkline, tint: r.metricColor,
                            badge: (r.stateText, badgeTone(r)))
        }
        .buttonStyle(LiquidPressStyle())
    }

    /// "−1,7 kg in 30 days" with a real minus and the reader's decimal separator.
    private func weightChangeText(_ kg: Double) -> String {
        let value = unitSystem == .imperial ? UnitFormatter.kgToPounds(kg) : kg
        let figure = abs(value).formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.activeLocale))
        let signed = "\(value < 0 ? "−" : "+")\(figure) \(UnitFormatter.massUnit(unitSystem))"
        return String(localized: "\(signed) in 30 days")
    }

    private static func order(_ key: String) -> Int {
        ["hrv", "rhr", "spo2", "resp_rate", "skin_temp", "spo2raw"].firstIndex(of: key) ?? 99
    }

    var body: some View {
        let readings = readings
        let scored = readings.filter { $0.banding.band != .noData && $0.key != "spo2raw" }
        let inRange = scored.filter { $0.banding.band == .inRange }.count
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForgeLargeHeader(title: "Health", onProfile: onProfile) { ForgeSearchButton() }
                    .id("forge-health-top")
                    VStack(alignment: .leading, spacing: 14) {
                        ForgeTabHero(
                            overline: String(localized: "Vitals last night"),
                            headline: scored.isEmpty ? String(localized: "No readings yet")
                                : String(localized: "\(inRange) of \(scored.count) in range")) {
                            FlowRows(spacing: 6) {
                                ForEach(scored) { r in
                                    let ok = r.banding.band == .inRange
                                    HStack(spacing: 6) {
                                        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                            .foregroundStyle(ok ? ForgeColor.text : ForgeColor.effortInk)
                                        Text(Self.plainLabel(r)).foregroundStyle(ok ? ForgeColor.text : ForgeColor.effortInk)
                                    }
                                    .font(.system(.footnote, weight: .semibold))
                                    .padding(.horizontal, 10).frame(minHeight: 30)
                                    .background(Capsule().fill(ok ? ForgeColor.card.opacity(0.75) : ForgeColor.effort.opacity(0.16)))
                                }
                            }
                            .padding(.top, 6)
                        }

                        if let off = scored.first(where: { $0.banding.band == .outOfRange }) {
                            offRangeCard(off)
                        }

                        ForgeSectionTitle(title: "Vitals")
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                                  spacing: 10) {
                            ForEach(readings.count % 2 == 0 ? readings : Array(readings.dropLast())) { r in
                                vitalTile(r)
                            }
                        }
                        // An odd last vital spans the row instead of leaving a hole beside it.
                        if readings.count % 2 == 1, let last = readings.last {
                            vitalTile(last)
                        }

                        // The cycle at a glance, only while cycle tracking is on.
                        ForgeCycleSummaryCard()

                        ForgeSectionTitle(title: "Focus areas")
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(ForgeFocusArea.allCases) { area in
                                NavigationLink(value: ForgeRoute.focus(area)) { ForgeFocusTile(area: area) }
                                    .buttonStyle(LiquidPressStyle())
                            }
                        }

                        ForgeSectionTitle(title: "Long term and patterns", action: nil)
                        if healthspanEnabled { agelessCard }
                        weekInRings
                        ForgeGroup {
                            NavigationLink(value: ForgeRoute.weeklyReport) {
                                ForgeRow(systemImage: "calendar", tint: ForgeColor.accent,
                                         title: String(localized: "Weekly report"),
                                         subtitle: String(localized: "Your week read back"))
                            }
                            ForgeRowDivider()
                            NavigationLink(value: TabRoute.trends) {
                                ForgeRow(systemImage: "chart.line.uptrend.xyaxis", tint: ForgeColor.charge,
                                         title: String(localized: "Trends"),
                                         subtitle: String(localized: "Charge, Effort and Rest over months"))
                            }
                            ForgeRowDivider()
                            NavigationLink(value: MoreDestination.insightsHub) {
                                ForgeRow(systemImage: "lightbulb.fill", tint: .yellow, title: String(localized: "What works"),
                                         subtitle: String(localized: "What helps you, what hurts you"))
                            }
                            ForgeRowDivider()
                            NavigationLink(value: TabRoute.metricExplorer) {
                                ForgeRow(systemImage: "square.grid.2x2.fill", tint: .blue, title: String(localized: "All metrics"),
                                         subtitle: String(localized: "Every metric, compare freely"))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 6)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .onChange(of: scrollToTopSignal) { _, _ in
                withAnimation(.smooth) { proxy.scrollTo("forge-health-top", anchor: .top) }
            }
        }
        .background(ForgeBackground(tab: .health))
        .refreshable { await repo.refresh() }
        .task(id: repo.days.count) { await load() }
        .task(id: "\(repo.refreshSeq)|\(healthspanEnabled)") {
            guard healthspanEnabled, let sex = HealthspanEngine.Sex(profileValue: profile.sex) else { healthspan = nil; return }
            healthspan = await HealthspanSnapshot.load(repo: repo, age: profile.age, sex: sex)?.weeks.last
        }
    }

    /// "Your week in rings": the last seven days' Charge, Effort and Rest as small stacked rings.
    private var weekInRings: some View {
        let days = Array(repo.days.suffix(7))
        return NavigationLink(value: TabRoute.trends) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your week in rings").font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.secondary)
                HStack(spacing: 0) {
                    ForEach(days, id: \.day) { d in
                        VStack(spacing: 4) {
                            ForgeMiniRings(charge: d.recovery, effort: d.strain, rest: restByDay[d.day])
                                .frame(width: 34, height: 34)
                            Text(Self.weekday(d.day)).font(.system(.caption2)).foregroundStyle(ForgeColor.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .forgeCard(radius: 22, padding: 14)
        }
        .buttonStyle(LiquidPressStyle())
    }

    private static func weekday(_ key: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: key) else { return "" }
        return date.formatted(.dateTime.weekday(.narrow).locale(AppLanguage.activeLocale))
    }

    /// The first vital outside the wearer's range, as the prototype's card: what it is, last night's value
    /// and its recent nights large, with the coach's questions when the coach is on. Works with it off.
    private func offRangeCard(_ r: BodyVitalReading) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Outside your usual range", systemImage: "waveform.path.ecg")
                .font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.accent)
            Text("\(Self.plainLabel(r)) is outside your usual range").font(.system(.title3, weight: .bold))
                .foregroundStyle(ForgeColor.text).fixedSize(horizontal: false, vertical: true)
            if let value = r.value {
                Text("**\(r.format(value)) \(r.unit)** last night. \(r.stateText).")
                    .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
            }
            if let line = r.sparkline, line.count > 1 {
                Sparkline(values: line, gradient: Gradient(colors: [ForgeColor.effort.opacity(0.6), ForgeColor.effort]),
                          lineWidth: 2, showsArea: true)
                    .frame(height: 90)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ForgeColor.card))
                    .accessibilityHidden(true)
            }
            if coachFeatureEnabled {
                FlowRows(spacing: 8) {
                    ForgeChip(title: String(localized: "What's causing it?")) {
                        onAsk(String(localized: "My \(r.label) was outside my usual range last night. What could be causing it?"))
                    }
                    ForgeChip(title: String(localized: "Should I rest?")) {
                        onAsk(String(localized: "My \(r.label) was outside my usual range last night. Should I rest or train lighter today?"))
                    }
                }
            }
        }
        .forgeCard(radius: 24, padding: 16)
    }

    private func badgeTone(_ r: BodyVitalReading) -> ForgeBadge.Tone {
        switch r.banding.band {
        case .inRange: return .good
        case .outOfRange: return .attention
        case .noData: return .neutral
        }
    }

    private func load() async {
        // Same flags the shipped Health tiles read, so an over-counted night is captioned identically.
        let oc = await repo.exploreSeries(key: "hrv_rr_overcount", source: "my-whoop", days: 14)
        hrvOverCountByDay = Dictionary(oc.map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
        let summary = await repo.weightTrendSummary(days: 91)
        weightKg = WeightSeries.currentWeight(summary: summary, profileWeightKg: profile.weightKg).kg
        weightChange30d = summary?.change30dKg
        let rest = await repo.exploreSeries(key: "sleep_performance", source: Repository.whoopSource, days: 14)
        restByDay = Dictionary(rest.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        let today = Repository.logicalDayKey(Date())
        energyKcal = (await repo.energySummaries(days: 2, profile: Repository.analyticsProfile(profile)))
            .last(where: { $0.day == today })?.totalBurnedSoFar
    }
}

extension ForgeHealthView {
    /// AgeLess on Health: the top of its page only (AgeLess age, actual age, pace, six months on) on the
    /// same age line, opening the full page. Without a week to show (no sex in the profile, too few nights)
    /// it still opens the page, which says what is missing.
    @ViewBuilder var agelessCard: some View {
        NavigationLink(value: ForgeRoute.ageless) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("AgeLess", systemImage: "hourglass").font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold)).foregroundStyle(ForgeColor.tertiary)
                }
                if let week = healthspan {
                    let age = week.result.healthspanAge, actual = week.result.chronologicalAge
                    let projected = week.pace.map { HealthspanEngine.projectedAge(currentAge: age, pace: $0) }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(HealthspanSection.years(age)).font(ForgeFont.rounded(34, .bold))
                            .foregroundStyle(age <= actual ? ForgeColor.chargeInk : ForgeColor.effortInk)
                        Text("AgeLess age · actual \(HealthspanSection.years(actual))").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    }
                    ForgeAgeLine(actual: actual, age: age, projected: projected).frame(height: 70)
                    if let pace = week.pace {
                        Text(ForgeAgeLessView.paceSentence(pace)).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    }
                } else {
                    Text("Your health age").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
            }
            .forgeCard(radius: 22, padding: 14)
        }
        .buttonStyle(.plain)
    }
}

extension ForgeHealthView {
    /// The vitals in whole words on this tab ("Resting heart rate", not "Resting HR"): the shared labels are
    /// abbreviated for the denser shipped screens.
    static func plainLabel(_ r: BodyVitalReading) -> String {
        switch r.key {
        case "rhr": return String(localized: "Resting heart rate")
        case "resp": return String(localized: "Breathing rate")
        case "spo2", "spo2raw": return String(localized: "Blood oxygen")
        case "skin": return String(localized: "Skin temperature")
        default: return r.label
        }
    }
}
#endif
