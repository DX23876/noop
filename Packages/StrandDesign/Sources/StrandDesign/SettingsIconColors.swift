import SwiftUI

// MARK: - Settings/Journey icon colors
//
// Compatibility facade for existing Settings and Journey call sites. New mappings belong in
// `AppleInspiredColors` so the shared preference affects all interface chrome consistently.
public enum SettingsIconColors {
    public static func color(for id: String) -> Color {
        AppleInspiredColors.color(for: id)
    }
}
