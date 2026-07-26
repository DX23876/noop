import SwiftUI

// MARK: - Coach/Chat icon colors (Apple Health style)
//
// Same idea as `MoreRowAppleHealthColors`, extended to the Coach chat screen and its submenus
// (`CoachView`, `CoachSettingsView` — both its hub AND one level deeper inside its 5 subpages,
// `CoachInfoView` — both its "how it works" sections AND the sibling `CoachFirstUseSheet` struct,
// `CoachGoalJourneyView` — both its entry points AND the per-goal card icon) — fixed, non-chart-
// style-reactive accents for LEADING row/section icons only (the icon that identifies a row, not
// chevrons/checkmarks/state icons like `bell`/`bell.badge.fill`, which stay as they are — including
// icons whose GLYPH changes with state, e.g. `lock`/`lock.open.fill`; an icon whose glyph is fixed but
// whose EMPHASIS is state-modulated, e.g. accent-vs-muted, still gets its accent branch recolored).
// Gated behind the same single switch `MoreRowAppleHealthColors` reads (`SettingsView`'s
// `noop.moreRowAppleHealthColors`, labeled "App icon colors" — one switch recolors the More tab AND
// Chat AND its submenus together), ON by default; turning it off keeps every icon `StrandPalette.accent`
// instead.
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
        // CoachGoalJourneyView — per-goal card icon, keyed by CoachGoal.Kind.rawValue
        case "coach.goal.run":         return .systemGreen
        case "coach.goal.consistency": return .systemOrange
        case "coach.goal.sleep":       return .systemIndigo
        case "coach.goal.strength":    return .systemRed
        case "coach.goal.weight":      return .systemTeal
        case "coach.goal.stress":      return .systemYellow
        case "coach.goal.recovery":    return .systemPink
        case "coach.goal.custom":      return .systemPurple

        // CoachSettingsView — one level deeper than the hub, inside its 5 subpages
        case "coach.settings.presets":       return .systemPurple
        case "coach.settings.verbosity":     return .systemTeal
        case "coach.settings.proactive":     return .systemOrange
        case "coach.settings.dataAccess":    return .systemBlue
        case "coach.settings.howItWorks":    return .systemIndigo
        case "coach.settings.entry":         return .systemGreen
        case "coach.settings.autoSummarize": return .systemCyan
        case "coach.settings.usage":         return .systemBrown
        case "coach.settings.memoryBar":     return .systemIndigo
        case "coach.settings.systemPrompt":  return .systemGray
        // CoachSettingsView — quick-preset row icon, keyed by CoachPreset.rawValue
        case "coach.preset.focused":    return .systemBlue
        case "coach.preset.supportive": return .systemPink
        case "coach.preset.onDemand":   return .systemGray
        // CoachSettingsView — persona row icon, keyed by CoachPersona.rawValue
        case "coach.persona.guardian":  return .systemTeal
        case "coach.persona.friend":    return .systemPink
        case "coach.persona.commander": return .systemRed

        // CoachInfoView — CoachFirstUseSheet (the sibling struct in the same file; the "how it works"
        // sections above are a DIFFERENT struct, CoachInfoView itself)
        case "coach.firstUse.model":       return .systemBlue
        case "coach.firstUse.support":     return .systemTeal
        case "coach.firstUse.notMedical":  return .systemRed
        case "coach.firstUse.dataConsent": return .systemGreen

        default: return .systemBlue
        }
    }
}
