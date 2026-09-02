import SwiftUI
import StrandAnalytics
import StrandDesign

/// The Today MOMENTUM card: the one thing worth saying right now, with a hint that there is more.
///
/// It is the Today-side window onto the ranked Momentum feed — the card shows the feed's top entry and
/// links to `MomentumView`, the dashboard where the whole feed lives. Same name on both ends on
/// purpose: they are one feature seen at two sizes.
///
/// It lives in the app target rather than in StrandDesign because it renders a `MomentumMessage`, and
/// StrandDesign is deliberately dependency-free (it cannot see StrandAnalytics — the same constraint
/// that put `ChargeBand` in the design system rather than in analytics). It is still built only from
/// design-system pieces: `NoopCard`, `StrandFont`, `StrandPalette`, `NoopMetrics`.
///
/// One layout serves every message kind. What changes per message is the tint, the symbol, the optional
/// illustration and which of the optional rows are present — never the shape, so the card reads the
/// same whether it is talking about recovery, steps or a goal.
struct MomentumCard: View {

    let message: MomentumMessage
    /// How many further messages are waiting behind this one. 0 hides the affordance entirely — a "+0"
    /// promising a page with nothing on it would be worse than no chip at all.
    let remainingCount: Int
    /// Opens the Momentum page.
    let onOpenMore: () -> Void
    /// Runs the message's own action, when it has one.
    let onAction: (MomentumDestination) -> Void
    /// Snoozes this message for the rest of the day. nil where there is nothing to snooze (the list on
    /// the Momentum sheet), and the control is then not drawn at all — a visible × that does nothing
    /// reads as broken.
    var onDismiss: (() -> Void)?

    var body: some View {
        NoopCard(padding: NoopMetrics.cardPadding, tint: tint) {
            HStack(alignment: .top, spacing: 12) {
                iconTile
                VStack(alignment: .leading, spacing: 6) {
                    headerRow
                    Text(message.headline)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message.detail)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let line = message.actionLine {
                        Text(line)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    footer
                }
            }
        }
        .background(alignment: .top) { illustration }
        .overlay(alignment: .topTrailing) {
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // "this message", not "this card": the card keeps working, one message stops appearing.
                .accessibilityLabel("Hide this message for today")
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Pieces

    /// The name plus the way into the dashboard.
    ///
    /// The entry point used to be a grey "+2 ›" chip in the footer — easy to miss, and not a pattern
    /// this app uses anywhere else. The Goals card beside it has had the right one all along: a
    /// tappable header with the section name and an accent-coloured "All ›". Same affordance here, so
    /// the dashboard is discoverable by anyone who has already learned it once.
    ///
    /// "MOMENTUM" itself is a product name, not a description, so it stays out of the string catalog
    /// exactly as the CHARGE / EFFORT / REST hero labels do (`DomainTheme.productName`).
    @ViewBuilder
    private var headerRow: some View {
        if remainingCount > 0 {
            Button(action: onOpenMore) {
                HStack(spacing: 6) {
                    momentumLabel
                    Spacer(minLength: 8)
                    Text("All")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.accent)
                    Image(systemName: "chevron.right")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The count is spoken rather than drawn: it is context for the affordance, not a badge.
            .accessibilityLabel("Momentum — open all \(remainingCount + 1) insights")
        } else {
            momentumLabel
        }
    }

    private var momentumLabel: some View {
        Text(verbatim: "MOMENTUM")
            .font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .foregroundStyle(StrandPalette.textSecondary)
    }

    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.16))
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 42, height: 42)
        .accessibilityHidden(true)
    }

    /// The progress chip, the message's own action, and the "there is more" affordance.
    @ViewBuilder
    private var footer: some View {
        let hasFooter = message.progress != nil || message.deltaText != nil || message.action != nil
        if hasFooter {
            HStack(spacing: 8) {
                if let p = message.progress {
                    // The percentage, not the raw counts: the detail line above already carries those,
                    // and a chip repeating them made the card say one thing twice.
                    chip(text: p.percentText, tint: tint)
                }
                if let delta = message.deltaText {
                    chip(text: delta, tint: tint)
                }
                if let action = message.action {
                    Button { onAction(action.destination) } label: {
                        Text(action.title)
                            .font(StrandFont.footnote.weight(.semibold))
                            .foregroundStyle(tint)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 4)
            }
            .padding(.top, 2)
        }
    }

    private func chip(text: String, tint: Color) -> some View {
        Text(text)
            .font(StrandFont.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14),
                        in: Capsule())
    }

    /// The optional hand-painted wash behind the card, under the SAME rules `SceneHeroBackground`
    /// enforces: a flat image, top-aligned, faded out downward and capped low enough to stay a wash
    /// rather than a picture. Absent for most kinds, which is why the icon tile is a complete design on
    /// its own rather than a placeholder.
    @ViewBuilder
    private var illustration: some View {
        if let asset = MomentumScene.assetName(for: message.kind) {
            Image(asset)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: 96, alignment: .top)
                .clipped()
                .opacity(0.22)
                .mask(LinearGradient(colors: [.black, .clear],
                                     startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Tone → look

    /// Both look-ups are SHARED with the dashboard (`MomentumTint` / `MomentumSymbol`). They started as
    /// private switches here; the moment `MomentumView` needed the same mapping, two copies would have
    /// been two chances for the card and the page to tint or badge one message differently.
    private var tint: Color { MomentumTint.color(for: message.tone) }
    private var symbol: String { MomentumSymbol.name(for: message.kind) }
}
