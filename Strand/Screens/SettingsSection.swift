import SwiftUI
import StrandDesign

/// A restrained settings group with one semantic icon, one title and one concise explanation.
/// On a page that holds just this one section the page already names it, so the header row is hidden
/// (`settingsSectionHeaderHidden`) rather than repeating "Training" under "Training".
struct SettingsSection<Content: View>: View {
    @Environment(\.settingsSectionHeaderHidden) private var headerHidden
    let icon: String
    let title: LocalizedStringKey
    let blurb: LocalizedStringKey
    var headerAction: (label: LocalizedStringKey, perform: () -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        StrandCard(padding: NoopMetrics.space5, cornerRadius: NoopMetrics.groupedRadius) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                if !headerHidden || headerAction != nil {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    #if os(macOS)
                    Text("Settings").strandOverline()
                    #endif
                    HStack(spacing: NoopMetrics.space2) {
                        if !headerHidden {
                            Image(systemName: icon)
                                .appleInspiredMenuIcon(icon)
                                .accessibilityHidden(true)
                            Text(title)
                                .font(StrandFont.title2)
                                .foregroundStyle(StrandPalette.textPrimary)
                        }
                        if let headerAction {
                            Spacer(minLength: NoopMetrics.space2)
                            Button(headerAction.label, action: headerAction.perform)
                                .buttonStyle(NoopButtonStyle(.tertiary))
                        }
                    }
                }
                }
                Text(blurb)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                content
            }
        }
    }
}

private struct SettingsSectionHeaderHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by a Settings page whose only section carries the page's own title.
    var settingsSectionHeaderHidden: Bool {
        get { self[SettingsSectionHeaderHiddenKey.self] }
        set { self[SettingsSectionHeaderHiddenKey.self] = newValue }
    }
}
