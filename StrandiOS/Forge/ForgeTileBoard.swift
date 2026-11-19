#if os(iOS) && DEBUG
import SwiftUI
import StrandDesign

/// The comparison board: every Today tile, at every size it has, on one page.
///
/// Debug builds only, reached from Lab. It exists so the two phones can be held against each other
/// without first arranging a layout by hand on both: the same list, in the same order, drawn from the
/// same data, so a difference on screen is a difference in the tile and not in what was placed where.
///
/// It draws each tile through `ForgeTodayWidgetView`, the same view Today uses, rather than a second
/// rendering of the same thing. A board that drew its own version of a tile would agree with itself and
/// with nothing else, which is the opposite of what it is for.
///
/// Which account it shows is the build: a demo build shows the demo account, an ordinary one shows the
/// wearer's. There is no switch here, because a switch would mean a second store open at once.
///
/// Analysis migration required: no.
struct ForgeTileBoardView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var measuresOnly = false

    /// Every measure at its three sizes, then the cards at theirs. A whole-row measure is shown once,
    /// because one size is all it has.
    private var rows: [(title: String, widgets: [ForgeTodayWidget])] {
        var out: [(String, [ForgeTodayWidget])] = []
        for section in TileMeasures.Section.allCases {
            for measure in TileMeasures.all where measure.section == section {
                let base = ForgeTodayWidget(kind: .measure, key: measure.key, source: measure.source)
                if base.isWholeRowMeasure {
                    out.append(("\(measure.key) · \(section.rawValue) · whole row only",
                                [ForgeTodayWidget(kind: .measure, key: measure.key, source: measure.source, wide: true)]))
                    continue
                }
                out.append(("\(measure.key) · \(section.rawValue)", [
                    base,
                    ForgeTodayWidget(kind: .measure, key: measure.key, source: measure.source, span: 2),
                    ForgeTodayWidget(kind: .measure, key: measure.key, source: measure.source, wide: true),
                ]))
            }
        }
        guard !measuresOnly else { return out }
        for kind in ForgeTodayWidget.Kind.allCases where kind != .measure {
            let small = ForgeTodayWidget(kind: kind)
            var sizes = [small]
            if small.size != .medium { sizes.append(ForgeTodayWidget(kind: kind, span: 2)) }
            if ForgeTodayWidget(kind: kind, wide: true).size == .wide {
                sizes.append(ForgeTodayWidget(kind: kind, wide: true))
            }
            out.append((kind.rawValue, sizes))
        }
        return out
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    Text("Every tile at every size, drawn by the same views Today uses. The account is the one this build carries.")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: row.title)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(ForgeColor.tertiary)
                            ForEach(Array(row.widgets.enumerated()), id: \.offset) { _, widget in
                                ForgeTodayWidgetView(widget: widget)
                                    .frame(maxWidth: widget.size == .small ? 186 : .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(ForgeColor.canvas.ignoresSafeArea())
            .navigationTitle("Tile board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(measuresOnly ? "All" : "Measures") { measuresOnly.toggle() }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
#endif
