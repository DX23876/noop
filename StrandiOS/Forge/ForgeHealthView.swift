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
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    @State private var hrvOverCountByDay: [String: Double] = [:]
    @State private var weightKg: Double?
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
    }

    var body: some View {
        let readings = readings
        let scored = readings.filter { $0.banding.band != .noData && $0.key != "spo2raw" }
        let inRange = scored.filter { $0.banding.band == .inRange }.count
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForgeLargeHeader(title: "Health", onProfile: onProfile).id("forge-health-top")
                    VStack(alignment: .leading, spacing: 14) {
                        ForgeTabHero(
                            overline: String(localized: "Vitals last night"),
                            headline: scored.isEmpty ? String(localized: "No readings yet")
                                : String(localized: "\(inRange) of \(scored.count) in range")) {
                            FlowRows(spacing: 6) {
                                ForEach(scored) { r in
                                    HStack(spacing: 4) {
                                        Image(systemName: r.banding.band == .inRange ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                            .foregroundStyle(r.banding.band == .inRange ? ForgeColor.charge : ForgeColor.effort)
                                        Text(r.label).foregroundStyle(ForgeColor.text)
                                    }
                                    .font(.system(size: 13, weight: .medium))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Capsule().fill(ForgeColor.fill))
                                }
                            }
                            .padding(.top, 6)
                            if coachFeatureEnabled, inRange < scored.count {
                                ForgeChip(title: String(localized: "What's behind it?"), systemImage: "sparkles",
                                          prominent: true) {
                                    onAsk(String(localized: "Some of my vitals were outside my usual range last night. What could be behind it, and should I change anything today?"))
                                }
                                .padding(.top, 8)
                            }
                        }

                        ForgeSectionTitle(title: "Vitals")
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                                  spacing: 10) {
                            ForEach(readings) { r in
                                NavigationLink(value: TabRoute.metric(r.key == "spo2raw" ? "spo2" : r.key)) {
                                    ForgeMetricTile(label: r.label, value: r.value.map(r.format), unit: r.unit,
                                                    trend: r.sparkline, tint: r.metricColor,
                                                    badge: (r.stateText, badgeTone(r)))
                                }
                                .buttonStyle(LiquidPressStyle())
                            }
                        }
                        Text("Once NOOP has 14 nights of history, in-range compares each vital to your own baseline (approximate, not medical advice); until then, typical adult ranges apply.")
                            .font(ForgeFont.caption)
                            .foregroundStyle(ForgeColor.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)

                        ForgeSectionTitle(title: "Heart and stress")
                        ForgeGroup {
                            NavigationLink(value: TabRoute.stress) {
                                ForgeRow(systemImage: "bolt.heart.fill", tint: .orange, title: String(localized: "Stress"),
                                         subtitle: String(localized: "Through the day"))
                            }
                            ForgeRowDivider()
                            NavigationLink(value: TabRoute.fullDayChart) {
                                ForgeRow(systemImage: "waveform.path.ecg", tint: .red, title: String(localized: "Heart rate"),
                                         subtitle: String(localized: "The whole day, beat by beat"))
                            }
                            ForgeRowDivider()
                            NavigationLink(value: MoreDestination.ecg) {
                                ForgeRow(systemImage: "heart.text.square.fill", tint: .pink, title: String(localized: "ECG"),
                                         subtitle: String(localized: "Saved readings"))
                            }
                        }
                        .buttonStyle(.plain)

                        ForgeSectionTitle(title: "Body and energy")
                        ForgeGroup {
                            NavigationLink(value: TabRoute.weight) {
                                ForgeRow(systemImage: "scalemass.fill", tint: .indigo, title: String(localized: "Weight"),
                                         subtitle: String(localized: "Weigh-ins and trend"),
                                         value: weightKg.map { UnitFormatter.massFromKilograms($0, system: unitSystem) })
                            }
                            ForgeRowDivider()
                            NavigationLink(value: TabRoute.energy) {
                                ForgeRow(systemImage: "flame.fill", tint: .orange, title: String(localized: "Energy today"),
                                         subtitle: String(localized: "Burned so far"),
                                         value: energyKcal.map { "\(Int($0.rounded()))" }, unit: energyKcal == nil ? nil : "kcal")
                            }
                            ForgeRowDivider()
                            NavigationLink(value: MoreDestination.body) {
                                ForgeRow(systemImage: "figure.stand", tint: .teal, title: String(localized: "Body"),
                                         subtitle: String(localized: "Measurements and composition"))
                            }
                            ForgeRowDivider()
                            NavigationLink(value: MoreDestination.labBook) {
                                ForgeRow(systemImage: "testtube.2", tint: .purple, title: String(localized: "Lab values"),
                                         subtitle: String(localized: "Blood pressure, blood tests"))
                            }
                        }
                        .buttonStyle(.plain)

                        ForgeSectionTitle(title: "Long term and patterns")
                        ForgeGroup {
                            NavigationLink(value: TabRoute.trends) {
                                ForgeRow(systemImage: "chart.line.uptrend.xyaxis", tint: ForgeColor.charge,
                                         title: String(localized: "Trends"),
                                         subtitle: String(localized: "Charge, Effort and Rest over months"))
                            }
                            if healthspanEnabled {
                                ForgeRowDivider()
                                NavigationLink(value: MoreDestination.ageless) {
                                    ForgeRow(systemImage: "hourglass", tint: .mint, title: String(localized: "AgeLess"),
                                             subtitle: String(localized: "Your health age"))
                                }
                            }
                            ForgeRowDivider()
                            NavigationLink(value: MoreDestination.insights) {
                                ForgeRow(systemImage: "lightbulb.fill", tint: .yellow, title: String(localized: "Patterns"),
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
        weightKg = WeightSeries.currentWeight(summary: await repo.weightTrendSummary(days: 91),
                                              profileWeightKg: profile.weightKg).kg
        let today = Repository.logicalDayKey(Date())
        energyKcal = (await repo.energySummaries(days: 2, profile: Repository.analyticsProfile(profile)))
            .last(where: { $0.day == today })?.totalBurnedSoFar
    }
}
#endif
