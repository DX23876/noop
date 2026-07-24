import SwiftUI

// MARK: - Coach/Chat icon colors (Apple Health style)
//
// Same idea as `MoreRowAppleHealthColors`, extended to the Coach chat screen and its submenus
// (`CoachView`, `CoachSettingsView`, `CoachInfoView`, `CoachGoalJourneyView`) — fixed, non-chart-
// style-reactive accents for LEADING row/section icons only (the icon that identifies a row, not
// chevrons/checkmarks/state icons like `bell`/`bell.badge.fill`, which stay as they are). Applied only
// when the user opts in via the same single switch `MoreRowAppleHealthColors` reads
// (`SettingsView`'s `noop.moreRowAppleHealthColors`, labeled "App icon colors" — one switch recolors
// the More tab AND Chat AND its submenus together); off by default, which keeps every icon
// `StrandPalette.accent` exactly as before.
//
// Keyed by a short semantic id per call site (`"coach.settings.connection"`, not the raw SF Symbol
// name) because the same symbol appears at multiple call sites with different meaning — e.g.
// `sparkles` identifies "How it works" in `CoachInfoView` and "New goal" in
// `CoachGoalJourneyView`, and those shouldn't be forced to share a color just because they share a
// glyph.
public enum CoachIconColors {
    public static func color(for id: String) -> Color {
        switch id {
        // CoachView — chat header + empty states
        case "chat.header.newChat":  return .systemGreen
        case "chat.header.menu":     return .systemGray
        case "chat.notConnected":    return .systemPurple

        // CoachSettingsView — hub rows
        case "coach.settings.connection":  return .systemBlue
        case "coach.settings.goalJourney": return .systemOrange
        case "coach.settings.coaching":    return .systemGreen
        case "coach.settings.memory":      return .systemIndigo
        case "coach.settings.privacy":     return .systemTeal

        // CoachInfoView — "how it works" sections
        case "coach.info.howItWorks":       return .systemPurple
        case "coach.info.whatIsShared":     return .systemTeal
        case "coach.info.providerModel":    return .systemBlue
        case "coach.info.whyModelMatters":  return .systemIndigo
        case "coach.info.limits":           return .systemRed

        // CoachGoalJourneyView
        case "coach.goalJourney.newGoal":  return .systemOrange
        case "coach.goalJourney.progress": return .systemGreen

        default: return .systemBlue
        }
    }
}
