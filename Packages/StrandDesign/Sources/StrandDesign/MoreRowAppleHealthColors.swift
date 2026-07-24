import SwiftUI

// MARK: - More-tab row colors (Apple Health style)
//
// Fixed, non-chart-style-reactive accent per row of the iOS "More" tab index (`RootTabView.MoreRow`) —
// these are chrome/navigation, not a data encoding, so unlike `StrandPalette.metricAmber`/`chargeColor`/
// etc. they must NOT re-skin when the user picks a different chart style (the redesign rule "colour
// only re-skins data encodings, never chrome" cuts the other way here). Applied only when the user
// opts in via a single switch (`RootTabView`'s `moreRowAppleHealthColors`); off by default, which keeps
// every row `StrandPalette.accent` exactly as before. Apple's own dynamic system colors (light/dark
// pairs), one per row, some reuse across sections is expected — Apple Health's own category list
// reuses hues too. Keyed by the row's `MoreDestination` case name (`String(describing:)` of a
// no-associated-value enum case), so this package stays decoupled from the app-layer route type.
public enum MoreRowAppleHealthColors {
    public static func color(for id: String) -> Color {
        switch id {
        // Analysis
        case "insightsHub":     return .systemPurple
        case "intelligence":    return .systemIndigo
        case "goalJourney":     return .systemOrange
        case "insights":        return .systemBrown
        case "explore":         return .systemBlue
        case "compare":         return .systemGray

        // Body
        case "live":            return .systemRed
        case "workouts":        return .systemGreen
        case "health":          return .systemPink
        case "labBook":         return .systemIndigo
        case "stress":          return .systemYellow
        case "breathe":         return .systemMint
        case "intervals":       return .systemCyan
        case "rhythm":          return .systemRed

        // Data
        case "fusedRecord":     return .systemBlue
        case "appleHealth":     return .systemPink
        case "miBand":          return .systemGreen
        case "dataSources":     return .systemGray
        case "backupSync":      return .systemBlue
        case "shortcutsExport": return .systemOrange

        // App
        case "alarms":          return .systemOrange
        case "automations":     return .systemPurple
        case "testCentre":      return .systemTeal
        case "siriShortcuts":   return .systemPink
        case "settings":        return .systemGray

        default:                return .systemBlue
        }
    }
}
