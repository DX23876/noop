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
        AppleInspiredColors.color(for: id)
    }
}
