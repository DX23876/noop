import WidgetKit
import SwiftUI
import StrandDesign

/// Replaces a Home Screen widget's body with an explanation when this install has no App Group.
///
/// Signers that use a wildcard provisioning profile (Feather and similar, with a bought or enterprise
/// certificate) cannot grant `com.apple.security.application-groups`. The app and the extension then
/// each write to a private container, so every widget renders empty rings forever and reads as broken.
/// Saying why is the only honest state: no other channel between the app and the extension exists
/// without that entitlement. Accessory families are too small for the sentence and keep their dashes.
struct AppGroupNotice: ViewModifier {
    @Environment(\.widgetFamily) private var family

    func body(content: Content) -> some View {
        if WidgetSnapshot.groupContainerAvailable || !Self.homeScreen.contains(family) {
            content
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("No shared data")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("This install method gives NOOP no App Group, so widgets can't read the app. Install with Xcode, AltStore or SideStore.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private static let homeScreen: Set<WidgetFamily> = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
}

extension View {
    func appGroupNotice() -> some View { modifier(AppGroupNotice()) }
}
