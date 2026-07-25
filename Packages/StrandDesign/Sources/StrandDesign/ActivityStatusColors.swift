import SwiftUI

/// Apple Health-style fixed colors for the four manual activity-status states (Active/Sick/Injured/On
/// break) — chrome, not a data encoding, so fixed regardless of chart style, same rationale as
/// `MoreRowAppleHealthColors`/`CoachIconColors`. Keyed by a raw string (the app-layer `ActivityStatus
/// .State` enum's `rawValue`, since that type isn't visible from this package) rather than the enum
/// itself. Always applied — unlike the icon-recoloring features, this isn't gated behind the "App icon
/// colors" opt-in, since a distinct color per state is the point of the feature, not a chrome preference.
public enum ActivityStatusColors {
    public static func color(for stateRawValue: String) -> Color {
        switch stateRawValue {
        case "active":  return .systemGreen
        case "sick":    return .systemRed
        case "injured": return .systemOrange
        case "onBreak": return .systemYellow
        default:        return .systemBlue
        }
    }
}
