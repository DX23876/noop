import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Accent colours are chosen to read as fills, rings and dots. As small text on a light card the
/// brighter ones (yellow, orange, mint) fall well below a readable contrast, so text that takes an
/// accent colour goes through `legibleText`, which darkens it in light appearance only.
public enum LegibleText {
    /// WCAG contrast the darkened text must reach against the light card surface.
    public static let minimumContrast: Double = 4.5
    /// The light card surface the text sits on.
    public static let lightSurface: (r: Double, g: Double, b: Double) = (1, 1, 1)

    static func luminance(r: Double, g: Double, b: Double) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    static func contrast(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
        let l1 = luminance(r: a.r, g: a.g, b: a.b), l2 = luminance(r: b.r, g: b.g, b: b.b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// Mixes the colour towards black in 2 % steps until it reaches `minimumContrast` on white.
    /// A colour that already reads is returned unchanged; hue is preserved.
    public static func darkened(r: Double, g: Double, b: Double,
                                minimumContrast: Double = LegibleText.minimumContrast)
        -> (r: Double, g: Double, b: Double) {
        var t = 0.0
        var c = (r: r, g: g, b: b)
        while contrast(c, lightSurface) < minimumContrast && t < 1 {
            t += 0.02
            c = (r * (1 - t), g * (1 - t), b * (1 - t))
        }
        return c
    }
}

public extension Color {
    /// This colour as small text: darkened on light cards, unchanged in dark appearance and on macOS.
    var legibleText: Color {
        #if canImport(UIKit) && !os(watchOS)
        let source = self
        return Color(UIColor { trait in
            let resolved = UIColor(source).resolvedColor(with: trait)
            guard trait.userInterfaceStyle != .dark else { return resolved }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return resolved }
            let d = LegibleText.darkened(r: Double(r), g: Double(g), b: Double(b))
            return UIColor(red: CGFloat(d.r), green: CGFloat(d.g), blue: CGFloat(d.b), alpha: a)
        })
        #else
        return self
        #endif
    }
}
