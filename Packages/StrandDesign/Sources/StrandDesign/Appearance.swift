import SwiftUI

/// The user's appearance preference for the whole app. Persisted via
/// `@AppStorage(AppearanceMode.storageKey)`. `.system` follows the OS (the default);
/// `.light` / `.dark` force a scheme regardless of the system setting.
///
/// Applied once at each app root via `.preferredColorScheme(mode.colorScheme)`. Because every
/// `StrandPalette` token is a dynamic `Color(light:dark:)`, flipping this re-resolves the entire
/// UI automatically — no per-view plumbing.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    /// The @AppStorage key shared by the app roots and the Settings picker.
    public static let storageKey = "theme.appearance"

    /// Human label for the Settings control.
    public var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// SF Symbol for the Settings control.
    public var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon.stars"
        }
    }

    /// The `ColorScheme` to force, or `nil` to follow the system (the `.system` case).
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Resolve a stored raw value (tolerant of an unknown/missing value → `.system`).
    public static func resolve(_ raw: String) -> AppearanceMode {
        AppearanceMode(rawValue: raw) ?? .system
    }
}

// MARK: - Light-idiom helpers

/// An additive glow (ring blooms, sparkline heads, hero halos) only reads on a DARK canvas —
/// `.plusLighter` blending on white produces no visible glow and just muddies edges. On dark this
/// applies the additive blend; on light it hides the layer. Self-contained (reads the scheme itself)
/// so every glow becomes a one-token swap from `.blendMode(.plusLighter)` → `.additiveBloom()`.
private struct AdditiveBloom: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        if scheme == .dark { content.blendMode(.plusLighter) }
        else { content.opacity(0) }
    }
}

/// Card / floating-surface elevation. Dark separates surfaces by a lighter FILL (no resting shadow);
/// light separates white-on-paper by a soft DROP SHADOW. Reads the scheme itself and deepens on hover.
private struct NoopElevation: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var hovering: Bool
    func body(content: Content) -> some View {
        let lightShadow = Color(hex: "#1A2230")
        return content.shadow(
            color: scheme == .light ? lightShadow.opacity(hovering ? 0.16 : 0.09)
                                    : Color.black.opacity(hovering ? 0.45 : 0.0),
            radius: scheme == .light ? (hovering ? 14 : 10) : (hovering ? 18 : 0),
            x: 0, y: scheme == .light ? (hovering ? 5 : 3) : (hovering ? 8 : 0)
        )
    }
}

public extension View {
    /// Apply the additive glow only on dark; hide it on light. See `AdditiveBloom`.
    func additiveBloom() -> some View { modifier(AdditiveBloom()) }

    /// Apply the per-scheme card/surface elevation (shadow on light, lighter-fill idiom on dark).
    func noopElevation(hovering: Bool = false) -> some View { modifier(NoopElevation(hovering: hovering)) }
}
