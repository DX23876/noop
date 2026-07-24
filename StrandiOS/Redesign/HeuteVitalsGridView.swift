import SwiftUI
import Charts
import StrandDesign
import WhoopStore

// MARK: - Vitalwerte-Raster + Bearbeitungsmodus (docs/feature-spec.md §4; docs/design/design-spec.md §4)
//
// Tiles render from `VitalTileConfigStore` (already built) — never hardcoded, so a new metric only
// needs an id appended to `VitalGridMetric.available` (Strand/Data/VitalTileConfig.swift). The wide
// "Activity" row is NOT one of the six configurable metrics — the mockup exempts it from the edit
// system entirely (`.grid.editing .tile.wide{animation:none}`, its remove badge is hidden), so it's a
// fixed, always-shown, non-draggable row here too, not part of `configs`.

/// A tile's live data — kept as plain parameters (not a Repository lookup) so this view stays
/// data-agnostic/previewable, matching `HeuteRingsView`/`HeuteCardZoneView`'s convention.
struct HeuteVitalReading {
    var value: Double
    var asOf: String
    var sparkline: [Double] = []
    /// A pre-formatted value string that overrides the generic `number + unit` rendering — e.g. Sleep's
    /// "7h 32m", where the raw `452 min` would be meaningless. When set, the tile shows this verbatim and
    /// draws no separate unit label. nil → the normal numeric formatting from the descriptor.
    var valueText: String? = nil
}

struct HeuteVitalsGridView: View {
    /// Keyed by MetricCatalog id (`"source:key"`, e.g. `"my-whoop:hrv"`). A visible tile with no entry
    /// here renders nothing (design-spec §0.2: "keine leeren Kacheln").
    let readings: [String: HeuteVitalReading]
    /// The selected day's latest workout, or nil to hide the wide Activity row (same "no data, no tile"
    /// rule). Rendered as a tappable card — sport, duration/calories, effort — matching the last-workout
    /// affordance the other two Today screens show.
    var workout: WorkoutRow?

    /// The user's Effort scale (0–21 vs 0–100), so the workout card's effort read-out matches the hero
    /// rings and every other Effort surface in the app.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { EffortScale(rawValue: effortScaleRaw) ?? .hundred }

    /// Detailed tiles + trend window — the SAME `@AppStorage` keys classic Today and Liquid Today read
    /// (`KeyMetricsEditorSheet`), not Heute-private ones, so a toggle on any screen applies to all three
    /// ("keine Unterschiede zwischen den Screens", on-device feedback). Sparklines only draw while
    /// Detailed is on; the window trims each tile's trailing history to 2 days / 1 week / 2 weeks.
    @AppStorage("today.keyMetricsDetailed") private var keyMetricsDetailed = false
    @AppStorage("today.keyMetricsWindowDays") private var keyMetricsWindowDays = 14

    @State private var configs = VitalTileConfigStore.load()
    @State private var density = VitalTileConfigStore.density(UserDefaults.standard.integer(forKey: VitalTileConfigStore.densityKey))
    @State private var editing = false
    @State private var draggingId: String?
    @State private var dragTranslation: CGSize = .zero
    @State private var tileFrames: [String: CGRect] = [:]
    /// Drag anchor, frozen at lift (see `dragGesture(for:)`): the slot rectangles in visual order, the
    /// slot the dragged tile started in, the finger position at lift, and the slot the last reorder was
    /// triggered by (the boundary-crossing debounce).
    @State private var dragSlots: [CGRect] = []
    @State private var dragAnchorSlot = 0
    @State private var dragStartLocation: CGPoint = .zero
    @State private var dragHoveredSlot: Int?

    private let gridSpace = "heuteVitalsGrid"

    private var visibleConfigs: [VitalTileConfig] {
        // "Keine leeren Kacheln": a visible metric with no reading is dropped — EXCEPT the nav-only
        // special tiles (Coupled view), which never carry a value yet must still show once un-hidden.
        VitalTileConfigStore.visibleTiles(configs).filter {
            readings[$0.metricId] != nil || Self.navOnlyTiles.contains($0.metricId)
        }
    }
    private var hiddenConfigs: [VitalTileConfig] {
        configs.filter { !$0.visible }
    }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: NoopMetrics.space4), count: density)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if editing { editBar }
            grid
            if !hiddenConfigs.isEmpty { hiddenTray }
        }
        .onChange(of: density) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: VitalTileConfigStore.densityKey)
        }
    }

    // MARK: Header / edit bar

    // No "Edit" affordance here any more (on-device feedback: the separate button was redundant). The
    // only way into edit mode is a long-press on a tile (`onEnterEdit`); the exit is the edit bar's "Done".
    private var header: some View {
        HStack {
            Text("Vitals")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.1)
                .textCase(.uppercase)
                .foregroundStyle(HeuteRedesignPalette.ink3)
            Spacer()
        }
    }

    /// The in-place edit controls, shown while `editing`. Beyond the column-density switch it now carries
    /// the two options the classic "Edit Key Metrics" sheet has — Detailed tiles + trend window — bound to
    /// the shared `@AppStorage` keys so all three Today screens stay in step.
    private var editBar: some View {
        VStack(spacing: 12) {
            HStack {
                SegmentedPillControl([2, 3], selection: $density) { "\($0)" }
                Spacer()
                Button("Done") { editing = false }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(HeuteRedesignPalette.charge)
                    .buttonStyle(.plain)
            }
            Divider().overlay(HeuteRedesignPalette.line)
            HStack {
                Text("Detailed tiles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HeuteRedesignPalette.ink2)
                Spacer()
                Toggle("", isOn: $keyMetricsDetailed)
                    .labelsHidden()
                    .tint(HeuteRedesignPalette.charge)
            }
            if keyMetricsDetailed {
                HStack {
                    Text("Trend window")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HeuteRedesignPalette.ink2)
                    Spacer()
                    SegmentedPillControl([2, 7, 14], selection: $keyMetricsWindowDays,
                                         adaptsToAvailableWidth: true) { windowLabel($0) }
                }
            }
        }
        .padding(12)
        .background(HeuteRedesignPalette.tile, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HeuteRedesignPalette.line, lineWidth: 1))
    }

    /// The trend-window pill labels — reusing the classic editor's exact strings ("2 days" / "1 week" /
    /// "2 weeks", `KeyMetricsEditorSheet`), so no new localization is introduced.
    private func windowLabel(_ days: Int) -> String {
        switch days {
        case 2:  return String(localized: "2 days")
        case 7:  return String(localized: "1 week")
        default: return String(localized: "2 weeks")
        }
    }

    // MARK: Grid

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: NoopMetrics.space4) {
            ForEach(Array(visibleConfigs.enumerated()), id: \.element.metricId) { index, config in
                if let descriptor = metricDescriptor(config.metricId) {
                    let isDragging = draggingId == config.metricId
                    let navOnly = Self.navOnlyTiles.contains(config.metricId)
                    // Non-nav tiles are guaranteed a reading by `visibleConfigs`; a nav-only tile (Coupled)
                    // gets a placeholder its layout ignores.
                    let reading = readings[config.metricId] ?? HeuteVitalReading(value: 0, asOf: "")
                    HeuteVitalTile(
                        descriptor: descriptor, reading: reading,
                        route: route(for: config.metricId, descriptor: descriptor), navOnly: navOnly,
                        density: density, detailed: keyMetricsDetailed, windowDays: keyMetricsWindowDays,
                        editing: editing, isDragging: isDragging, wiggleDelay: index.isMultiple(of: 2) ? 0 : 0.06,
                        onRemove: { setVisible(config.metricId, false) },
                        onEnterEdit: { editing = true }
                    )
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: TileFramePreferenceKey.self,
                                                value: [config.metricId: geo.frame(in: .named(gridSpace))])
                    })
                    .offset(isDragging ? dragTranslation : .zero)
                    .zIndex(isDragging ? 1 : 0)
                    // High-priority: this grid lives inside `HeuteRedesignView`'s ScrollView, and a plain
                    // `.gesture()` here routinely loses the arbitration against the ScrollView's own pan
                    // gesture (on-device bug report: dragging a tile produced no visible movement — the
                    // touch was being consumed by scrolling instead). High-priority wins that race while
                    // editing, matching the same pattern the remove badge below already uses for the same
                    // reason.
                    .highPriorityGesture(editing ? dragGesture(for: config.metricId) : nil)
                }
            }

            if let workout {
                HeuteActivityTile(workout: workout, effortScale: effortScale)
                    .gridCellColumns(density)
            }
        }
        .coordinateSpace(name: gridSpace)
        .onPreferenceChange(TileFramePreferenceKey.self) { tileFrames = $0 }
    }

    /// Editing-gated drag-to-reorder: no separate "press and hold to lift" step (the tile is already
    /// wiggling — you can drag it immediately, matching the iOS home-screen convention), tracked via
    /// `tileFrames` (collected through `TileFramePreferenceKey`) rather than `.onDrag`/`.onDrop` (which
    /// requires its own activation hold and was previously attached even outside edit mode — see the
    /// on-device bug report this replaced).
    ///
    /// Three properties make it stop oscillating (the on-device bug where a tile ping-ponged between two
    /// slots as long as the finger was held still):
    /// 1. **Frozen anchor.** The slot geometry is snapshotted at lift (`dragSlots`) and hit-testing runs
    ///    against that snapshot, never against the live `tileFrames` — which move *because* of the drag
    ///    (the dragged tile carries an `.offset`, the others re-slot on reorder), i.e. the old code fed
    ///    its own output back into its input.
    /// 2. **Debounced reorder.** A reorder happens only when the finger crosses into a *different* slot,
    ///    not on every gesture frame; re-running `move` + `withAnimation` per frame restarted the
    ///    animation continuously and was what made it look like a vibration.
    /// 3. **Finger-relative position.** The visible offset is recomputed from the anchor slot plus the
    ///    live finger delta, minus the slot the tile currently occupies, so the tile stays glued under
    ///    the finger even after its own slot changed mid-drag. The order is only persisted on drop.
    private func dragGesture(for metricId: String) -> some Gesture {
        DragGesture(coordinateSpace: .named(gridSpace))
            .onChanged { value in
                let order = visibleConfigs.map(\.metricId)
                if draggingId != metricId { beginDrag(metricId, at: value.startLocation, order: order) }

                let currentSlot = order.firstIndex(of: metricId) ?? dragAnchorSlot
                let anchor = slot(dragAnchorSlot)
                let current = slot(currentSlot)
                dragTranslation = CGSize(
                    width: anchor.minX + (value.location.x - dragStartLocation.x) - current.minX,
                    height: anchor.minY + (value.location.y - dragStartLocation.y) - current.minY)

                let hovered = dragSlots.firstIndex { $0.contains(value.location) }
                guard hovered != dragHoveredSlot else { return }   // still inside the same slot
                dragHoveredSlot = hovered
                if let hovered, hovered != currentSlot, order.indices.contains(hovered) {
                    reorder(dragging: metricId, over: order[hovered])
                }
            }
            .onEnded { _ in endDrag() }
    }

    private func beginDrag(_ metricId: String, at start: CGPoint, order: [String]) {
        draggingId = metricId
        dragStartLocation = start
        // Slot rectangles in visual order. The grid's geometry doesn't change during a drag (same tiles,
        // same density), only which tile sits in which slot — so this snapshot stays valid throughout.
        dragSlots = order.map { tileFrames[$0] ?? .zero }
        dragAnchorSlot = order.firstIndex(of: metricId) ?? 0
        dragHoveredSlot = dragAnchorSlot
    }

    private func endDrag() {
        // The settle IS animated (the tile glides from under the finger into its slot); the mid-drag
        // re-slotting deliberately is not — see `reorder`.
        withAnimation(StrandMotion.interactive) {
            draggingId = nil
            dragTranslation = .zero
        }
        dragSlots = []
        dragHoveredSlot = nil
        // The final slotting is what gets persisted — nothing is written mid-drag.
        for i in configs.indices { configs[i].sortOrder = i }
        VitalTileConfigStore.save(configs)
    }

    private func slot(_ index: Int) -> CGRect {
        dragSlots.indices.contains(index) ? dragSlots[index] : .zero
    }

    /// Deliberately NOT wrapped in `withAnimation`: the dragged tile's offset is compensated against the
    /// slot it occupies *after* the move (see `dragGesture`), so an animated move would leave the tile
    /// visually a whole slot away from the finger for the animation's duration — the exact one-slot jump
    /// this rework is meant to remove. The settle at drop is animated instead (`endDrag`).
    private func reorder(dragging draggingId: String, over targetId: String) {
        guard let from = configs.firstIndex(where: { $0.metricId == draggingId }),
              let to = configs.firstIndex(where: { $0.metricId == targetId }) else { return }
        configs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        for i in configs.indices { configs[i].sortOrder = i }
    }

    // MARK: Hidden tray

    private var hiddenTray: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hidden")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.1)
                .textCase(.uppercase)
                .foregroundStyle(HeuteRedesignPalette.ink3)
            FlowRow(spacing: 8) {
                ForEach(hiddenConfigs, id: \.metricId) { config in
                    if let descriptor = metricDescriptor(config.metricId) {
                        Button {
                            withAnimation(StrandMotion.interactive) { setVisible(config.metricId, true) }
                        } label: {
                            HStack(spacing: 5) {
                                Text("+").foregroundStyle(HeuteRedesignPalette.charge).fontWeight(.bold)
                                Text(descriptor.title)
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HeuteRedesignPalette.ink2)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(HeuteRedesignPalette.tile, in: Capsule())
                            .overlay(Capsule().strokeBorder(HeuteRedesignPalette.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HeuteRedesignPalette.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }

    // MARK: Helpers

    private func metricDescriptor(_ metricId: String) -> MetricDescriptor? {
        // The `heute:…` special tiles don't resolve through the catalog — they carry their own
        // title/icon (matching `DashboardCard` so the wording stays app-wide consistent).
        if let special = Self.specialDescriptors[metricId] { return special }
        guard let colonIndex = metricId.firstIndex(of: ":") else { return nil }
        let source = String(metricId[metricId.startIndex..<colonIndex])
        let key = String(metricId[metricId.index(after: colonIndex)...])
        return MetricCatalog.metric(key: key, source: source)
    }

    /// The tap destination for a tile. The special tiles route to their own full screen (matching Liquid
    /// Today's `cardLink` choices) instead of the generic metric-detail page; everything else opens its
    /// `MetricCatalog` detail, exactly as before.
    private func route(for metricId: String, descriptor: MetricDescriptor) -> TabRoute {
        switch metricId {
        case "heute:sleep":     return .sleep
        case "heute:hydration": return .hydration
        case "heute:coupled":   return .coupled
        default:                return .metricSourced(key: descriptor.key, source: descriptor.source)
        }
    }

    /// Special tiles that carry no value at all (pure navigation): shown even without a `reading`, and
    /// rendered as icon + title + chevron rather than a number.
    static let navOnlyTiles: Set<String> = ["heute:coupled"]

    /// Locally-built descriptors for the `heute:…` tiles — title/icon lifted verbatim from `DashboardCard`
    /// (`Strand/Screens/DashboardCards.swift`) so Sleep/Hydration/Coupled read identically wherever they
    /// appear. `source` is the synthetic `"heute"` partition; these never touch `MetricCatalog`.
    static let specialDescriptors: [String: MetricDescriptor] = [
        "heute:sleep": MetricDescriptor(key: "sleep", title: String(localized: "Sleep"), category: "Rest",
                                        unit: "", source: "heute", icon: "bed.double.fill",
                                        decimals: 0, higherIsBetter: true),
        "heute:hydration": MetricDescriptor(key: "hydration", title: String(localized: "Hydration"),
                                            category: "Health", unit: "ml", source: "heute",
                                            icon: "waterbottle.fill", decimals: 0, higherIsBetter: true),
        "heute:coupled": MetricDescriptor(key: "coupled", title: String(localized: "Coupled view"),
                                          category: "Health", unit: "", source: "heute",
                                          icon: "circle.hexagongrid.fill", decimals: 0, higherIsBetter: nil),
    ]

    private func setVisible(_ metricId: String, _ visible: Bool) {
        guard let index = configs.firstIndex(where: { $0.metricId == metricId }) else { return }
        configs[index].visible = visible
        VitalTileConfigStore.save(configs)
    }
}

// MARK: - Drag-reorder

/// Collects each visible tile's on-screen frame (in the grid's own coordinate space) as it's laid out,
/// so `dragGesture(for:)` above can hit-test the dragged finger position against every OTHER tile
/// without needing `.onDrag`/`.onDrop`'s system drag-and-drop machinery.
private struct TileFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Vital tile

private struct HeuteVitalTile: View {
    let descriptor: MetricDescriptor
    let reading: HeuteVitalReading
    /// Where a tap goes — `.metricSourced` for a normal metric, or a special tile's own screen.
    let route: TabRoute
    /// True for a pure-navigation tile (Coupled view): renders icon + title + chevron, no number/sparkline.
    var navOnly: Bool = false
    let density: Int
    /// The shared "Detailed tiles" switch — sparklines only draw while it's on (matches classic/Liquid).
    var detailed: Bool = false
    /// The shared trend window (days) — trims the tile's trailing sparkline history.
    var windowDays: Int = 14
    let editing: Bool
    /// True while THIS tile is the one currently being dragged — freezes its own wiggle so it reads as
    /// "picked up" rather than still trembling under the finger (on-device bug report: dragging felt
    /// jittery because every tile, including the one being moved, kept wiggling through the gesture).
    let isDragging: Bool
    let wiggleDelay: Double
    let onRemove: () -> Void
    /// design-spec §4's second edit-mode trigger ("Long-Press auf eine beliebige Kachel") — was missing;
    /// only the "Edit" label worked before.
    let onEnterEdit: () -> Void

    private var isNeutral: Bool { descriptor.key == "steps" }
    private var accent: Color {
        switch descriptor.key {
        case "hrv": return HeuteRedesignPalette.icHrv
        case "rhr": return HeuteRedesignPalette.icRhr
        case "resp_rate": return HeuteRedesignPalette.icResp
        case "spo2": return HeuteRedesignPalette.icSpo2
        case "fitness_age": return HeuteRedesignPalette.icFitage
        case "weight": return HeuteRedesignPalette.icWeight
        case "energy_kcal": return HeuteRedesignPalette.icCalories
        // Special tiles: Rest violet for Sleep, cyan for Hydration, Charge green for the Coupled overview.
        case "sleep": return HeuteRedesignPalette.rest
        case "hydration": return HeuteRedesignPalette.icSpo2
        case "coupled": return HeuteRedesignPalette.charge
        default: return HeuteRedesignPalette.ink3
        }
    }
    private var badgeSize: CGFloat { density == 3 ? 24 : 30 }
    private var numberSize: CGFloat { density == 3 ? 20 : 30 }
    private var innerPadding: CGFloat { density == 3 ? 13 : 18 }
    /// One fixed height every tile snaps to regardless of content (sparkline vs. none, or a tile that
    /// individually has <2 spark points while its row-mates do) — same rationale as
    /// `NoopMetrics.keyMetricTileHeight`: a row of tiles must read as ONE row, not a jagged one. Keyed off
    /// `detailed` (the screen-wide toggle), not per-tile `showSparkline`, for exactly that reason. Density
    /// 2's 178 already has sparkline headroom baked in unconditionally (was 150, too tight once "Detailed
    /// tiles" shipped — badge+title+number+sparkline+caption summed to ~173pt, real clipping at default
    /// Dynamic Type). Density 3 only grows to 150 while Detailed is on — on-device feedback: sparklines
    /// were 2-column-only, but 3-column has room for a slightly smaller graph too; 128 stays the default
    /// when Detailed is off, unchanged from before.
    private var tileHeight: CGFloat {
        density == 3 ? (detailed ? 150 : 128) : 178
    }
    /// The sparkline's own height — a touch smaller at 3-column density, where there's less vertical room.
    private var sparklineHeight: CGFloat { density == 3 ? 16 : 22 }
    /// The tile's sparkline, trimmed to the shared trend window (2 / 7 / 14 days). Same "suffix, not a
    /// calendar-day filter" approximation classic Today uses — the source array is already ≤ the selected
    /// day, so trailing-N is the last N banked days.
    private var windowedSparkline: [Double] { Array(reading.sparkline.suffix(windowDays)) }
    /// Sparklines are gated on the shared "Detailed tiles" switch (parity with classic/Liquid) and ≥2
    /// points after windowing (a single point draws an empty plot area — the "keine leeren Kacheln" rule).
    /// No longer density-gated (on-device feedback: 3-column had room for a smaller graph too, just not
    /// the same 22pt-tall one 2-column uses — see `sparklineHeight`/`tileHeight`).
    private var showSparkline: Bool { detailed && windowedSparkline.count >= 2 }
    /// The value line: a caller-supplied override (Sleep's "7h 32m") wins; otherwise the descriptor's
    /// numeric formatting.
    private var numberText: String {
        if let t = reading.valueText { return t }
        return descriptor.decimals == 0 ? "\(Int(reading.value.rounded()))" : String(format: "%.\(descriptor.decimals)f", reading.value)
    }

    // NOTE: the remove badge is a SIBLING overlay, not nested inside a tap-gesture-bearing container —
    // a Button nested inside another Button's hit-testing tree doesn't reliably receive taps in SwiftUI.
    // Also: the NavigationLink/long-press below is hit-test-DISABLED while editing (not just
    // action-gated) so it never competes with the outer drag-to-reorder gesture the parent grid attaches
    // to this whole tile — two live recognizers on overlapping regions was exactly the "still jittery
    // during drag" bug on-device.
    //
    // A real push, not a no-op closure (on-device feedback: tiles didn't open anything) — the same
    // `TabRoute.metricSourced` every other screen's card taps use (TodayView.swift), resolved by
    // `.tabRouteDestinations()` on the ambient NavigationStack `RootTabView`'s `tab(...)` helper already
    // wraps this whole screen in, so no extra wiring is needed here beyond the link itself.
    var body: some View {
        // Wiggle is driven by wall-clock time (`TimelineView`), not a `repeatForever` `Animation` object —
        // on-device bug report: tiles kept wiggling after tapping "Done" even with the previous declarative
        // `.animation(value:)` binding (a known SwiftUI limitation: a running `repeatForever` is notoriously
        // unreliable to interrupt cleanly, regardless of how the animation-curve switch is expressed). A
        // pure function of time sidesteps the whole class of bug: there is nothing long-lived to cancel —
        // the instant `editing` (or `isDragging`) flips, this branch stops rendering the TimelineView
        // entirely and the rotation simply stops being computed, snapping back with a short, ordinary,
        // non-repeating animation.
        Group {
            if editing && !isDragging {
                TimelineView(.animation) { context in
                    tileStack.rotationEffect(.degrees(wiggleAngle(at: context.date)))
                }
            } else {
                tileStack
                    .rotationEffect(.degrees(0))
                    .animation(.easeOut(duration: 0.12), value: editing)
            }
        }
    }

    /// The wiggle angle at a given moment: a plain sine wave (no `Animation` object involved), period
    /// matched to the old `easeInOut(duration: 0.28)` autoreversing pair (0.28s out + 0.28s back = 0.56s
    /// full cycle), `wiggleDelay` offsetting each tile's phase for the organic "not perfectly in sync" look.
    private func wiggleAngle(at date: Date) -> Double {
        let period = 0.56
        let t = date.timeIntervalSinceReferenceDate + wiggleDelay
        let phase = t.truncatingRemainder(dividingBy: period) / period
        return sin(phase * 2 * .pi) * 0.7
    }

    private var tileStack: some View {
        ZStack(alignment: .topLeading) {
            NavigationLink(value: route) {
                tileContent
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in onEnterEdit() })
            .allowsHitTesting(!editing)
            if editing {
                Button(action: onRemove) {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(HeuteRedesignPalette.attn, in: Circle())
                        .overlay(Circle().strokeBorder(HeuteRedesignPalette.bg, lineWidth: 2))
                }
                .buttonStyle(.plain)
                // The badge is NOT part of the drag surface: this high-priority gesture claims every
                // touch that starts on it, so the parent grid's reorder `DragGesture` never activates
                // here and a slightly imprecise tap deletes instead of dragging the tile away. It also
                // supersedes the Button's own tap (so `onRemove` fires exactly once); the Button itself
                // stays for its hit shape and VoiceOver activation.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            let moved = max(abs(value.translation.width), abs(value.translation.height))
                            if moved < 12 { onRemove() }
                        }
                )
                .offset(x: -7, y: -7)
                .accessibilityLabel(Text("Hide \(descriptor.title)"))
            }
        }
    }

    private var tileContent: some View {
        ZStack(alignment: .topLeading) {
            if !isNeutral {
                accent.opacity(0.10)
            }
            if navOnly {
                navContent
            } else {
                valueContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: tileHeight, alignment: .topLeading)
        .background(HeuteRedesignPalette.tile, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(HeuteRedesignPalette.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    /// The standard number tile: badge, title, value(+unit), optional sparkline, and the "as of" caption.
    private var valueContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            badge
            Text(descriptor.title)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.1)
                .textCase(.uppercase)
                .foregroundStyle(HeuteRedesignPalette.ink3)
                .padding(.top, 10)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(numberText)
                    .font(.system(size: numberSize, weight: .bold))
                    .foregroundStyle(HeuteRedesignPalette.ink)
                // No separate unit chip when the value line is a pre-formatted override (it already
                // carries its own unit, e.g. Sleep's "7h 32m").
                if reading.valueText == nil, !descriptor.unit.isEmpty {
                    Text(descriptor.unit)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HeuteRedesignPalette.ink3)
                }
            }
            .padding(.top, 2)
            if showSparkline {
                Chart {
                    ForEach(Array(windowedSparkline.enumerated()), id: \.offset) { point in
                        LineMark(x: .value("i", point.offset), y: .value("v", point.element))
                            .foregroundStyle(accent.opacity(0.7))
                            .interpolationMethod(.monotone)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: sparklineHeight)
                .padding(.top, 6)
            }
            Spacer(minLength: 6)
            Text(reading.asOf)
                .font(.system(size: 11))
                .foregroundStyle(HeuteRedesignPalette.ink3)
        }
        .padding(innerPadding)
    }

    /// A pure-navigation tile (Coupled view): badge, title, and a trailing chevron — no value, no
    /// sparkline. The whole tile is the tap target (set in `body`'s NavigationLink).
    private var navContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            badge
            Text(descriptor.title)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.1)
                .textCase(.uppercase)
                .foregroundStyle(HeuteRedesignPalette.ink3)
                .padding(.top, 10)
            Spacer(minLength: 6)
            HStack {
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HeuteRedesignPalette.ink3)
            }
        }
        .padding(innerPadding)
    }

    private var badge: some View {
        Group {
            if isNeutral {
                HeuteRedesignPalette.ink3
            } else {
                LinearGradient(colors: [accent, accent.mix(with: .black, by: 0.15)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(width: badgeSize, height: badgeSize)
        .clipShape(Circle())
        .overlay {
            Image(systemName: descriptor.icon)
                .font(.system(size: badgeSize * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

/// The always-present, non-configurable wide Activity row (design-spec §4 "Wide-Kachel"). Not part of
/// `VitalTileConfig` — the mockup exempts it from the edit system entirely. Shows the day's latest
/// workout as sport + duration/calories + effort, tapping into the Workouts screen — parity with the
/// last-workout card the other two Today screens show, in Heute's own token set.
private struct HeuteActivityTile: View {
    let workout: WorkoutRow
    var effortScale: EffortScale = .hundred

    private var sport: String { WorkoutSource.displaySport(workout.sport) }

    /// "42 min · 380 kcal" — duration always, calories only when the file carried them.
    private var subline: String {
        let secs = workout.durationS ?? Double(max(workout.endTs - workout.startTs, 0))
        var parts = [String(localized: "\(Int(secs / 60)) min")]
        if let kcal = workout.energyKcal { parts.append(String(localized: "\(Int(kcal.rounded())) kcal")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationLink(value: TabRoute.workouts) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sport)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(HeuteRedesignPalette.ink)
                    Text(subline)
                        .font(.system(size: 12))
                        .foregroundStyle(HeuteRedesignPalette.ink3)
                }
                Spacer()
                if let strain = workout.strain {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(UnitFormatter.effortDisplay(strain, scale: effortScale))
                            .font(.system(size: 15, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(HeuteRedesignPalette.effort)
                        Text("Effort")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.7)
                            .textCase(.uppercase)
                            .foregroundStyle(HeuteRedesignPalette.ink3)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HeuteRedesignPalette.ink3)
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
        }
        .buttonStyle(.plain)
        .background(HeuteRedesignPalette.tile, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(HeuteRedesignPalette.line, lineWidth: 1))
    }
}

/// Minimal wrap row for the hidden-tray restore pills — same rationale as the duration row's `FlowRow`
/// in `HeuteHeaderView.swift` (a handful of short items, not worth a general reflow layout).
private struct FlowRow<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: spacing) { content() }
    }
}

private extension Color {
    /// Blends toward another colour by `amount` (0...1) in sRGB — used for the icon badge's 135°
    /// gradient (design-spec §4: "heller Ton → 15% abgedunkelter Ton").
    func mix(with other: Color, by amount: Double) -> Color {
        #if canImport(UIKit)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        UIColor(self).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        UIColor(other).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(red: Double(r1 + (r2 - r1) * amount),
                      green: Double(g1 + (g2 - g1) * amount),
                      blue: Double(b1 + (b2 - b1) * amount))
        #else
        return self
        #endif
    }
}
