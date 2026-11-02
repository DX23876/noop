#if os(iOS)
import SwiftUI
import StrandDesign

/// The redesign's one search (prototype board "Search"): metrics, screens and settings in one list, with
/// the last searches kept on this iPhone. Metrics come from `MetricCatalog`, settings from
/// `SettingsSearchCatalog`; the screen index below is the redesign's own map of where things live.
struct ForgeSearchView: View {
    @State private var query = ""
    @AppStorage("forge.search.recent") private var recentRaw = ""
    @FocusState private var focused: Bool
    @State private var scrolledPast = false

    /// Where a screen result goes. Each case pushes the value its stack already knows.
    enum Target: Hashable {
        case forge(ForgeRoute)
        case tab(TabRoute)
        case more(MoreDestination)
    }

    struct Screen: Identifiable {
        let title: String
        let place: String
        let symbol: String
        let target: Target
        let keywords: [String]
        var id: String { title }
    }

    /// Every screen the redesign reaches, by the words a person would type. Titles are the screens' own.
    static var screens: [Screen] {
        let training = String(localized: "Training"), health = String(localized: "Health"), profile = String(localized: "Profile")
        return [
            Screen(title: String(localized: "Workouts"), place: training, symbol: "figure.run", target: .forge(.workouts), keywords: ["sessions", "history", "activity"]),
            Screen(title: String(localized: "Strength"), place: training, symbol: "dumbbell.fill", target: .forge(.strength), keywords: ["lifting", "gym", "volume", "routine"]),
            Screen(title: String(localized: "Muscles"), place: training, symbol: "figure.strengthtraining.traditional", target: .forge(.muscles), keywords: ["body map", "fatigue", "balance", "soreness"]),
            Screen(title: String(localized: "This week's plan"), place: training, symbol: "calendar", target: .forge(.weekPlan), keywords: ["plan", "schedule", "week"]),
            Screen(title: String(localized: "Goals"), place: training, symbol: "flag.fill", target: .tab(.goals), keywords: ["target", "milestone"]),
            Screen(title: String(localized: "Endurance"), place: training, symbol: "figure.run", target: .tab(.cardio), keywords: ["cardio", "running", "pace", "ride"]),
            Screen(title: String(localized: "Training load"), place: training, symbol: "chart.bar.fill", target: .tab(.trainingLoad), keywords: ["load", "injury", "acute"]),
            Screen(title: String(localized: "Interval timer"), place: training, symbol: "timer", target: .more(.intervals), keywords: ["intervals", "rounds", "rest timer"]),
            Screen(title: String(localized: "Live heart rate"), place: training, symbol: "heart.fill", target: .more(.live), keywords: ["live", "zones", "bpm"]),
            Screen(title: String(localized: "Breathe"), place: health, symbol: "wind", target: .more(.breathe), keywords: ["breathing", "calm", "relax"]),
            Screen(title: String(localized: "Stress"), place: health, symbol: "waveform.path.ecg", target: .tab(.stress), keywords: ["tension", "calm"]),
            Screen(title: String(localized: "ECG"), place: health, symbol: "waveform.path.ecg.rectangle", target: .more(.ecg), keywords: ["ekg", "rhythm", "heart"]),
            Screen(title: String(localized: "Body"), place: health, symbol: "figure.arms.open", target: .more(.body), keywords: ["photos", "waist", "measurements", "blood pressure"]),
            Screen(title: String(localized: "Weight"), place: health, symbol: "scalemass.fill", target: .tab(.weight), keywords: ["weigh-in", "kg", "scale"]),
            Screen(title: String(localized: "Energy"), place: health, symbol: "flame.fill", target: .tab(.energy), keywords: ["calories", "kcal", "food", "eaten"]),
            Screen(title: String(localized: "Water"), place: health, symbol: "drop.fill", target: .tab(.hydration), keywords: ["hydration", "drink"]),
            Screen(title: String(localized: "Blood tests"), place: health, symbol: "testtube.2", target: .more(.labBook), keywords: ["lab", "cholesterol", "markers", "lab book"]),
            Screen(title: "AgeLess", place: health, symbol: "hourglass", target: .more(.ageless), keywords: ["age", "healthspan", "rhythm age"]),
            Screen(title: String(localized: "The whole day"), place: health, symbol: "chart.xyaxis.line", target: .tab(.fullDayChart), keywords: ["day chart", "timeline"]),
            Screen(title: String(localized: "All metrics"), place: health, symbol: "list.bullet", target: .more(.explore), keywords: ["explore", "metrics"]),
            Screen(title: String(localized: "Compare"), place: health, symbol: "arrow.left.arrow.right", target: .more(.compare), keywords: ["correlation", "two metrics"]),
            Screen(title: String(localized: "Smart alarm"), place: String(localized: "Sleep"), symbol: "alarm.fill", target: .more(.alarms), keywords: ["alarm", "wake", "nap"]),
            Screen(title: String(localized: "Devices"), place: profile, symbol: "sensor.tag.radiowaves.forward", target: .more(.devices), keywords: ["strap", "pair", "battery", "bluetooth"]),
            Screen(title: String(localized: "Data sources"), place: profile, symbol: "square.stack.3d.up", target: .more(.dataSources), keywords: ["import", "apple health", "conflict"]),
            Screen(title: String(localized: "Backup"), place: profile, symbol: "externaldrive.fill", target: .more(.backupSync), keywords: ["restore", "export", "icloud"]),
            Screen(title: String(localized: "Automations"), place: profile, symbol: "bolt.fill", target: .more(.automations), keywords: ["shortcuts", "rules"]),
        ]
    }

    private var recents: [String] { recentRaw.split(separator: "|").map(String.init).filter { !$0.isEmpty } }

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForgeDetailHeader(overline: String(localized: "Health"), title: String(localized: "Search"), scrolledPast: $scrolledPast)
                field
                if q.isEmpty {
                    recentSection
                } else {
                    results(q)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(ForgeBackground(tab: .health))
        .forgeDetailBar(title: String(localized: "Search"), showsTitle: scrolledPast)
        .onAppear { focused = true }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(ForgeColor.secondary)
            TextField("Metrics, screens, settings", text: $query)
                .focused($focused)
                .submitLabel(.search)
                .onSubmit { remember(query) }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(ForgeColor.tertiary) }
                    .accessibilityLabel(Text("Clear search"))
            }
        }
        .font(.system(size: 17))
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ForgeColor.fill))
    }

    // MARK: Results

    @ViewBuilder private func results(_ q: String) -> some View {
        let metrics = MetricCatalog.all.filter { Self.matches(q, $0.title, [$0.category]) }.prefix(8)
        let screens = Self.screens.filter { Self.matches(q, $0.title, $0.keywords) }
        let settings = SettingsSearchCatalog.matching(q).prefix(6)
        if metrics.isEmpty && screens.isEmpty && settings.isEmpty {
            Text("Nothing found for “\(q)”.").font(ForgeFont.body).foregroundStyle(ForgeColor.secondary).padding(.horizontal, 4)
        }
        if !metrics.isEmpty {
            ForgeSectionTitle(title: "Metrics")
            ForgeGroup {
                ForEach(Array(metrics.enumerated()), id: \.element.id) { index, m in
                    if index > 0 { ForgeRowDivider() }
                    NavigationLink(value: TabRoute.metricSourced(key: m.key, source: m.source)) {
                        ForgeRow(systemImage: m.icon, tint: ForgeColor.charge, title: m.title, subtitle: m.sourceLabel)
                    }
                    .simultaneousGesture(TapGesture().onEnded { remember(q) })
                }
            }
            .buttonStyle(.plain)
        }
        if !screens.isEmpty {
            ForgeSectionTitle(title: "Screens")
            ForgeGroup {
                ForEach(Array(screens.enumerated()), id: \.element.id) { index, s in
                    if index > 0 { ForgeRowDivider() }
                    link(s.target) {
                        ForgeRow(systemImage: s.symbol, tint: ForgeColor.accent, title: s.title, subtitle: s.place)
                    }
                    .simultaneousGesture(TapGesture().onEnded { remember(q) })
                }
            }
            .buttonStyle(.plain)
        }
        if !settings.isEmpty {
            ForgeSectionTitle(title: "Settings")
            ForgeGroup {
                ForEach(Array(settings.enumerated()), id: \.offset) { index, entry in
                    if index > 0 { ForgeRowDivider() }
                    NavigationLink(value: MoreDestination.settingsSearch(q)) {
                        ForgeRow(systemImage: "gearshape.fill", tint: .gray, title: String(localized: entry.title),
                                 subtitle: String(localized: "Settings"))
                    }
                    .simultaneousGesture(TapGesture().onEnded { remember(q) })
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private func link<L: View>(_ target: Target, @ViewBuilder label: () -> L) -> some View {
        switch target {
        case .forge(let r): NavigationLink(value: r, label: label)
        case .tab(let r): NavigationLink(value: r, label: label)
        case .more(let r): NavigationLink(value: r, label: label)
        }
    }

    static func matches(_ q: String, _ title: String, _ keywords: [String]) -> Bool {
        let needle = q.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: AppLanguage.activeLocale)
        return ([title] + keywords).contains {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: AppLanguage.activeLocale).contains(needle)
        }
    }

    // MARK: Recent

    @ViewBuilder private var recentSection: some View {
        if !recents.isEmpty {
            ForgeSectionTitle(title: "Recent", action: ("Clear", { recentRaw = "" }))
            FlowRows(spacing: 8) {
                ForEach(recents, id: \.self) { r in
                    ForgeChip(title: r) { query = r }
                }
            }
        } else {
            Text("Search for a metric like HRV, a screen like Workouts, or a setting like the alarm.")
                .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary).padding(.horizontal, 4)
        }
    }

    private func remember(_ q: String) {
        let term = q.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        recentRaw = ([term] + recents.filter { $0.caseInsensitiveCompare(term) != .orderedSame }).prefix(8).joined(separator: "|")
    }
}
#endif
