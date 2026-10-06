import SwiftUI
import StrandDesign

struct SettingsHubRow: View {
    let page: SettingsPage
    var caption: String?

    var body: some View {
        NavigationLink(value: page) {
            HStack(spacing: NoopMetrics.space3) {
                Image(systemName: page.icon)
                    .appleInspiredMenuIcon(page.colorKey)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text(page.title)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(caption ?? String(localized: page.subtitle))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: NoopMetrics.space2)
                Image(systemName: "chevron.right")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.vertical, NoopMetrics.space3)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
