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
        case cycle, tonight, breathe, nextSession, changes, whatWorks, strap, dietGoal
        /// The day's eating against its goal, with the macros (owner, 2026-11-18).
        case nutrition
        /// Today's heart rate since midnight, with last night's sleep band and the day's workouts.
        case dayHeart
    }

    var id = UUID()
    var kind: Kind
    /// For a measure: the catalog key and the preferred source.
    var key: String? = nil
    var source: String? = nil
    /// Live heart rate and AgeLess: a full-width card (the curve, the age line) instead of a small tile.
    var wide: Bool? = nil
    /// A tile over two columns (2) instead of one; nil or 1 is one column.
    var span: Int? = nil

    /// Measures that exist ONLY across the whole row (2026-11-18): Charge, Effort and Rest.
    ///
    /// The three rings stand directly above them and already say today's number. A small tile repeating
    /// it would be the same fact twice on one screen; across the row, with its thirty days, the tile says
    /// something the rings do not. The set is derived from the metrics, in the shared folder, where it is
    /// tested against the ones the seed refuses to carry.
    static let wholeRowMeasures = ForgeTodayTileSeed.wholeRowMeasures

    /// Whether this is one of those three.
    var isWholeRowMeasure: Bool { kind == .measure && Self.wholeRowMeasures.contains(key ?? "") }

    /// Cards that can be drawn over TWO COLUMNS, each saying the two facts the owner's table gives it
    /// (2026-11-19): last night's hours and its span, tonight's bedtime and its alarm, the latest session's
    /// length and sport, the day's burn with its resting and active parts.
    ///
    /// Two columns, never one. A card has no change chip and no sparkline, so it can never meet the floor
    /// a SMALL tile has to meet, and a single figure on a square was exactly what the owner rejected the
    /// evening before. Over two columns it says two things, which is what that size is for.
    ///
    /// Goals, training load, the cycle and the diet goal are not here: their figure lives inside a shared
    /// section or behind an enum that needs its own form, and a size control offering a size nothing can
    /// draw is worse than no control. The rest carry a sentence or an action, and a shortened sentence is
    /// not a smaller fact.
    static let shrinkableCards: Set<Kind> = [.lastNight, .tonight, .lastWorkout, .energy, .nutrition]

    var isWide: Bool {
        switch kind {
        case .measure: return isWholeRowMeasure || wide == true
        case .water, .breathe, .strap: return false
        case .liveHeart, .ageless: return wide == true
        // A card that can shrink starts wide and STAYS wide unless the wearer shrank it: `wide` is nil on
        // every tile placed before today, and reading nil as "small" would have rearranged their Today
        // overnight, which is the one thing this release promised not to do.
        default: return Self.shrinkableCards.contains(kind) ? (wide ?? true) : true
        }
    }

    /// How much of a row the widget takes, as the editor switches it.
    enum Size: Hashable { case small, medium, wide }

    /// A shrinkable card is never small: it has two facts, not one, and two columns is where they fit.
    var size: Size {
        if isWide { return .wide }
        if Self.shrinkableCards.contains(kind) { return .medium }
        return span == 2 ? .medium : .small
    }

    /// The narrow size a shrinkable card is drawn at, or nil while it is wide.
    var compactSize: TileSize? {
        switch size {
        case .wide: return nil
        case .medium: return .medium
        case .small: return .small
        }
    }

    /// Kinds drawn as a tile: they come small or over two columns, and some also across the row.
    ///
    /// A whole-row measure answers false: it has one size, so a size control on it would be a button that
    /// does nothing, and a control that does nothing says something untrue about the thing it sits on.
    var resizable: Bool {
        if isWholeRowMeasure { return false }
        switch kind {
        case .measure, .water, .breathe, .strap, .liveHeart, .ageless: return true
        default: return Self.shrinkableCards.contains(kind)
        }
    }

    /// The size after one tap on the size control: small, two columns, then the whole row where the kind
    /// has a card for it, then small again.
    var nextSize: Size {
        switch size {
        case .small: return .medium
        // A measure grows across the row too since 2026-11-18, where it draws its thirty days.
        case .medium: return (kind == .liveHeart || kind == .ageless || kind == .measure
                              || Self.shrinkableCards.contains(kind)) ? .wide : .small
        // A card has only the two sizes, so its control goes back to two columns rather than to a small
        // form it does not have.
        case .wide: return Self.shrinkableCards.contains(kind) ? .medium : .small
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
            widgets = Self.firstTiles(selection: UserDefaults.standard.string(forKey: KeyMetricPrefs.layoutKey))
                + widgets
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

    /// The tiles placed on a first run, from `ForgeTodayTileSeed` (shared, so it is tested) turned into
    /// widgets. A key the gallery does not offer is dropped rather than placed as an empty tile.
    static func firstTiles(selection: String?) -> [ForgeTodayWidget] {
        ForgeTodayTileSeed.measureKeys(selection: selection).compactMap { key in
            ForgeWidgetMeasures.all.first { $0.key == key }.map { .init(kind: .measure, key: $0.key, source: $0.source) }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(widgets) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func add(_ w: ForgeTodayWidget) { widgets.append(w); save() }
    func remove(_ id: UUID) { widgets.removeAll { $0.id == id }; save() }

    /// A resizable widget to its next size: small, two columns, the whole row.
    func cycleSize(_ id: UUID) {
        guard let i = widgets.firstIndex(where: { $0.id == id }) else { return }
        switch widgets[i].nextSize {
        case .small: widgets[i].wide = false; widgets[i].span = nil
        case .medium: widgets[i].wide = false; widgets[i].span = 2
        case .wide: widgets[i].wide = true; widgets[i].span = nil
        }
        save()
    }

    /// Moves `id` into the place `target` holds: a later target puts it after, an earlier one before, so a
    /// tile dragged over its neighbour swaps with it either way.
    func move(_ id: UUID, to target: UUID) {
        guard id != target, let from = widgets.firstIndex(where: { $0.id == id }),
              let to = widgets.firstIndex(where: { $0.id == target }) else { return }
        let item = widgets.remove(at: from)
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
            .init(kind: .dietGoal),
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
///
/// The list itself is `TileMeasures.all`, which Android reads through the core as well, so a tile's history
/// is fetched from the same place on both phones. Charge, Effort and Rest are its last three and are only
/// ever drawn across the whole row (`ForgeTodayWidget.wholeRowMeasures`): the three rings above already say
/// today's number, so a small tile would be the same fact twice, while thirty days of it is something the
/// rings do not show.
enum ForgeWidgetMeasures {
    static let all: [(key: String, source: String, section: TileMeasures.Section)] = TileMeasures.all

    /// One section of the gallery: the catalogue group and the measures offered under it.
    struct Group: Identifiable {
        let section: TileMeasures.Section
        let measures: [Measure]
        var id: TileMeasures.Section { section }
    }

    /// One row of a section.
    struct Measure: Identifiable {
        let key: String
        let source: String
        var id: String { key }
    }

    /// The gallery's sections in the catalogue's own order, each with the measures it offers.
    static var sections: [Group] {
        var out: [Group] = []
        for section in TileMeasures.Section.allCases {
            var measures: [Measure] = []
            for row in TileMeasures.all where row.section == section {
                measures.append(Measure(key: row.key, source: row.source))
            }
            if !measures.isEmpty { out.append(Group(section: section, measures: measures)) }
        }
        return out
    }

    /// What a section is called on screen. The words are the catalogue's, so a measure sits under the same
    /// heading here as on the page it opens.
    static func title(_ section: TileMeasures.Section) -> String {
        switch section {
        case .charge: return String(localized: "Charge")
        case .rest: return String(localized: "Rest")
        case .effort: return String(localized: "Effort")
        case .heart: return String(localized: "Heart")
        case .body: return String(localized: "Body")
        case .food: return String(localized: "Food")
        case .mind: return String(localized: "Mind")
        }
    }

    static func descriptor(_ key: String, _ source: String?) -> MetricDescriptor? {
        source.flatMap { MetricCatalog.metric(key: key, source: $0) } ?? MetricCatalog.all.first { $0.key == key }
    }
}

// MARK: - The widget area on Today

struct ForgeTodayWidgetArea: View {
    @Binding var editing: Bool
    @ObservedObject private var store = ForgeTodayWidgetStore.shared
    @State private var addingWidget = false
    /// The area's width, for the column widths a tile over two columns needs.
    @State private var areaWidth: CGFloat = 0
    /// The tile being moved while arranging; the others trade places with it as it passes over them.
    @State private var dragged: UUID?
    private static let gap: CGFloat = 12

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
        return store.widgets.filter { ($0.kind != .ageless || healthspanEnabled) && ($0.kind != .cycle || cycle) }
    }

    /// Columns a tile takes in a row: two for a medium tile (the whole row when there are only two).
    private func span(_ w: ForgeTodayWidget) -> Int { w.size == .medium ? min(2, columns) : 1 }

    /// Tiles fill a row of two or three columns, a medium tile taking two; a wide widget takes its own row.
    private var rows: [[ForgeTodayWidget]] {
        var out: [[ForgeTodayWidget]] = []
        var pending: [ForgeTodayWidget] = []
        var used = 0
        for w in shown {
            if w.isWide {
                if !pending.isEmpty { out.append(pending); pending = []; used = 0 }
                out.append([w])
            } else {
                let n = span(w)
                if used + n > columns, !pending.isEmpty { out.append(pending); pending = []; used = 0 }
                pending.append(w)
                used += n
                if used >= columns { out.append(pending); pending = []; used = 0 }
            }
        }
        if !pending.isEmpty { out.append(pending) }
        return out
    }

    /// A tile's width in its row. A full row, and every row while arranging, keeps to the column grid so tiles
    /// line up across rows; a short last row shares the width by span instead of leaving a hole.
    private func width(_ w: ForgeTodayWidget, in row: [ForgeTodayWidget]) -> CGFloat? {
        guard areaWidth > 0, !w.isWide else { return nil }
        let units = row.reduce(0) { $0 + span($1) }
        if units >= columns || editing {
            let column = (areaWidth - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)
            return (column * CGFloat(span(w)) + Self.gap * CGFloat(span(w) - 1)).rounded(.down)
        }
        let free = areaWidth - Self.gap * CGFloat(row.count - 1)
        return (free * CGFloat(span(w)) / CGFloat(units)).rounded(.down)
    }

    var body: some View {
        if editing || !shown.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
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
                VStack(alignment: .leading, spacing: Self.gap) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: Self.gap) {
                            ForEach(row) { w in
                                cell(w)
                                    .frame(width: width(w, in: row))
                                    .frame(maxWidth: width(w, in: row) == nil ? .infinity : nil)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // The full width on offer, whatever the tiles in it ask for: measured on a frame that takes the
                // whole proposal, so a tile's width can never feed back into the width it is computed from.
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { ($0.size.width).rounded(.down) } action: { areaWidth = $0 }
                                .sensoryFeedback(.selection, trigger: store.widgets.map(\.id))
                // Let go between tiles: the tile is already in its new place, only the faint slot clears.
                .onDrop(of: [.text], isTargeted: nil) { _ in dragged = nil; return true }
                .onChange(of: editing) { _, _ in dragged = nil }

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
                        Button { withAnimation(.snappy) { store.cycleSize(w.id) } } label: {
                            Image(systemName: w.nextSize == .small ? "arrow.down.right.and.arrow.up.left.circle.fill" : "arrow.up.left.and.arrow.down.right.circle.fill")
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
                // Held and dragged, a tile lifts; passing over another trades places with it at once, and the
                // system scrolls the page at its edges.
                .onDrag {
                    dragged = w.id
                    return NSItemProvider(object: w.id.uuidString as NSString)
                }
                .onDrop(of: [.text], delegate: ForgeWidgetDropDelegate(target: w.id, dragged: $dragged, store: store))
                // Dragging is not the only way: VoiceOver and Switch Control move a widget by action.
                .accessibilityAction(named: Text("Move earlier")) { store.shift(w.id, by: -1) }
                .accessibilityAction(named: Text("Move later")) { store.shift(w.id, by: 1) }
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


/// Arranging Today's tiles: a tile carried over another takes its place at once, so the board rearranges under
/// the finger rather than only where it is let go.
struct ForgeWidgetDropDelegate: DropDelegate {
    let target: UUID
    @Binding var dragged: UUID?
    let store: ForgeTodayWidgetStore

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target else { return }
        withAnimation(.snappy) { store.move(dragged, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
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
        case .measure: ForgeMeasureWidget(key: widget.key ?? "hrv", source: widget.source,
                                          detailed: widget.size == .medium, wide: widget.size == .wide)
        case .trainingLoad: LiquidTrainingLoadSection(surfaceOpacity: surfaceOpacity ?? Double(opacityPercent) / 100)
        // The name inside the card, as every other widget carries it.
        case .goals: GoalsTodaySection(headerOutside: false)
        case .energy: ForgeEnergyWidget(compact: widget.compactSize)
        case .nutrition: ForgeNutritionWidget(compact: widget.compactSize)
        case .water: ForgeWaterWidget(detailed: widget.size == .medium)
        case .liveHeart:
            switch widget.size {
            case .wide: ForgeLiveHeartWideWidget()
            case .medium: ForgeLiveHeartWidget(showsCurve: true)
            case .small: ForgeLiveHeartWidget()
            }
        case .momentum: ForgeMomentumWidget()
        case .lastNight: ForgeLastNightWidget(compact: widget.compactSize)
        case .weekPlan: ForgeWeekPlanWidget()
        case .dietGoal: ForgeDietGoalWidget()
        case .coachNote: ForgeCoachNoteWidget()
        case .ageless:
            if widget.isWide { ForgeAgeLessWideWidget() } else { ForgeAgeLessWidget(detailed: widget.size == .medium) }
        case .lastWorkout: ForgeLastWorkoutWidget(compact: widget.compactSize)
        case .cycle: ForgeCycleWidget()
        case .tonight: ForgeTonightWidget(compact: widget.compactSize)
        case .breathe: ForgeBreatheWidget()
        case .nextSession: ForgeNextSessionWidget()
        case .changes: ForgeChangesWidget()
        case .whatWorks: ForgeWhatWorksWidget()
        case .strap: ForgeStrapWidget(detailed: widget.size == .medium)
        case .dayHeart: ForgeDayHeartWidget()
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
    /// The move's colour: green, yellow or red by what it means for the body; grey when it has none.
    var deltaColor: Color? = nil
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
                        // A tile that knows why it is empty ("Strap not connected") says so; the rest say no data yet.
                        caption: value == nil ? (caption ?? String(localized: "No data yet")) : caption,
                        tint: tint,
                        delta: value == nil ? nil : delta,
                        deltaColor: deltaColor ?? StrandPalette.textTertiary,
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
    /// Over two columns: the share of the goal beside it.
    var detailed = false
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @State private var totalML: Double = 0
    @State private var week: [Double] = []

    var body: some View {
        NavigationLink(value: TabRoute.hydration) {
            ForgeTodayTile(label: String(localized: "Hydration"), symbol: "drop.fill",
                           value: UnitFormatter.localizedMark(String(format: "%.1f", HydrationGoal.litres(fromML: totalML))),
                           unit: "L",
                           caption: caption,
                           tint: StrandPalette.metricCyan,
                           trend: week.count > 1 ? week : nil)
        }
        .buttonStyle(LiquidPressStyle())
        .task(id: repo.refreshSeq) {
            totalML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
            week = await repo.hydrationHistory(days: 7).map(\.value)
        }
    }

    private var caption: String {
        let goal = Double(repo.hydrationGoalML(profileSex: profile.sex))
        let of = String(localized: "of \(UnitFormatter.localizedMark(String(format: "%.1f", HydrationGoal.litres(fromML: goal)))) L")
        guard detailed, goal > 0 else { return of }
        return of + " · " + (totalML / goal).formatted(.percent.precision(.fractionLength(0)).locale(AppLanguage.activeLocale))
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

/// The heart rate right now as a small tile, with a heart beating at that rate. Opens the Live page. Over two
/// columns it also draws the pulse as a line: the last minute and a half while the strap streams, today's
/// five-minute trace while it does not.
struct ForgeLiveHeartWidget: View {
    var showsCurve = false
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var repo: Repository
    @State private var samples: [Double] = []
    @State private var banked: [Double] = []
    private let maxSamples = 90

    private var curve: [Double]? {
        guard showsCurve else { return nil }
        let line = samples.count >= 2 ? samples : banked
        return line.count >= 2 ? line : nil
    }

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
                           tint: StrandPalette.metricRose, trend: curve)
                .overlay(alignment: .bottomTrailing) {
                    if bpm != nil {
                        ForgeBeatingHeart(bpm: bpm)
                            .padding(12)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(LiquidPressStyle())
        .onChange(of: live.heartRate) { _, hr in
            guard showsCurve else { return }
            guard let hr, hr > 0, live.connected else { samples.removeAll(); return }
            samples.append(Double(hr))
            if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        }
        .task(id: showsCurve ? repo.refreshSeq : -1) {
            guard showsCurve else { banked = []; return }
            let now = Date()
            banked = await repo.hrBuckets(from: Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970),
                                          to: Int(now.timeIntervalSince1970), bucketSeconds: 300).map(\.bpm)
        }
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

/// Today's stress by the hour: the stress tile's row-wide form (2026-11-18).
///
/// One of the two named exceptions to "wider means more time". Thirty daily stress figures say very
/// little; the shape of today says most of what there is to say, and the app already draws it
/// (`DaytimeLoadLine`), so this is a choice of card rather than a second way of drawing one thing.
struct ForgeStressDayWidget: View {
    @EnvironmentObject private var repo: Repository
    @State private var hours: [DaytimeStress.HourPoint] = []

    var body: some View {
        NavigationLink(value: TabRoute.stress) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill").font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(StressRamp.calm)
                    Text("Stress through the day").font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(ForgeColor.text)
                    Spacer(minLength: 0)
                }
                if hours.contains(where: { $0.level != nil }) {
                    DaytimeLoadLine(hours: hours)
                } else {
                    // The honest blank, in the word the other stress cards already use: only waking hours
                    // score and an hour needs enough heart rate, so early morning is empty by
                    // construction rather than by failure.
                    Text("Calibrating").font(ForgeFont.caption).foregroundStyle(ForgeColor.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .forgeCard(radius: ForgeRadius.card, padding: 16)
        }
        .buttonStyle(LiquidPressStyle())
        .task(id: repo.refreshSeq) {
            hours = await StressDayCurve.today(repo: repo,
                                               personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled)?
                .result.timeline ?? []
        }
    }
}

/// Which of the two narrow sizes a shrunk card is drawn at: one column, or two.
enum TileSize { case small, medium }

/// A card shrunk to its one leading figure (owner, 2026-11-18).
///
/// The rule the owner set: a card may shrink only where it HAS one leading figure, and the small form is
/// that figure with its name. A card that carries a sentence keeps its one size, because a shortened
/// sentence is not a smaller fact.
///
/// One tile for all of them, so a shrunk Training load and a shrunk Last night sit on the same grid as the
/// measures beside them rather than each inventing its own small card.
struct ForgeCardTile: View {
    let symbol: String
    let label: String
    let value: String?
    var unit: String = ""
    /// Added over two columns, where there is room for the second fact.
    var caption: String? = nil
    let tint: Color
    let route: ForgeRoute?
    var tabRoute: TabRoute? = nil

    var body: some View {
        let tile = ForgeTodayTile(label: label, symbol: symbol, value: value, unit: unit,
                                  caption: caption, tint: tint)
        if let route {
            NavigationLink(value: route) { tile }.buttonStyle(LiquidPressStyle())
        } else if let tabRoute {
            NavigationLink(value: tabRoute) { tile }.buttonStyle(LiquidPressStyle())
        } else {
            tile
        }
    }
}

/// The last main night: hours asleep, its stages, bedtime to wake. Opens the Rest page.
struct ForgeLastNightWidget: View {
    @EnvironmentObject private var repo: Repository
    @State private var night: ForgeRecentSleep.Night?

    private var asleep: Int? { night.map { Int($0.asleepMinutes) } }

    /// Small: the hours. Over two columns: bedtime to wake beside them.
    var compact: TileSize? = nil

    var body: some View {
        if let compact {
            ForgeCardTile(symbol: "moon.fill", label: String(localized: "Last night"),
                          value: asleep.map { "\($0 / 60):\(String(format: "%02d", $0 % 60))" }, unit: "h",
                          caption: compact == .medium ? night.map { "\(Self.time($0.start)) – \(Self.time($0.end))" } : nil,
                          tint: ForgeColor.rest, route: ForgeRoute.rest(nil))
                .task(id: repo.refreshSeq) {
                    night = await ForgeRecentSleep.load(repo: repo, days: 3).nights.max { $0.end < $1.end }
                }
        } else {
            full
        }
    }

    @ViewBuilder private var full: some View {
        ForgeWidgetCard(title: String(localized: "Last night"), route: ForgeRoute.rest(nil)) {
            if let night, let asleep {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    // The figures large, their units small beside them, as Apple writes a duration.
                    Text(verbatim: "\(asleep / 60)").font(ForgeFont.figure(28)).foregroundStyle(ForgeColor.text)
                    Text("h").font(.system(.footnote, weight: .medium)).foregroundStyle(ForgeColor.secondary)
                    Text(verbatim: String(asleep % 60)).font(ForgeFont.figure(28)).foregroundStyle(ForgeColor.text)
                        .padding(.leading, 4)
                    Text("min").font(.system(.footnote, weight: .medium)).foregroundStyle(ForgeColor.secondary)
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

/// The way to the goal weight from the diet plan (owner, 2026-11-10), the plan page's card in small. It reads the
/// same plan, goal weight (`DietTargets.plannedGoalWeight`) and weight trend, so the two cannot disagree. Without a
/// plan it offers to make one.
struct ForgeDietGoalWidget: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @AppStorage(DietPlan.storageKey) private var planRaw = ""
    @State private var progress: DietProgress.Progress?

    var body: some View {
        NavigationLink(value: ForgeRoute.food) {
            if let progress {
                DietProgressCard(progress: progress, compact: true,
                                 male: profile.sex.lowercased() == "male" ? true : profile.sex.lowercased() == "female" ? false : nil)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Way to your goal").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    Text(message)
                        .font(.subheadline).foregroundStyle(ForgeColor.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .forgeCard(padding: 14)
            }
        }
        .buttonStyle(.plain)
        .task(id: planRaw) { await load() }
    }

    private var message: String {
        guard let plan = DietPlan.decode(planRaw) else { return String(localized: "Plan your diet to see your way here.") }
        if plan.hideNumbers { return String(localized: "Your plan keeps weight and numbers hidden.") }
        return String(localized: "Set a goal weight in your plan to see your way here.")
    }

    private func load() async {
        // A plan that hides weight and numbers keeps them off Today too.
        guard let plan = DietPlan.decode(planRaw), !plan.hideNumbers else { progress = nil; return }
        let p = Repository.analyticsProfile(profile)
        let person = DietPerson(weightKg: p.weightKg, heightCm: p.heightCm > 0 ? p.heightCm : nil, age: p.age > 0 ? Int(p.age) : nil,
                                male: p.sex.lowercased() == "male" ? true : p.sex.lowercased() == "female" ? false : nil)
        let weights = await repo.weightDailyValues(days: 120).map { (day: $0.day, kg: $0.value) }
        progress = DietProgress.resolve(plan: plan, goalWeightKg: DietTargets.plannedGoalWeight(plan, person: person),
                                        weighIns: weights)
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
                            // Three lines: at two the sentence broke off mid-word ("Die Charge ist st…"), which read
                            // as a fault rather than as more to read (design critique 2026-11-28).
                            Text(first.detail).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                // The card shows one message; say that there are more behind it, so the page is worth opening.
                if store.messages.count > 1 {
                    Text("\(store.messages.count - 1) more").font(ForgeFont.caption).foregroundStyle(ForgeColor.tertiary)
                }
                // A goal-type message carries its progress: draw it.
                if let progress = first.progress {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: min(1, max(0, progress.fraction))).tint(tint)
                        Text(verbatim: progress.label).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    }
                }
            } else {
                // "Nothing stands out" is a finding; it is only said once the feed was read with days behind it.
                // Before that, or with no days at all, the card says which it is (owner, 2026-11-25).
                Text(store.updatedAt == nil ? "Checking…" : store.recentDays.isEmpty ? "No data yet" : "Nothing stands out today.")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            }
        }
    }
}

/// A measure as the Health focus tiles draw it: its name, the latest value, the last 30 days.
struct ForgeMeasureWidget: View {
    let key: String
    let source: String?
    /// Over two columns (owner, 2026-11-11): the usual and the last 30 days' range under the figure.
    var detailed = false
    /// Across the whole row (owner, 2026-11-18): everything the two-column tile says, and under it the
    /// thirty days those words describe, drawn.
    var wide = false
    @EnvironmentObject private var repo: Repository
    @State private var values: [Double] = []
    @State private var dayPoints: [MeasureFacts.Point] = []
    @State private var metric: MetricDescriptor?
    /// Which scale the skin-temperature tile is on, nil for every other measure. Skin temperature is the
    /// one measure whose stored column holds two different things (#622), so the tile cannot take its
    /// unit from the catalogue: it has to say which of the two it is showing.
    @State private var skinKind: SkinTempDisplay.Kind?
    @AppStorage(UnitPrefs.skinTempDisplayKey) private var skinTempDisplayRaw = ""
    /// How much of today was calm, for the stress tile alone (`DaytimeStress.calmShare`).
    @State private var calmShare: Double?
    /// The goal for a measure whose goal is resolved rather than stored (protein, `FoodTargets.dayGoal`),
    /// asked for in `load()` and handed to every reading below, so the tile never works one out itself.
    @State private var resolvedTarget: Double?
    /// The wearer's calendar age, which the two ages measured in years are read against.
    @EnvironmentObject private var profile: ProfileStore

    /// This tile's goal: the resolved one where the measure has one, else the stored one. One funnel, so
    /// the goal bar, the facts line and the strip cannot each answer differently.
    private var target: Double? { resolvedTarget ?? MeasureFacts.storedTarget(forKey: key) }

    var body: some View {
        let m = metric ?? ForgeWidgetMeasures.descriptor(key, source)
        if wide {
            wideBody(m)
        } else {
            tileBody(m)
        }
    }

    /// The row-wide form. One rule, said in one line: the wider it is, the more time it shows.
    ///
    /// Two measures are named exceptions, because for them thirty days is the weaker answer: last night's
    /// stages beat thirty nights of duration, and today's stress by the hour beats thirty daily figures.
    /// Both are the cards this app already draws, so the exception is a choice of card, not a second way
    /// of drawing the same thing.
    @ViewBuilder private func wideBody(_ m: MetricDescriptor?) -> some View {
        switch key {
        case "sleep_total_min": ForgeLastNightWidget()
        case "stress": ForgeStressDayWidget()
        default: wideChart(m)
        }
    }

    @ViewBuilder private func wideChart(_ m: MetricDescriptor?) -> some View {
        let unit = leadUnit(m)
        // Thirty points, which for a measure written weekly is thirty weeks: the window is counted in
        // readings, as Android counts it, so the two phones draw the same stretch of history.
        let series = Array(values.suffix(30))
        NavigationLink(value: route(m)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: m?.icon ?? "chart.xyaxis.line")
                        .font(.system(.subheadline, weight: .semibold)).foregroundStyle(Self.tint(key))
                    Text(verbatim: Self.shortTitle(key) ?? m?.title ?? key)
                        .font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Spacer(minLength: 6)
                    // No stress branch here: stress has its own row-wide card and never reaches this one.
                    if let value = leadFigure(m) {
                        Text(verbatim: value).font(.system(.title3, weight: .semibold)).foregroundStyle(ForgeColor.text)
                        if !unit.isEmpty { Text(verbatim: unit).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary) }
                    }
                }
                // The caption describes the picture under it, so it is scoped to what that picture
                // covers. A day total draws its WEEK, and the usual-and-range line is read over thirty
                // readings: seven bars between 6.800 and 11.200 under "range 4.300 to 16.900" names two
                // ends a reader cannot find (2026-11-19). Those measures say the week's daily average
                // instead, which is the window the bars show AND the one thing the strip under them does
                // not already carry; every other measure draws thirty days and keeps the range, which is
                // read over exactly those thirty.
                if let line = Self.wideCaption(key: key, points: dayPoints, values: values, unit: unit) {
                    Text(verbatim: line).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
                if Self.isDayTotal(key) {
                    // A day total asks which DAYS, so its row-wide picture is the week (owner, 2026-11-19).
                    ForgeWeekBars(points: dayPoints, today: Repository.localDayKey(Date()),
                                  goal: target, tint: Self.tint(key),
                                  height: Self.wideChartHeight)
                } else if series.count > 1 {
                    TrendChart(points: Self.points(Array(dayPoints.suffix(series.count))),
                               gradient: Gradient(colors: [Self.tint(key).opacity(0.35), Self.tint(key)]),
                               valueRange: (series.min() ?? 0)...(max(series.max() ?? 1, (series.min() ?? 0) + 1)),
                               showsArea: true,
                               // No second reference drawn in here. The usual and the range are already in
                               // the caption above, from one resolver; a dashed rule re-derived from the
                               // plotted values could disagree with the words right over it.
                               height: Self.wideChartHeight, showsHover: false)
                } else {
                    // Short on purpose: a measure with nothing stored must not stand on Today as a tall
                    // empty card, which reads as broken rather than as empty.
                    Text("Not enough days yet").font(ForgeFont.caption).foregroundStyle(ForgeColor.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // The kit's floor for this size (owner, 2026-11-19): a chart and two more blocks, never
                // under five things said. Figure, change, caption and chart are four; these are the rest,
                // and they are what makes the extra room worth taking.
                ForgeFactStrip(blocks: Self.stripBlocks(key: key, points: dayPoints, values: values,
                                                        target: target))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Its own surface: the small and two-column forms get theirs from the tile, this one draws
            // its contents itself and would otherwise float on the page.
            .forgeCard(radius: ForgeRadius.card, padding: 16)
        }
        .buttonStyle(LiquidPressStyle())
        .task(id: repo.refreshSeq) { await load() }
    }

    /// The measures that are a day total rather than a reading: what you did that day, not what you were.
    /// Their row-wide form draws the week as bars instead of thirty days as a line.
    ///
    /// The list lives with the facts, because the drawn window also decides which best mark the strip under
    /// it may name — seen on screen as "highest 13,729 on 26 Oct" under seven bars that begin on a Friday.
    static func isDayTotal(_ key: String) -> Bool { MeasureFacts.drawsTheWeek(forKey: key) }

    /// A fixed height, not the row's: a row-wide tile has its row to itself, so nothing else is stretched
    /// by it, and the curve is then the same height on every phone instead of depending on its neighbour.
    static let wideChartHeight: CGFloat = 96

    /// The drawn window as the chart takes it, each point on the day it was actually recorded.
    ///
    /// Counted back one day per point until 2026-11-19, which is only true of a measure recorded daily.
    /// The fitness age is written weekly, so thirty of its points span seven months, and the chart dated
    /// them as thirty days: an axis reading "3 Nov to 15 Nov" under half a year of readings. Seen in the
    /// side-by-side, where Android's axis said July to November for the same tile.
    static func points(_ points: [MeasureFacts.Point]) -> [TrendPoint] {
        points.compactMap { point in
            WeightSeries.date(forDay: point.day).map { TrendPoint(date: $0, value: point.value) }
        }
    }

    /// The figure the tile leads with. Skin temperature is formatted on the scale it is actually on, so a
    /// wrist temperature reads "33.8" and a baseline move "+0.1" — never a deviation under a °C heading.
    private func leadFigure(_ m: MetricDescriptor?) -> String? {
        if key == "stress" { return values.last.map { Self.stressWord($0) } }
        if let kind = skinKind, let v = values.last {
            return SkinTempDisplay.numberString(v, kind: kind, fahrenheit: Self.fahrenheit)
        }
        return m.flatMap { ForgeFocusView.format(values.last, $0) }
    }

    /// Steps speak for themselves, and the word would crowd the number in a small tile; stress reads as a
    /// word ("Medium"), and "/3" beside a word said nothing. Skin temperature names its own scale.
    private func leadUnit(_ m: MetricDescriptor?) -> String {
        if key == "steps" || key == "stress" { return "" }
        if let kind = skinKind { return SkinTempDisplay.unitSymbol(kind: kind, fahrenheit: Self.fahrenheit) }
        return m.map(ForgeFocusView.unit) ?? ""
    }

    static var fahrenheit: Bool { ForgeToday.readerTemperatureUnit == .fahrenheit }

    @ViewBuilder private func tileBody(_ m: MetricDescriptor?) -> some View {
        NavigationLink(value: route(m)) {
            ForgeTodayTile(label: Self.shortTitle(key) ?? m?.title ?? key, symbol: m?.icon ?? "chart.xyaxis.line",
                           value: leadFigure(m),
                           unit: leadUnit(m),
                           // The measure's own fact first; the usual-and-range line stays for the measures
                           // whose fact is not built yet, so nothing loses what it already said.
                           caption: caption(m),
                           delta: Self.delta(key: key, values: values),
                           deltaColor: Self.deltaTone(key: key, values: values),
                           tint: Self.tint(key),
                           trend: values.count > 1 ? Array(values.suffix(30)) : nil)
        }
        .buttonStyle(LiquidPressStyle())
        .task(id: repo.refreshSeq) { await load() }
    }

    /// What the tile says under its figure over two columns: the measure's own fact first, and the
    /// usual-and-range line for the measures whose fact is not built yet, so nothing loses what it said.
    /// Weight opens its own page (trend, forecast, dates, reports); every other measure opens its explorer.
    private func route(_ m: MetricDescriptor?) -> TabRoute {
        key == "weight" ? .weight
            : .metricSourced(key: m?.key ?? key, source: m?.source ?? source ?? Repository.whoopSource)
    }

    private func caption(_ m: MetricDescriptor?) -> String? {
        guard detailed else { return nil }
        // Weight says what lies ahead over two columns (owner, 2026-11-26): the next date with its expected weight,
        // else the trend's weekly change, both worded by the weight page from its one snapshot. Not on the small
        // tile: there it sat beside the week's change chip, cut short, a second weekly figure next to the first.
        if key == "weight", let w = WeightWidgetSnapshot.load() {
            if let e = w.events.first { return "\(e.name): \(e.expected ?? "—") \(w.unit)" }
            if let rate = w.rateLine { return rate }
        }
        if key == "stress" {
            // What two columns add for stress (owner's table): the word alone says what today is, the
            // share says how it got there.
            return calmShare.map { share in
                String(localized: "\(share.formatted(.percent.precision(.fractionLength(0)).locale(AppLanguage.activeLocale))) of today calm")
            }
        }
        return Self.factsLine(key: key, points: dayPoints, unit: leadUnit(m),
                              calendarAge: profile.age > 0 ? Double(profile.age) : nil, target: target)
            ?? Self.summaryLine(key: key, values: values, unit: leadUnit(m))
    }

    /// The change against the wearer's usual and its colour, from the reading Android shares (`MeasureTileReading`).
    static func delta(key: String, values: [Double]) -> String? { MeasureTileReading.delta(key: key, values: values) }

    /// "usually 53 bpm · range 51 to 58", from the shared `MeasureTileReading.summary`.
    /// What a tile over two columns adds, per measure (owner, 2026-11-18): a fact about the wearer's own
    /// recent past rather than the same figure over a longer span.
    ///
    /// Nil for a measure whose fact is not built yet, and the caller then keeps the usual-and-range line,
    /// so this can be filled in measure by measure without anything losing what it already said. The
    /// numbers all come from `MeasureFacts`, which Android reads too; only the words are written here.
    static func factsLine(key: String, points: [MeasureFacts.Point], unit: String,
                          calendarAge: Double? = nil, target: Double? = nil) -> String? {
        guard !points.isEmpty else { return nil }
        let facts = MeasureFacts.read(points: points, today: Repository.localDayKey(Date()), target: target,
                                      direction: MeasureFacts.direction(forKey: key))
        func figure(_ value: Double?) -> String? {
            value.map { MeasureTileReading.figure(key: key, value: $0) }
        }
        func withUnit(_ text: String) -> String {
            unit.isEmpty || unit.hasPrefix("/") ? text : "\(text) \(unit)"
        }
        switch key {
        // Day totals: the week and its daily average. Steps, the energy burned, the calories eaten.
        case "steps", "active_kcal", "calories_in", "hr_zones13_min", "hr_zones45_min":
            guard let total = figure(facts.weekTotal), let average = figure(facts.weekAverage) else { return nil }
            return String(localized: "This week \(total) · \(average) a day")
        // Protein, the one macro with a goal of its own in the core: today against that goal, and how many
        // of the week's logged days reached it. The goal is resolved rather than stored, so it arrives from
        // the caller; without one the tile still says the week, as the other day totals do.
        case "protein_g":
            guard let eaten = figure(facts.today ?? facts.lastValue) else { return nil }
            guard let goal = facts.target, let goalText = figure(goal) else {
                guard let total = figure(facts.weekTotal), let average = figure(facts.weekAverage) else { return nil }
                return String(localized: "This week \(total) · \(average) a day")
            }
            let line = String(localized: "\(eaten) of \(withUnit(goalText)) today")
            guard let reached = facts.daysAboveTarget, facts.weekDaysWithEntry > 0 else { return line }
            return line + " · " + String(localized: "\(reached) of \(facts.weekDaysWithEntry) days reached")
        // Measured now and then rather than daily, like the weigh-in: when it was taken, and which way it
        // has gone since.
        case "weight", "body_fat", "lean_mass":
            guard let days = facts.daysSinceLast else { return nil }
            let when = days <= 0 ? String(localized: "today")
                     : days == 1 ? String(localized: "yesterday")
                     : String(localized: "\(days) days ago")
            guard let change = facts.weekChange else { return String(localized: "Weighed \(when)") }
            // Signed on purpose: which way it went is the fact, and "0,4 kg" alone would not say it.
            let sign = change > 0 ? "+" : change < 0 ? "−" : "±"
            let moved = withUnit(sign + MeasureTileReading.figure(key: key, value: abs(change)))
            return String(localized: "Weighed \(when) · \(moved) this week")
        // The two measures that ARE an age: how far the body's reading sits from the wearer's own years,
        // which is what the figure is for (owner's table, 2026-11-19). Vitality is a score rather than an
        // age, whatever the table grouped it with, so it keeps the quarter's change below.
        case "fitness_age", "body_age":
            guard let age = calendarAge, let reading = facts.today ?? facts.lastValue else { return nil }
            let gap = (age - reading).rounded()
            // Plural forms, not a count beside a bare plural noun: "1 years under your age" is not a
            // sentence, and the Tools gate says so.
            let line = gap > 0 ? String(localized: "\(Int(gap)) years under your age")
                     : gap < 0 ? String(localized: "\(Int(-gap)) years over your age")
                     : String(localized: "Right at your age")
            guard let change = facts.quarterChange, let text = figure(abs(change)) else { return line }
            let sign = change > 0 ? "+" : change < 0 ? "−" : "±"
            return line + " · " + String(localized: "\(sign + text) over 90 days")
        // Measures a week cannot move: the quarter's change is the only honest fact about their recent
        // past, and it is the one the owner's table asks for (2026-11-19).
        case "vo2max_est", "vitality":
            guard let change = facts.quarterChange, let text = figure(abs(change)) else { return nil }
            let sign = change > 0 ? "+" : change < 0 ? "−" : "±"
            return String(localized: "\(sign + text) over 90 days")
        // Readings taken once a day: the wearer's own last seven, and the span they moved in. Two facts,
        // because two columns must add a block to the small form rather than only a line (owner,
        // 2026-11-19); the span is the one every measure of this kind can answer.
        case "hrv", "rhr", "spo2", "resp_rate", "skin_temp", "sleep_total_min", "mood", "sleep_debt_min":
            guard let average = figure(facts.weekAverage) else { return nil }
            let line = String(localized: "7-day average \(withUnit(average))")
            guard let summary = MeasureTileReading.summary(key: key, values: points.map(\.value)) else { return line }
            return line + " · " + String(localized: "range \(summary.low) to \(summary.high)")
        default:
            return nil
        }
    }

    /// The blocks under the row-wide chart, with the words each one is read in.
    ///
    /// Which blocks, and their order, come from `MeasureFacts.strip`, which Android reads through the core —
    /// so "what else does this tile say" has one answer on both phones. Only the labels are written here.
    /// A best mark is named for the direction that counts as better for the measure, so the highest HRV and
    /// the lowest resting pulse both read as what they are.
    static func stripBlocks(key: String, points: [MeasureFacts.Point], values: [Double],
                            target: Double? = nil)
        -> [(label: String, value: String, detail: String?)] {
        guard !points.isEmpty else { return [] }
        let facts = MeasureFacts.read(points: points, today: Repository.localDayKey(Date()),
                                      target: target ?? MeasureFacts.storedTarget(forKey: key),
                                      direction: MeasureFacts.direction(forKey: key))
        return MeasureFacts.strip(key: key, facts: facts, values: values).compactMap { entry in
            func counted(_ label: String) -> (label: String, value: String, detail: String?)? {
                guard let count = entry.count, let total = entry.total else { return nil }
                return (label, String(localized: "\(count) of \(total)"), nil)
            }
            switch entry.item {
            case .best:
                guard let text = entry.text else { return nil }
                let label = MeasureFacts.direction(forKey: key) == .lowerIsBetter
                    ? String(localized: "Lowest") : String(localized: "Highest")
                return (label, text, entry.day.flatMap(Self.shortDate))
            case .weekAverage:
                return entry.text.map { (String(localized: "7-day average"), $0, nil) }
            case .weekTotal:
                return entry.text.map { (String(localized: "This week"), $0, nil) }
            case .range:
                guard let low = entry.text, let high = entry.text2 else { return nil }
                return (String(localized: "Range"), "\(low)–\(high)", nil)
            case .weekChange, .quarterChange:
                guard let text = entry.text else { return nil }
                // The sign is the fact: "0,4" alone does not say which way the week went.
                let sign = (entry.count ?? 0) > 0 ? "+" : (entry.count ?? 0) < 0 ? "−" : "±"
                let label = entry.item == .weekChange
                    ? String(localized: "This week") : String(localized: "Over 90 days")
                return (label, sign + text, nil)
            case .daysOverGoal: return counted(String(localized: "Over goal"))
            case .daysWithEntry: return counted(String(localized: "Days logged"))
            case .aboveUsual: return counted(String(localized: "Above usual"))
            case .targetLeft:
                return entry.text.map { (String(localized: "Left today"), $0, nil) }
            }
        }
    }

    /// The row-wide card's caption, scoped to the window its picture draws and to what the strip under it
    /// does not already say. Thirty days of line keep the usual and the range; the week's seven bars take
    /// the daily average, because the strip beside them already carries the week's total and its best.
    static func wideCaption(key: String, points: [MeasureFacts.Point], values: [Double], unit: String) -> String? {
        guard isDayTotal(key) else { return summaryLine(key: key, values: values, unit: unit) }
        let facts = MeasureFacts.read(points: points, today: Repository.localDayKey(Date()))
        guard let average = facts.weekAverage else { return nil }
        let text = MeasureTileReading.figure(key: key, value: average)
        let withUnit = unit.isEmpty || unit.hasPrefix("/") ? text : "\(text) \(unit)"
        return String(localized: "\(withUnit) a day")
    }

    /// A day key as the strip writes it: day and month, no year, because every mark is inside thirty days.
    static func shortDate(_ day: String) -> String? {
        guard let date = WeightSeries.date(forDay: day) else { return nil }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale))
    }

    static func summaryLine(key: String, values: [Double], unit: String) -> String? {
        guard let s = MeasureTileReading.summary(key: key, values: values) else { return nil }
        let usual = unit.isEmpty || unit.hasPrefix("/") ? s.usual : "\(s.usual) \(unit)"
        return String(localized: "usually \(usual)") + " · " + String(localized: "range \(s.low) to \(s.high)")
    }

    static func deltaTone(key: String, values: [Double]) -> Color? {
        switch MeasureTileReading.tone(key: key, values: values) {
        case .good?: return ForgeColor.chargeInk
        case .small?: return StrandPalette.statusWarningForeground
        case .large?: return StrandPalette.statusCritical
        case nil: return nil
        }
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
    /// WHICH colour a measure gets is decided once, in the shared table (`TileMeasures.tint`); this only
    /// says what that name is in this phone's palette.
    static func tint(_ key: String) -> Color {
        switch TileMeasures.tint(forKey: key) {
        case .charge: return StrandPalette.chargeColor
        case .effort: return StrandPalette.effortColor
        case .rest: return StrandPalette.restColor
        case .cyan: return StrandPalette.metricCyan
        case .rose: return StrandPalette.metricRose
        case .amber: return StrandPalette.metricAmber
        case .energy: return StrandPalette.energyHighlight
        }
    }

    /// The preferred source first, then any other source of the same measure that has data.
    /// Time asleep with its latest night taken from the same resolver the Sleep tab, the timeline and the
    /// Last night card read (`ForgeRecentSleep`), so the tile cannot print another figure for that night. The
    /// daily row can hold a different total (another source, a nap folded in); older days keep the series.
    private static func withLatestNight(_ series: [(day: String, value: Double)],
                                        repo: Repository) async -> [(day: String, value: Double)] {
        guard let night = await ForgeRecentSleep.load(repo: repo, days: 3).nights.max(by: { $0.end < $1.end })
        else { return series }
        let wakeDay = Repository.localDayKey(night.end)
        var out = series.filter { $0.day != wakeDay && $0.day < wakeDay }
        out.append((day: wakeDay, value: night.asleepMinutes))
        return out + series.filter { $0.day > wakeDay }
    }

    private func load() async {
        // One door for every measure (`StoreReader.tileHistory`), and Android reads through the same one:
        // the step resolver for steps, one skin-temperature scale, the gallery's source then any other
        // catalogue source for the rest. The days travel with the values, because the facts line asks when
        // something was last recorded, not only what it was (`MeasureFacts`).
        metric = ForgeWidgetMeasures.descriptor(key, source)
        let prefer = SkinTempDisplay.Kind(rawValue: skinTempDisplayRaw) ?? .absolute
        let history = await repo.tileHistory(key: key, days: TileMeasures.windowDays(forKey: key),
                                            skinTempPrefer: prefer)
        skinKind = history.skinKind
        if key == "sleep_total_min" {
            // The latest night from the resolver the Sleep tab, the timeline and the Last night card read,
            // so the tile cannot print another figure for the night they all show.
            let s = await Self.withLatestNight(history.points.map { (day: $0.day, value: $0.value) }, repo: repo)
            values = s.map(\.value)
            dayPoints = s.map { .init(day: $0.day, value: $0.value) }
            return
        }
        values = history.values
        dayPoints = history.points
        if MeasureFacts.resolvesItsTarget(forKey: key) {
            // Protein's goal is the day's macro goal, which only the goal resolver can answer. Asked
            // through the SAME reading the Nutrition tile loads, so the two tiles beside each other on
            // Today cannot name different protein goals.
            resolvedTarget = await ForgeNutritionReading.load(repo: repo, profile: profile)?.proteinGoal
        }
        if key == "stress" {
            // Over two columns stress says how much of today was calm (owner's table, 2026-11-19): a daily
            // figure as a word says what it is, the share of the day says how it got there. The same hours
            // the row-wide card draws, through the same resolver.
            let hours = await StressDayCurve.today(repo: repo,
                                                   personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled)?
                .result.hours
            calmShare = DaytimeStress.calmShare(hours ?? [])
        }
    }
}

/// The row of extra facts under a row-wide tile's chart: a quiet label with its figure, and a date under
/// the one figure that has one.
///
/// Up to three, side by side on one baseline, because a block that wraps onto a second line turns the strip
/// into a paragraph. Nothing is drawn when a short history answers none of them, so an empty strip costs no
/// room rather than leaving three labels over three dashes.
struct ForgeFactStrip: View {
    let blocks: [(label: String, value: String, detail: String?)]

    var body: some View {
        if !blocks.isEmpty {
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(blocks.prefix(3).enumerated()), id: \.offset) { _, block in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: block.label).font(ForgeFont.caption).foregroundStyle(ForgeColor.tertiary)
                        Text(verbatim: block.value)
                            .font(.system(.subheadline, weight: .semibold).monospacedDigit())
                            .foregroundStyle(ForgeColor.text)
                        if let detail = block.detail {
                            Text(verbatim: detail).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 2)
        }
    }
}

/// Seven bars, one for each day of the week ending today, with the weekday letters under them and a dashed
/// rule where there is a goal.
///
/// For a measure that is a DAY TOTAL this is the better row-wide picture than thirty days of line (owner,
/// 2026-11-19): steps, the energy burned, the water drunk and the minutes in a heart-rate zone are things
/// you do in a day, and the question is which days you did them on. A day with nothing recorded is drawn as
/// an empty slot rather than left out, so the week keeps its shape and a gap reads as a gap.
struct ForgeWeekBars: View {
    /// The series, day-keyed; only the seven days ending `today` are drawn.
    let points: [MeasureFacts.Point]
    let today: String
    let goal: Double?
    let tint: Color
    var height: CGFloat = 96

    var body: some View {
        let week = Self.week(points: points, today: today)
        let top = max(week.compactMap(\.value).max() ?? 0, goal ?? 0)
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(week, id: \.day) { slot in
                        let fraction = top > 0 ? min(1, max(0, (slot.value ?? 0) / top)) : 0
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            // Today solid, the days behind it quieter: the bar the wearer is still filling
                            // is the one being asked about.
                            .fill(tint.opacity(slot.day == today ? 1 : 0.5))
                            .frame(height: max(2, height * fraction))
                            .frame(maxWidth: .infinity)
                    }
                }
                if let goal, top > 0, goal <= top {
                    // One dashed rule for the goal, over the bars, so "over the goal" can be seen and not
                    // only read in the strip below.
                    Rectangle().fill(ForgeColor.secondary)
                        .frame(height: 1)
                        .offset(y: -height * CGFloat(goal / top))
                }
            }
            .frame(height: height, alignment: .bottom)
            HStack(spacing: 6) {
                ForEach(week, id: \.day) { slot in
                    Text(verbatim: Self.weekdayLetter(slot.day))
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// The seven day keys ending `today`, oldest first, each with its value where there is one.
    static func week(points: [MeasureFacts.Point], today: String) -> [(day: String, value: Double?)] {
        let byDay = Dictionary(points.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        return (0..<7).reversed().map { back in
            let day = MeasureFacts.dayKey(today, minusDays: back)
            return (day: day, value: byDay[day])
        }
    }

    static func weekdayLetter(_ day: String) -> String {
        guard let date = WeightSeries.date(forDay: day) else { return "" }
        return String(date.formatted(.dateTime.weekday(.narrow).locale(AppLanguage.activeLocale)).prefix(2))
    }
}

/// AgeLess as a small tile: the AgeLess age, with the calendar age under it. Opens the AgeLess page.
struct ForgeAgeLessWidget: View {
    /// Over two columns: the years against the calendar age as the change beside the figure.
    var detailed = false
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @State private var week: HealthspanWeek?

    var body: some View {
        NavigationLink(value: ForgeRoute.ageless) {
            ForgeTodayTile(label: "AgeLess", symbol: "hourglass",
                           value: week.map { HealthspanSection.years($0.result.healthspanAge) },
                           unit: String(localized: "years"),
                           caption: week.map { String(localized: "Age \(HealthspanSection.years($0.result.chronologicalAge))") },
                           delta: detailed ? week.map { Self.gapText($0.result.healthspanAge - $0.result.chronologicalAge) } : nil,
                           deltaColor: week.map { $0.result.healthspanAge <= $0.result.chronologicalAge ? ForgeColor.chargeInk : StrandPalette.statusCritical },
                           tint: week.map { $0.result.healthspanAge <= $0.result.chronologicalAge ? ForgeColor.charge : ForgeColor.effort }
                               ?? ForgeColor.accent)
        }
        .buttonStyle(LiquidPressStyle())
        .task(id: repo.refreshSeq) { week = await ForgeAgeLessWidget.latestWeek(repo: repo, profile: profile) }
    }

    /// The AgeLess age against the calendar age as a signed change, "↘ −2.1" younger, "↗ +1.4" older.
    static func gapText(_ gap: Double) -> String {
        let n = abs(gap).formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.activeLocale))
        return abs(gap) < 0.05 ? "±0" : gap < 0 ? "↘ −\(n)" : "↗ +\(n)"
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
    /// Small: how long it was. Over two columns: the sport beside it.
    var compact: TileSize? = nil

    var body: some View {
        Group {
            if let compact {
                ForgeCardTile(symbol: "figure.run", label: String(localized: "Latest workout"),
                              value: row?.durationS.map { ForgeTodayView.hoursMinutes($0 / 60) },
                              caption: compact == .medium ? row?.sport : nil,
                              tint: ForgeColor.effort,
                              route: row.map { ForgeRoute.workout(startTs: $0.startTs, sport: $0.sport) } ?? ForgeRoute.workouts)
            } else if let row {
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
                    Text(Repository.sessionName(row, titles: repo.sessionTitles))
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
    /// Over two columns: what the day has burned, with the resting and active parts that make it up.
    ///
    /// Not what was eaten. The Nutrition tile carries the eating (owner, 2026-11-18), so the day's intake
    /// is not stated twice on one page, and Android's energy card has the same two parts to say.
    var compact: TileSize? = nil

    var body: some View {
        if let compact {
            ForgeCardTile(symbol: "flame.fill", label: String(localized: "Energy"),
                          value: summary?.totalBurnedSoFar.map { String(Int($0.rounded())) }, unit: "kcal",
                          caption: compact == .medium ? Self.partsLine(summary) : nil,
                          tint: ForgeColor.effort, route: Optional<ForgeRoute>.none, tabRoute: TabRoute.energy)
                .task(id: repo.refreshSeq) { await loadEnergy() }
        } else {
            full
        }
    }

    /// "Resting 1.620 · Everyday 480 · Active 480", from the same summary the full card draws its ring from.
    static func partsLine(_ summary: DailyEnergySummary?) -> String? {
        guard let summary, let resting = summary.basalBurnedSoFar, let active = summary.activeBurnedSoFar
        else { return nil }
        var parts = [String(localized: "Resting") + " " + String(Int(resting.rounded()))]
        if let everyday = summary.everydayBurnedSoFar, everyday > 0 {
            parts.append(String(localized: "Everyday") + " " + String(Int(everyday.rounded())))
        }
        parts.append(String(localized: "Active") + " " + String(Int(active.rounded())))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var full: some View {
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
                        ForgeEnergyRing(resting: summary.basalBurnedSoFar, everyday: summary.everydayBurnedSoFar,
                                        active: summary.activeBurnedSoFar,
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
                                if let everyday = summary.everydayBurnedSoFar, everyday > 0 {
                                    figure(StrandPalette.forgeEnergyEveryday, String(localized: "Everyday"), everyday)
                                }
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
        .task(id: repo.refreshSeq) { await loadEnergy() }
    }

    /// One loader for both forms, so the small tile and the card can never show different burns.
    private func loadEnergy() async {
        let today = Repository.logicalDayKey(Date())
        let all = await repo.energySummaries(days: 30, profile: Repository.analyticsProfile(profile))
        summary = all.first { $0.day == today }
        usual = ForgeEnergyView.usualTotal(all, today: today)
        eaten = await repo.intakeByDay(from: today, to: today)[today]
        loaded = true
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
    @EnvironmentObject private var repo: Repository
    /// Whether anything has been eaten at all, which decides if the Nutrition tile is offered.
    @State private var foodLogged = false

    var body: some View {
        NavigationStack {
            List {
                // One section per catalogue group (owner, 2026-11-18): twenty-odd measures in a single run
                // is a list nobody reads to the end.
                ForEach(ForgeWidgetMeasures.sections) { group in
                    Section {
                        ForEach(group.measures) { m in
                            if let d = ForgeWidgetMeasures.descriptor(m.key, m.source) {
                                row(symbol: d.icon, title: d.title,
                                    subtitle: ForgeTodayWidget.wholeRowMeasures.contains(m.key)
                                        ? String(localized: "Wide · its thirty days")
                                        : String(localized: "Small · the latest value and its month")) {
                                    store.add(.init(kind: .measure, key: m.key, source: m.source))
                                }
                            }
                        }
                    } header: { Text(verbatim: ForgeWidgetMeasures.title(group.section)) }
                }
                Section {
                    row(symbol: "chart.bar.fill", title: String(localized: "Training load"),
                        subtitle: String(localized: "Wide · both lanes against your usual")) { store.add(.init(kind: .trainingLoad)) }
                    row(symbol: "flag.fill", title: String(localized: "Goals"),
                        subtitle: String(localized: "Wide · this week's goals")) { store.add(.init(kind: .goals)) }
                    row(symbol: "flame.fill", title: String(localized: "Energy"),
                        subtitle: String(localized: "Wide · burned and eaten today")) { store.add(.init(kind: .energy)) }
                    // Offered only once something has been eaten, as the cycle card is offered only to the
                    // people it is for: an empty Nutrition tile is a goal with nothing to weigh against it.
                    if foodLogged {
                        row(symbol: "fork.knife", title: String(localized: "Nutrition"),
                            subtitle: String(localized: "Small · what is left of today")) { store.add(.init(kind: .nutrition)) }
                    }
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
                    row(symbol: "mountain.2.fill", title: String(localized: "Way to your goal"),
                        subtitle: String(localized: "Wide · how far your diet plan has come")) { store.add(.init(kind: .dietGoal)) }
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
                    row(symbol: "heart.text.square.fill", title: String(localized: "Heart rate through the day"),
                        subtitle: String(localized: "Wide · the whole day, with sleep and workouts")) { store.add(.init(kind: .dayHeart)) }
                } header: { Text("Cards") }
            }
            .scrollContentBackground(.hidden)
            .background(ForgeColor.canvas.ignoresSafeArea())
            .navigationTitle(Text("Add a widget"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { foodLogged = await ForgeNutritionReading.load(repo: repo, profile: profile)?.logged ?? false }
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
        .background(ForgeCardSurface(radius: ForgeRadius.card))
    }
}
