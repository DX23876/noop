import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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

    /// The chrome the redesign (NOOP Forge, 2026-11) draws with: a warm paper canvas and near-white cards
    /// in Light, a deep graphite in Dark, and the system label greys for secondary text. The values are
    /// the redesign's own tokens (`ForgeColor` in the iOS app), held here so every shared screen pushed
    /// from the redesigned tabs wears the same chrome without a per-screen rewrite.
    enum ForgeHex {
        static let canvas = ChromeHex.Pair(light: "#F4EFE8", dark: "#0A0D12")
        static let surface = ChromeHex.Pair(light: "#FFFDFA", dark: "#161A20")
        static let surfaceTop = ChromeHex.Pair(light: "#FFFDFA", dark: "#191E25")
        static let surfaceBottom = ChromeHex.Pair(light: "#FBF7F1", dark: "#13171D")
        static let inset = ChromeHex.Pair(light: "#F2ECE3", dark: "#1E232B")
        static let border = ChromeHex.Pair(light: "#B9AE9F", dark: "#454D59")
        static let borderHighlight = ChromeHex.Pair(light: "#FFFFFF", dark: "#454D58")
        static let divider = ChromeHex.Pair(light: "#B9AE9F", dark: "#454D59")
        static let primaryText = ChromeHex.Pair(light: "#000000", dark: "#FFFFFF")
        static let secondaryText = ChromeHex.Pair(light: "#3C3C43D8", dark: "#EBEBF5B8")
        static let tertiaryText = ChromeHex.Pair(light: "#3C3C43C4", dark: "#EBEBF594")
    }

    /// One colour profile's chrome and accent. A nil accent follows the wearer's accent choice.
    struct ForgeProfileHex {
        let canvas, surface, surfaceTop, surfaceBottom, inset, border, borderHighlight, divider: ChromeHex.Pair
        var accent: ChromeHex.Pair?
        var onAccent: ChromeHex.Pair?
    }

    /// How the new design colours the whole app. Colorful is the default; the other three are calmer.
    public enum ForgeColorProfile: String, CaseIterable, Identifiable, Sendable {
        case colorful, stone, slate, sage
        public var id: String { rawValue }
        public static let storageKey = "noop.forgeDesign.colorProfile"
        public static func resolve(_ raw: String?) -> ForgeColorProfile { raw.flatMap(ForgeColorProfile.init) ?? .colorful }

        var hex: ForgeProfileHex {
            func pair(_ light: String, _ dark: String) -> ChromeHex.Pair { .init(light: light, dark: dark) }
            switch self {
            // Apple's neutral greys and pure white cards: the accent and the data carry the colour.
            case .colorful:
                return .init(canvas: pair("#F2F2F7", "#000000"), surface: pair("#FFFFFF", "#1C1C1E"),
                             surfaceTop: pair("#FFFFFF", "#1F1F21"), surfaceBottom: pair("#FBFBFD", "#19191B"),
                             inset: pair("#E9E9EE", "#2C2C2E"), border: pair("#AEAEB2", "#636366"),
                             borderHighlight: pair("#FFFFFF", "#48484A"), divider: pair("#AEAEB2", "#636366"))
            case .stone:
                return .init(canvas: ForgeHex.canvas, surface: ForgeHex.surface, surfaceTop: ForgeHex.surfaceTop,
                             surfaceBottom: ForgeHex.surfaceBottom, inset: ForgeHex.inset, border: ForgeHex.border,
                             borderHighlight: ForgeHex.borderHighlight, divider: ForgeHex.divider,
                             accent: pair("#9A3E1C", "#E8B64A"), onAccent: pair("#FFFFFF", "#2A1D00"))
            case .slate:
                return .init(canvas: pair("#EEF1F5", "#0B0F14"), surface: pair("#FFFFFF", "#161B22"),
                             surfaceTop: pair("#FFFFFF", "#191F27"), surfaceBottom: pair("#F9FAFC", "#13181E"),
                             inset: pair("#E4E8EE", "#202730"), border: pair("#A3ADBB", "#4D5764"),
                             borderHighlight: pair("#FFFFFF", "#4D5764"), divider: pair("#A3ADBB", "#4D5764"),
                             accent: pair("#3F5F85", "#8FB3DC"), onAccent: pair("#FFFFFF", "#0B1B2B"))
            case .sage:
                return .init(canvas: pair("#EFF2EC", "#0B100D"), surface: pair("#FFFFFF", "#151B17"),
                             surfaceTop: pair("#FFFFFF", "#181F1A"), surfaceBottom: pair("#F9FBF8", "#121714"),
                             inset: pair("#E4E9E0", "#1F2721"), border: pair("#A0AB99", "#4E5A52"),
                             borderHighlight: pair("#FFFFFF", "#4E5A52"), divider: pair("#A0AB99", "#4E5A52"),
                             accent: pair("#4A6B52", "#9CC7A8"), onAccent: pair("#FFFFFF", "#0D2214"))
            }
        }
    }
    public static var forgeProfile: ForgeColorProfile = .colorful

    /// Which chrome the shared tokens resolve to. The iOS shell sets it from the "New design" switch
    /// before its first frame and again when the switch changes; macOS and the watch never touch it.
    public enum ChromeSkin: Sendable { case standard, forge }
    public static var skin: ChromeSkin = .standard

    private static func token(_ pair: ChromeHex.Pair, forge: ChromeHex.Pair,
                              profile: KeyPath<ForgeProfileHex, ChromeHex.Pair>? = nil) -> Color {
        let standard = Color(light: pair.light, dark: pair.dark)
        #if canImport(UIKit) && !os(watchOS)
        // Resolved per draw, so a token follows the switch and the profile without being rebuilt.
        let s = UIColor(standard), f = UIColor(Color(light: forge.light, dark: forge.dark))
        var byProfile: [ForgeColorProfile: UIColor] = [:]
        if let profile {
            for option in ForgeColorProfile.allCases {
                let hex = option.hex[keyPath: profile]
                byProfile[option] = UIColor(Color(light: hex.light, dark: hex.dark))
            }
        }
        return Color(UIColor { trait in
            let chosen = skin != .forge ? s : (byProfile[forgeProfile] ?? f)
            return chosen.resolvedColor(with: trait)
        })
        #else
        return standard
        #endif
    }

    public static let canvas = token(ChromeHex.canvas, forge: ForgeHex.canvas, profile: \.canvas)
    public static let surface = token(ChromeHex.surface, forge: ForgeHex.surface, profile: \.surface)
    public static let surfaceTop = token(ChromeHex.surfaceTop, forge: ForgeHex.surfaceTop, profile: \.surfaceTop)
    public static let surfaceBottom = token(ChromeHex.surfaceBottom, forge: ForgeHex.surfaceBottom, profile: \.surfaceBottom)
    public static let inset = token(ChromeHex.inset, forge: ForgeHex.inset, profile: \.inset)

    public static let border = token(ChromeHex.border, forge: ForgeHex.border, profile: \.border)
    public static let borderHighlight = token(ChromeHex.borderHighlight, forge: ForgeHex.borderHighlight, profile: \.borderHighlight)
    public static let divider = token(ChromeHex.divider, forge: ForgeHex.divider, profile: \.divider)

    public static let primaryText = token(ChromeHex.primaryText, forge: ForgeHex.primaryText)
    public static let secondaryText = token(ChromeHex.secondaryText, forge: ForgeHex.secondaryText)
    public static let tertiaryText = token(ChromeHex.tertiaryText, forge: ForgeHex.tertiaryText)

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
    /// nil follows the subtree default (`noopCardKind(_:)`), `.data` unless a screen sets it.
    public var kind: NoopCardKind?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.noopCardKind) private var environmentKind
    @Environment(\.noopQuietCardRims) private var quietRims
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
        surfaceOpacity: Double = 1,
        kind: NoopCardKind? = nil
    ) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.elevated = elevated
        self.surfaceOpacity = surfaceOpacity
        self.kind = kind
    }

    #if os(iOS)
    private static let quietEdges = true
    #else
    private static let quietEdges = false
    #endif

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let chrome = NoopCardChrome.resolve(
            kind: kind ?? environmentKind,
            isLight: scheme == .light,
            isTransparent: resolvedOpacity < 1,
            increasedContrast: contrast == .increased,
            quietEdges: Self.quietEdges,
            quietRims: quietRims)
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
            .overlay {
                switch chrome.rim {
                case .none:
                    EmptyView()
                case .strong where scheme == .light:
                    // The gradient's top stop is white in light appearance; use the real border colour.
                    shape.strokeBorder(NoopVisualStyle.border, lineWidth: 1.5)
                case .hairline, .strong:
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [NoopVisualStyle.borderHighlight.opacity(NoopVisualStyle.panelRimHighlightOpacity),
                                     NoopVisualStyle.border.opacity(NoopVisualStyle.panelRimBorderOpacity)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: chrome.rim == .strong ? 1.4 : 0.8
                    )
                case .tinted, .tintedStrong:
                    shape.strokeBorder((tint ?? NoopVisualStyle.border).opacity(chrome.rim == .tintedStrong ? 0.85 : 0.45),
                                       lineWidth: chrome.rim == .tintedStrong ? 1.4 : 1)
                }
            }
            // Dark keeps its depth shadow; in light the shadow follows the kind.
            .shadow(
                color: scheme == .dark ? .black.opacity(elevated ? 0.34 : 0.18)
                                       : (chrome.shadow ? .black.opacity(elevated ? 0.10 : NoopCardChrome.lightShadowOpacity) : .clear),
                radius: elevated ? 18 : (scheme == .dark ? 9 : NoopCardChrome.lightShadowRadius),
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
        surfaceOpacity: Double = 1,
        kind: NoopCardKind? = nil
    ) -> some View {
        background {
            NoopPanelSurface(
                tint: tint,
                cornerRadius: cornerRadius,
                elevated: elevated,
                surfaceOpacity: surfaceOpacity,
                kind: kind
            )
        }
    }
}
