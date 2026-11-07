#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandCore

// MARK: - The Vitals tiles on Health, chosen by the wearer
//
// Held, a tile starts the editor, as on Today: tiles are removed, dragged into order, tapped to swap for
// another, and added from a short list of measures that belong with the vitals, up to nine. Two or three
// tiles to a row. Every tile draws a value from the same resolver its page uses, so nothing reads
// differently here than there. Display only: nothing is derived or stored apart from the choice itself.

/// One tile the Vitals grid can show.
enum ForgeVitalTile: String, CaseIterable, Identifiable, Codable {
    // The nightly vitals, keyed as `BodyVitalSigns.readings` keys them.
    case hrv, rhr, spo2, resp, skin, spo2raw
    // Measures that sit well beside them.
    case ageless, vo2max, weight, stress, steps

    var id: String { rawValue }

    var isVital: Bool {
        switch self {
        case .hrv, .rhr, .spo2, .resp, .skin, .spo2raw: return true
        default: return false
        }
    }

    /// Catalog key and preferred source for the plain measures.
    var measure: (key: String, source: String)? {
        switch self {
        case .vo2max: return ("vo2max_est", Repository.whoopSource)
        case .stress: return ("stress", Repository.whoopSource)
        case .steps: return ("steps", Repository.whoopSource)
        // The weigh-in Today's weight tile shows, from the same series.
        case .weight: return ("weight", "noop-weight")
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .hrv: return "waveform.path.ecg"
        case .rhr: return "heart.fill"
        case .spo2, .spo2raw: return "drop.fill"
        case .resp: return "lungs.fill"
        case .skin: return "thermometer.medium"
        case .ageless: return "hourglass"
        case .vo2max: return "figure.run"
        case .weight: return "scalemass.fill"
        case .stress: return "brain.head.profile"
        case .steps: return "figure.walk"
        }
    }
}

/// The wearer's tiles in order, kept in UserDefaults. Until the wearer changes them, the tiles follow
/// the readings the night produced, so a fresh install looks exactly as before.
@MainActor
final class ForgeVitalTileStore: ObservableObject {
    static let key = "forge.health.vitalTiles"
    static let columnsKey = "forge.health.vitalColumns"
    static let maxTiles = 9
    static let shared = ForgeVitalTileStore()

    /// nil: never edited.
    @Published private(set) var chosen: [ForgeVitalTile]?

    init() {
        if let raw = UserDefaults.standard.stringArray(forKey: Self.key) {
            chosen = raw.compactMap(ForgeVitalTile.init(rawValue:))
        }
    }

    func tiles(default fallback: [ForgeVitalTile]) -> [ForgeVitalTile] {
        Array((chosen ?? fallback).prefix(Self.maxTiles))
    }

    func set(_ list: [ForgeVitalTile]) {
        var seen = Set<ForgeVitalTile>()
        let clean = list.filter { seen.insert($0).inserted }.prefix(Self.maxTiles)
        chosen = Array(clean)
        UserDefaults.standard.set(clean.map(\.rawValue), forKey: Self.key)
    }
}

/// What the tile picker was opened for.
enum ForgeVitalTilePick: Identifiable {
    case add
    case replace(ForgeVitalTile)
    var id: String {
        switch self {
        case .add: return "add"
        case .replace(let t): return "replace-\(t.rawValue)"
        }
    }
}

/// A plain measure as a Vitals tile: its latest value and two months as a line, drawn like the vitals.
struct ForgeHealthMeasureTile: View {
    let key: String
    let source: String
    /// The short name the grid uses: a catalog title such as "VO₂ Max (estimated)" is cut off in a tile.
    let label: String
    let compact: Bool
    @EnvironmentObject private var repo: Repository
    @State private var values: [Double] = []
    @State private var metric: MetricDescriptor?

    var body: some View {
        let m = metric ?? ForgeWidgetMeasures.descriptor(key, source)
        NavigationLink(value: TabRoute.metricSourced(key: m?.key ?? key, source: m?.source ?? source)) {
            ForgeMetricTile(label: label,
                            value: key == "stress"
                                ? values.last.map { ForgeMeasureWidget.stressWord($0) }
                                : m.flatMap { ForgeFocusView.format(values.last, $0) },
                            unit: key == "steps" || key == "stress" ? "" : m.map(ForgeFocusView.unit) ?? "",
                            trend: values.count > 1 ? Array(values.suffix(60)) : nil,
                            tint: ForgeMeasureWidget.tint(key),
                            minHeight: compact ? 96 : 132)
        }
        .buttonStyle(LiquidPressStyle())
        .task(id: repo.refreshSeq) { await load() }
    }

    /// The preferred source first, then any other source of the same measure that has data (the rule
    /// Today's measure tiles follow, so the two never disagree).
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
        values = []
    }
}

/// The list a tile is added from or swapped for.
struct ForgeVitalTilePicker: View {
    let pick: ForgeVitalTilePick
    let placed: [ForgeVitalTile]
    let offered: [ForgeVitalTile]
    let title: (ForgeVitalTile) -> String
    let choose: (ForgeVitalTile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(offered.filter { $0.isVital }) { row($0) }
                } header: { Text("Vitals") }
                let more = offered.filter { !$0.isVital }
                if !more.isEmpty {
                    Section {
                        ForEach(more) { row($0) }
                    } header: { Text("Measures") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ForgeColor.canvas.ignoresSafeArea())
            .navigationTitle(Text(pickTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var pickTitle: String {
        switch pick {
        case .add: return String(localized: "Add a tile")
        case .replace(let t): return String(localized: "Swap \(title(t))")
        }
    }

    private func row(_ t: ForgeVitalTile) -> some View {
        let isPlaced = placed.contains(t)
        return Button {
            choose(t)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: t.symbol).font(.system(.body, weight: .semibold)).foregroundStyle(ForgeColor.accent)
                    .frame(width: 36, height: 36).background(Circle().fill(ForgeColor.accent.opacity(ForgeOpacity.wash)))
                Text(title(t)).font(.system(.body, weight: .semibold)).foregroundStyle(ForgeColor.text)
                Spacer(minLength: 6)
                Image(systemName: isPlaced ? "checkmark.circle.fill" : "plus.circle.fill").font(.title3)
                    .foregroundStyle(isPlaced ? ForgeColor.tertiary : ForgeColor.accent)
            }
        }
        .disabled(isPlaced)
        .listRowBackground(ForgeColor.card)
    }
}
#endif
