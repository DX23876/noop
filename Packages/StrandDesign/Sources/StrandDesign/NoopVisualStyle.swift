import SwiftUI

// MARK: - NOOP visual foundation
//
// These tokens describe the visual treatment used by NOOP's existing views. They deliberately
// contain no navigation, state, or domain semantics: screens keep their current hierarchy and data
// bindings, while cards, gauges, typography, and chrome share one maintainable source of truth.

public enum NoopVisualStyle {
    // Apple grouped-background hierarchy. These values mirror the public iOS system colours while
    // remaining explicit dynamic tokens, so macOS, widgets, and watchOS resolve the same design language.
    public static let canvas = Color(light: "#F2F2F7", dark: "#000000")
    public static let surface = Color(light: "#FFFFFF", dark: "#1C1C1E")
    public static let surfaceTop = Color(light: "#FFFFFF", dark: "#1C1C1E")
    public static let surfaceBottom = Color(light: "#FFFFFF", dark: "#1C1C1E")
    public static let inset = Color(light: "#F2F2F7", dark: "#2C2C2E")

    public static let border = Color(light: "#C6C6C8", dark: "#38383A")
    public static let borderHighlight = Color(light: "#FFFFFF", dark: "#48484A")
    public static let divider = Color(light: "#C6C6C8", dark: "#38383A")

    public static let primaryText = Color(light: "#000000", dark: "#FFFFFF")
    public static let secondaryText = Color(light: "#3C3C4399", dark: "#EBEBF599")
    public static let tertiaryText = Color(light: "#3C3C434D", dark: "#EBEBF54D")

    public static let mint = Color(light: "#149A78", dark: "#69DDB8")
    public static let mintDeep = Color(light: "#0D765C", dark: "#13A982")
    public static let mintGlow = Color(light: "#38C99E", dark: "#54E6BD")

    public static let cardRadius: CGFloat = 22
    public static let compactRadius: CGFloat = 16
    public static let pillRadius: CGFloat = 999
    public static let pagePadding: CGFloat = 16
    public static let cardPadding: CGFloat = 16
    public static let itemGap: CGFloat = 12
    public static let sectionGap: CGFloat = 26
}

/// Shared card/panel treatment: a quiet vertical gradient, a top-lit rim, and deep soft elevation.
/// `tint` is intentionally faint so metric identity never turns the whole card into a coloured tile.
public struct NoopPanelSurface: View {
    public var tint: Color?
    public var cornerRadius: CGFloat
    public var elevated: Bool
    public var surfaceOpacity: Double
    @Environment(\.colorScheme) private var scheme
    /// Reduce Transparency is enforced HERE rather than at each caller that passes a `surfaceOpacity`.
    /// The setting was previously honoured in three places (`StrandCard`, `LiquidTodayView`,
    /// `LiquidPrimitives`), which meant it held exactly as long as every future caller remembered it —
    /// and the surface has the last word on its own opacity anyway.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The opacity actually painted: whatever the caller asked for, or fully opaque when the reader
    /// has asked for transparency to be reduced.
    private var resolvedOpacity: Double {
        reduceTransparency ? 1 : surfaceOpacity
    }

    public init(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopVisualStyle.cardRadius,
        elevated: Bool = false,
        surfaceOpacity: Double = 1
    ) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.elevated = elevated
        self.surfaceOpacity = surfaceOpacity
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(
                LinearGradient(
                    colors: [NoopVisualStyle.surfaceTop, NoopVisualStyle.surfaceBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                if let tint {
                    shape.fill(
                        LinearGradient(
                            colors: [tint.opacity(0.055), tint.opacity(0.012), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [NoopVisualStyle.borderHighlight.opacity(0.72), NoopVisualStyle.border.opacity(0.52)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            )
            .shadow(
                color: scheme == .dark ? .black.opacity(elevated ? 0.34 : 0.18) : .black.opacity(0.10),
                radius: elevated ? 18 : 9,
                x: 0,
                y: elevated ? 10 : 5
            )
            .opacity(resolvedOpacity)
    }
}

/// Shared edge-to-edge chrome for sheet and split-view headers. Unlike a card it has no
/// rounded outline or elevation, but it uses the same top-lit surface ramp and divider token.
public struct NoopChromeSurface: View {
    public init() {}

    public var body: some View {
        LinearGradient(
            colors: [NoopVisualStyle.surfaceTop, NoopVisualStyle.surfaceBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NoopVisualStyle.divider)
                .frame(height: 0.5)
        }
    }
}

public extension View {
    func noopPanel(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopVisualStyle.cardRadius,
        elevated: Bool = false,
        surfaceOpacity: Double = 1
    ) -> some View {
        background {
            NoopPanelSurface(
                tint: tint,
                cornerRadius: cornerRadius,
                elevated: elevated,
                surfaceOpacity: surfaceOpacity
            )
        }
    }
}
