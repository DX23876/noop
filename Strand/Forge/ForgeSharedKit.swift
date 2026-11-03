import SwiftUI
import StrandDesign

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
            HStack(spacing: NoopMetrics.space2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(StrandFont.subhead)
                        .foregroundStyle(role == .destructive ? StrandPalette.statusCritical : StrandPalette.textPrimary)
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
        .buttonStyle(.plain)
    }
}

