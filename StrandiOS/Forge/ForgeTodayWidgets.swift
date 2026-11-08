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
    enum Kind: String, Codable, CaseIterable {
        case measure, trainingLoad, goals, energy, water, liveHeart, momentum, lastNight, weekPlan, coachNote, ageless, lastWorkout
        case cycle, tonight, breathe, nextSession, changes, whatWorks, strap
    }

    var id = UUID()
    var kind: Kind
    /// For a measure: the catalog key and the preferred source.
    var key: String? = nil
    var source: String? = nil
    /// Live heart rate and AgeLess: a full-width card (the curve, the age line) instead of a small tile.
    var wide: Bool? = nil

    var isWide: Bool {
        switch kind {
        case .measure, .water, .breathe, .strap: return false
        case .liveHeart, .ageless: return wide == true
        default: return true
        }
    }

    /// Kinds that come in both sizes, switched in the editor.
    var resizable: Bool { kind == .liveHeart || kind == .ageless }
}

/// The wearer's widgets, oldest first, kept as JSON in UserDefaults.
@MainActor
final class ForgeTodayWidgetStore: ObservableObject {
    static let key = "forge.today.widgets"
    static let shared = ForgeTodayWidgetStore()
    /// True: the tiles start after the timeline instead of under the rings.
    static let belowTimelineKey = "forge.today.tilesBelowTimeline"
    /// False: Today shows no timeline, only the rings and the tiles.
    static let showsTimelineKey = "forge.today.showsTimeline"
    /// Set once the first set of tiles was placed, so removing them all stays removed.
    private static let seededKey = "forge.today.widgetsSeeded"
    /// Set once the cycle card, fixed on Today until 2026-11-08, became a widget for those who saw it.
    private static let cycleSeededKey = "forge.today.cycleWidgetSeeded"

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
        // The cycle card stood fixed on Today; whoever saw it keeps it, now as a widget they can remove.
        let d = UserDefaults.standard
        if !d.bool(forKey: Self.cycleSeededKey) {
            d.set(true, forKey: Self.cycleSeededKey)
            if d.bool(forKey: AppModel.cycleAwarenessKey),
               ForgeCycleAudience.applies(sex: d.string(forKey: "profile.sex") ?? "male",
                                          bodyFormulaSex: d.string(forKey: "profile.bodyFormulaSex") ?? ""),
               !widgets.contains(where: { $0.kind == .cycle }) {
                widgets.append(.init(kind: .cycle))
                save()
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(widgets) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func add(_ w: ForgeTodayWidget) { widgets.append(w); save() }
    func remove(_ id: UUID) { widgets.removeAll { $0.id == id }; save() }

    /// A resizable widget between its small tile and its full-width card.
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
            .init(kind: .tonight),
            .init(kind: .nextSession),
            .init(kind: .changes),
            .init(kind: .whatWorks),
            .init(kind: .breathe),
            .init(kind: .strap),
            .init(kind: .cycle),
            .init(kind: .ageless),
            .init(kind: .measure, key: "hrv", source: Repository.whoopSource),
            .init(kind: .measure, key: "rhr", source: Repository.whoopSource),
            .init(kind: .energy),
            .init(kind: .lastWorkout),
            .init(kind: .ageless, wide: true),
            .init(kind: .momentum),
            .init(kind: .lastNight),
            .init(kind: .weekPlan),
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
        ("fitness_age", Repository.whoopSource),
    ]

    static func descriptor(_ key: String, _ source: String?) -> MetricDescriptor? {
        source.flatMap { MetricCatalog.metric(key: key, source: $0) } ?? MetricCatalog.all.first { $0.key == key }
    }
}

// MARK: - The widget area on Today

struct ForgeTodayWidgetArea: View {
    @Binding var editing: Bool
    /// Kinds Today shows elsewhere right now (its "right now" section); kept in the list, left off the board.
    var hiddenKinds: Set<ForgeTodayWidget.Kind> = []
    @ObservedObject private var store = ForgeTodayWidgetStore.shared
    @State private var addingWidget = false

    @AppStorage(KeyMetricPrefs.columnsKey) private var columnsRaw = 0
    @AppStorage(ForgeTodayWidgetStore.belowTimelineKey) private var belowTimeline = false
    @AppStorage(ForgeTodayWidgetStore.showsTimelineKey) private var showsTimeline = true
    @AppStorage(HealthspanFeature.defaultsKey) private var healthspanEnabled = false
    @AppStorage(AppModel.cycleAwarenessKey) private var cycleEnabled = false
    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// At the accessibility text sizes three tiles to a row cut their figures off ("51 bp…"); two fit.
    private var columns: Int {
        let chosen = KeyMetricPrefs.columns(columnsRaw)
        return dynamicTypeSize.isAccessibilitySize ? min(chosen, 2) : chosen
    }

    /// The placed widgets on show: AgeLess only while AgeLess is switched on, the cycle only for those it is
    /// for while tracking is on, so a widget with nothing to draw never holds an empty row.
    private var shown: [ForgeTodayWidget] {
        let cycle = cycleEnabled && ForgeCycleAudience.applies(sex: profile.sex, bodyFormulaSex: profile.bodyFormulaSex)
        return store.widgets.filter {
            ($0.kind != .ageless || healthspanEnabled) && ($0.kind != .cycle || cycle)
                && (editing || !hiddenKinds.contains($0.kind))
        }
    }

    /// Small tiles fill a row of two or three; a wide tile takes its own row.
    private var rows: [[ForgeTodayWidget]] {
        var out: [[ForgeTodayWidget]] = []
        var pending: [ForgeTodayWidget] = []
        for w in shown {
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
        if editing || !shown.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
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
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ForgeColor.card))
                }
                ForEach(rows, id: \.first!.id) { row in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(row) { w in cell(w) }
                        // A short last row shares the width instead of leaving an empty third of the row,
                        // except while arranging, where the empty slot shows where a tile can go.
                        if !row[0].isWide, editing {
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
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ForgeColor.card))
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
        VStack(alignment: .leading, spacing: 12) {
            layoutChoice("Tiles per row") {
                Picker("Tiles per row", selection: Binding(get: { columns }, set: { columnsRaw = $0 })) {
                    ForEach(KeyMetricPrefs.columnChoices, id: \.self) { Text(verbatim: "\($0)").tag($0) }
                }
            }
            Toggle(isOn: $showsTimeline.animation(.snappy)) {
                Text("Show the timeline").font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
            }
            .tint(ForgeColor.accent)
            if showsTimeline {
                layoutChoice("Tiles start") {
                    Picker("Tiles start", selection: $belowTimeline) {
                        Text("Under the rings").tag(false)
                        Text("After the timeline").tag(true)
                    }
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
                    if w.resizable {
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
        case .ageless:
            if widget.isWide { ForgeAgeLessWideWidget() } else { ForgeAgeLessWidget() }
        case .lastWorkout: ForgeLastWorkoutWidget()
        case .cycle: ForgeCycleWidget()
        case .tonight: ForgeTonightWidget()
        case .breathe: ForgeBreatheWidget()
        case .nextSession: ForgeNextSessionWidget()
        case .changes: ForgeChangesWidget()
        case .whatWorks: ForgeWhatWorksWidget()
        case .strap: ForgeStrapWidget()
        }
    }
}

/// The Liquid Today metric tile as Today's tiles draw it: neutral surface, colour on the icon and the line.
struct ForgeTodayTile: View {
    let label: String
    let symbol: String
    let value: String?
    let unit: String
    var caption: String? = nil
    /// Today against the wearer's usual value ("↘ −2", "±0"), as Liquid Today's tiles show it.
    var delta: String? = nil
    let tint: Color
    var trend: [Double]? = nil
    @AppStorage(KeyMetricPrefs.columnsKey) private var columnsRaw = 0
    /// nil until the wearer sets Card transparency: until then close to solid, so figures stay clean.
    @AppStorage(CardAppearancePrefs.opacityKey) private var opacityPercent: Int?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.forgeSurfaceOpacity) private var surfaceOpacity

    var body: some View {
        // Matches the area's columns: two at the accessibility text sizes, so not dense there.
        let dense = KeyMetricPrefs.columns(columnsRaw) > 2 && !dynamicTypeSize.isAccessibilitySize
        // Sentence case: small tracked capitals over a picture were the hardest words on the page to read.
        // An empty tile says so in a quiet line instead of a lone dash in the large figure's place.
        TodayMetricTile(label: Text(verbatim: label),
                        systemImage: symbol,
                        value: value ?? "",
                        unit: value == nil ? "" : unit,
                        caption: value == nil ? String(localized: "No data yet") : caption,
                        tint: tint,
                        delta: value == nil ? nil : delta,
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
            .forgeCard(radius: ForgeRadius.card, padding: 16)
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
        ForgeWidgetCard(title: String(localized: "Last night"), route: ForgeRoute.rest(nil)) {
            if let night, let asleep {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    // The figures large, their units small beside them, as Apple writes a duration.
                    (Text(verbatim: "\(asleep / 60)").font(ForgeFont.figure(28))
                     + Text(verbatim: " ") + Text("h").font(.system(.footnote, weight: .medium)).foregroundColor(ForgeColor.secondary)
                     + Text(verbatim: " ") + Text(verbatim: String(asleep % 60)).font(ForgeFont.figure(28))
                     + Text(verbatim: " ")
                     + Text("min").font(.system(.footnote, weight: .medium)).foregroundColor(ForgeColor.secondary))
                        .foregroundStyle(ForgeColor.text)
                    Spacer(minLength: 8)
                    Text(verbatim: "\(Self.time(night.start)) – \(Self.time(night.end))")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
                ForgeStageStrip(deep: night.deep, rem: night.rem, light: night.light, awake: night.awake)
                HStack(spacing: 16) {
                    stage(String(localized: "Deep"), night.deep, StrandPalette.sleepStageColor(.deep))
                    stage(String(localized: "Light"), night.light, StrandPalette.sleepStageColor(.light))
                    stage(String(localized: "REM"), night.rem, StrandPalette.sleepStageColor(.rem))
                    Spacer(minLength: 0)
                }
            } else {
                Text("No night yet.").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            }
        }
        .task(id: repo.refreshSeq) {
            night = await ForgeRecentSleep.load(repo: repo, days: 3).nights.max { $0.end < $1.end }
        }
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func stage(_ name: String, _ minutes: Double, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(verbatim: "\(name) \(ForgeTodayView.hoursMinutes(minutes))")
                .font(ForgeFont.caption.monospacedDigit()).foregroundStyle(ForgeColor.secondary)
        }
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
        ForgeWidgetCard(title: String(localized: "This week's plan"), route: ForgeRoute.weekPlan) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        let key = Repository.localDayKey(day)
                        let planned = plan.proposals(forDay: key).contains { $0.status.isCommitment }
                        VStack(spacing: 4) {
                            Circle()
                                .fill(doneDays.contains(key) ? ForgeColor.effort : Color.clear)
                                .overlay(Circle().strokeBorder(doneDays.contains(key) || planned ? ForgeColor.effort : ForgeColor.secondary.opacity(0.3),
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
                Text("Workouts on \(doneDays.count) of 7 days").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        ForgePictureTile(symbol: "sparkles", accent: "text.bubble.fill", tint: StrandPalette.metricPurple) {
            Text("Coach note").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            Text(note ?? String(localized: "No note yet."))
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(note == nil ? ForgeColor.secondary : ForgeColor.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What matters most right now, from the Momentum feed. Opens the Momentum page.
struct ForgeMomentumWidget: View {
    @ObservedObject private var store = MomentumStore.shared

    var body: some View {
        // Momentum's own colour; a neutral message's grey tone made the picture look switched off.
        let tint = StrandPalette.metricAmber
        ForgeWidgetCard(title: String(localized: "Momentum"), route: MoreDestination.momentum) {
            if let first = store.messages.first {
                HStack(alignment: .top, spacing: 12) {
                    TrendsChangeSummary.categoryMark("bolt.horizontal.fill", tint: tint, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(first.headline).font(.system(.headline)).foregroundStyle(ForgeColor.text)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        if !first.detail.isEmpty {
                            Text(first.detail).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                // A goal-type message carries its progress: draw it.
                if let progress = first.progress {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: min(1, max(0, progress.fraction))).tint(tint)
                        Text(verbatim: progress.label).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    }
                }
            } else {
                Text("Nothing stands out today.").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            }
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
            ForgeTodayTile(label: Self.shortTitle(key) ?? m?.title ?? key, symbol: m?.icon ?? "chart.xyaxis.line",
                           value: key == "stress"
                               ? values.last.map { Self.stressWord($0) }
                               : m.flatMap { ForgeFocusView.format(values.last, $0) },
                           // Steps speak for themselves, and the word would crowd the number in a small tile; stress
                           // reads as a word ("Medium"), and "/3" beside a word said nothing.
                           unit: key == "steps" || key == "stress" ? "" : m.map(ForgeFocusView.unit) ?? "",
                           delta: Self.delta(key: key, values: values),
                           tint: Self.tint(key),
                           trend: values.count > 1 ? Array(values.suffix(30)) : nil)
        }
        .buttonStyle(LiquidPressStyle())
        .task(id: repo.refreshSeq) { await load() }
    }

    /// The latest value against the median of the 30 before it, as a signed whole step ("↗ +3", "±0"):
    /// the plain "against your usual" Liquid Today's tiles carry. Kilograms and degrees keep one decimal.
    /// None for measures read as words or totals (stress, steps, sleep), or with under a week of history.
    static func delta(key: String, values: [Double]) -> String? {
        guard !["stress", "steps", "sleep_total_min", "active_kcal", "calories_in"].contains(key),
              let last = values.last, values.count >= 8 else { return nil }
        let before = values.dropLast().suffix(30).sorted()
        let usual = before[before.count / 2]
        let decimals = ["weight", "skin_temp"].contains(key) ? 1 : 0
        let step = decimals == 1 ? 0.1 : 1.0
        let diff = ((last - usual) / step).rounded() * step
        if diff == 0 { return "±0" }
        let number = diff.magnitude.formatted(.number.precision(.fractionLength(decimals)).locale(AppLanguage.activeLocale))
        return diff > 0 ? "↗ +\(number)" : "↘ −\(number)"
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

/// AgeLess as a small tile: the AgeLess age, with the calendar age under it. Opens the AgeLess page.
struct ForgeAgeLessWidget: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @State private var week: HealthspanWeek?

    var body: some View {
        NavigationLink(value: ForgeRoute.ageless) {
            ForgeTodayTile(label: "AgeLess", symbol: "hourglass",
                           value: week.map { HealthspanSection.years($0.result.healthspanAge) },
                           unit: String(localized: "years"),
                           caption: week.map { String(localized: "Age \(HealthspanSection.years($0.result.chronologicalAge))") },
                           tint: week.map { $0.result.healthspanAge <= $0.result.chronologicalAge ? ForgeColor.charge : ForgeColor.effort }
                               ?? ForgeColor.accent)
        }
        .buttonStyle(LiquidPressStyle())
        .task(id: repo.refreshSeq) { week = await ForgeAgeLessWidget.latestWeek(repo: repo, profile: profile) }
    }

    /// The week the AgeLess page opens on, read through the shipped engine; nil without a sex in the profile.
    static func latestWeek(repo: Repository, profile: ProfileStore) async -> HealthspanWeek? {
        guard let sex = HealthspanEngine.Sex(profileValue: profile.sex) else { return nil }
        return await HealthspanSnapshot.load(repo: repo, age: profile.age, sex: sex)?.weeks.last
    }
}

/// AgeLess as a full-width card: the top of the AgeLess page on its age line.
struct ForgeAgeLessWideWidget: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @State private var week: HealthspanWeek?

    var body: some View {
        ForgeAgeLessSummary(week: week)
            .task(id: repo.refreshSeq) { week = await ForgeAgeLessWidget.latestWeek(repo: repo, profile: profile) }
    }
}

/// The latest session: sport, when and how long, and its Effort. Opens the workout.
struct ForgeLastWorkoutWidget: View {
    @EnvironmentObject private var repo: Repository
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @State private var row: WorkoutRow?
    @State private var loaded = false

    var body: some View {
        Group {
            if let row {
                ForgeWidgetCard(title: String(localized: "Latest workout"),
                                route: ForgeRoute.workout(startTs: row.startTs, sport: row.sport)) { card(row) }
            } else {
                ForgeWidgetCard(title: String(localized: "Latest workout"), route: ForgeRoute.workouts) {
                    Text("Workouts you record or import appear here.")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
            }
        }
        .task(id: repo.refreshSeq) {
            row = await repo.workoutRows(days: 60, reconcileHrCap: 0).max { $0.endTs < $1.endTs }
            loaded = true
        }
    }

    private func card(_ row: WorkoutRow) -> some View {
        let tint = AppleInspiredColors.role(forSport: row.sport).color
        let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
        let minutes = (row.durationS ?? Double(max(row.endTs - row.startTs, 0))) / 60
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                WorkoutTypeIcon(workoutType: row.sport, size: 18, weight: .semibold, color: .white)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint))
                VStack(alignment: .leading, spacing: 1) {
                    Text(WorkoutSource.localizedDisplaySport(row.sport))
                        .font(.system(.headline)).foregroundStyle(ForgeColor.text).lineLimit(1)
                    Text(verbatim: LiquidTodayView.workoutDayText(start) + " "
                         + start.formatted(.dateTime.hour().minute().locale(AppLanguage.activeLocale))
                         + " · " + String(localized: "\(Int(minutes)) min"))
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let strain = row.strain {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(ForgeToday.effortText(strain, scale: UnitPrefs.resolveEffortScale(effortScaleRaw)))
                            .font(ForgeFont.figure(24)).foregroundStyle(ForgeColor.text)
                        Text(DomainTheme.effort.productName).font(.system(.caption2)).foregroundStyle(ForgeColor.secondary)
                    }
                }
            }
            // Where the effort went: the heart-rate zones of the session, when it stored them.
            if let zones = WorkoutZones.percents(row.zonesJSON) {
                ForgeZoneBar(percents: zones, minutes: minutes)
            }
        }
        .accessibilityElement(children: .combine)
    }

}

/// Today's energy as the Energy page opens: the same ring, burned against a usual day, with resting, active
/// and eaten beside it. Opens the Energy page.
struct ForgeEnergyWidget: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @State private var summary: DailyEnergySummary?
    @State private var usual: Double?
    @State private var eaten: Double?
    @State private var loaded = false

    var body: some View {
        NavigationLink(value: TabRoute.energy) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Energy").font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold)).foregroundStyle(ForgeColor.tertiary)
                }
                if let summary, summary.totalBurnedSoFar == nil, eaten == nil {
                    // Nothing measured yet: one quiet line, not a large empty ring taking the tile's height.
                    HStack(spacing: 12) {
                        Image(systemName: "flame.fill").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(StrandPalette.forgeEnergyActive)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(StrandPalette.forgeEnergyActive.opacity(0.15)))
                        Text("Nothing recorded today yet.")
                            .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        Spacer(minLength: 0)
                    }
                } else if let summary {
                    HStack(spacing: 16) {
                        ForgeEnergyRing(resting: summary.basalBurnedSoFar, active: summary.activeBurnedSoFar,
                                        total: summary.totalBurnedSoFar, usual: usual,
                                        totalText: ForgeEnergyView.plainTotal(summary), selectedDay: summary.day, compact: true)
                            .frame(width: 104, height: 104)
                        VStack(alignment: .leading, spacing: 6) {
                            if summary.totalBurnedSoFar == nil {
                                // Before the first sync of the day: one sentence, not two rows of dashes.
                                Text("Nothing recorded today yet.")
                                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                figure(StrandPalette.forgeEnergyResting, String(localized: "Resting"), summary.basalBurnedSoFar)
                                figure(StrandPalette.forgeEnergyActive, String(localized: "Active"), summary.activeBurnedSoFar)
                            }
                            if let eaten { figure(ForgeColor.charge, String(localized: "Eaten"), eaten) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(loaded ? "Energy appears as soon as a connected source records activity." : "Loading energy…")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                }
            }
            .forgeCard(radius: ForgeRadius.card, padding: 16)
        }
        .buttonStyle(LiquidPressStyle())
        .task(id: repo.refreshSeq) {
            let today = Repository.logicalDayKey(Date())
            let all = await repo.energySummaries(days: 30, profile: Repository.analyticsProfile(profile))
            summary = all.first { $0.day == today }
            usual = ForgeEnergyView.usualTotal(all, today: today)
            eaten = await repo.intakeByDay(from: today, to: today)[today]
            loaded = true
        }
    }

    private func figure(_ color: Color, _ title: String, _ value: Double?) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            Spacer(minLength: 4)
            Text(verbatim: value.map { Int($0.rounded()).formatted(.number.locale(AppLanguage.activeLocale)) } ?? "–")
                .font(.system(.subheadline, weight: .semibold).monospacedDigit()).foregroundStyle(ForgeColor.text)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Gallery

struct ForgeWidgetGallery: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ForgeTodayWidgetStore.shared
    @EnvironmentObject private var profile: ProfileStore
    @AppStorage(AppModel.cycleAwarenessKey) private var cycleEnabled = false
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    @AppStorage(HealthspanFeature.defaultsKey) private var healthspanEnabled = false

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
                    row(symbol: "figure.run", title: String(localized: "Latest workout"),
                        subtitle: String(localized: "Wide · your last session and its Effort")) { store.add(.init(kind: .lastWorkout)) }
                    if healthspanEnabled {
                        row(symbol: "hourglass", title: "AgeLess",
                            subtitle: String(localized: "Small · your AgeLess age")) { store.add(.init(kind: .ageless)) }
                        row(symbol: "hourglass", title: "AgeLess",
                            subtitle: String(localized: "Wide · your AgeLess age on the age line")) { store.add(.init(kind: .ageless, wide: true)) }
                    }
                    row(symbol: "moon.fill", title: String(localized: "Last night"),
                        subtitle: String(localized: "Wide · hours asleep and bedtime")) { store.add(.init(kind: .lastNight)) }
                    row(symbol: "calendar", title: String(localized: "This week's plan"),
                        subtitle: String(localized: "Wide · done and planned days")) { store.add(.init(kind: .weekPlan)) }
                    if coachFeatureEnabled {
                        row(symbol: "bubble.left.fill", title: String(localized: "Coach note"),
                            subtitle: String(localized: "Wide · the coach's latest line")) { store.add(.init(kind: .coachNote)) }
                    }
                    row(symbol: "moon.fill", title: String(localized: "Tonight"),
                        subtitle: String(localized: "Wide · bedtime for a full night and the alarm")) { store.add(.init(kind: .tonight)) }
                    row(symbol: "dumbbell.fill", title: String(localized: "Next session"),
                        subtitle: String(localized: "Wide · your next planned routine, ready to start")) { store.add(.init(kind: .nextSession)) }
                    row(symbol: "chart.line.uptrend.xyaxis", title: String(localized: "What changed"),
                        subtitle: String(localized: "Wide · this week against last, in a word")) { store.add(.init(kind: .changes)) }
                    row(symbol: "lightbulb.fill", title: String(localized: "What works"),
                        subtitle: String(localized: "Wide · the habit that moves your Charge most")) { store.add(.init(kind: .whatWorks)) }
                    row(symbol: "wind", title: String(localized: "Breathe"),
                        subtitle: String(localized: "Small · two calm minutes, one tap away")) { store.add(.init(kind: .breathe)) }
                    row(symbol: "battery.75percent", title: String(localized: "Strap"),
                        subtitle: String(localized: "Small · battery and last sync")) { store.add(.init(kind: .strap)) }
                    if cycleEnabled, ForgeCycleAudience.applies(sex: profile.sex, bodyFormulaSex: profile.bodyFormulaSex) {
                        row(symbol: "drop.fill", title: String(localized: "Cycle"),
                            subtitle: String(localized: "Wide · cycle day and phase")) { store.add(.init(kind: .cycle)) }
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

/// A Today tile with its picture: the subject drawn small in its colour on the left, the words on the
/// right, the card washed in the same colour, as Trends' coach cards are.
struct ForgePictureTile<Content: View>: View {
    let symbol: String
    let accent: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            CoachPicture(main: symbol, accentA: accent, accentB: "sparkle", tint: tint)
                .frame(width: CoachPictureSize.small, height: CoachPictureSize.small)
            VStack(alignment: .leading, spacing: 4) { content() }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The colour stays in the picture: Today holds many tiles side by side, and a wash on each
        // card in its own colour turned the board into a rainbow.
        .background(RoundedRectangle(cornerRadius: ForgeRadius.card, style: .continuous).fill(ForgeColor.card))
    }
}
