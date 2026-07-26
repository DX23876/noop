import SwiftUI

// MARK: - More-tab row colors
//
// Compatibility facade for More-tab call sites. Semantic roles and the shared Appearance preference
// live in `AppleInspiredColors` so icons and primary controls always use the same color contract.
public enum MoreRowAppleHealthColors {
    public static func color(for id: String) -> Color {
        AppleInspiredColors.color(for: id)
    }
}
