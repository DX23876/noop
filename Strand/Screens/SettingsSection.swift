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
    /// The new design leaves the footer out when the page's own head already says the same thing.
    var forgeBlurbHidden = false
    @ViewBuilder let content: Content

    var body: some View {
        if NoopVisualStyle.skin == .forge {
            // The new design's settings group, built as iOS Settings builds one: a small header above the
            // card, the controls on the card, and the plain explanation as a footer under it, so a page
            // reads as one list of groups instead of a stack of text boxes.
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                if !headerHidden || headerAction != nil {
                    HStack(alignment: .firstTextBaseline) {
                        if !headerHidden {
                            Text(title)
                                .font(StrandFont.footnote.weight(.semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .accessibilityAddTraits(.isHeader)
                        }
                        if let headerAction {
                            Spacer(minLength: NoopMetrics.space2)
                            Button(headerAction.label, action: headerAction.perform)
                                .font(StrandFont.body.weight(.semibold))
                                .foregroundStyle(StrandPalette.accent)
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, NoopMetrics.space4)
                }
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        content
                    }
                    .font(SettingsRowFont.value)
                }
                if !forgeBlurbHidden {
                    Text(blurb)
                        .settingsCaption()
                        .padding(.horizontal, NoopMetrics.space4)
                }
            }
        } else {
            standardBody
        }
    }

    private var standardBody: some View {
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

/// The text size of a setting's label in the new design: the app's body token, which Android's Forge
/// Settings read from the same generated scale, so both platforms label a setting at one size.
enum SettingsRowFont {
    static var value: Font { NoopVisualStyle.skin == .forge ? StrandFont.body : StrandFont.subhead }
    /// The same size where the classic look used its larger body text for a label.
    static var title: Font { StrandFont.body }
}

/// The explanation that sits under a setting or a group: secondary text that wraps instead of clipping.
private struct SettingsCaptionStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(NoopVisualStyle.skin == .forge ? StrandFont.footnote : StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension Text {
    /// A blank line between two explanations joined into one footer.
    static var paragraphBreak: Text {
        let gap = "\n\n"
        return Text(verbatim: gap)
    }
}

extension View {
    /// Styles a line of explanation under a setting (see `SettingsCaptionStyle`).
    func settingsCaption() -> some View { modifier(SettingsCaptionStyle()) }
}

/// A group on a Settings subpage in the new design, built like `SettingsSection` but without its icon and
/// blurb: an optional upper-case header above the card, the controls on the card and an optional plain
/// explanation as the footer under it. Subpages draw this only in the forge skin and keep their own classic
/// layout otherwise.
struct SettingsSubGroup<Content: View>: View {
    var title: LocalizedStringKey? = nil
    var footer: Text? = nil
    var spacing: CGFloat = NoopMetrics.space3
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if let title {
                Text(title)
                    .font(StrandFont.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, NoopMetrics.space4)
            }
            NoopCard {
                VStack(alignment: .leading, spacing: spacing) {
                    content
                }
                .font(SettingsRowFont.value)
            }
            if let footer {
                footer
                    .settingsCaption()
                    .padding(.horizontal, NoopMetrics.space4)
            }
        }
    }
}

/// A switch row on a `SettingsSubGroup` card: the label at the setting size, with an optional hint under it.
struct SettingsSubToggle: View {
    let title: LocalizedStringKey
    var hint: Text? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(SettingsRowFont.value).foregroundStyle(StrandPalette.textPrimary)
                if let hint {
                    hint.settingsCaption()
                }
            }
        }
        .tint(StrandPalette.chargeColor)
        .frame(minHeight: 44)
    }
}

/// The label of a tappable row on a `SettingsSubGroup` card: title at the setting size, an optional hint
/// under it, an optional value and a chevron.
struct SettingsSubRowLabel: View {
    let title: LocalizedStringKey
    var hint: Text? = nil
    var value: String? = nil
    var isDestructive = false

    var body: some View {
        HStack(spacing: NoopMetrics.space2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SettingsRowFont.value)
                    .foregroundStyle(isDestructive ? StrandPalette.statusCritical : StrandPalette.textPrimary)
                    .multilineTextAlignment(.leading)
                if let hint {
                    hint.settingsCaption().multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: NoopMetrics.space2)
            if let value {
                Text(value).font(SettingsRowFont.value).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// A tappable row on a `SettingsSubGroup` card (see `SettingsSubRowLabel`).
struct SettingsSubAction: View {
    let title: LocalizedStringKey
    var hint: Text? = nil
    var value: String? = nil
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            SettingsSubRowLabel(title: title, hint: hint, value: value, isDestructive: role == .destructive)
        }
        .buttonStyle(.plain)
    }
}

/// A row on a `SettingsSubGroup` card that opens a page.
struct SettingsSubLink<Destination: View>: View {
    let title: LocalizedStringKey
    var hint: Text? = nil
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            SettingsSubRowLabel(title: title, hint: hint)
        }
        .buttonStyle(.plain)
    }
}
