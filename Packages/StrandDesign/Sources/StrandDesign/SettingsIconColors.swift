import SwiftUI

// MARK: - Settings/Journey icon colors (Apple Health style)
//
// Same idea as `MoreRowAppleHealthColors`/`CoachIconColors`, extended to `JourneyView` and
// `SettingsView`'s shared `SettingsSection` component — kept as its own enum (not folded into
// `CoachIconColors`) so that file's name stays honest about its Coach-only scope. Fixed, non-chart-
// style-reactive accents for LEADING row/section icons only, same exclusions as the other two: not
// chevrons/checkmarks/state icons, and not an icon whose color already carries a DELIBERATE semantic
// meaning (e.g. a plan-status icon, or an achieved/expired goal-outcome icon) — recoloring those would
// compete with the meaning they already carry, not just re-skin chrome.
//
// `SettingsSection`'s call sites key directly on their own `icon` SF Symbol name rather than a separate
// semantic id: every one of its 15 sections already uses a distinct symbol (no repeats with different
// meaning, unlike Coach's screens), so the icon name alone is already a stable, unique key.
public enum SettingsIconColors {
    public static func color(for id: String) -> Color {
        switch id {
        // JourneyView — the goal-header icon reuses `CoachIconColors`' `coach.goal.*` cases directly
        // (same goal, same color as its CoachGoalJourneyView card), so only the "next suggestion" arrow
        // needs its own id here.
        case "journey.nextStep": return .systemGreen

        // SettingsView — SettingsSection, keyed by its own `icon` SF Symbol name
        case "person.crop.circle":              return .systemBlue     // Photo and name
        case "person.fill":                     return .systemIndigo   // Profile
        case "ruler":                           return .systemOrange   // Units
        case "circle.lefthalf.filled":          return .systemPurple   // Appearance
        case "antenna.radiowaves.left.and.right": return .systemGreen  // Strap
        case "battery.25":                      return .systemYellow  // Power saving
        case "heart.text.square":               return .systemRed     // Recovery
        case "testtube.2":                      return .systemTeal    // Test Centre
        case "drop.fill":                       return .systemCyan    // Features
        case "shield.lefthalf.filled":          return .systemIndigo  // Live Sessions (experimental)
        case "bed.double.fill":                 return .systemIndigo  // Sleep staging
        case "flask.fill":                      return .systemPurple  // WHOOP 5 / MG (experimental)
        case "doc.text.magnifyingglass":        return .systemGray    // Diagnostics
        case "externaldrive.fill":              return .systemBlue    // Backup & restore
        case "info.circle.fill":                return .systemGray    // About

        default: return .systemBlue
        }
    }
}
