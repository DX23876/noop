import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Basiskarte + Notification-Karten (docs/feature-spec.md §2, §3; docs/design/design-spec.md §3)
//
// A fixed, never-dismissable base card sits behind a stack of ephemeral, individually-swipeable
// notification cards. No existing swipe-to-dismiss precedent exists anywhere in the repo (checked) —
// the drag physics below are transcribed from noop-heute-ausgebaut.html's vanilla-JS implementation,
// which is more precise than design-spec §3's prose.

/// One ephemeral notification card (feature-spec §3: generic "title + text", not coupled to any
/// specific source — propose_plan / vitals-anomaly / future sources all produce the same shape).
struct NotificationCardItem: Identifiable, Equatable {
    var id: String = UUID().uuidString
    /// Small overline tag, e.g. "Suggestion" / "Anomaly".
    var category: String
    /// The one-line body sentence.
    var text: String
}

struct HeuteCardZoneView: View {
    /// Already day-scoped by the host (`HeuteRedesignView.dayStatus`) — a past day is never shown with
    /// today's exception-state override, since `ActivityStatus` is a current state, not a per-day record.
    let status: ActivityStatus
    let readiness: ReadinessEngine.Readiness
    /// While the recovery baseline is still forming, the honest "Learning your baseline, N of 4 nights"
    /// line (from `LiquidTodayView.ChargeDisplay.calibrationDetail`, the same copy the other two screens
    /// show) REPLACES the readiness statement — mid-calibration there is no trustworthy verdict to state.
    /// nil once a score or a carry exists. Ignored when an ActivityStatus override is active (a set status
    /// is an explicit user statement that wins regardless).
    var calibrationNote: String? = nil
    /// Owned by the screen root: a `@State` copy here silently resurrected every dismissed card whenever
    /// the parent re-created this view (e.g. on a day change or any reload).
    @Binding var cards: [NotificationCardItem]

    private let zoneHeight: CGFloat = 150

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                ZStack {
                    HeuteBaseCard(status: status, readiness: readiness, calibrationNote: calibrationNote)
                    ForEach(Array(cards.enumerated()).reversed(), id: \.element.id) { index, card in
                        HeuteNotificationCard(
                            item: card,
                            isTop: index == 0,
                            screenWidth: geo.size.width,
                            onDismiss: { dismiss(card) }
                        )
                    }
                }
            }
            .frame(height: zoneHeight)

            if cards.count > 1 {
                HeuteCardDots(count: cards.count)
            }
        }
    }

    private func dismiss(_ card: NotificationCardItem) {
        cards.removeAll { $0.id == card.id }
    }
}

// MARK: - Base card

/// The persistent readiness statement (feature-spec §2). Content comes straight from
/// `BaseCardStatement.current(status:readiness:)` — active shows the real computed statement,
/// the three exception states show the fixed override; this view never branches on `status` itself,
/// only on the already-resolved `statement.isOverride`.
private struct HeuteBaseCard: View {
    let status: ActivityStatus
    let readiness: ReadinessEngine.Readiness
    var calibrationNote: String? = nil

    /// Priority: an ActivityStatus override (a set status is an explicit user statement) beats everything;
    /// otherwise, while calibrating, the honest "N of 4 nights" progress replaces the readiness verdict
    /// (there is none yet); otherwise the computed readiness statement. Mirrors the `calibrationDetail ??`
    /// swap the other two Today screens make.
    private var statement: BaseCardStatement {
        let base = BaseCardStatement.current(status: status, readiness: readiness)
        if base.isOverride { return base }
        if let note = calibrationNote {
            return BaseCardStatement(headline: String(localized: "Calibrating"), summary: note, isOverride: false)
        }
        return base
    }
    private var tint: Color { statement.isOverride ? HeuteRedesignPalette.attn : HeuteRedesignPalette.charge }
    /// mockup `baseTag.textContent = isActive ? 'Push' : chosenStatus` — the active state's tag is a
    /// generic placeholder text, not derived from any real suggestion category (that categorisation is
    /// out of scope here, same boundary as the sample `NotificationCardItem`s above).
    private var tagText: String { statement.isOverride ? status.state.displayName : String(localized: "Push") }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(tagText)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(tint)
            }
            .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 4)
            .background(tint.opacity(0.16), in: Capsule())

            Text(statement.summary)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(HeuteRedesignPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                HeuteRedesignPalette.tile
                LinearGradient(colors: [tint.opacity(0.10), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(tint, lineWidth: 1.5))
    }
}

// MARK: - Notification card

/// A draggable notification card. Physics transcribed from the mockup: rotation `dx/18°` and opacity
/// `1 - min(|dx|/260, 0.7)` while dragging; on release, `|dx| > 90` flings it off-screen (rotation
/// `dx/10°`, opacity 0, `.easeOut(duration: 0.28)`) and removes it, otherwise it springs back. Cards
/// behind the top one are non-interactive and fixed at scale 0.95 / +9pt / 55% opacity.
private struct HeuteNotificationCard: View {
    let item: NotificationCardItem
    let isTop: Bool
    let screenWidth: CGFloat
    let onDismiss: () -> Void

    @State private var offsetX: CGFloat = 0
    @State private var rotation: Double = 0
    @State private var opacity: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(item.category)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.7)
                .textCase(.uppercase)
                .foregroundStyle(HeuteRedesignPalette.effort)
            Text(item.text)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(HeuteRedesignPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if isTop {
                Text("Drag to dismiss")
                    .font(.system(size: 11))
                    .foregroundStyle(HeuteRedesignPalette.ink3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(HeuteRedesignPalette.tile2, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(HeuteRedesignPalette.line, lineWidth: 1))
        .scaleEffect(isTop ? 1 : 0.95)
        .offset(x: isTop ? offsetX : 0, y: isTop ? 0 : 9)
        .rotationEffect(.degrees(isTop ? rotation : 0))
        .opacity(isTop ? opacity : 0.55)
        .allowsHitTesting(isTop)
        .gesture(isTop ? drag : nil)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("Dismiss")) { fling(direction: 1) }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                offsetX = value.translation.width
                rotation = offsetX / 18
                opacity = 1 - min(abs(offsetX) / 260, 0.7)
            }
            .onEnded { value in
                let dx = value.translation.width
                if abs(dx) > 90 {
                    fling(direction: dx > 0 ? 1 : -1, exitRotation: dx / 10)
                } else {
                    withAnimation(StrandMotion.interactive) {
                        offsetX = 0; rotation = 0; opacity = 1
                    }
                }
            }
    }

    private func fling(direction: CGFloat, exitRotation: Double? = nil) {
        withAnimation(.easeOut(duration: 0.28)) {
            offsetX = direction * screenWidth * 1.1
            rotation = exitRotation ?? (direction * 24)
            opacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { onDismiss() }
    }
}

// MARK: - Page dots

private struct HeuteCardDots: View {
    let count: Int
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == 0 ? HeuteRedesignPalette.ink : HeuteRedesignPalette.ink3)
                    .opacity(i == 0 ? 1 : 0.4)
                    .frame(width: 5, height: 5)
            }
        }
    }
}
