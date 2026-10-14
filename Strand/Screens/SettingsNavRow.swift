import SwiftUI
import StrandDesign

/// The canonical value-driven navigation row used inside Settings cards. It leads either to a subpage
/// below the current page or to another Settings page (a cross-link such as Training → Notifications,
/// so a control keeps one home while the screens that need it point there).
struct SettingsNavRow: View {
    enum Link: Hashable {
        case subpage(SettingsSubpage)
        case page(SettingsPage)
    }

    var icon: (symbol: String, id: String)?
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var accessibilityLabel: LocalizedStringKey?
    let link: Link

    init(icon: (symbol: String, id: String)? = nil, title: LocalizedStringKey,
         subtitle: LocalizedStringKey? = nil, accessibilityLabel: LocalizedStringKey? = nil,
         route: SettingsSubpage) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.accessibilityLabel = accessibilityLabel
        self.link = .subpage(route)
    }

    init(icon: (symbol: String, id: String)? = nil, title: LocalizedStringKey,
         subtitle: LocalizedStringKey? = nil, accessibilityLabel: LocalizedStringKey? = nil,
         page: SettingsPage) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.accessibilityLabel = accessibilityLabel
        self.link = .page(page)
    }

    var body: some View {
        Group {
            switch link {
            case .subpage(let route): NavigationLink(value: route) { label }
            case .page(let page): NavigationLink(value: page) { label }
            }
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel(Text(accessibilityLabel ?? title))
    }

    private var label: some View {
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
}
