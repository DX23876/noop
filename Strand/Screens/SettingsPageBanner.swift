import SwiftUI
import StrandDesign

/// The new design's head of a Settings page: the page's symbol as a picture in its own colour beside what
/// the page is for, so a page of switches opens on something to look at rather than on the first toggle.
struct SettingsPageBanner: View {
    let page: SettingsPage

    var body: some View {
        let tint = AppleInspiredColors.color(for: page.colorKey)
        HStack(spacing: 16) {
            CoachPicture(main: page.icon, accentA: "sparkle", accentB: "star.fill", tint: tint)
                .frame(width: CoachPictureSize.medium, height: CoachPictureSize.medium)
            Text(page.subtitle)
                .font(StrandFont.body.weight(.medium))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.18), tint.opacity(0.04)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
        .accessibilityElement(children: .combine)
    }
}
