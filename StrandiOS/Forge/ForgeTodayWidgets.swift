#if os(iOS)
import SwiftUI
import StrandTraining
import StrandDesign
import StrandAnalytics
import StrandCore
import WhoopStore

// MARK: - Widgets on Today (board "TodayWFew", 2026-11)
//
// Tiles between the rings and the timeline, or after it. A first set comes on its own; the wearer adds from a
// small gallery and reorders or removes them in place, and picks two or three to a row for the phone in hand.
// Small tiles are the Liquid Today metric tile; wide tiles are the app's own cards (Training load, Goals,
// Energy), unchanged, so a widget never shows a number differently from the page it opens.

/// One widget the wearer placed on Today.
struct ForgeTodayWidget: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case measure, trainingLoad, goals, energy, water, liveHeart, momentum, lastNight, weekPlan, coachNote }

    var id = UUID()
    var kind: Kind
    /// For a measure: the catalog key and the preferred source.
    var key: String? = nil
    var source: String? = nil
    /// Live heart rate only: a full-width card with its curve instead of a tile with a beating heart.
    var wide: Bool? = nil

    var isWide: Bool {
        switch kind {
        case .measure, .water: return false
        case .liveHeart: return wide == true
        default: return true
        }
    }
}

/// The wearer's widgets, oldest first, kept as JSON in UserDefaults.
@MainActor
final class ForgeTodayWidgetStore: ObservableObject {
    static let key = "forge.today.widgets"
    static let shared = ForgeTodayWidgetStore()
    /// True: the tiles start after the timeline instead of under the rings.
    static let belowTimelineKey = "forge.today.tilesBelowTimeline"
    /// Set once the first set of tiles was placed, so removing them all stays removed.
    private static let seededKey = "forge.today.widgetsSeeded"

    @Published private(set) var widgets: [ForgeTodayWidget] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([ForgeTodayWidget].self, from: data) {
            widgets = list
        }
        if !UserDefaults.standard.bool(forKey: Self.seededKey) {
            UserDefaults.standard.set(true, forKey: Self.seededKey)
            let first: [ForgeTodayWidget] = ["hrv", "rhr", "steps", "sleep_total_min", "stress", "weight"].compactMap { key in
                ForgeWidgetMeasures.all.first { $0.key == key }.map { .init(kind: .measure, key: $0.key, source: $0.source) }
            }
            widgets = first + widgets
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(widgets) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func add(_ w: ForgeTodayWidget) { widgets.append(w); save() }
    func remove(_ id: UUID) { widgets.removeAll { $0.id == id }; save() }

    /// Live heart rate between its small tile and its full-width card.
    func toggleWide(_ id: UUID) {
        guard let i = widgets.firstIndex(where: { $0.id == id }) else { return }
        widgets[i].wide = widgets[i].isWide ? false : true
        save()
    }

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

    @AppStorage(KeyMetricPrefs.columnsKey) private var columnsRaw = 0
    @AppStorage(ForgeTodayWidgetStore.belowTimelineKey) private var belowTimeline = false
    private var columns: Int { KeyMetricPrefs.columns(columnsRaw) }

    /// Small tiles fill a row of two or three; a wide tile takes its own row.
    private var rows: [[ForgeTodayWidget]] {
        var out: [[ForgeTodayWidget]] = []
        var pending: [ForgeTodayWidget] = []
        for w in store.widgets {
            if w.isWide {
                if !pending.isEmpty { out.append(pending); pending = [] }
                out.append([w])
            } else {
                pending.append(w)
                if pending.count == columns { out.append(pending); pending = [] }
            }
        }
        if !pending.isEmpty { out.append(pending) }
        return out
    }

    var body: some View {
        if editing || !store.widgets.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if editing {
                    // On a card of its own: the picture behind it changes with the hour.
                    VStack(alignment: .leading, spacing: 12) {
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
                        layoutChoices
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(ForgeColor.card))
                }
                ForEach(rows, id: \.first!.id) { row in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(row) { w in cell(w) }
                        if !row[0].isWide {
                            ForEach(row.count..<columns, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                if editing {
                    Button { addingWidget = true } label: {
                        Label("Add a widget", systemImage: "plus.circle.fill")
                            .font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.accent)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(ForgeColor.card))
                    }
                    .buttonStyle(.plain)
                }
            }
            .sheet(isPresented: $addingWidget) { ForgeWidgetGallery() }
            .sensoryFeedback(.impact, trigger: editing)
        }
    }

    /// Two or three tiles to a row, for the phone in hand, and where the tiles start.
    private var layoutChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            layoutChoice("Tiles per row") {
                Picker("Tiles per row", selection: Binding(get: { columns }, set: { columnsRaw = $0 })) {
                    ForEach(KeyMetricPrefs.columnChoices, id: \.self) { Text(verbatim: "\($0)").tag($0) }
                }
            }
            layoutChoice("Tiles start") {
                Picker("Tiles start", selection: $belowTimeline) {
                    Text("Under the rings").tag(false)
                    Text("After the timeline").tag(true)
                }
            }
        }
    }

    private func layoutChoice<Choice: View>(_ title: LocalizedStringKey, @ViewBuilder choice: () -> Choice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(.footnote, weight: .semibold)).foregroundStyle(ForgeColor.secondary)
            choice().pickerStyle(.segmented).labelsHidden()
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
                .overlay(alignment: .topTrailing) {
                    if w.kind == .liveHeart {
                        Button { withAnimation(.snappy) { store.toggleWide(w.id) } } label: {
                            Image(systemName: w.isWide ? "arrow.down.right.and.arrow.up.left.circle.fill" : "arrow.up.left.and.arrow.down.right.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette).foregroundStyle(.white, ForgeColor.accent)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 14, y: -14)
                        .accessibilityLabel(Text("Change size"))
                    }
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
            // Held, a tile starts the editor; a plain tap still opens its page.
            content
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    withAnimation(.snappy) { editing = true }
                })
                .accessibilityAction(named: Text("Customize Today")) { editing = true }
        }
    }
}

/// One widget's content.
struct ForgeTodayWidgetView: View {
    let widget: ForgeTodayWidget
    @EnvironmentObject private var repo: Repository
    @AppStorage(CardAppearancePrefs.opacityKey) private var opacityPercent = ForgeCardModifier.defaultGlassPercent
    @Environment(\.forgeSurfaceOpacity) private var surfaceOpacity

    var body: some View {
        switch widget.kind {
        case .measure: ForgeMeasureWidget(key: widget.key ?? "hrv", source: widget.source)
        case .trainingLoad: LiquidTrainingLoadSection(surfaceOpacity: surfaceOpacity ?? Double(opacityPercent) / 100)
        case .goals: GoalsTodaySection(headerOutside: true)
        case .energy: ForgeEnergyWidget()
        case .water: ForgeWaterWidget()
        case .liveHeart:
            if widget.isWide { ForgeLiveHeartWideWidget() } else { ForgeLiveHeartWidget() }
        case .momentum: ForgeMomentumWidget()
        case .lastNight: ForgeLastNightWidget()
        case .weekPlan: ForgeWeekPlanWidget()
        case .coachNote: ForgeCoachNoteWidget()
        }
    }
}

/// The Liquid Today metric tile as Today's tiles draw it: neutral surface, colour on the icon and the line.
private struct ForgeTodayTile: View {
    let label: String
    let symbol: String
    let value: String?
    let unit: String
    var caption: String? = nil
    let tint: Color
    var trend: [Double]? = nil
    @AppStorage(KeyMetricPrefs.columnsKey) private var columnsRaw = 0
    /// nil until the wearer sets Card transparency: until then close to solid, so figures stay clean.
    @AppStorage(CardAppearancePrefs.opacityKey) private var opacityPercent: Int?
    @Environment(\.forgeSurfaceOpacity) private var surfaceOpacity

    var body: some View {
        let dense = KeyMetricPrefs.columns(columnsRaw) > 2
        // Sentence case: small tracked capitals over a picture were the hardest words on the page to read.
        TodayMetricTile(label: Text(verbatim: label),
                        systemImage: symbol,
                        value: value ?? "–",
                        unit: value == nil ? "" : unit,
                        caption: caption,
                        tint: tint,
                        sparkline: trend,
                        sparkColor: tint,
                        sparklineHeight: dense ? 22 : 28,
                        dense: dense,
                        surfaceOpacity: surfaceOpacity ?? opacityPercent.map { Double($0) / 100 } ?? 0.92,
                        tintsSurface: false)
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
            ForgeTodayTile(label: String(localized: "Hydration"), symbol: "drop.fill",
                           value: UnitFormatter.localizedMark(String(format: "%.1f", HydrationGoal.litres(fromML: totalML))),
                           unit: "L",
                           caption: String(localized: "of \(UnitFormatter.localizedMark(String(format: "%.1f", HydrationGoal.litres(fromML: Double(repo.hydrationGoalML(profileSex: profile.sex)))))) L"),
                           tint: StrandPalette.metricCyan,
                           trend: week.count > 1 ? week : nil)
        }
        .buttonStyle(LiquidPressStyle())
        .task(id: repo.refreshSeq) {
            totalML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
            week = await repo.hydrationHistory(days: 7).map(\.value)
        }
    }
}

/// A heart that beats at the rate it shows, so the figure reads as live. Still and grey without a reading.
struct ForgeBeatingHeart: View {
    let bpm: Int?
    var size: CGFloat = 26
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The gate every never-settling loop consults: when it says still, the heart stands still.
    @ObservedObject private var motion = NoopMotionState.shared

    var body: some View {
        if let bpm, bpm > 0, !motion.poseStill(reduceMotion) {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                heart(tint: StrandPalette.metricRose)
                    .scaleEffect(Self.scale(at: context.date.timeIntervalSinceReferenceDate, bpm: bpm))
            }
        } else {
            heart(tint: bpm == nil ? ForgeColor.tertiary : StrandPalette.metricRose)
        }
    }

    private func heart(tint: Color) -> some View {
        Image(systemName: "heart.fill")
            .font(.system(size: size))
            .foregroundStyle(tint)
    }

    /// Two quick swells per beat, the second smaller, as a heart sounds.
    static func scale(at time: TimeInterval, bpm: Int) -> CGFloat {
        let period = 60 / Double(max(bpm, 1))
        let phase = time.truncatingRemainder(dividingBy: period) / period
        func swell(_ from: Double, _ to: Double) -> Double {
            guard phase >= from, phase < to else { return 0 }
            return sin((phase - from) / (to - from) * .pi)
        }
        return 1 + 0.2 * swell(0, 0.16) + 0.1 * swell(0.22, 0.36)
    }
}

/// The heart rate right now as a small tile, with a heart beating at that rate. Opens the Live page.
struct ForgeLiveHeartWidget: View {
    @EnvironmentObject private var live: LiveState

    /// The same gate the Live card reads: no number without a connected strap reporting one.
    private var bpm: Int? {
        guard live.connected, let hr = live.heartRate, hr > 0 else { return nil }
        return hr
    }

    var body: some View {
        NavigationLink(value: MoreDestination.live) {
            // Without a strap streaming there is no number to give, so the tile says why instead of a dash.
            ForgeTodayTile(label: String(localized: "Live"), symbol: "waveform.path.ecg",
                           value: bpm.map { "\($0)" }, unit: "bpm",
                           caption: bpm == nil ? (live.connected ? String(localized: "Waiting for a pulse") : String(localized: "Strap not connected")) : nil,
                           tint: StrandPalette.metricRose)
                .overlay(alignment: .bottomTrailing) {
                    if bpm != nil {
                        ForgeBeatingHeart(bpm: bpm)
                            .padding(12)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(LiquidPressStyle())
    }
}

/// The heart rate right now across the whole width, with its curve: the Live card itself, falling back to
/// today's banked trace while no strap streams.
struct ForgeLiveHeartWideWidget: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var banked: [HRBucket] = []

    var body: some View {
        LiquidLiveHR(tint: StrandPalette.metricRose, fallback: banked.map(\.bpm),
                     fallbackTimes: banked.map { Date(timeIntervalSince1970: TimeInterval($0.ts)) },
                     animated: !reduceMotion, headerRoute: .fullDayChart)
            .forgeCard(radius: ForgeRadius.card, padding: 14)
            .task(id: repo.refreshSeq) {
                let now = Date()
                banked = await repo.hrBuckets(from: Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970),
                                              to: Int(now.timeIntervalSince1970), bucketSeconds: 300)
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
            .forgeCard(radius: ForgeRadius.card, padding: 14)
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
            .forgeCard(radius: ForgeRadius.card, padding: 14)
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
        .forgeCard(radius: ForgeRadius.card, padding: 14)
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
            ForgeTodayTile(label: Self.shortTitle(key) ?? m?.title ?? key, symbol: m?.icon ?? "chart.xyaxis.line",
                           value: key == "stress"
                               ? values.last.map { Self.stressWord($0) }
                               : m.flatMap { ForgeFocusView.format(values.last, $0) },
                           // Steps speak for themselves, and the word would crowd the number in a small tile.
                           unit: key == "steps" ? "" : m.map(ForgeFocusView.unit) ?? "",
                           tint: Self.tint(key),
                           trend: values.count > 1 ? Array(values.suffix(30)) : nil)
        }
        .buttonStyle(LiquidPressStyle())
        .task(id: repo.refreshSeq) { await load() }
    }

    /// Stress on its 0 to 3 scale as a word: "2,2" alone said nothing without the scale beside it.
    static func stressWord(_ score: Double) -> String {
        switch StressBand(score: score) {
        case .low: return String(localized: "Low")
        case .medium: return String(localized: "Medium")
        case .high: return String(localized: "High")
        }
    }

    /// The short names the Liquid Today tiles use: a catalog title is cut off in a row of three.
    private static func shortTitle(_ key: String) -> String? {
        switch key {
        case "hrv": return "HRV"
        case "rhr": return String(localized: "Rest HR")
        case "sleep_total_min": return String(localized: "Sleep")
        case "stress": return String(localized: "Stress")
        case "spo2": return "SpO₂"
        case "skin_temp": return String(localized: "Skin Temp")
        case "resp_rate": return String(localized: "Respiratory")
        default: return nil
        }
    }

    /// Each measure in the colour the Liquid Today tiles give it.
    static func tint(_ key: String) -> Color {
        switch key {
        case "hrv", "spo2": return StrandPalette.metricCyan
        case "rhr": return StrandPalette.metricRose
        case "steps": return StrandPalette.chargeColor
        case "sleep_total_min": return StrandPalette.restColor
        case "weight", "skin_temp": return StrandPalette.metricAmber
        case "active_kcal", "calories_in": return StrandPalette.energyHighlight
        case "stress": return StrandPalette.effortColor
        default: return StrandPalette.accent
        }
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
                    .forgeCard(radius: ForgeRadius.card, padding: 14)
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
                        subtitle: String(localized: "Small · a heart beating with your pulse")) { store.add(.init(kind: .liveHeart)) }
                    row(symbol: "waveform.path.ecg", title: String(localized: "Live heart rate"),
                        subtitle: String(localized: "Wide · your heart rate as a curve")) { store.add(.init(kind: .liveHeart, wide: true)) }
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
                    .frame(width: 36, height: 36).background(Circle().fill(ForgeColor.accent.opacity(ForgeOpacity.wash)))
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
