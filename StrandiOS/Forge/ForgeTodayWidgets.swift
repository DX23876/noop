#if os(iOS)
import SwiftUI
import StrandTraining
import StrandDesign
import StrandAnalytics
import StrandCore
import WhoopStore

// MARK: - Widgets on Today (board "TodayWFew", 2026-11)
//
// Optional tiles between the rings and the timeline. None by default; the wearer adds them from a small
// gallery and reorders or removes them in place. Small tiles are measures drawn as the Health focus tiles
// draw them; wide tiles are the app's own cards (Training load, Goals, Energy), unchanged, so a widget never
// shows a number differently from the page it opens.

/// One widget the wearer placed on Today.
struct ForgeTodayWidget: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case measure, trainingLoad, goals, energy, water, liveHeart, momentum, lastNight, weekPlan, coachNote }

    var id = UUID()
    var kind: Kind
    /// For a measure: the catalog key and the preferred source.
    var key: String? = nil
    var source: String? = nil

    var isWide: Bool { kind != .measure && kind != .water && kind != .liveHeart }
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
            .init(kind: .momentum),
            .init(kind: .lastNight),
            .init(kind: .weekPlan),
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
                        if row.count == 1, !row[0].isWide { Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
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
        case .water: ForgeWaterWidget()
        case .liveHeart: ForgeLiveHeartWidget()
        case .momentum: ForgeMomentumWidget()
        case .lastNight: ForgeLastNightWidget()
        case .weekPlan: ForgeWeekPlanWidget()
        case .coachNote: ForgeCoachNoteWidget()
        }
    }
}

/// The day's water against its goal. Opens the Hydration page, where drinks are added.
struct ForgeWaterWidget: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @State private var totalML: Double = 0
    @State private var week: [Double] = []

    var body: some View {
        NavigationLink(value: TabRoute.hydration) {
            ForgeMetricTile(label: String(localized: "Hydration"),
                            value: UnitFormatter.localizedMark(String(format: "%.1f", HydrationGoal.litres(fromML: totalML))),
                            unit: String(localized: "of \(UnitFormatter.localizedMark(String(format: "%.1f", HydrationGoal.litres(fromML: Double(repo.hydrationGoalML(profileSex: profile.sex)))))) L"),
                            trend: week.count > 1 ? week : nil,
                            tint: ForgeColor.accent)
        }
        .buttonStyle(LiquidPressStyle())
        .task(id: repo.refreshSeq) {
            totalML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
            week = await repo.hydrationHistory(days: 7).map(\.value)
        }
    }
}

/// The heart rate right now, while a strap streams it. Opens the Live page.
struct ForgeLiveHeartWidget: View {
    @EnvironmentObject private var model: AppModel
    /// The readings since this tile came on screen, drawn as its line. Never stored.
    @State private var recent: [Double] = []

    var body: some View {
        NavigationLink(value: MoreDestination.live) {
            ForgeMetricTile(label: String(localized: "Live heart rate"), value: model.bpm.map { "\($0)" },
                            unit: "bpm", trend: recent, tint: ForgeColor.accent)
        }
        .buttonStyle(LiquidPressStyle())
        .onChange(of: model.bpm) { _, bpm in
            guard let bpm else { return }
            recent = Array((recent + [Double(bpm)]).suffix(60))
        }
    }
}

/// The last main night: hours asleep, its stages, bedtime to wake. Opens the Rest page.
struct ForgeLastNightWidget: View {
    @EnvironmentObject private var repo: Repository
    @State private var night: ForgeRecentSleep.Night?

    private var asleep: Int? { night.map { Int($0.asleepMinutes) } }

    var body: some View {
        NavigationLink(value: ForgeRoute.rest(nil)) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Last night").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                if let night, let asleep {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "\(asleep / 60) h \(asleep % 60) min")
                            .font(.system(.title3, weight: .semibold).monospacedDigit())
                            .foregroundStyle(ForgeColor.text)
                        Spacer(minLength: 4)
                        Text(verbatim: "\(Self.time(night.start)) – \(Self.time(night.end))")
                            .font(ForgeFont.caption)
                            .foregroundStyle(ForgeColor.secondary)
                    }
                } else {
                    Text("No night yet.").font(.system(.subheadline)).foregroundStyle(ForgeColor.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .forgeCard(radius: 22, padding: 14)
        }
        .buttonStyle(LiquidPressStyle())
        .task(id: repo.refreshSeq) {
            night = await ForgeRecentSleep.load(repo: repo, days: 3).nights.max { $0.end < $1.end }
        }
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// The week at a glance: one dot per day, filled where a workout happened, ringed where one is planned.
struct ForgeWeekPlanWidget: View {
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var plan = CoachPlanStore.shared
    @AppStorage("training.weekStartsOn") private var weekStartRaw = TrainingWeekStart.monday.rawValue
    @State private var doneDays: Set<String> = []

    private var days: [Date] {
        var cal = Calendar.current
        cal.firstWeekday = (TrainingWeekStart(rawValue: weekStartRaw) ?? .monday) == .monday ? 2 : 1
        let start = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? cal.startOfDay(for: Date())
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        NavigationLink(value: ForgeRoute.weekPlan) {
            VStack(alignment: .leading, spacing: 8) {
                Text("This week's plan").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                HStack(spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        let key = Repository.localDayKey(day)
                        let planned = plan.proposals(forDay: key).contains { $0.status.isCommitment }
                        VStack(spacing: 4) {
                            Circle()
                                .fill(doneDays.contains(key) ? ForgeColor.accent : Color.clear)
                                .overlay(Circle().strokeBorder(doneDays.contains(key) || planned ? ForgeColor.accent : ForgeColor.secondary.opacity(0.3),
                                                               lineWidth: 1.5))
                                .frame(width: 20, height: 20)
                            Text(String(day.formatted(.dateTime.weekday(.narrow))))
                                .font(ForgeFont.caption)
                                .foregroundStyle(ForgeColor.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(doneDays.count) days with a workout this week"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .forgeCard(radius: 22, padding: 14)
        }
        .buttonStyle(LiquidPressStyle())
        .task(id: repo.refreshSeq) {
            let rows = await repo.workoutRows(days: 7, reconcileHrCap: 0)
            doneDays = Set(rows.map { Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs))) })
        }
    }
}

/// The coach's latest stored brief line, the same one the Home Screen widget quotes.
struct ForgeCoachNoteWidget: View {
    private var note: String? {
        guard let text = UserDefaults(suiteName: WidgetSnapshot.suiteName)?.string(forKey: "coachBrief.widgetText")?
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.split(separator: "\n").first.map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Coach note").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            Text(note ?? String(localized: "No note yet."))
                .font(.system(.subheadline))
                .foregroundStyle(note == nil ? ForgeColor.secondary : ForgeColor.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .forgeCard(radius: 22, padding: 14)
    }
}

/// What matters most right now, from the Momentum feed. Opens the Momentum page.
struct ForgeMomentumWidget: View {
    @ObservedObject private var store = MomentumStore.shared

    var body: some View {
        NavigationLink(value: MoreDestination.momentum) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Momentum").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                if let first = store.messages.first {
                    Text(first.headline)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(ForgeColor.text)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Nothing stands out today.")
                        .font(.system(.subheadline))
                        .foregroundStyle(ForgeColor.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .forgeCard()
        }
        .buttonStyle(LiquidPressStyle())
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
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false

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
                    row(symbol: "moon.fill", title: String(localized: "Last night"),
                        subtitle: String(localized: "Wide · hours asleep and bedtime")) { store.add(.init(kind: .lastNight)) }
                    row(symbol: "calendar", title: String(localized: "This week's plan"),
                        subtitle: String(localized: "Wide · done and planned days")) { store.add(.init(kind: .weekPlan)) }
                    if coachFeatureEnabled {
                        row(symbol: "bubble.left.fill", title: String(localized: "Coach note"),
                            subtitle: String(localized: "Wide · the coach's latest line")) { store.add(.init(kind: .coachNote)) }
                    }
                    row(symbol: "bolt.fill", title: String(localized: "Momentum"),
                        subtitle: String(localized: "Wide · what matters most right now")) { store.add(.init(kind: .momentum)) }
                    row(symbol: "drop.fill", title: String(localized: "Hydration"),
                        subtitle: String(localized: "Small · water today against your goal")) { store.add(.init(kind: .water)) }
                    row(symbol: "heart.fill", title: String(localized: "Live heart rate"),
                        subtitle: String(localized: "Small · your heart rate right now")) { store.add(.init(kind: .liveHeart)) }
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
