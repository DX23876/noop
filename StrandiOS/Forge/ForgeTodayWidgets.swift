#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Widgets on Today (board "TodayWFew", 2026-11)
//
// Optional tiles between the rings and the timeline. None by default; the wearer adds them from a small
// gallery and reorders or removes them in place. Small tiles are measures drawn as the Health focus tiles
// draw them; wide tiles are the app's own cards (Training load, Goals, Energy), unchanged, so a widget never
// shows a number differently from the page it opens.

/// One widget the wearer placed on Today.
struct ForgeTodayWidget: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case measure, trainingLoad, goals, energy }

    var id = UUID()
    var kind: Kind
    /// For a measure: the catalog key and the preferred source.
    var key: String? = nil
    var source: String? = nil

    var isWide: Bool { kind != .measure }
}

/// The wearer's widgets, oldest first, kept as JSON in UserDefaults.
@MainActor
final class ForgeTodayWidgetStore: ObservableObject {
    static let key = "forge.today.widgets"
    static let shared = ForgeTodayWidgetStore()

    @Published private(set) var widgets: [ForgeTodayWidget] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([ForgeTodayWidget].self, from: data) {
            widgets = list
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(widgets) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func add(_ w: ForgeTodayWidget) { widgets.append(w); save() }
    func remove(_ id: UUID) { widgets.removeAll { $0.id == id }; save() }

    /// Moves `id` to the place of `target`.
    func move(_ id: UUID, before target: UUID) {
        guard id != target, let from = widgets.firstIndex(where: { $0.id == id }) else { return }
        let item = widgets.remove(at: from)
        let to = widgets.firstIndex(where: { $0.id == target }) ?? widgets.count
        widgets.insert(item, at: to)
        save()
    }

    /// Moves `id` one place up or down the list.
    func shift(_ id: UUID, by delta: Int) {
        guard let from = widgets.firstIndex(where: { $0.id == id }) else { return }
        let to = from + delta
        guard widgets.indices.contains(to) else { return }
        widgets.swapAt(from, to)
        save()
    }

    #if DEBUG
    /// `--demo-widgets` seeds the board's set for captures.
    func seedDemoIfRequested() {
        guard CommandLine.arguments.contains("--demo-widgets") else { return }
        widgets = [
            .init(kind: .measure, key: "hrv", source: Repository.whoopSource),
            .init(kind: .measure, key: "rhr", source: Repository.whoopSource),
            .init(kind: .goals),
            .init(kind: .measure, key: "weight", source: "apple-health"),
            .init(kind: .measure, key: "sleep_total_min", source: Repository.whoopSource),
            .init(kind: .trainingLoad),
        ]
    }
    #endif
}

/// The measures the gallery offers, in its order: catalog key, preferred source.
enum ForgeWidgetMeasures {
    static let all: [(key: String, source: String)] = [
        ("hrv", Repository.whoopSource), ("rhr", Repository.whoopSource), ("steps", Repository.whoopSource),
        ("sleep_total_min", Repository.whoopSource), ("vo2max_est", Repository.whoopSource), ("stress", Repository.whoopSource),
        ("weight", "noop-weight"), ("spo2", Repository.whoopSource), ("resp_rate", Repository.whoopSource),
        ("skin_temp", Repository.whoopSource), ("active_kcal", "apple-health"), ("calories_in", "nutrition-csv"),
    ]

    static func descriptor(_ key: String, _ source: String?) -> MetricDescriptor? {
        source.flatMap { MetricCatalog.metric(key: key, source: $0) } ?? MetricCatalog.all.first { $0.key == key }
    }
}

// MARK: - The widget area on Today

struct ForgeTodayWidgetArea: View {
    @Binding var editing: Bool
    @ObservedObject private var store = ForgeTodayWidgetStore.shared
    @State private var addingWidget = false

    /// Small tiles pair up two by two; a wide tile takes its own row.
    private var rows: [[ForgeTodayWidget]] {
        var out: [[ForgeTodayWidget]] = []
        var pending: ForgeTodayWidget?
        for w in store.widgets {
            if w.isWide {
                if let p = pending { out.append([p]); pending = nil }
                out.append([w])
            } else if let p = pending {
                out.append([p, w]); pending = nil
            } else {
                pending = w
            }
        }
        if let p = pending { out.append([p]) }
        return out
    }

    var body: some View {
        if editing || !store.widgets.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if editing {
                    HStack {
                        Text("Edit Today").font(.system(.headline)).foregroundStyle(ForgeColor.text)
                        Spacer()
                        Button { withAnimation(.snappy) { editing = false } } label: {
                            Text("Done").font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.onAccent)
                                .padding(.horizontal, 16).frame(minHeight: 36)
                                .background(Capsule().fill(ForgeColor.accent))
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(rows, id: \.first!.id) { row in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(row) { w in cell(w) }
                        if row.count == 1, !row[0].isWide { Color.clear.frame(maxWidth: .infinity) }
                    }
                }
                if editing {
                    Button { addingWidget = true } label: {
                        Label("Add a widget", systemImage: "plus.circle.fill")
                            .font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.accent)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(ForgeColor.separator, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                    }
                    .buttonStyle(.plain)
                }
            }
            .sheet(isPresented: $addingWidget) { ForgeWidgetGallery() }
        }
    }

    @ViewBuilder private func cell(_ w: ForgeTodayWidget) -> some View {
        let content = ForgeTodayWidgetView(widget: w)
            .frame(maxWidth: .infinity)
        if editing {
            content
                .allowsHitTesting(false)
                .overlay(alignment: .topLeading) {
                    Button { withAnimation(.snappy) { store.remove(w.id) } } label: {
                        Image(systemName: "minus.circle.fill").font(.title2)
                            .symbolRenderingMode(.palette).foregroundStyle(.white, ForgeColor.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .offset(x: -14, y: -14)
                    .accessibilityLabel(Text("Remove widget"))
                }
                .contentShape(Rectangle())
                // Dragging is not the only way: VoiceOver and Switch Control move a widget by action.
                .accessibilityAction(named: Text("Move earlier")) { store.shift(w.id, by: -1) }
                .accessibilityAction(named: Text("Move later")) { store.shift(w.id, by: 1) }
                .draggable(w.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let s = items.first, let id = UUID(uuidString: s) else { return false }
                    withAnimation(.snappy) { store.move(id, before: w.id) }
                    return true
                }
        } else {
            content
        }
    }
}

/// One widget's content.
struct ForgeTodayWidgetView: View {
    let widget: ForgeTodayWidget
    @EnvironmentObject private var repo: Repository
    @AppStorage(CardAppearancePrefs.opacityKey) private var opacityPercent = ForgeCardModifier.defaultGlassPercent

    var body: some View {
        switch widget.kind {
        case .measure: ForgeMeasureWidget(key: widget.key ?? "hrv", source: widget.source)
        case .trainingLoad: LiquidTrainingLoadSection(surfaceOpacity: Double(opacityPercent) / 100)
        case .goals: GoalsTodaySection(headerOutside: true)
        case .energy: ForgeEnergyWidget()
        }
    }
}

/// A measure as the Health focus tiles draw it: its name, the latest value, the last 30 days.
struct ForgeMeasureWidget: View {
    let key: String
    let source: String?
    @EnvironmentObject private var repo: Repository
    @State private var values: [Double] = []
    @State private var metric: MetricDescriptor?

    var body: some View {
        let m = metric ?? ForgeWidgetMeasures.descriptor(key, source)
        NavigationLink(value: TabRoute.metricSourced(key: m?.key ?? key, source: m?.source ?? source ?? Repository.whoopSource)) {
            ForgeMetricTile(label: m?.title ?? key,
                            value: m.flatMap { ForgeFocusView.format(values.last, $0) },
                            unit: m.map(ForgeFocusView.unit) ?? "",
                            trend: values.count > 1 ? Array(values.suffix(30)) : nil,
                            tint: ForgeColor.accent)
        }
        .buttonStyle(LiquidPressStyle())
        .task(id: repo.refreshSeq) { await load() }
    }

    /// The preferred source first, then any other source of the same measure that has data.
    private func load() async {
        var candidates: [MetricDescriptor] = []
        if let d = ForgeWidgetMeasures.descriptor(key, source) { candidates.append(d) }
        candidates += MetricCatalog.all.filter { $0.key == key && !candidates.contains($0) }
        for d in candidates {
            let s = await repo.exploreSeries(key: d.key, source: d.source, days: 60)
            if !s.isEmpty {
                metric = d
                values = s.map(\.value)
                return
            }
        }
        metric = candidates.first
    }
}

/// Today's energy as the shipped Energy card draws it.
struct ForgeEnergyWidget: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @State private var summary: DailyEnergySummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Energy").font(.system(.headline)).foregroundStyle(ForgeColor.text).padding(.horizontal, 2)
            NavigationLink(value: TabRoute.energy) {
                if let summary {
                    EnergyCard(summary: summary, compact: true, showsTitle: false)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading energy…").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .forgeCard(radius: 22, padding: 14)
                }
            }
            .buttonStyle(.plain)
        }
        .task(id: repo.refreshSeq) {
            let today = Repository.logicalDayKey(Date())
            summary = await repo.energySummaries(days: 3, profile: Repository.analyticsProfile(profile)).first { $0.day == today }
        }
    }
}

// MARK: - Gallery

struct ForgeWidgetGallery: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ForgeTodayWidgetStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ForgeWidgetMeasures.all, id: \.key) { m in
                        if let d = ForgeWidgetMeasures.descriptor(m.key, m.source) {
                            row(symbol: d.icon, title: d.title, subtitle: String(localized: "Small · the latest value and its month")) {
                                store.add(.init(kind: .measure, key: m.key, source: m.source))
                            }
                        }
                    }
                } header: { Text("Measures") }
                Section {
                    row(symbol: "chart.bar.fill", title: String(localized: "Training load"),
                        subtitle: String(localized: "Wide · both lanes against your usual")) { store.add(.init(kind: .trainingLoad)) }
                    row(symbol: "flag.fill", title: String(localized: "Goals"),
                        subtitle: String(localized: "Wide · this week's goals")) { store.add(.init(kind: .goals)) }
                    row(symbol: "flame.fill", title: String(localized: "Energy"),
                        subtitle: String(localized: "Wide · burned and eaten today")) { store.add(.init(kind: .energy)) }
                } header: { Text("Cards") }
            }
            .scrollContentBackground(.hidden)
            .background(ForgeColor.canvas.ignoresSafeArea())
            .navigationTitle(Text("Add a widget"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(symbol: String, title: String, subtitle: String, add: @escaping () -> Void) -> some View {
        Button {
            add()
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(.body, weight: .semibold)).foregroundStyle(ForgeColor.accent)
                    .frame(width: 36, height: 36).background(Circle().fill(ForgeColor.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(.body, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Text(subtitle).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
                Spacer(minLength: 6)
                Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(ForgeColor.accent)
            }
        }
        .listRowBackground(ForgeColor.card)
    }
}
#endif
