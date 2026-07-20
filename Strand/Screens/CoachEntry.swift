import SwiftUI
import StrandDesign

/// How the user reaches the Coach from the home surface. The user picks in Coach settings; the Today
/// card and the floating button honour it. Shared (not iOS-only) because the Today views that read it
/// compile for macOS too — the floating button itself is only mounted on iOS (see `CoachFloatingButton`).
enum CoachEntryMode: String, CaseIterable, Identifiable {
    case card, button, both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .card:   return "Today card"
        case .button: return "Floating button"
        case .both:   return "Both"
        }
    }

    var showsCard: Bool { self == .card || self == .both }
    var showsButton: Bool { self == .button || self == .both }

    /// The shared UserDefaults key both the setting and the surfaces read.
    static let storageKey = "coach.entryMode"

    /// Master switch for the Coach's home-surface UI (#R7 / list 14): when off, the Today card AND the
    /// floating button are hidden regardless of `self`, while the chosen entry style is remembered for
    /// when it's turned back on. Deliberately independent of `dataConsent` / `isConfigured` and of the
    /// card- and background-AI paths (`model(for:)`), which keep running — this hides only the coach's
    /// own entry points, not the AI features that don't depend on the chat.
    static let uiEnabledKey = "coach.uiEnabled"

    /// Whether the Coach's home-surface UI is enabled. Absent key ⇒ true, so existing installs are
    /// unaffected. Surfaces use `@AppStorage(uiEnabledKey)` for reactivity; this is for plain call sites.
    static var uiEnabled: Bool {
        UserDefaults.standard.object(forKey: uiEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: uiEnabledKey)
    }

    /// Show the current coach's avatar (rather than a generic sparkle) on the Today entry card (#R11).
    /// Default on; turning it off restores the previous plain-icon look. Independent of `uiEnabled`.
    static let todayAvatarKey = "coach.todayAvatar"

    /// Current mode from UserDefaults (defaults to `.both`). A tiny helper so call sites don't repeat the
    /// `@AppStorage` raw-string dance.
    static var current: CoachEntryMode {
        CoachEntryMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .both
    }
}

/// Where the floating Coach button rests. The four corners are pinned clear of the app chrome — the
/// bottom pair sits above the floating tab bar, the top pair below the status bar + Today header — so a
/// pinned button never covers the menu. `.custom` means the user dragged it somewhere themselves.
enum CoachButtonCorner: String, CaseIterable, Identifiable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing, custom

    var id: String { rawValue }

    /// Only the four real corners are offered in the picker; `.custom` is a state you reach by dragging.
    static var pickable: [CoachButtonCorner] { [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing] }

    static let storageKey = "coach.fab.corner"
    static let lockedKey = "coach.fab.locked"

    var label: String {
        switch self {
        case .topLeading:     return "Top left"
        case .topTrailing:    return "Top right"
        case .bottomLeading:  return "Bottom left"
        case .bottomTrailing: return "Bottom right"
        case .custom:         return "Custom"
        }
    }

    var symbol: String {
        switch self {
        case .topLeading:     return "arrow.up.left"
        case .topTrailing:    return "arrow.up.right"
        case .bottomLeading:  return "arrow.down.left"
        case .bottomTrailing: return "arrow.down.right"
        case .custom:         return "hand.draw"
        }
    }

    /// Side margin from the screen edge.
    static let margin: CGFloat = 18
    /// Extra clearance ABOVE the floating tab bar, so a bottom-pinned button never sits on the menu.
    static let bottomChrome: CGFloat = 96
    /// Extra clearance BELOW the status bar + Today header cluster, so a top-pinned button never covers
    /// the header's round buttons.
    static let topChrome: CGFloat = 64

    /// Keys holding the user's freely-dragged spot (fractions of the container).
    static let fracXKey = "coach.fab.fx"
    static let fracYKey = "coach.fab.fy"

    /// One-time migration for anyone who dragged the button BEFORE corners existed: they have a stored
    /// fraction but no corner key, so the new `.bottomTrailing` default would yank the button out from
    /// under them. Mark those as `.custom` to keep the spot they chose.
    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: storageKey) == nil,
              defaults.object(forKey: fracXKey) != nil,
              defaults.double(forKey: fracXKey) >= 0 else { return }
        defaults.set(custom.rawValue, forKey: storageKey)
    }

    /// Resolve this corner to a point inside `size`, honouring the safe area and the chrome clearances.
    /// `nil` for `.custom` — the caller then uses the user's dragged fractions instead.
    func point(in size: CGSize, safeArea: EdgeInsets, half: CGFloat) -> CGPoint? {
        guard self != .custom else { return nil }
        let leadingX = half + Self.margin
        let trailingX = size.width - half - Self.margin
        let topY = safeArea.top + Self.topChrome + half
        let bottomY = size.height - safeArea.bottom - Self.bottomChrome - half
        switch self {
        case .topLeading:     return CGPoint(x: leadingX, y: topY)
        case .topTrailing:    return CGPoint(x: trailingX, y: topY)
        case .bottomLeading:  return CGPoint(x: leadingX, y: bottomY)
        case .bottomTrailing: return CGPoint(x: trailingX, y: bottomY)
        case .custom:         return nil
        }
    }
}

/// Card-AI entry (#P11): a small "ask the coach about this" affordance a metric screen mounts in its
/// header. Tapping it hands the coach the card's own context (current value + trend) and opens the chat,
/// which then produces a short read of that one metric. Only appears once the coach is connected — a dead
/// sparkle on a card the user never set up would be noise. Design tokens only; shared (macOS + iOS).
struct CoachCardButton: View {
    /// Built by the card from data it already loaded — the coach reads this, nothing new is derived.
    let context: CoachCardContext

    @EnvironmentObject private var coach: AICoachEngine
    /// Dismisses a presenting sheet (some cards open as sheets) so the coach isn't buried under it; a
    /// no-op for a pushed or root screen, which is fine.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if coach.isConfigured {
            Button {
                coach.openedFromCard(context)
                NotificationCenter.default.post(name: .noopOpenCoachCard, object: nil)
                dismiss()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                    Text("Ask coach")
                }
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.accent)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(StrandPalette.accent.opacity(0.12), in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.accent.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ask coach about \(context.title)")
            .accessibilityHint("Opens the AI coach with this metric's data.")
        }
    }
}

#if os(iOS)
/// A circular button that opens the Coach, floating over the whole app. It can be pinned to one of four
/// chrome-clear corners from Coach settings, or dragged anywhere (which switches it to `.custom` and
/// persists the spot as screen fractions, so it survives rotation / device changes). Locking it disables
/// dragging entirely — a tap still opens the chat. Design tokens only; iOS-only (it lives over `RootTabView`).
struct CoachFloatingButton: View {
    /// Flipped true to present the Coach (the host owns the actual `.coachCover`).
    @Binding var isPresented: Bool

    /// Which corner it's pinned to; `.custom` = wherever the user dragged it.
    @AppStorage(CoachButtonCorner.storageKey) private var cornerRaw = CoachButtonCorner.bottomTrailing.rawValue
    /// When on, the button can't be dragged (guards against nudging it away by accident).
    @AppStorage(CoachButtonCorner.lockedKey) private var locked = false
    /// Persisted dragged position as a FRACTION of the container (0…1). Only used when `.custom`.
    @AppStorage(CoachButtonCorner.fracXKey) private var fracX: Double = -1
    @AppStorage(CoachButtonCorner.fracYKey) private var fracY: Double = -1
    /// Live drag translation while the finger is down (committed to fracX/fracY on release).
    @GestureState private var dragging: CGSize = .zero

    private let size: CGFloat = 56

    init(isPresented: Binding<Bool>) {
        _isPresented = isPresented
        // Keep a pre-corners dragged spot instead of snapping it to the new default (see migrateIfNeeded).
        CoachButtonCorner.migrateIfNeeded()
    }

    private var corner: CoachButtonCorner { CoachButtonCorner(rawValue: cornerRaw) ?? .bottomTrailing }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let half = size / 2
            let margin = CoachButtonCorner.margin
            // A pinned corner wins; `.custom` falls back to the dragged fractions (and, failing that, the
            // bottom-trailing default so a fresh install still lands somewhere sensible).
            let pinned = corner.point(in: geo.size, safeArea: geo.safeAreaInsets, half: half)
            let fallback = CoachButtonCorner.bottomTrailing.point(in: geo.size, safeArea: geo.safeAreaInsets,
                                                                  half: half) ?? .zero
            let baseX = pinned?.x ?? (fracX < 0 ? fallback.x : fracX * w)
            let baseY = pinned?.y ?? (fracY < 0 ? fallback.y : fracY * h)
            let x = clamp(baseX + dragging.width, min: half + margin, max: w - half - margin)
            let y = clamp(baseY + dragging.height, min: half + margin, max: h - half - margin)

            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(StrandPalette.accent))
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 4)
                .contentShape(Circle())
                .position(x: x, y: y)
                // Locked: no drag gesture at all, so the button can't be nudged. minimumDistance lets a
                // tap through to onTapGesture; only a real drag moves it (and unpins it to `.custom`).
                .gesture(
                    locked ? nil :
                    DragGesture(minimumDistance: 8)
                        .updating($dragging) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            let nx = clamp(baseX + value.translation.width, min: half + margin, max: w - half - margin)
                            let ny = clamp(baseY + value.translation.height, min: half + margin, max: h - half - margin)
                            fracX = nx / w
                            fracY = ny / h
                            cornerRaw = CoachButtonCorner.custom.rawValue
                        }
                )
                .onTapGesture { isPresented = true }
                .animation(StrandMotion.interactive, value: cornerRaw)
                .accessibilityLabel("Ask your Coach")
                .accessibilityHint(locked
                                   ? "Opens the AI coach chat."
                                   : "Opens the AI coach chat. Draggable.")
                .accessibilityAddTraits(.isButton)
        }
        .allowsHitTesting(true)
    }

    private func clamp(_ v: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(v, lo), hi)
    }
}
#endif
