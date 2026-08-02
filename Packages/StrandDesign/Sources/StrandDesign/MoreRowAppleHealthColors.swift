import SwiftUI

// MARK: - More-tab row colors (Apple Health style)
//
// Fixed, non-chart-style-reactive accent per row of the iOS "More" tab index (`RootTabView.MoreRow`) —
// these are chrome/navigation, not a data encoding, so unlike `StrandPalette.metricAmber`/`chargeColor`/
// etc. they must NOT re-skin when the user picks a different chart style (the redesign rule "colour
// only re-skins data encodings, never chrome" cuts the other way here). Gated behind a single switch
// (`AppleInspiredColorsPrefs`, ON by default) that the user can still turn off to keep every row
// `StrandPalette.accent` instead. The mapping now lives in `AppleInspiredColors` so navigation icons
// and primary controls share one semantic colour contract.
public enum MoreRowAppleHealthColors {
    public static func color(for id: String) -> Color {
        AppleInspiredColors.color(for: id)
    }
}
