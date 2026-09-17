import SwiftUI

// MARK: - NOOP visual foundation
//
// These tokens describe the visual treatment used by NOOP's existing views. They deliberately
// contain no navigation, state, or domain semantics: screens keep their current hierarchy and data
// bindings, while cards, gauges, typography, and chrome share one maintainable source of truth.

public enum NoopVisualStyle {
    // A cool slate hierarchy: near-black in Dark, paper in Light, both carrying a deliberate blue-cool
    // cast rather than the neutral grey these tokens used to mirror from iOS.
    //
    // WHY THE VALUES MOVED. The previous set was the Apple system grey ramp verbatim (#000000 /
    // #1C1C1E / #2C2C2E, border #38383A), which measured as follows and read as washed out for it:
    // border carried only 1.45:1 against the surface, so dividers and card rims dissolved into the
    // fill; `tertiaryText` reached 2.50:1 in Dark and 1.74:1 in Light; and `secondaryText` in Light
    // sat at 3.44:1, under the 4.5:1 AA floor for body text. Surface saturation was 0.034 — grey in
    // all but name. Every value below is chosen against `ChromeContrastTests`, which re-checks the
    // same arithmetic, so a future edit cannot quietly walk any of it back.
    //
    // `surfaceTop`/`surfaceBottom` are now genuinely distinct. `NoopPanelSurface` has always drawn a
    // LinearGradient between them and promised "a quiet vertical gradient" in its own doc comment,
    // but all three tokens held the same hex, so the gradient rendered flat.
    //
    // This layer deliberately does NOT branch on `ChartStyle` — chart styles recolour data encodings,
    // never chrome (see `Appearance.swift`). A cool cast is what lets one chrome carry all seven of
    // them; a green or gold one would fight Aurora's frost and Forest's earth.
    /// The raw hex behind every chrome token, kept as strings so `ChromeContrastTests` can parse the
    /// very values the tokens are built from. A `Color` backed by a dynamic provider cannot be read
    /// back, and a test that re-typed the literals would only be checking its own copy — the same
    /// reason `StrandPalette.LaneColorTable` exists.
    enum ChromeHex {
        struct Pair {
            let light: String
            let dark: String
        }
        static let canvas = Pair(light: "#E7EBF3", dark: "#03050A")
        static let surface = Pair(light: "#FFFFFF", dark: "#151B2A")
        static let surfaceTop = Pair(light: "#FFFFFF", dark: "#181F30")
        static let surfaceBottom = Pair(light: "#F9FAFD", dark: "#121724")
        static let inset = Pair(light: "#E8ECF5", dark: "#212B3D")
        static let border = Pair(light: "#98A3B6", dark: "#374861")
        static let borderHighlight = Pair(light: "#FFFFFF", dark: "#4C5F83")
        static let divider = Pair(light: "#98A3B6", dark: "#374861")
        static let primaryText = Pair(light: "#0B0F18", dark: "#F4F7FC")
        // Translucent, NOT opaque: cards and the Liquid hero are partly transparent, so secondary and
        // tertiary copy composites over whatever is actually behind it. Only the opacity rose — enough
        // to clear 4.5:1 over canvas, surface and inset alike.
        static let secondaryText = Pair(light: "#28313FCC", dark: "#E6EDFAC4")
        static let tertiaryText = Pair(light: "#28313FB8", dark: "#E6EDFA96")
    }

    private static func token(_ pair: ChromeHex.Pair) -> Color {
        Color(light: pair.light, dark: pair.dark)
    }

    public static let canvas = token(ChromeHex.canvas)
    public static let surface = token(ChromeHex.surface)
    public static let surfaceTop = token(ChromeHex.surfaceTop)
    public static let surfaceBottom = token(ChromeHex.surfaceBottom)
    public static let inset = token(ChromeHex.inset)

    public static let border = token(ChromeHex.border)
    public static let borderHighlight = token(ChromeHex.borderHighlight)
    public static let divider = token(ChromeHex.divider)

    public static let primaryText = token(ChromeHex.primaryText)
    public static let secondaryText = token(ChromeHex.secondaryText)
    public static let tertiaryText = token(ChromeHex.tertiaryText)

    public static let mint = Color(light: "#149A78", dark: "#69DDB8")
    public static let mintDeep = Color(light: "#0D765C", dark: "#13A982")
    public static let mintGlow = Color(light: "#38C99E", dark: "#54E6BD")

    /// The opacities `NoopPanelSurface` strokes its rim with, named rather than inlined so
    /// `ChromeContrastTests` can check what is actually PAINTED and not merely the token behind it.
    /// They used to be 0.72 / 0.52, which put the rendered card rim at 1.34:1 even once the `border`
    /// token itself cleared 1.85:1 — the gate would have been asserting something the eye never got.
    public static let panelRimHighlightOpacity: Double = 0.92
    public static let panelRimBorderOpacity: Double = 0.80

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
                        colors: [NoopVisualStyle.borderHighlight.opacity(NoopVisualStyle.panelRimHighlightOpacity),
                                 NoopVisualStyle.border.opacity(NoopVisualStyle.panelRimBorderOpacity)],
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
