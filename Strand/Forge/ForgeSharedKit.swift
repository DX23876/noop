import SwiftUI
import StrandDesign
import StrandAnalytics

/// One finding as a line in the new design: its name, a bar from the middle that shows direction and size,
/// the figure at the end. A tap opens what the line rests on.
struct ForgeEffectRow<Detail: View>: View {
    let title: String
    var note: String?
    let value: String
    /// Direction and size, from -1 to 1.
    let fraction: Double
    let tint: Color
    @ViewBuilder var detail: Detail
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: NoopMetrics.space3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .multilineTextAlignment(.leading)
                        if let note {
                            Text(note)
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: NoopMetrics.space1)
                    ForgeCenteredBar(fraction: fraction, tint: tint)
                        .frame(width: 72, height: 6)
                        .accessibilityHidden(true)
                    Text(value)
                        .font(StrandFont.number(15).monospacedDigit())
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .frame(minWidth: 44, alignment: .trailing)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(expanded ? .isSelected : [])
            if expanded {
                detail.transition(.opacity)
            }
        }
    }
}

/// A bar that grows from its middle to the left or the right.
struct ForgeCenteredBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let half = proxy.size.width / 2
            let length = half * min(1, abs(fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.surfaceInset)
                Capsule().fill(tint)
                    .frame(width: length)
                    .offset(x: fraction >= 0 ? half : half - length)
            }
        }
    }
}

/// Long guidance in the new design: two lines until the reader asks for the rest. The text stays complete.
struct ForgeExpandableText: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(expanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            if text.count > 90 {
                Button(expanded ? "Show less" : "Show all") {
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .font(StrandFont.footnote.weight(.semibold))
                .foregroundStyle(StrandPalette.accent)
                .buttonStyle(.plain)
                .frame(minHeight: 32)
            }
        }
    }
}

/// A switch row in the new design's grouped cards.
struct ForgeToggleRow: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                if let subtitle {
                    Text(subtitle).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(StrandPalette.chargeColor)
        .frame(minHeight: 44)
    }
}

/// A tappable row in the new design's grouped cards: a label, an optional value, a chevron.
struct ForgeActionRow: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var value: String?
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            ForgeActionLabel(title: title, subtitle: subtitle, value: value, isDestructive: role == .destructive)
        }
        .buttonStyle(.plain)
    }
}

/// What a `ForgeActionRow` shows, for a row whose action is a menu.
struct ForgeActionLabel: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var value: String?
    var isDestructive = false

    var body: some View {
        HStack(spacing: NoopMetrics.space2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StrandFont.subhead)
                    .foregroundStyle(isDestructive ? StrandPalette.statusCritical : StrandPalette.textPrimary)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: NoopMetrics.space2)
            if let value {
                Text(value).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// A chip in the new design: filled when selected, quiet otherwise.
struct ForgeFilterChip: View {
    let title: String
    var symbol: String?
    var isSelected = false
    var showsRemove = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(StrandFont.caption.weight(.semibold)).accessibilityHidden(true)
                }
                Text(title).font(StrandFont.subhead.weight(isSelected ? .semibold : .regular)).lineLimit(1)
                if showsRemove {
                    Image(systemName: "xmark").font(StrandFont.caption.weight(.bold)).accessibilityHidden(true)
                }
            }
            .foregroundStyle(isSelected ? StrandPalette.forgeOnAccent : StrandPalette.textPrimary)
            .padding(.horizontal, NoopMetrics.space3)
            .frame(minHeight: 36)
            .background(isSelected ? AnyShapeStyle(StrandPalette.forgeAccent) : AnyShapeStyle(StrandPalette.surfaceInset), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One reading on a card of its own: its name, the figure with a small unit, a note under it.
struct ForgeValueTile: View {
    let label: LocalizedStringKey
    let value: String
    var unit: String?
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(StrandFont.number(24).monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit, !unit.isEmpty {
                    Text(unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
                }
            }
            Text(note ?? " ").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A label on the left and its answer on the right, the rows of a facts card.
struct ForgeFactRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: NoopMetrics.space2)
            Text(value)
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 32)
        .accessibilityElement(children: .combine)
    }
}

/// A titled group in the new design's settings-like pages: a small label, one card, an optional note.
struct ForgeListGroup<Content: View>: View {
    let title: LocalizedStringKey?
    var note: LocalizedStringKey?
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey? = nil, note: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if let title {
                Text(title)
                    .font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityAddTraits(.isHeader)
            }
            NoopCard(padding: NoopMetrics.space3) {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let note {
                Text(note)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A row that opens a page, in the new design's grouped cards.
struct ForgeLinkRow<Destination: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: NoopMetrics.space2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        .multilineTextAlignment(.leading)
                    if let subtitle {
                        Text(subtitle).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: NoopMetrics.space2)
                Image(systemName: "chevron.right")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Wraps chips onto as many lines as they need.
struct ForgeFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// The What works findings in the reader's language. The engines keep their English sentences for the coach
/// and the logs; these say the same from the same figures.
enum ForgeEffectWording {
    static func lag(_ days: Int) -> String {
        switch days {
        case 0: return String(localized: "same day")
        case 1: return String(localized: "next morning")
        default: return String(localized: "\(days) mornings later")
        }
    }

    static func line(delta: Double, percent: Double?) -> String {
        guard delta != 0 else { return String(localized: "No different on days with this.") }
        let amount = percent.map { "\(Int(abs($0).rounded()))%" }
            ?? UnitFormatter.localizedMark(String(format: "%.1f", abs(delta)))
        return delta > 0
            ? String(localized: "\(amount) higher on days with this.")
            : String(localized: "\(amount) lower on days with this.")
    }

    static func dose(_ r: DoseResponse, outcome: String) -> String {
        let amount = UnitFormatter.localizedMark(String(format: "%.1f", abs(r.perUnit)))
        if r.contradictsPrior && !r.priorDominated {
            return String(localized: "In your data so far, this does not move \(outcome) the way it typically does.")
        }
        switch (r.priorDominated, r.perUnit <= 0) {
        case (true, true): return String(localized: "Each extra unit typically lines up with about \(amount) lower \(outcome). A typical pattern, not yet yours.")
        case (true, false): return String(localized: "Each extra unit typically lines up with about \(amount) higher \(outcome). A typical pattern, not yet yours.")
        case (false, true): return String(localized: "Each extra unit lines up with about \(amount) lower \(outcome) for you.")
        case (false, false): return String(localized: "Each extra unit lines up with about \(amount) higher \(outcome) for you.")
        }
    }

    static func cost(_ cost: ActivityCost) -> String {
        let points = Int(abs(cost.delta).rounded())
        if abs(cost.delta) < ActivityCostEngine.barelyMovesPoints {
            return String(localized: "Sessions like this barely move the next morning's Charge.")
        }
        return cost.delta >= 0
            ? String(localized: "Sessions like this usually cost about \(points) Charge points the next morning.")
            : String(localized: "Sessions like this usually lift the next morning's Charge by about \(points) points.")
    }
}

