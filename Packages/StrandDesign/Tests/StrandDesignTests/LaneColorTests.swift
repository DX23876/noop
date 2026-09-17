import XCTest
import SwiftUI
@testable import StrandDesign

/// Verifies the Strength/Cardio lane colour tokens (`StrandPalette.strengthColor`/`cardioColor` and
/// their deep/bright siblings): each lane must read as one fixed, saturated identity, distinct from
/// the other lane and from the existing status/charge colours, in every chart style and colour scheme.
/// Hue and contrast math is reimplemented here rather than imported from `StrandDesign`, so a bug in
/// the app's own helpers can't hide a palette regression from its own test.
final class LaneColorTests: XCTestCase {

    // MARK: - Pure colour helpers (hex -> sRGB -> HSL hue / WCAG contrast)

    private struct RGB { let r: Double; let g: Double; let b: Double }

    private static func rgb(_ hex: String) -> RGB {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        return RGB(r: Double((v >> 16) & 0xFF) / 255.0,
                   g: Double((v >> 8) & 0xFF) / 255.0,
                   b: Double(v & 0xFF) / 255.0)
    }

    /// Hue in degrees [0, 360) from an sRGB hex triple, via the standard HSL conversion.
    private static func hue(_ hex: String) -> Double {
        let c = rgb(hex)
        let maxV = max(c.r, c.g, c.b)
        let minV = min(c.r, c.g, c.b)
        let delta = maxV - minV
        guard delta > 0 else { return 0 }
        var h: Double
        if maxV == c.r {
            h = 60 * (((c.g - c.b) / delta).truncatingRemainder(dividingBy: 6))
        } else if maxV == c.g {
            h = 60 * (((c.b - c.r) / delta) + 2)
        } else {
            h = 60 * (((c.r - c.g) / delta) + 4)
        }
        if h < 0 { h += 360 }
        return h
    }

    /// Shortest angular distance between two hues, in degrees [0, 180].
    private static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    /// WCAG relative luminance of an sRGB hex colour.
    private static func relativeLuminance(_ hex: String) -> Double {
        let c = rgb(hex)
        func linear(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    /// WCAG contrast ratio between two sRGB hex colours (always >= 1).
    private static func contrastRatio(_ a: String, _ b: String) -> Double {
        let l1 = relativeLuminance(a)
        let l2 = relativeLuminance(b)
        let (hi, lo) = l1 > l2 ? (l1, l2) : (l2, l1)
        return (hi + 0.05) / (lo + 0.05)
    }

    // MARK: - Reference hex tables

    /// `StrandPalette.onDarkPrimary` (Palette.swift) — fixed/scheme-invariant, copied here as a literal
    /// since a `Color` built from a dynamic provider can't be read back to hex.
    private static let onDarkPrimary = "#F4F6F8"

    private struct StyleRefs { let light: String; let dark: String }

    // Existing token hex values, copied from `StrandPalette` (Palette.swift) for the hue-separation
    // checks below — NOT changed by this change; see the file for their canonical definitions.
    private static let statusWarning: [ChartStyle: StyleRefs] = [
        .signature: .init(light: "#C2792E", dark: "#F0A020"),
        .titanium:  .init(light: "#C2792E", dark: "#F0A020"),
        .classic:   .init(light: "#CFA528", dark: "#F2C53D"),
        .health:    .init(light: "#FFCC00", dark: "#FFD60A"),
        .aurora:    .init(light: "#C9A860", dark: "#EBCB8B"),
        .sunset:    .init(light: "#E0952E", dark: "#FFB74D"),
        .forest:    .init(light: "#BC8A3E", dark: "#D8A657"),
    ]
    private static let statusCritical: [ChartStyle: StyleRefs] = [
        .signature: .init(light: "#C84E1E", dark: "#E0662F"),
        .titanium:  .init(light: "#C84E1E", dark: "#E0662F"),
        .classic:   .init(light: "#CB3A2F", dark: "#E5483B"),
        .health:    .init(light: "#FF3B30", dark: "#FF453A"),
        .aurora:    .init(light: "#A54650", dark: "#BF616A"),
        .sunset:    .init(light: "#E03656", dark: "#FF4D6D"),
        .forest:    .init(light: "#9C3524", dark: "#B5432E"),
    ]
    private static let statusPositive: [ChartStyle: StyleRefs] = [
        .signature: .init(light: "#1F8A5B", dark: "#03E095"),
        .titanium:  .init(light: "#1F8A5B", dark: "#03E095"),
        .classic:   .init(light: "#2E9E4F", dark: "#46B45A"),
        .health:    .init(light: "#34C759", dark: "#30D158"),
        .aurora:    .init(light: "#6E9460", dark: "#A3BE8C"),
        .sunset:    .init(light: "#5F9456", dark: "#86B87A"),
        .forest:    .init(light: "#3B7345", dark: "#4E8C57"),
    ]
    private static let chargeColor: [ChartStyle: StyleRefs] = [
        .signature: .init(light: "#0C8F62", dark: "#31E39C"),
        .titanium:  .init(light: "#0F9D62", dark: "#03E095"),
        .classic:   .init(light: "#2E9E4F", dark: "#46B45A"),
        .health:    .init(light: "#34C759", dark: "#30D158"),
        .aurora:    .init(light: "#6E9460", dark: "#A3BE8C"),
        .sunset:    .init(light: "#E0AE3E", dark: "#FFD166"),
        .forest:    .init(light: "#437E4C", dark: "#5A9C63"),
    ]
    // Soft constraint only (not asserted) — recorded per the design brief's request to note styles
    // that land within 18° of it.
    private static let effortColor: [ChartStyle: StyleRefs] = [
        .signature: .init(light: "#0A63B8", dark: "#3AA0FF"),
        .titanium:  .init(light: "#2A78C8", dark: "#4090E0"),
        .classic:   .init(light: "#3A74C4", dark: "#4A90E2"),
        .health:    .init(light: "#FF9500", dark: "#FF9F0A"),
        .aurora:    .init(light: "#5C82A6", dark: "#81A1C1"),
        .sunset:    .init(light: "#E04E50", dark: "#FF6B6B"),
        .forest:    .init(light: "#AC7239", dark: "#C58A47"),
    ]

    private static let allStyles = ChartStyle.allCases

    private func lane(_ style: ChartStyle) -> StrandPalette.LaneColorTable.Style {
        StrandPalette.LaneColorTable.style(style)
    }

    // MARK: - 1: Strength vs Cardio hue separation

    func testLaneHuesAreAtLeast60DegreesApart() {
        for style in Self.allStyles {
            let s = lane(style)
            for (mode, strengthHex, cardioHex) in [
                ("light", s.strengthColor.light, s.cardioColor.light),
                ("dark", s.strengthColor.dark, s.cardioColor.dark),
            ] {
                let d = Self.hueDistance(Self.hue(strengthHex), Self.hue(cardioHex))
                XCTAssertGreaterThanOrEqual(d, 60, "\(style)/\(mode): strength/cardio hue distance \(d)")
            }
        }
    }

    // MARK: - 2: separation from statusWarning / statusCritical / statusPositive / chargeColor

    func testLaneHuesAreSeparatedFromStatusAndCharge() {
        let refTables: [(String, [ChartStyle: StyleRefs])] = [
            ("warning", Self.statusWarning), ("critical", Self.statusCritical),
            ("positive", Self.statusPositive), ("charge", Self.chargeColor),
        ]
        for style in Self.allStyles {
            let s = lane(style)
            for (mode, strengthHex, cardioHex) in [
                ("light", s.strengthColor.light, s.cardioColor.light),
                ("dark", s.strengthColor.dark, s.cardioColor.dark),
            ] {
                let strengthHue = Self.hue(strengthHex)
                let cardioHue = Self.hue(cardioHex)
                for (name, table) in refTables {
                    guard let ref = table[style] else { continue }
                    let refHex = mode == "light" ? ref.light : ref.dark
                    let refHue = Self.hue(refHex)
                    let ds = Self.hueDistance(strengthHue, refHue)
                    let dc = Self.hueDistance(cardioHue, refHue)
                    XCTAssertGreaterThanOrEqual(ds, 18, "\(style)/\(mode): strength vs \(name) hue distance \(ds)")
                    XCTAssertGreaterThanOrEqual(dc, 18, "\(style)/\(mode): cardio vs \(name) hue distance \(dc)")
                }
            }
        }
    }

    /// `effortColor` is NOT a hard constraint — this only records (via `print`, visible with
    /// `swift test --verbose`) which styles land within 18° of it, per the design brief.
    func testEffortProximityIsRecordedNotEnforced() {
        for style in Self.allStyles {
            let s = lane(style)
            guard let ref = Self.effortColor[style] else { continue }
            for (mode, strengthHex, refHex) in [
                ("light", s.strengthColor.light, ref.light),
                ("dark", s.strengthColor.dark, ref.dark),
            ] {
                let d = Self.hueDistance(Self.hue(strengthHex), Self.hue(refHex))
                if d < 18 {
                    print("LaneColorTests: strengthColor is within 18° of effortColor in "
                        + "\(style)/\(mode) (\u{394}=\(String(format: "%.1f", d))\u{b0})")
                }
            }
        }
    }

    // MARK: - 3: deep tones carry small white text (onDarkPrimary) at >= 4.5:1

    func testLaneDeepTonesHaveSufficientContrastForWhiteText() {
        for style in Self.allStyles {
            let s = lane(style)
            for (mode, strengthDeepHex, cardioDeepHex) in [
                ("light", s.strengthDeep.light, s.cardioDeep.light),
                ("dark", s.strengthDeep.dark, s.cardioDeep.dark),
            ] {
                let cs = Self.contrastRatio(strengthDeepHex, Self.onDarkPrimary)
                let cc = Self.contrastRatio(cardioDeepHex, Self.onDarkPrimary)
                XCTAssertGreaterThanOrEqual(cs, 4.5, "\(style)/\(mode): strengthDeep contrast \(cs)")
                XCTAssertGreaterThanOrEqual(cc, 4.5, "\(style)/\(mode): cardioDeep contrast \(cc)")
            }
        }
    }
}
