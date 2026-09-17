import XCTest
import SwiftUI
@testable import StrandDesign

/// Holds the chrome tokens in `NoopVisualStyle` to a readable floor: text has to clear WCAG AA over
/// every surface it can land on, structure (borders, dividers, the surface/canvas and inset/surface
/// steps) has to stay visible instead of dissolving into its fill, and the dark surfaces have to keep
/// the deliberate cool cast rather than drifting back to neutral grey.
///
/// The colour math is reimplemented here rather than imported from `StrandDesign`, exactly as
/// `LaneColorTests` does it and for the same reason: a bug in the app's own helpers must not be able
/// to hide a token regression from the test that exists to catch it. Values are read from
/// `NoopVisualStyle.ChromeHex`, which is the source the tokens themselves are built from — a
/// `Color` backed by a dynamic provider cannot be read back, and re-typing the literals here would
/// only check this file against itself.
final class ChromeContrastTests: XCTestCase {

    // MARK: - Pure colour helpers (hex -> sRGB -> alpha compositing -> WCAG contrast / HSL)

    private struct RGBA {
        let r: Double
        let g: Double
        let b: Double
        let a: Double
    }

    private static func rgba(_ hex: String) -> RGBA {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0
        if s.count == 8 { // RRGGBBAA
            return RGBA(r: Double((v >> 24) & 0xFF) / 255.0, g: Double((v >> 16) & 0xFF) / 255.0,
                        b: Double((v >> 8) & 0xFF) / 255.0, a: Double(v & 0xFF) / 255.0)
        }
        return RGBA(r: Double((v >> 16) & 0xFF) / 255.0, g: Double((v >> 8) & 0xFF) / 255.0,
                    b: Double(v & 0xFF) / 255.0, a: 1.0)
    }

    /// Composite a possibly-translucent foreground over an opaque background. The text tokens carry
    /// alpha on purpose, so contrast can only be judged against the surface they actually sit on.
    private static func composite(_ fg: String, over bg: String) -> RGBA {
        let f = rgba(fg)
        let b = rgba(bg)
        return RGBA(r: f.a * f.r + (1 - f.a) * b.r,
                    g: f.a * f.g + (1 - f.a) * b.g,
                    b: f.a * f.b + (1 - f.a) * b.b,
                    a: 1.0)
    }

    private static func relativeLuminance(_ c: RGBA) -> Double {
        func linear(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    /// WCAG contrast ratio of `fg` (composited) against an opaque `bg`.
    private static func contrastRatio(_ fg: String, on bg: String) -> Double {
        let l1 = relativeLuminance(composite(fg, over: bg))
        let l2 = relativeLuminance(rgba(bg))
        let (hi, lo) = l1 > l2 ? (l1, l2) : (l2, l1)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// HSL saturation of an opaque hex, used to pin the cool cast on the dark surfaces.
    private static func saturation(_ hex: String) -> Double {
        let c = rgba(hex)
        let mx = max(c.r, c.g, c.b)
        let mn = min(c.r, c.g, c.b)
        let delta = mx - mn
        guard delta > 0 else { return 0 }
        let light = (mx + mn) / 2
        return light > 0.5 ? delta / (2 - mx - mn) : delta / (mx + mn)
    }

    // MARK: - The token set under test

    private typealias Pair = NoopVisualStyle.ChromeHex.Pair

    private enum Scheme: String, CaseIterable {
        case light, dark
        func hex(_ pair: Pair) -> String { self == .light ? pair.light : pair.dark }
    }

    private static let hex = NoopVisualStyle.ChromeHex.self

    /// Every opaque fill that text can be drawn on.
    private func backdrops(_ scheme: Scheme) -> [(String, String)] {
        [("canvas", scheme.hex(Self.hex.canvas)),
         ("surface", scheme.hex(Self.hex.surface)),
         ("surfaceTop", scheme.hex(Self.hex.surfaceTop)),
         ("surfaceBottom", scheme.hex(Self.hex.surfaceBottom)),
         ("inset", scheme.hex(Self.hex.inset))]
    }

    // MARK: - 1: text clears WCAG AA on every surface it can land on

    /// 4.5:1 is the AA floor for body text, and it applies to `tertiaryText` too — it labels units and
    /// section headings, which are read, not decoration. The previous values missed it badly:
    /// `tertiaryText` measured 2.50:1 in Dark and 1.74:1 in Light, and `secondaryText` in Light sat at
    /// 3.44:1, i.e. under AA for ordinary copy.
    func testTextTokensClearAAOnEverySurface() {
        for scheme in Scheme.allCases {
            for (name, token) in [("secondaryText", Self.hex.secondaryText),
                                  ("tertiaryText", Self.hex.tertiaryText)] {
                let fg = scheme.hex(token)
                for (backdropName, backdrop) in backdrops(scheme) {
                    let r = Self.contrastRatio(fg, on: backdrop)
                    XCTAssertGreaterThanOrEqual(
                        r, 4.5,
                        "\(scheme.rawValue)/\(name) on \(backdropName): \(String(format: "%.2f", r)):1")
                }
            }
        }
    }

    /// Primary copy carries the screen; it should be far clear of the floor, not scraping it.
    func testPrimaryTextIsStronglyLegible() {
        for scheme in Scheme.allCases {
            let fg = scheme.hex(Self.hex.primaryText)
            for (backdropName, backdrop) in backdrops(scheme) {
                let r = Self.contrastRatio(fg, on: backdrop)
                XCTAssertGreaterThanOrEqual(
                    r, 12.0,
                    "\(scheme.rawValue)/primaryText on \(backdropName): \(String(format: "%.2f", r)):1")
            }
        }
    }

    // MARK: - 2: structure stays visible

    /// A border at 1.45:1 — what `#38383A` on `#1C1C1E` measured — is a border you cannot see, which is
    /// why the old sections read as one undifferentiated grey block. 1.8:1 is not AA (borders are not
    /// text); it is the point at which a 1px rim is actually perceptible on both fills it separates.
    func testBordersAreVisibleAgainstTheFillsTheySeparate() {
        for scheme in Scheme.allCases {
            for (name, token) in [("border", Self.hex.border), ("divider", Self.hex.divider)] {
                let fg = scheme.hex(token)
                for (backdropName, backdrop) in [("surface", scheme.hex(Self.hex.surface)),
                                                 ("canvas", scheme.hex(Self.hex.canvas))] {
                    let r = Self.contrastRatio(fg, on: backdrop)
                    XCTAssertGreaterThanOrEqual(
                        r, 1.8,
                        "\(scheme.rawValue)/\(name) on \(backdropName): \(String(format: "%.2f", r)):1")
                }
            }
        }
    }

    /// A card has to read as lifted off the canvas, and an inset as recessed into the card, from fill
    /// alone — a reader who turns off the borders should still see the hierarchy.
    func testSurfaceStepsAreDistinguishable() {
        for scheme in Scheme.allCases {
            let steps = [("surface over canvas", scheme.hex(Self.hex.surface), scheme.hex(Self.hex.canvas)),
                         ("inset over surface", scheme.hex(Self.hex.inset), scheme.hex(Self.hex.surface))]
            for (name, fg, bg) in steps {
                let r = Self.contrastRatio(fg, on: bg)
                XCTAssertGreaterThanOrEqual(
                    r, 1.18, "\(scheme.rawValue)/\(name): \(String(format: "%.2f", r)):1")
            }
        }
    }

    // MARK: - 3: the dark chrome keeps its cool cast

    /// The whole point of the re-value: the old surfaces were the Apple system grey ramp, saturation
    /// 0.034 and below. Without a floor here, a later "tidy-up" slides them back to neutral and the app
    /// is washed out again with every contrast test still green.
    func testDarkSurfacesAreNotNeutralGrey() {
        for (name, token) in [("canvas", Self.hex.canvas), ("surface", Self.hex.surface),
                              ("surfaceTop", Self.hex.surfaceTop), ("surfaceBottom", Self.hex.surfaceBottom),
                              ("inset", Self.hex.inset), ("border", Self.hex.border)] {
            let s = Self.saturation(token.dark)
            XCTAssertGreaterThanOrEqual(
                s, 0.18, "dark/\(name) saturation \(String(format: "%.3f", s)) — drifting back to grey")
        }
    }

    /// The card rim is not painted at token strength — `NoopPanelSurface` strokes it through
    /// `panelRimBorderOpacity`. Checking only the token would assert a crispness the eye never
    /// receives, which is how the rendered rim sat at 1.34:1 while `border` itself measured 1.85:1.
    ///
    /// The floor here is 1.6 rather than the 1.8 demanded of a full-strength divider, and deliberately
    /// so: a card rim is reinforced by the surface/canvas fill step and by the panel's shadow, whereas
    /// a divider inside a card has nothing but itself to be seen by.
    func testPaintedCardRimStaysVisible() {
        for scheme in Scheme.allCases {
            let surface = scheme.hex(Self.hex.surface)
            let rim = Self.withAlpha(scheme.hex(Self.hex.border),
                                     NoopVisualStyle.panelRimBorderOpacity)
            let r = Self.contrastRatio(rim, on: surface)
            XCTAssertGreaterThanOrEqual(
                r, 1.6, "\(scheme.rawValue)/painted card rim: \(String(format: "%.2f", r)):1")
        }
    }

    /// Re-express an opaque `#RRGGBB` as `#RRGGBBAA` at the given opacity, so the compositing helper
    /// above can be pointed at a stroke that a view draws translucently.
    private static func withAlpha(_ hex: String, _ opacity: Double) -> String {
        let base = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let a = Int((max(0, min(1, opacity)) * 255).rounded())
        return "#" + base + String(format: "%02X", a)
    }

    /// `NoopPanelSurface` draws a LinearGradient between these two and its doc comment promises "a
    /// quiet vertical gradient". All three surface tokens used to hold the same hex, so it rendered
    /// flat. Keep them apart.
    func testPanelGradientHasActualEndpoints() {
        for scheme in Scheme.allCases {
            let top = scheme.hex(Self.hex.surfaceTop)
            let bottom = scheme.hex(Self.hex.surfaceBottom)
            XCTAssertNotEqual(top, bottom, "\(scheme.rawValue): panel gradient endpoints are identical")
        }
    }
}
