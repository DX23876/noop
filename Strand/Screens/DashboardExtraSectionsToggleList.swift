import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// The complete opt-in catalogue for the two dashboard styles. The same controls appear in Settings
/// and in `DashboardExtraSectionsSheet`, which each dashboard opens from a long-press on its wordmark.
struct DashboardExtraSectionsToggleList: View {
    /// "trends" or "overview" — keeps each dashboard's on/off state independent.
    let dashboard: String

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
            ForEach(DashboardExtraSection.allCases) { section in
                ExtraSectionToggleRow(section: section, dashboard: dashboard)
            }
        }
    }
}

private struct ExtraSectionToggleRow: View {
    let section: DashboardExtraSection
    @AppStorage private var isOn: Bool

    init(section: DashboardExtraSection, dashboard: String) {
        self.section = section
        _isOn = AppStorage(wrappedValue: false, DashboardExtraSection.storageKey(section, dashboard: dashboard))
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(section.label)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(section.detail)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .appleInspiredTint("settings.controls")
    }
}

/// The dashboard-native host for `DashboardExtraSectionsToggleList`, opened from either dashboard's
/// wordmark long-press. Settings embeds the same list directly rather than duplicating its rows.
struct DashboardExtraSectionsSheet: View {
    let dashboard: String
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DashboardLayoutEditor(dashboard: dashboard, title: title, onDone: { dismiss() })
    }
}

/// Shared editor for the long-press sheet and Settings. It replaces a toggle-only model with a proper
/// shown/hidden layout list, so the reference blocks and optional blocks are both reorderable.
struct DashboardLayoutEditor: View {
    @Environment(\.dismiss) private var dismiss
    let dashboard: String
    let title: String
    var onDone: (() -> Void)? = nil
    @AppStorage private var orderRaw: String
    @AppStorage private var hiddenRaw: String
    @State private var draft: EditableLayoutDraft<DashboardLayoutSection>

    init(dashboard: String, title: String = String(localized: "Dashboard sections"), onDone: (() -> Void)? = nil) {
        self.dashboard = dashboard
        self.title = title
        self.onDone = onDone
        _orderRaw = AppStorage(wrappedValue: "", DashboardLayoutPrefs.orderKey(dashboard))
        _hiddenRaw = AppStorage(wrappedValue: "", DashboardLayoutPrefs.hiddenKey(dashboard))
        let order = DashboardLayoutPrefs.order("", dashboard: dashboard)
        let hidden = DashboardLayoutPrefs.hidden("", dashboard: dashboard)
        _draft = State(initialValue: EditableLayoutDraft(visible: order.filter { !hidden.contains($0) }, hidden: order.filter { hidden.contains($0) }))
    }

    var body: some View {
        NavigationStack {
            EditableLayoutList(
                draft: $draft,
                shownTitle: String(localized: "Shown"),
                hiddenTitle: String(localized: "Hidden"),
                title: \.title,
                subtitle: { $0.isExtra ? String(localized: "Optional") : nil },
                icon: \.icon,
                tint: { $0.isExtra ? StrandPalette.accent : StrandPalette.textSecondary },
                configurationLabel: { _ in nil },
                onConfigure: { _ in },
                onReset: reset
            ) {
                Section("Cards") {
                    DashboardCardSelectionEditor()
                    HostedCardSelectionEditor()
                    if dashboard == "overview" {
                        NavigationLink { OverviewFocusEditor() } label: {
                            Label("Configure today's focus", systemImage: "rectangle.3.group")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        }
                        NavigationLink { OverviewHealthCardsEditor() } label: {
                            Label("Configure health metrics", systemImage: "heart.text.square")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: save).foregroundStyle(StrandPalette.accent) }
            }
        }
        .onAppear { loadDraft() }
    }

    private func loadDraft() {
        let order = DashboardLayoutPrefs.order(orderRaw, dashboard: dashboard)
        let hidden = DashboardLayoutPrefs.hidden(hiddenRaw, dashboard: dashboard)
        draft = EditableLayoutDraft(visible: order.filter { !hidden.contains($0) }, hidden: order.filter { hidden.contains($0) })
    }
    private func save() {
        orderRaw = DashboardLayoutPrefs.encode(draft.visible + draft.hidden)
        hiddenRaw = DashboardLayoutPrefs.encodeHidden(draft.hidden)
        if let onDone { onDone() } else { dismiss() }
    }
    private func reset() {
        let order = DashboardLayoutSection.defaultOrder(for: dashboard)
        let hidden = Set(order.filter(\.isExtra))
        draft = EditableLayoutDraft(visible: order.filter { !hidden.contains($0) }, hidden: order.filter { hidden.contains($0) })
    }
}

private struct OverviewFocusEditor: View {
    @AppStorage(OverviewFocusPrefs.slotKeys[0]) private var first = OverviewFocusPrefs.defaults[0].rawValue
    @AppStorage(OverviewFocusPrefs.slotKeys[1]) private var second = OverviewFocusPrefs.defaults[1].rawValue
    @AppStorage(OverviewFocusPrefs.slotKeys[2]) private var third = OverviewFocusPrefs.defaults[2].rawValue
    var body: some View {
        Form {
            Section {
                focusPicker("Tile 1", index: 0)
                focusPicker("Tile 2", index: 1)
                focusPicker("Tile 3", index: 2)
            } header: {
                Text("Today's focus")
            } footer: {
                Text("Choose the three compact cards shown at the top of Overview.")
            }
        }
        .navigationTitle("Today's focus")
    }
    private var values: [String] {
        get { [first, second, third] }
        nonmutating set { first = newValue[0]; second = newValue[1]; third = newValue[2] }
    }
    private func focusPicker(_ title: String, index: Int) -> some View {
        Picker(title, selection: Binding(get: { values[index] }, set: { newValue in
            var next = values
            let oldValue = next[index]
            if let duplicate = next.indices.first(where: { $0 != index && next[$0] == newValue }) {
                next[duplicate] = oldValue
            }
            next[index] = newValue
            values = next
        })) {
            ForEach(OverviewFocusItem.allCases) { Text($0.title).tag($0.rawValue) }
        }
    }
}

private struct OverviewHealthCardsEditor: View {
    @AppStorage(OverviewHealthCardsPrefs.selectionKey) private var raw = ""
    @State private var draft = EditableLayoutDraft(visible: OverviewHealthCardsPrefs.defaultSelection,
                                                   allItems: OverviewHealthCardsPrefs.available)
    var body: some View {
        EditableLayoutList(draft: $draft,
                           shownTitle: String(localized: "Shown"), hiddenTitle: String(localized: "Hidden"),
                           title: \.title, subtitle: { _ in nil }, icon: \.icon,
                           tint: { TrendsMetricStrip.tint($0) }, configurationLabel: { _ in nil },
                           onConfigure: { _ in }, onReset: reset, allowEmpty: false) { EmptyView() }
            .navigationTitle("Health metrics")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: save) } }
            .onAppear { draft = EditableLayoutDraft(visible: OverviewHealthCardsPrefs.decode(raw), allItems: OverviewHealthCardsPrefs.available) }
            .onDisappear(perform: save)
    }
    private func save() { raw = OverviewHealthCardsPrefs.encode(draft.visible) }
    private func reset() { draft = EditableLayoutDraft(visible: OverviewHealthCardsPrefs.defaultSelection, allItems: OverviewHealthCardsPrefs.available) }
}

// MARK: - Dashboard-native supplemental sections

/// Optional Today capabilities shared by Trends and Overview. This deliberately reads Today’s stores and
/// preferences, but it never embeds a Today/Liquid card: every row uses the compact Noop dashboard chrome.
struct DashboardSupplementSections: View {
    let dashboard: String
    let compact: Bool
    let day: DailyMetric?
    let appleDay: AppleDaily?
    let dayKey: String
    let isToday: Bool
    let only: DashboardLayoutSection?
    /// The host dashboard's already-resolved read-out for a card.
    ///
    /// This used to re-query all seven of the expensive derived series (fitness age, VO2 max, vitality,
    /// stress, hydration, energy, weight) for itself — the exact set the host dashboard's own `load()`
    /// had just finished resolving. Worse, the host renders ONE of these per visible section (`only:`),
    /// so enabling "Your cards", "More metrics" and "Recovery vitals" together ran that whole set three
    /// more times per load. Threading the host's resolver in removes every one of those repeats and
    /// guarantees the two surfaces cannot print different numbers for the same card and day.
    let resolvedValue: (DashboardCard) -> String

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var router: NavRouter
    @ObservedObject private var momentum = MomentumStore.shared
    @AppStorage(DashboardCardPrefs.selectionKey) private var dashboardCardsRaw = ""
    @AppStorage(HostedCardPrefs.selectionKey) private var hostedCardsRaw = ""
    @State private var showLiveSession = false
    @State private var showMomentumSheet = false
    @State private var dayHr: [Double] = []

    init(dashboard: String, compact: Bool, day: DailyMetric?, appleDay: AppleDaily?,
         dayKey: String, isToday: Bool, only: DashboardLayoutSection? = nil,
         resolvedValue: @escaping (DashboardCard) -> String) {
        self.dashboard = dashboard
        self.compact = compact
        self.day = day
        self.appleDay = appleDay
        self.dayKey = dayKey
        self.isToday = isToday
        self.only = only
        self.resolvedValue = resolvedValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : NoopMetrics.sectionSpacing) {
            if includes(.liveSession) { liveSessionSection }
            if includes(.momentum) { momentumSection }
            if includes(.keyMetrics) { metricsSection }
            if includes(.heartRate) { heartRateSection }
            if includes(.recoveryVitals) { recoverySection }
            if includes(.yourCards) { yourCardsSection }
            if includes(.dataSources) { sourcesSection }
            if includes(.addedCards) { hostedCardsSection }
        }
        .task(id: "\(dayKey)-\(only?.rawValue ?? "all")") { await loadHeartRate() }
        .liveSessionCover(isPresented: $showLiveSession)
        .sheet(isPresented: $showMomentumSheet) { NavigationStack { MomentumScreen() } }
    }

    private func includes(_ section: DashboardLayoutSection) -> Bool {
        guard only == nil || only == section else { return false }
        if !isToday, [.liveSession, .momentum, .addedCards].contains(section) { return false }
        return true
    }

    private var cardPadding: CGFloat { compact ? 12 : NoopMetrics.cardPadding }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : NoopMetrics.gap) {
            Text(title).font(compact ? StrandFont.overline : StrandFont.headline)
                .tracking(compact ? StrandFont.overlineTracking : 0)
                .foregroundStyle(compact ? StrandPalette.textSecondary : StrandPalette.textPrimary)
            content()
        }
    }

    private var liveSessionSection: some View {
        section("Live session") {
            Button { showLiveSession = true } label: {
                NoopCard(padding: cardPadding, tint: StrandPalette.metricCyan) {
                    HStack(spacing: 10) {
                        Image(systemName: "shield.lefthalf.filled").foregroundStyle(StrandPalette.metricCyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start session").font(StrandFont.subhead.weight(.semibold))
                            Text("Silent strap coaching against today's Charge.").font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer(); Image(systemName: "chevron.right").foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private var momentumSection: some View {
        section("Momentum") {
            if let message = momentum.messages.first {
                MomentumCard(message: message, remainingCount: max(0, momentum.messages.count - 1),
                             onOpenMore: { showMomentumSheet = true }, onAction: { _ in showMomentumSheet = true })
            } else {
                NavigationLink { MomentumScreen() } label: {
                    NoopCard(padding: cardPadding, tint: StrandPalette.chargeColor) {
                        HStack { Image(systemName: "sparkles").foregroundStyle(StrandPalette.chargeColor)
                            Text("Open Momentum for today's recommendations").font(StrandFont.subhead)
                            Spacer(); Image(systemName: "chevron.right").foregroundStyle(StrandPalette.textTertiary) }
                    }
                }.buttonStyle(.plain)
            }
        }
    }

    private var metricsSection: some View {
        section("More metrics") {
            NoopCard(padding: cardPadding) {
                VStack(spacing: 0) {
                    metricRow(.respiratory); Divider().overlay(StrandPalette.hairline)
                    metricRow(.bloodOxygen); Divider().overlay(StrandPalette.hairline)
                    metricRow(.skinTemp); Divider().overlay(StrandPalette.hairline)
                    metricRow(.stress)
                }
            }
        }
    }

    private var recoverySection: some View {
        section("Recovery vitals") {
            NoopCard(padding: cardPadding) {
                VStack(spacing: 0) {
                    metricRow(.hrv); Divider().overlay(StrandPalette.hairline)
                    metricRow(.restingHr); Divider().overlay(StrandPalette.hairline)
                    metricRow(.respiratory); Divider().overlay(StrandPalette.hairline)
                    metricRow(.bloodOxygen)
                }
            }
        }
    }

    private func metricRow(_ card: DashboardCard) -> some View {
        NavigationLink(value: card.detailRoute(day: day, appleDay: appleDay)) {
            HStack(spacing: 8) {
                Image(systemName: card.icon).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TrendsMetricStrip.tint(card)).frame(width: 20)
                Text(card.title).font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(resolvedValue(card))
                    .font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                if !card.unit.isEmpty { Text(card.unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary) }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(StrandPalette.textTertiary)
            }.padding(.vertical, compact ? 5 : 7)
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var heartRateSection: some View {
        section("Heart rate") {
            NavigationLink(value: TabRoute.fullDayChart) {
                NoopCard(padding: cardPadding, tint: StrandPalette.metricRose) {
                    HStack(spacing: 10) {
                        Image(systemName: "heart.fill").foregroundStyle(StrandPalette.metricRose)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dayHr.last.map { "\(Int($0.rounded())) bpm" } ?? String(localized: "No heart rate yet"))
                                .font(StrandFont.subhead.weight(.semibold))
                            Text("Today's heart-rate timeline").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer()
                        if dayHr.count > 2 { Sparkline(values: dayHr, gradient: Gradient(colors: [StrandPalette.metricRose]), lineWidth: 1.5, showsArea: false, showsHover: false).frame(width: compact ? 70 : 100, height: 28) }
                        Image(systemName: "chevron.right").foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private var yourCardsSection: some View {
        let cards = DashboardCardPrefs.decodeEnabled(dashboardCardsRaw)
        section("Your cards") {
            NoopCard(padding: cardPadding) { VStack(spacing: 0) { ForEach(cards) { card in metricRow(card); if card != cards.last { Divider().overlay(StrandPalette.hairline) } } } }
        }
    }

    private var sourcesSection: some View {
        section("Data sources") {
            NavigationLink(value: TabRoute.dataSources) {
                NoopCard(padding: cardPadding) {
                    HStack { Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(StrandPalette.metricCyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Data sources").font(StrandFont.subhead.weight(.semibold))
                            Text(String(format: String(localized: "%lld synced days"),
                                        locale: AppLanguage.activeLocale, Int64(repo.days.count)))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer(); Image(systemName: "chevron.right").foregroundStyle(StrandPalette.textTertiary) }
                }
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private var hostedCardsSection: some View {
        let cards = HostedCardPrefs.decodeEnabled(hostedCardsRaw)
        if !cards.isEmpty {
            section("Added cards") {
                NoopCard(padding: cardPadding) {
                    VStack(spacing: 0) { ForEach(cards) { card in
                        NavigationLink(value: TabRoute.sleep) { HStack { Image(systemName: card.customizationIcon).foregroundStyle(StrandPalette.restColor).frame(width: 20); Text(card.title).font(StrandFont.footnote); Spacer(); Text(card.origin).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary); Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(StrandPalette.textTertiary) }.padding(.vertical, compact ? 5 : 7) }.buttonStyle(.plain)
                        if card != cards.last { Divider().overlay(StrandPalette.hairline) }
                    } }
                }
            }
        }
    }

    private func loadHeartRate() async {
        guard includes(.heartRate) else { dayHr = []; return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        guard let date = formatter.date(from: dayKey) else { dayHr = []; return }
        let start = Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
        let end = isToday ? Int(Date().timeIntervalSince1970) : start + 86_400
        dayHr = await repo.hrSamples(from: start, to: end, limit: 160).map { Double($0.bpm) }
    }
}

/// Selection management is deliberately only exposed in dashboard configuration, never as a visible
/// edit affordance on either reference-matched dashboard.
///
/// This was a flat list of on/off toggles, which made the "Your cards" list the one editable surface on
/// these dashboards you could not actually arrange: a card could be added or removed, never moved, so the
/// order was whatever order it happened to be toggled in. The Overview health list next to it has had a
/// proper shown/hidden editor all along — this now uses the same one (`EditableLayoutList`), so both
/// behave alike and the stored order means what it looks like.
struct DashboardCardSelectionEditor: View {
    @AppStorage(DashboardCardPrefs.selectionKey) private var raw = ""
    var body: some View {
        NavigationLink {
            DashboardCardArrangeList(raw: $raw)
        } label: {
            Label("Manage your cards", systemImage: "rectangle.grid.2x2")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
        }
    }
}

private struct DashboardCardArrangeList: View {
    @Binding var raw: String
    @State private var draft = EditableLayoutDraft(visible: DashboardCard.defaultSelection,
                                                   allItems: DashboardCard.canonicalOrder)

    var body: some View {
        EditableLayoutList(draft: $draft,
                           shownTitle: String(localized: "Shown"), hiddenTitle: String(localized: "Hidden"),
                           title: \.title, subtitle: { _ in nil }, icon: \.icon,
                           tint: { TrendsMetricStrip.tint($0) }, configurationLabel: { _ in nil },
                           onConfigure: { _ in }, onReset: reset, allowEmpty: false) { EmptyView() }
            .navigationTitle("Your cards")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: save) } }
            .onAppear {
                draft = EditableLayoutDraft(visible: DashboardCardPrefs.decodeEnabled(raw),
                                            allItems: DashboardCard.canonicalOrder)
            }
            // Saved on the way out as well as on Done: a swipe-back is a normal way to leave a pushed
            // screen, and losing the arrangement to it would read as the editor not working at all.
            .onDisappear(perform: save)
    }

    private func save() { raw = DashboardCardPrefs.encode(draft.visible) }
    private func reset() {
        draft = EditableLayoutDraft(visible: DashboardCard.defaultSelection,
                                    allItems: DashboardCard.canonicalOrder)
    }
}

struct HostedCardSelectionEditor: View {
    @AppStorage(HostedCardPrefs.selectionKey) private var raw = ""
    var body: some View { NavigationLink { selectionList } label: { Label("Manage added cards", systemImage: "moon.stars").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary) } }
    private var selectionList: some View { List { ForEach(HostedCard.allCases) { card in Toggle(card.title, isOn: binding(card)) } }.navigationTitle("Added cards") }
    private func binding(_ card: HostedCard) -> Binding<Bool> { Binding(get: { HostedCardPrefs.decodeEnabled(raw).contains(card) }, set: { enabled in var cards = HostedCardPrefs.decodeEnabled(raw); if enabled { if !cards.contains(card) { cards.append(card) } } else { cards.removeAll { $0 == card } }; raw = HostedCardPrefs.encode(cards) }) }
}
