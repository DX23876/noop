import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Strand Typography (§9.2)
//
// Native Apple typography: semantic system roles for prose and navigation, SF Rounded
// for the score/numeric identity, and SF Mono for raw/log views. System roles preserve
// Dynamic Type's complete scaling curve and language-specific font fallback.
//
// All numeric styles use `.monospacedDigit()` so live values don't reflow.

public enum StrandFont {

    // MARK: Family

    /// Fixed-geometry score numerals use SF Rounded. Prose never comes through this helper; it uses
    /// semantic system roles below so Larger Text receives the native scaling curve.
    private static func roundedSystem(_ size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // MARK: Scale (§9.2)

    /// Display 64–80 / Bold — the SF Rounded gauge score number. Fixed geometry and tabular digits
    /// keep a changing live value from reflowing its ring or tile.
    public static func display(_ size: CGFloat = 72) -> Font {
        roundedSystem(size, weight: .bold).monospacedDigit()
    }

    /// The tight tracking for big display numbers (≈ -0.04em). Apply alongside
    /// `display(_:)` at the use site, e.g. `.tracking(StrandFont.displayTracking(72))`.
    public static func displayTracking(_ size: CGFloat = 72) -> CGFloat {
        -size * 0.02
    }

    /// SF Rounded at an arbitrary fixed size/weight — the house score numeral.
    public static func rounded(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        roundedSystem(size, weight: weight).monospacedDigit()
    }

    /// Native rounded title. Scales through the complete Dynamic Type curve.
    public static let title1 = Font.system(.title, design: .rounded).weight(.bold)

    /// Native rounded secondary title.
    public static let title2 = Font.system(.title2, design: .rounded).weight(.semibold)

    /// Native UI headline.
    public static let headline = Font.headline.weight(.semibold)

    #if os(iOS)
    /// Compact iPhone body text (15pt at the default content-size category). Mapping the app's body
    /// role to Apple's next smaller semantic role restores the denser phone layout while preserving
    /// Dynamic Type, locale fallback and the user's Larger Text setting.
    public static let body = Font.subheadline

    /// Compact iPhone secondary prose (13pt at the default content-size category).
    public static let subhead = Font.footnote
    #else
    /// Native platform body text. watchOS and macOS keep their platform-tuned semantic scale.
    public static let body = Font.body

    /// Native platform secondary prose.
    public static let subhead = Font.subheadline
    #endif

    /// Native caption.
    public static let caption = Font.caption

    #if os(iOS)
    /// Compact iPhone footnote (11pt at the default content-size category).
    public static let footnote = Font.caption2
    #else
    /// Native platform footnote.
    public static let footnote = Font.footnote
    #endif

    /// Compact section overline. Semibold rather than bold, with restrained tracking below.
    public static let overline = Font.caption2.weight(.semibold)

    /// A deliberately fixed compact SF label for gauges and watch layouts. Ordinary section labels
    /// should use `overline`, which scales semantically; this escape hatch is only for bounded chrome.
    public static func overlineScaled(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    /// Mono 13 (SF Mono) — raw / log views. Tabular by nature.
    public static let mono = Font.system(size: 13, weight: .regular, design: .monospaced)

    // MARK: Numeric variants (tabular digits)

    /// A rounded numeric style at an arbitrary size/weight for live values.
    public static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        roundedSystem(size, weight: weight).monospacedDigit()
    }

    #if os(iOS)
    /// Compact iPhone body number, kept in lockstep with the 15pt body role.
    public static let bodyNumber = Font.subheadline.weight(.medium).monospacedDigit()
    #else
    /// Native platform body number for inline live values that should align.
    public static let bodyNumber = Font.body.weight(.medium).monospacedDigit()
    #endif

    /// Native caption number for small live values (sparklines, chips).
    public static let captionNumber = Font.caption.weight(.medium).monospacedDigit()

    /// Mono at an arbitrary size.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Restrained but legible tracking for compact section overlines. The extra fraction of a point
    /// restores the precise, instrument-like rhythm without returning to the older wide 1.4pt spacing.
    public static let overlineTracking: CGFloat = 1.0
}

// MARK: - Text helpers

public extension Text {
    /// Style as a compact section overline: uppercase, semibold, restrained tracking.
    func strandOverline() -> some View {
        self.font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .textCase(.uppercase)
            .foregroundStyle(StrandPalette.textSecondary)
    }
}

public extension View {
    /// Convenience: an overline-styled label string.
    static func strandOverline(_ string: String) -> some View {
        Text(string).strandOverline()
    }
}

#if DEBUG
#Preview("Typography") {
    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("88").font(StrandFont.display(72)).tracking(StrandFont.displayTracking(72)).foregroundStyle(StrandPalette.textPrimary)
            Text("Title 1 / Bold 28").font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
            Text("Title 2 / Semibold 22").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text("Headline / Semibold 17").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text("Body / Regular 15 — the thread of you, read in full.")
                .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
            Text("Subhead 13").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Text("Caption 12").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Text("Footnote 11").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Text("Overline").strandOverline()
            Text("0xAA 41 00 1c crc32=f3a1  mono 13").font(StrandFont.mono).foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: 4) {
                Text("HRV").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Text("62").font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                Text("ms").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 520, height: 620)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
