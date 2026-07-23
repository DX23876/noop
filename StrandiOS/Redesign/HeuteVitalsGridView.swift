import SwiftUI
import Charts
import StrandDesign

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
}

struct HeuteVitalsGridView: View {
    /// Keyed by MetricCatalog id (`"source:key"`, e.g. `"my-whoop:hrv"`). A visible tile with no entry
    /// here renders nothing (design-spec §0.2: "keine leeren Kacheln").
    let readings: [String: HeuteVitalReading]
    /// nil hides the wide Activity row entirely (same "no data, no tile" rule).
    var activitySummary: String?

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
        VitalTileConfigStore.visibleTiles(configs).filter { readings[$0.metricId] != nil }
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

    private var header: some View {
        HStack {
            Text("Vitals")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.1)
                .textCase(.uppercase)
                .foregroundStyle(HeuteRedesignPalette.ink3)
            Spacer()
            Button(editing ? "Done" : "Edit") { editing.toggle() }
                .font(.system(size: 10, weight: .bold))
                .tracking(1.1)
                .textCase(.uppercase)
                .foregroundStyle(HeuteRedesignPalette.ink3)
                .buttonStyle(.plain)
        }
    }

    private var editBar: some View {
        HStack {
            SegmentedPillControl([2, 3], selection: $density) { "\($0)" }
            Spacer()
            Button("Done") { editing = false }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(HeuteRedesignPalette.charge)
                .buttonStyle(.plain)
        }
        .padding(9)
        .background(HeuteRedesignPalette.tile, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HeuteRedesignPalette.line, lineWidth: 1))
    }

    // MARK: Grid

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: NoopMetrics.space4) {
            ForEach(Array(visibleConfigs.enumerated()), id: \.element.metricId) { index, config in
                if let descriptor = metricDescriptor(config.metricId), let reading = readings[config.metricId] {
                    let isDragging = draggingId == config.metricId
                    HeuteVitalTile(
                        descriptor: descriptor, reading: reading, density: density,
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
                    .gesture(editing ? dragGesture(for: config.metricId) : nil)
                }
            }

            if let activitySummary {
                HeuteActivityTile(summary: activitySummary)
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
        guard let colonIndex = metricId.firstIndex(of: ":") else { return nil }
        let source = String(metricId[metricId.startIndex..<colonIndex])
        let key = String(metricId[metricId.index(after: colonIndex)...])
        return MetricCatalog.metric(key: key, source: source)
    }

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
    let density: Int
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

    @State private var wigglePhase = false

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
        default: return HeuteRedesignPalette.ink3
        }
    }
    private var badgeSize: CGFloat { density == 3 ? 24 : 30 }
    private var numberSize: CGFloat { density == 3 ? 20 : 30 }
    private var innerPadding: CGFloat { density == 3 ? 13 : 18 }
    /// One fixed height every tile snaps to regardless of content (sparkline vs. none) — same rationale
    /// as `NoopMetrics.keyMetricTileHeight`: a row of tiles must read as ONE row, not a jagged one.
    private var tileHeight: CGFloat { density == 3 ? 128 : 150 }
    /// A single point draws no line (Swift Charts renders an empty plot area) — that's an empty box, which
    /// design-spec §0.2's "keine leeren Kacheln" rule rejects, so two points are the minimum.
    private var showSparkline: Bool { density == 2 && reading.sparkline.count >= 2 }
    private var numberText: String {
        descriptor.decimals == 0 ? "\(Int(reading.value.rounded()))" : String(format: "%.\(descriptor.decimals)f", reading.value)
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
        ZStack(alignment: .topLeading) {
            NavigationLink(value: TabRoute.metricSourced(key: descriptor.key, source: descriptor.source)) {
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
        // Declarative animation binding (the animation depends on `editing`, not two competing imperative
        // `withAnimation` calls racing on the same state) — was the actual cause of the wiggle not
        // stopping cleanly on-device: a `repeatForever` started by one `withAnimation` isn't reliably
        // cancelled by a second, independent `withAnimation` targeting the same property afterwards. This
        // way SwiftUI owns starting/stopping the loop itself whenever `editing` (and so the animation
        // descriptor below) changes.
        .rotationEffect(.degrees(editing && !isDragging ? (wigglePhase ? 0.7 : -0.7) : 0))
        .animation(
            editing
                ? Animation.easeInOut(duration: 0.28).repeatForever(autoreverses: true).delay(wiggleDelay)
                : .easeInOut(duration: 0.12),
            value: wigglePhase
        )
        .onChange(of: editing) { _, isEditing in
            wigglePhase = isEditing
        }
    }

    private var tileContent: some View {
        ZStack(alignment: .topLeading) {
            if !isNeutral {
                accent.opacity(0.10)
            }
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
                    if !descriptor.unit.isEmpty {
                        Text(descriptor.unit)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(HeuteRedesignPalette.ink3)
                    }
                }
                .padding(.top, 2)
                if showSparkline {
                    Chart {
                        ForEach(Array(reading.sparkline.enumerated()), id: \.offset) { point in
                            LineMark(x: .value("i", point.offset), y: .value("v", point.element))
                                .foregroundStyle(accent.opacity(0.7))
                                .interpolationMethod(.monotone)
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 22)
                    .padding(.top, 6)
                }
                Spacer(minLength: 6)
                Text(reading.asOf)
                    .font(.system(size: 11))
                    .foregroundStyle(HeuteRedesignPalette.ink3)
            }
            .padding(innerPadding)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: tileHeight, alignment: .topLeading)
        .background(HeuteRedesignPalette.tile, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(HeuteRedesignPalette.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22))
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
/// `VitalTileConfig` — the mockup exempts it from the edit system entirely.
private struct HeuteActivityTile: View {
    let summary: String

    var body: some View {
        NavigationLink(value: TabRoute.workouts) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Activity")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(HeuteRedesignPalette.ink)
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(HeuteRedesignPalette.ink3)
                }
                Spacer()
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
