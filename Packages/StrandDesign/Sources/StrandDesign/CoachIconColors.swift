import SwiftUI

// MARK: - Coach/Chat icon colors
//
// Compatibility facade for existing Coach call sites. The semantic palette is centralized in
// `AppleInspiredColors`, which keeps icon and primary-control colors in sync.
public enum CoachIconColors {
    public static func color(for id: String) -> Color {
        AppleInspiredColors.color(for: id)
    }
}
