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
    /// The strap's own nightly blood-oxygen estimate, read the way Today reads it.
    @State private var spo2CandidateByDay: [String: Double] = [:]
    @State private var weightKg: Double?
    @State private var weightChange30d: Double?
    @State private var restByDay: [String: Double] = [:]
    @State private var energyKcal: Double?
    @ObservedObject private var tileStore = ForgeVitalTileStore.shared
    @AppStorage(ForgeVitalTileStore.columnsKey) private var tileColumnsRaw = 2
    @State private var editingTiles = false
    @State private var tilePick: ForgeVitalTilePick?
    /// Every vital the resolver knows, empty ones included: a chosen tile shows "–" rather than vanishing.
    private var allReadings: [BodyVitalReading] {
        BodyVitalSigns.readings(
            sourceRows: repo.vitalMetricRows,
            temperatureUnit: UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw),
            spo2CandidateByDay: spo2CandidateByDay,
            hrvOverCountByDay: hrvOverCountByDay,
            skinTempPreferred: SkinTempDisplay.Kind(rawValue: skinTempDisplayRaw) ?? .absolute)
    }

    private var readings: [BodyVitalReading] {
        allReadings
            // The raw optical reading is an experimental instrument; an empty one is noise on this tab.
            .filter { !($0.key == "spo2raw" && $0.value == nil) }
            // The prototype's order: HRV, resting heart rate, blood oxygen, breathing, then the rest.
            .sorted { Self.order($0.key) < Self.order($1.key) }
    }

    private func vitalTile(_ r: BodyVitalReading, compact: Bool = false) -> some View {
        NavigationLink(value: TabRoute.metric(r.key == "spo2raw" ? "spo2" : r.key)) {
            // Three to a row leave no room for the state words; the hero above still names what is out.
            ForgeMetricTile(label: compact ? r.label : Self.plainLabel(r), value: r.value.map(r.format), unit: r.unit,
                            trend: r.sparkline, tint: r.metricColor,
                            badge: compact ? nil : badge(r), minHeight: compact ? 96 : 132)
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
        ["hrv", "rhr", "spo2", "resp", "skin", "spo2raw"].firstIndex(of: key) ?? 99
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
                                            // In range reads green, as a check means "fine"; black said nothing.
                                            .foregroundStyle(ok ? ForgeColor.charge : ForgeColor.effortInk)
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

                        ForgeSectionTitle(title: "Vitals", action: editingTiles ? nil : (label: "Edit", run: {
                            withAnimation(.snappy) { editingTiles = true }
                        }))
                        vitalTiles(readings)

                        // The cycle at a glance, only while cycle tracking is on.
                        ForgeCycleSummaryCard()

                        ForgeSectionTitle(title: "Focus areas")
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
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
        .overlay { ForgeStatusBarScrim(tab: .health) }
        .refreshable { await repo.refresh() }
        .sheet(item: $tilePick) { pick in tilePicker(pick) }
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
            .forgeCard(radius: ForgeRadius.card, padding: 14)
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
                    .background(RoundedRectangle(cornerRadius: ForgeRadius.inner, style: .continuous).fill(ForgeColor.card))
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
        .forgeCard(radius: ForgeRadius.card, padding: 16)
    }

    /// The strap's blood-oxygen figure is an estimate, not a calibrated reading, and the tile says so.
    private func badge(_ r: BodyVitalReading) -> (text: String, tone: ForgeBadge.Tone) {
        if Self.isEstimate(r) { return (String(localized: "Estimated"), .neutral) }
        return (r.stateText, badgeTone(r))
    }

    /// A blood-oxygen value NOOP resolved itself is the strap's estimate: a calibrated one only arrives by import.
    static func isEstimate(_ r: BodyVitalReading) -> Bool {
        r.key == "spo2" && r.value != nil && r.source == .noopComputed
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
        let cand = await repo.exploreSeries(key: "spo2_candidate", source: "my-whoop", days: 30)
        spo2CandidateByDay = Dictionary(cand.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
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
    /// AgeLess on Health: the top of its page only, opening the full page (`ForgeAgeLessSummary`).
    var agelessCard: some View { ForgeAgeLessSummary(week: healthspan) }
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

#if os(iOS)
extension ForgeHealthView {
    private var tileColumns: Int { KeyMetricPrefs.columns(tileColumnsRaw) }

    /// The tiles before the wearer chose any: the night's vitals in the prototype's order.
    private func defaultTiles(_ readings: [BodyVitalReading]) -> [ForgeVitalTile] {
        readings.compactMap { ForgeVitalTile(rawValue: $0.key) }
    }

    /// The tiles on show: AgeLess only while AgeLess is switched on.
    private func shownTiles(_ readings: [BodyVitalReading]) -> [ForgeVitalTile] {
        tileStore.tiles(default: defaultTiles(readings)).filter { $0 != .ageless || healthspanEnabled }
    }

    private func offeredTiles() -> [ForgeVitalTile] {
        ForgeVitalTile.allCases.filter { $0 != .ageless || healthspanEnabled }
    }

    func tileTitle(_ t: ForgeVitalTile) -> String {
        if let r = allReadings.first(where: { $0.key == t.rawValue }) {
            return t == .spo2raw ? r.label : Self.plainLabel(r)
        }
        switch t {
        case .ageless: return "AgeLess"
        case .vo2max: return String(localized: "VO₂ Max")
        case .weight: return String(localized: "Weight")
        case .stress: return String(localized: "Stress")
        case .steps: return String(localized: "Steps")
        default: return t.rawValue
        }
    }

    /// Rows of two or three; a short last row stretches its tiles instead of leaving a hole.
    @ViewBuilder func vitalTiles(_ readings: [BodyVitalReading]) -> some View {
        let tiles = shownTiles(readings)
        let current = tileStore.tiles(default: defaultTiles(readings))
        let rows = stride(from: 0, to: tiles.count, by: tileColumns).map { Array(tiles[$0..<min($0 + tileColumns, tiles.count)]) }
        VStack(alignment: .leading, spacing: 10) {
            if editingTiles {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Edit Vitals").font(.system(.headline)).foregroundStyle(ForgeColor.text)
                        Spacer()
                        Button { withAnimation(.snappy) { editingTiles = false } } label: {
                            Text("Done").font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.onAccent)
                                .padding(.horizontal, 16).frame(minHeight: 36)
                                .background(Capsule().fill(ForgeColor.accent))
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Tap a tile to swap it, drag to reorder. Up to nine tiles.")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tiles per row").font(.system(.footnote, weight: .semibold)).foregroundStyle(ForgeColor.secondary)
                        Picker("Tiles per row", selection: Binding(get: { tileColumns }, set: { tileColumnsRaw = $0 })) {
                            ForEach(KeyMetricPrefs.columnChoices, id: \.self) { Text(verbatim: "\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(ForgeColor.card))
            }
            ForEach(rows, id: \.first!.id) { row in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(row) { t in tileCell(t, readings: readings, current: current) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if editingTiles && current.count < ForgeVitalTileStore.maxTiles {
                Button { tilePick = .add } label: {
                    Label("Add a tile", systemImage: "plus.circle.fill")
                        .font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.accent)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(ForgeColor.card))
                }
                .buttonStyle(.plain)
            }
        }
        .sensoryFeedback(.impact, trigger: editingTiles)
    }

    @ViewBuilder private func tileContent(_ t: ForgeVitalTile) -> some View {
        let compact = tileColumns > 2
        if t.isVital {
            if let r = allReadings.first(where: { $0.key == t.rawValue }) {
                vitalTile(r, compact: compact)
            } else {
                ForgeMetricTile(label: tileTitle(t), value: nil, unit: "", minHeight: compact ? 96 : 132)
            }
        } else if t == .ageless {
            NavigationLink(value: ForgeRoute.ageless) {
                ForgeMetricTile(label: "AgeLess",
                                value: healthspan.map { HealthspanSection.years($0.result.healthspanAge) },
                                unit: String(localized: "years"),
                                tint: ForgeColor.accent,
                                badge: compact ? nil : healthspan.map {
                                    let younger = $0.result.healthspanAge <= $0.result.chronologicalAge
                                    return (String(localized: "Age \(HealthspanSection.years($0.result.chronologicalAge))"),
                                            younger ? .good : .attention)
                                },
                                minHeight: compact ? 96 : 132)
            }
            .buttonStyle(LiquidPressStyle())
        } else if let m = t.measure {
            ForgeHealthMeasureTile(key: m.key, source: m.source, label: tileTitle(t), compact: compact)
        }
    }

    @ViewBuilder private func tileCell(_ t: ForgeVitalTile, readings: [BodyVitalReading], current: [ForgeVitalTile]) -> some View {
        let content = tileContent(t).frame(maxWidth: .infinity)
        if editingTiles {
            content
                .allowsHitTesting(false)
                .overlay {
                    // The whole tile swaps it; the badge in the corner removes it.
                    Color.clear.contentShape(Rectangle()).onTapGesture { tilePick = .replace(t) }
                }
                .overlay(alignment: .topLeading) {
                    Button {
                        withAnimation(.snappy) { tileStore.set(current.filter { $0 != t }) }
                    } label: {
                        Image(systemName: "minus.circle.fill").font(.title2)
                            .symbolRenderingMode(.palette).foregroundStyle(.white, ForgeColor.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .offset(x: -14, y: -14)
                    .accessibilityLabel(Text("Remove tile"))
                }
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: Text("Swap")) { tilePick = .replace(t) }
                .accessibilityAction(named: Text("Move earlier")) { shiftTile(t, by: -1, current: current) }
                .accessibilityAction(named: Text("Move later")) { shiftTile(t, by: 1, current: current) }
                .draggable(t.rawValue)
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, let moved = ForgeVitalTile(rawValue: raw), moved != t else { return false }
                    var list = current.filter { $0 != moved }
                    list.insert(moved, at: list.firstIndex(of: t) ?? list.count)
                    withAnimation(.snappy) { tileStore.set(list) }
                    return true
                }
        } else {
            // Held, a tile starts the editor, as on Today; a plain tap still opens its page.
            content
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    withAnimation(.snappy) { editingTiles = true }
                })
                .accessibilityAction(named: Text("Edit Vitals")) { editingTiles = true }
        }
    }

    private func shiftTile(_ t: ForgeVitalTile, by delta: Int, current: [ForgeVitalTile]) {
        guard let from = current.firstIndex(of: t), current.indices.contains(from + delta) else { return }
        var list = current
        list.swapAt(from, from + delta)
        tileStore.set(list)
    }

    func tilePicker(_ pick: ForgeVitalTilePick) -> some View {
        let current = tileStore.tiles(default: defaultTiles(readings))
        return ForgeVitalTilePicker(pick: pick, placed: current, offered: offeredTiles(), title: tileTitle) { chosen in
            withAnimation(.snappy) {
                switch pick {
                case .add:
                    tileStore.set(current + [chosen])
                case .replace(let old):
                    tileStore.set(current.map { $0 == old ? chosen : $0 })
                }
            }
        }
    }
}
#endif
