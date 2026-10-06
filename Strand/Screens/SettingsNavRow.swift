import SwiftUI
import StrandDesign

/// The canonical value-driven navigation row used inside Settings cards.
struct SettingsNavRow: View {
    var icon: (symbol: String, id: String)?
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var accessibilityLabel: LocalizedStringKey?
    let route: SettingsSubpage

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: NoopMetrics.space3) {
                if let icon {
                    Image(systemName: icon.symbol)
                        .appleInspiredMenuIcon(icon.id)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text(title)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel(Text(accessibilityLabel ?? title))
    }
}
