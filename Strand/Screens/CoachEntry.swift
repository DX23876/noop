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

    /// Current mode from UserDefaults (defaults to `.both`). A tiny helper so call sites don't repeat the
    /// `@AppStorage` raw-string dance.
    static var current: CoachEntryMode {
        CoachEntryMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .both
    }
}

#if os(iOS)
/// A draggable circular button that opens the Coach, floating over the whole app. The user can drag it
/// anywhere; its position persists (normalised to the screen, so it survives rotation / device changes)
/// and a tap opens the chat. Design tokens only. iOS-only: it lives over the `RootTabView` shell.
struct CoachFloatingButton: View {
    /// Flipped true to present the Coach (the host owns the actual `.coachCover`).
    @Binding var isPresented: Bool

    /// Persisted position as a FRACTION of the container (0…1). Negative = not yet placed → default corner.
    @AppStorage("coach.fab.fx") private var fracX: Double = -1
    @AppStorage("coach.fab.fy") private var fracY: Double = -1
    /// Live drag translation while the finger is down (committed to fracX/fracY on release).
    @GestureState private var dragging: CGSize = .zero

    private let size: CGFloat = 56
    private let margin: CGFloat = 18
    /// Clearance above the floating tab bar for the default resting spot.
    private let bottomInset: CGFloat = 108

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let half = size / 2
            // Default resting position: bottom-trailing, above the tab bar.
            let defaultX = w - half - margin
            let defaultY = h - half - bottomInset
            let baseX = fracX < 0 ? defaultX : fracX * w
            let baseY = fracY < 0 ? defaultY : fracY * h
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
                // minimumDistance lets a tap through to onTapGesture; a real drag moves the button.
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .updating($dragging) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            let nx = clamp(baseX + value.translation.width, min: half + margin, max: w - half - margin)
                            let ny = clamp(baseY + value.translation.height, min: half + margin, max: h - half - margin)
                            fracX = nx / w
                            fracY = ny / h
                        }
                )
                .onTapGesture { isPresented = true }
                .accessibilityLabel("Ask your Coach")
                .accessibilityHint("Opens the AI coach chat. Draggable.")
                .accessibilityAddTraits(.isButton)
        }
        .allowsHitTesting(true)
    }

    private func clamp(_ v: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(v, lo), hi)
    }
}
#endif
