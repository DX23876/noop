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
// "Apple-inspired colors"). The mapping itself lives in `AppleInspiredColors`, which keeps Coach's
// violet/pink identity aligned across navigation icons and primary controls.
//
// Keyed by a short semantic id per call site (`"coach.settings.connection"`, not the raw SF Symbol
// name) because the same symbol appears at multiple call sites with different meaning — e.g.
// `sparkles` identifies "How it works" in `CoachInfoView` and "New goal" in
// `CoachGoalJourneyView`, and those shouldn't be forced to share a color just because they share a
// glyph.
public enum CoachIconColors {
    public static func color(for id: String) -> Color {
        AppleInspiredColors.color(for: id)
    }
}
