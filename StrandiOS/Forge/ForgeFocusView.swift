#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// The Health tab's focus areas (prototype "focus areas", 2026-11): six areas, each a page with its key
/// measures as tiles (latest value and the last 30 days) and the screens that belong to it. The tiles read
/// the same series the metric pages chart (`Repository.exploreSeries`) and open those pages.
enum ForgeFocusArea: String, CaseIterable, Hashable, Identifiable {
    case fitness, sleep, vitals, body, mind, more
    var id: String { rawValue }

    var title: String {
        switch self {
        case .fitness: return String(localized: "Fitness")
        case .sleep: return String(localized: "Sleep")
        case .vitals: return String(localized: "Heart and vitals")
        case .body: return String(localized: "Body and nutrition")
        case .mind: return String(localized: "Mind and stress")
        case .more: return String(localized: "More")
        }
    }

    var subtitle: String {
        switch self {
        case .fitness: return String(localized: "VO₂max, cardio, strength")
        case .sleep: return String(localized: "Hours, steadiness, debt")
        case .vitals: return String(localized: "HRV, resting heart rate, ECG")
        case .body: return String(localized: "Weight, energy, health records")
        case .mind: return String(localized: "Stress, breathing, what works")
        case .more: return String(localized: "Trends, all metrics, compare")
        }
    }

    var symbol: String {
        switch self {
        case .fitness: return "figure.run"
        case .sleep: return "moon.fill"
        case .vitals: return "heart.fill"
        case .body: return "figure.stand"
        case .mind: return "brain.head.profile"
        case .more: return "square.grid.2x2.fill"
        }
    }

    var tint: Color {
        switch self {
        case .fitness: return ForgeColor.effort
        case .sleep: return ForgeColor.rest
        case .vitals: return ForgeColor.charge
        case .body: return .purple
        case .mind: return .teal
        case .more: return ForgeColor.accent
        }
    }

    /// The measures shown as tiles, by catalog key and source, in order. A measure with no data is left out.
    var metrics: [(key: String, source: String)] {
        let strap = Repository.whoopSource
        switch self {
        case .fitness: return [("vo2max_est", strap), ("rhr", strap), ("hr_zones13_min", strap), ("strength_min", strap), ("steps", strap), ("strain", strap)]
        case .sleep: return [("sleep_performance", strap), ("sleep_total_min", strap), ("sleep_consistency", strap), ("sleep_debt_min", strap),
                             ("restorative_min", strap), ("sleep_efficiency", strap)]
        case .vitals: return [("hrv", strap), ("rhr", strap), ("spo2", strap), ("resp_rate", strap), ("skin_temp", strap), ("avg_hr", strap)]
        case .body: return [("weight", "noop-weight"), ("weight", "apple-health"), ("body_fat", "apple-health"), ("lean_mass", "apple-health"),
                            ("calories_in", "nutrition-csv"), ("active_kcal", "apple-health")]
        case .mind: return [("stress", strap), ("mood", "noop-mood")]
        case .more: return []
        }
    }
}

/// One entry under a focus area's tiles: a screen, by the route its stack already knows.
private struct FocusLink: Identifiable {
    enum Target { case forge(ForgeRoute), tab(TabRoute), more(MoreDestination) }
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let target: Target
    var id: String { title }
}

struct ForgeFocusView: View {
    let area: ForgeFocusArea
    @EnvironmentObject private var repo: Repository
    @AppStorage(HealthspanFeature.defaultsKey) private var healthspanEnabled = false
    @AppStorage(AppModel.cycleAwarenessKey) private var cycleEnabled = false
    @AppStorage(AppModel.cycleAwarenessHiddenKey) private var cycleHidden = false
    @EnvironmentObject private var profile: ProfileStore
    @State private var series: [String: [(day: String, value: Double)]] = [:]
    @State private var loaded = false
    @State private var scrolledPast = false
    /// Body and nutrition: each finished day's burn, oldest first, so Energy has a tile beside Weight.
    @State private var energyTotals: [Double] = []

    private struct Tile: Identifiable {
        let metric: MetricDescriptor
        let values: [Double]
        var id: String { metric.id }
    }

    private var tiles: [Tile] {
        var seenKeys = Set<String>()
        return area.metrics.compactMap { m in
            guard !seenKeys.contains(m.key), let d = MetricCatalog.metric(key: m.key, source: m.source),
                  let s = series[d.id], !s.isEmpty else { return nil }
            seenKeys.insert(m.key)
            return Tile(metric: d, values: s.map(\.value))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForgeDetailHeader(overline: nil, title: area.title, scrolledPast: $scrolledPast)
                let tiles = self.tiles
                if !tiles.isEmpty || !energyTotals.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(tiles) { t in
                            NavigationLink(value: TabRoute.metricSourced(key: t.metric.key, source: t.metric.source)) {
                                ForgeMetricTile(label: t.metric.title, value: Self.format(t.values.last, t.metric),
                                                unit: Self.unit(t.metric), trend: Array(t.values.suffix(30)), tint: area.tint)
                            }
                            .buttonStyle(LiquidPressStyle())
                        }
                        if !energyTotals.isEmpty {
                            NavigationLink(value: TabRoute.energy) {
                                ForgeMetricTile(label: String(localized: "Energy"),
                                                value: energyTotals.last.map { Int($0.rounded()).formatted(.number.locale(AppLanguage.activeLocale)) },
                                                unit: "kcal", trend: Array(energyTotals.suffix(30)), tint: StrandPalette.forgeEnergyActive)
                            }
                            .buttonStyle(LiquidPressStyle())
                        }
                    }
                } else if loaded, !area.metrics.isEmpty {
                    Text("No measurements here yet. They appear once your strap or your imports provide them.")
                        .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary).padding(.horizontal, 4)
                }
                let links = self.links
                if !links.isEmpty {
                    ForgeSectionTitle(title: "In this area")
                    ForgeGroup {
                        ForEach(Array(links.enumerated()), id: \.element.id) { i, l in
                            if i > 0 { ForgeRowDivider() }
                            link(l)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .health))
        .forgeDetailBar(title: area.title, showsTitle: scrolledPast)
        .task(id: repo.refreshSeq) { await load() }
    }

    private func load() async {
        var out: [String: [(day: String, value: Double)]] = [:]
        for m in area.metrics {
            guard let d = MetricCatalog.metric(key: m.key, source: m.source) else { continue }
            out[d.id] = await repo.exploreSeries(key: m.key, source: m.source, days: 90)
        }
        series = out
        if area == .body {
            // Finished days only: today's running total would end every trend on a dip.
            let today = Repository.logicalDayKey(Date())
            let days = await repo.energySummaries(days: 30, profile: Repository.analyticsProfile(profile))
            energyTotals = days.filter { $0.day != today }.sorted { $0.day < $1.day }.compactMap(\.totalBurnedSoFar)
        }
        loaded = true
    }

    /// Minutes read as hours and minutes; everything else with the catalog's own precision.
    static func format(_ v: Double?, _ m: MetricDescriptor) -> String? {
        guard let v else { return nil }
        if m.unit == "min" {
            let total = Int(v.rounded())
            return "\(total / 60):\(String(format: "%02d", total % 60))"
        }
        let decimals = m.unit == "/100" ? 0 : m.decimals
        let text = v.formatted(.number.precision(.fractionLength(decimals)).locale(AppLanguage.activeLocale))
        // Skin temperature is stored either absolute (imports) or as a change from the wearer's usual: a
        // change carries its sign, so "+0.1 °C" is not read as a body at a tenth of a degree, nor as a
        // second, different temperature beside the Health tab's "33.9 °C".
        if m.key == "skin_temp", v < 20, v >= 0 { return "+" + text }
        return text
    }

    static func unit(_ m: MetricDescriptor) -> String {
        switch m.unit {
        case "min": return "h"
        // A score out of 100 reads by itself; "0.7" on a 0 to 3 scale needs its ceiling beside it.
        case "/100": return ""
        case "/3", "/5": return m.unit
        default: return m.unit
        }
    }

    @ViewBuilder private func link(_ l: FocusLink) -> some View {
        let row = ForgeRow(systemImage: l.symbol, tint: l.tint, title: l.title, subtitle: l.subtitle)
        switch l.target {
        case .forge(let r): NavigationLink(value: r) { row }.buttonStyle(.plain)
        case .tab(let r): NavigationLink(value: r) { row }.buttonStyle(.plain)
        case .more(let r): NavigationLink(value: r) { row }.buttonStyle(.plain)
        }
    }

    private var links: [FocusLink] {
        switch area {
        case .fitness:
            return [FocusLink(title: String(localized: "Cardio"), subtitle: String(localized: "Load, pace and bests"), symbol: "figure.run", tint: ForgeColor.effort, target: .tab(.cardio)),
                    FocusLink(title: String(localized: "Strength"), subtitle: String(localized: "Volume, sessions and muscles"), symbol: "dumbbell.fill", tint: ForgeColor.rest, target: .forge(.strength)),
                    FocusLink(title: String(localized: "Training load"), subtitle: String(localized: "Both lanes against your usual"), symbol: "chart.bar.fill", tint: ForgeColor.effort, target: .tab(.trainingLoad)),
                    FocusLink(title: String(localized: "Workouts"), subtitle: String(localized: "Thirteen weeks at a glance"), symbol: "calendar", tint: ForgeColor.effort, target: .forge(.workouts))]
        case .sleep:
            return [FocusLink(title: String(localized: "Sleep details"), subtitle: String(localized: "Every night, stages and history"), symbol: "bed.double.fill", tint: ForgeColor.rest, target: .tab(.sleep)),
                    FocusLink(title: String(localized: "Smart alarm"), subtitle: String(localized: "Wake window and wind-down"), symbol: "alarm.fill", tint: ForgeColor.rest, target: .more(.alarms))]
        case .vitals:
            return [FocusLink(title: String(localized: "Heart rate"), subtitle: String(localized: "The whole day, beat by beat"), symbol: "waveform.path.ecg", tint: .red, target: .tab(.fullDayChart)),
                    FocusLink(title: String(localized: "ECG"), subtitle: String(localized: "Saved readings"), symbol: "heart.text.square.fill", tint: .pink, target: .more(.ecg)),
                    FocusLink(title: String(localized: "Heart rhythm"), subtitle: String(localized: "Beat to beat, experimental"), symbol: "waveform.path", tint: .pink, target: .more(.rhythm))]
        case .body:
            return [FocusLink(title: String(localized: "Weight"), subtitle: String(localized: "Weigh-ins and trend"), symbol: "scalemass.fill", tint: .indigo, target: .tab(.weight)),
                    FocusLink(title: String(localized: "Body"), subtitle: String(localized: "Measurements and composition"), symbol: "figure.stand", tint: .teal, target: .more(.body)),
                    FocusLink(title: String(localized: "Energy"), subtitle: String(localized: "Burned and eaten"), symbol: "flame.fill", tint: .orange, target: .tab(.energy)),
                    FocusLink(title: String(localized: "Water"), subtitle: String(localized: "Today and the last week"), symbol: "drop.fill", tint: .blue, target: .tab(.hydration)),
                    FocusLink(title: String(localized: "Health records"), subtitle: String(localized: "Blood tests, blood pressure, measurements"), symbol: "testtube.2", tint: .purple, target: .more(.labBook))]
                + (!cycleHidden && (cycleEnabled || profile.cycleAwarenessApplies)
                   ? [FocusLink(title: String(localized: "Cycle"), subtitle: String(localized: "Phase, period and your nights"), symbol: "drop.circle.fill", tint: ForgeColor.cyclePeriod, target: .forge(.cycle))]
                   : [])
        case .mind:
            return [FocusLink(title: String(localized: "Stress"), subtitle: String(localized: "Through the day"), symbol: "bolt.heart.fill", tint: .orange, target: .tab(.stress)),
                    FocusLink(title: String(localized: "Breathe"), subtitle: String(localized: "Guided breathing"), symbol: "wind", tint: .teal, target: .more(.breathe)),
                    FocusLink(title: String(localized: "What works"), subtitle: String(localized: "What helps you, what hurts you"), symbol: "lightbulb.fill", tint: .yellow, target: .more(.insightsHub)),
                    FocusLink(title: String(localized: "Journal"), subtitle: String(localized: "Habits and experiments"), symbol: "book.closed.fill", tint: .brown, target: .more(.insights)),
                    FocusLink(title: String(localized: "Momentum"), subtitle: String(localized: "What matters most right now"), symbol: "bolt.horizontal", tint: .orange, target: .more(.momentum))]
        case .more:
            var out = [FocusLink(title: String(localized: "Trends"), subtitle: String(localized: "Charge, Effort and Rest over months"), symbol: "chart.line.uptrend.xyaxis", tint: ForgeColor.charge, target: .tab(.trends)),
                       FocusLink(title: String(localized: "All metrics"), subtitle: String(localized: "Every metric, compare freely"), symbol: "square.grid.2x2.fill", tint: .blue, target: .tab(.metricExplorer)),
                       FocusLink(title: String(localized: "Compare"), subtitle: String(localized: "Two metrics side by side"), symbol: "arrow.left.arrow.right", tint: .blue, target: .more(.compare)),
                       FocusLink(title: String(localized: "Daily rhythm"), subtitle: String(localized: "Your rhythm age from movement over the day"), symbol: "sun.and.horizon", tint: ForgeColor.charge, target: .more(.rhythmAge))]
            if healthspanEnabled {
                out.insert(FocusLink(title: "AgeLess", subtitle: String(localized: "Your health age"), symbol: "hourglass", tint: .mint, target: .forge(.ageless)), at: 0)
            }
            return out
        }
    }
}

/// One focus tile on the Health tab: the area's symbol, name and what it holds.
struct ForgeFocusTile: View {
    let area: ForgeFocusArea

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: area.symbol)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(area.tint)
                .frame(width: 40, height: 40)
                .background(Circle().fill(area.tint.opacity(ForgeOpacity.wash)))
            Text(area.title).font(.system(.callout, weight: .semibold)).foregroundStyle(ForgeColor.text)
                .lineLimit(2).multilineTextAlignment(.leading)
            Text(area.subtitle).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                .lineLimit(2).multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .forgeCard(radius: ForgeRadius.card, padding: 14)
        .accessibilityElement(children: .combine)
    }
}
#endif
