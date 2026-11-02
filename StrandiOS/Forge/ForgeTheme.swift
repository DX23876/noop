#if os(iOS)
import SwiftUI
import UIKit
import StrandDesign
import StrandAnalytics

/// Tokens for the redesigned iPhone UI (2026-11, "New design (preview)"). A separate set on purpose: the
/// shipped design keeps reading `StrandPalette` untouched while both run side by side. Light is the warm
/// "Schmiede" world (stone, copper), dark is "Nacht" (slate, gold). Charge, Effort and Rest keep their
/// meaning (green, orange, violet) in both.
enum ForgeColor {
    private static func dyn(_ light: UInt32, _ dark: UInt32, light la: CGFloat = 1, dark da: CGFloat = 1) -> Color {
        Color(UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            let alpha = trait.userInterfaceStyle == .dark ? da : la
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        })
    }

    static let canvas = dyn(0xF4EFE8, 0x0A0D12)
    static let card = dyn(0xFFFDFA, 0x161A20)
    static let raised = dyn(0xF2ECE3, 0x1E232B)
    static let text = dyn(0x000000, 0xFFFFFF)
    static let secondary = dyn(0x3C3C43, 0xEBEBF5, light: 0.62, dark: 0.62)
    static let tertiary = dyn(0x3C3C43, 0xEBEBF5, light: 0.42, dark: 0.42)
    static let fill = dyn(0x767680, 0x767680, light: 0.13, dark: 0.26)
    static let separator = dyn(0x3C3C43, 0x545458, light: 0.18, dark: 0.55)
    static let hairline = dyn(0xFFFFFF, 0xFFFFFF, light: 0.9, dark: 0.12)
    static let accent = dyn(0x9A3E1C, 0xE8B64A)
    static let onAccent = dyn(0xFFFFFF, 0x2A1D00)

    static let charge = dyn(0x13896B, 0x3DDC97)
    static let effort = dyn(0xD45F28, 0xFF8A3D)
    static let rest = dyn(0x5B4DBF, 0xA996FF)
    static let chargeInk = dyn(0x0E5C4A, 0x7FE3B4)
    static let effortInk = dyn(0x8C3911, 0xFFB07A)
    static let restInk = dyn(0x3F3398, 0xC2B5FB)

    /// The faint per-tab wash at the top of a plain screen.
    static func wash(_ tab: ForgeTab) -> Color {
        switch tab {
        case .today: return dyn(0xC9D6E8, 0x22314A)
        case .training: return dyn(0xF0D2BC, 0x3A2418)
        case .sleep: return dyn(0xDCD4F0, 0x241F44)
        case .health: return dyn(0xCFE2E0, 0x173040)
        }
    }
}

/// The four primary areas of the redesign.
enum ForgeTab: Int, CaseIterable {
    case today, training, sleep, health
}

enum ForgeFont {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static let largeTitle = Font.system(size: 34, weight: .bold)
    static let section = Font.system(size: 22, weight: .bold)
    static let cardTitle = Font.system(size: 19, weight: .semibold)
    static let body = Font.system(size: 15)
    static let caption = Font.system(size: 13)
    static let overDate = Font.system(size: 13, weight: .semibold)
}

// MARK: - Background

/// The page backdrop. Precedence follows the shipped app: the custom photo, then the day-cycle sky, then
/// the plain canvas with a faint per-tab wash. The sky reads the SAME switch the shipped design uses, but
/// defaults it off here (see `ForgeDesignPrefs.skyDefaultInNewDesign`).
struct ForgeBackground: View {
    let tab: ForgeTab
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var sky = ForgeDesignPrefs.skyDefaultInNewDesign
    @ObservedObject private var photo = BackgroundImageStore.shared

    var body: some View {
        ZStack(alignment: .top) {
            ForgeColor.canvas
            if photo.isActive {
                BackgroundImageBackdrop()
            } else if sky {
                SceneScreenBackground(height: 640)
            } else {
                // The prototype's per-tab tint reaches about the middle of the screen before it fades.
                LinearGradient(stops: [.init(color: ForgeColor.wash(tab).opacity(0.95), location: 0),
                                       .init(color: ForgeColor.wash(tab).opacity(0.55), location: 0.45),
                                       .init(color: ForgeColor.wash(tab).opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 720)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Glass cards

/// A redesign card: frosted glass whose fill follows the existing Card transparency setting, with a light
/// rim and, in light mode, a soft shadow. When the person never set a transparency, the redesign uses its
/// own glass default (the prototype's look) instead of the shipped design's solid 100 %.
struct ForgeCardModifier: ViewModifier {
    var radius: CGFloat = 26
    var padding: CGFloat = 16
    /// The redesign's glass when no Card transparency was ever chosen.
    static let defaultGlassPercent = 78
    @AppStorage(CardAppearancePrefs.opacityKey) private var opacityPercent = ForgeCardModifier.defaultGlassPercent
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let opacity = reduceTransparency ? 1 : max(0.35, Double(opacityPercent) / 100)
        let light = colorScheme == .light
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(shape)
            .background {
                ZStack {
                    if opacity < 0.99 { shape.fill(.ultraThinMaterial) }
                    shape.fill(ForgeColor.card.opacity(opacity))
                    shape.strokeBorder(ForgeColor.hairline, lineWidth: light ? 1 : 0.6)
                }
                .shadow(color: .black.opacity(light ? 0.07 : 0), radius: 14, x: 0, y: 5)
            }
    }
}

extension View {
    func forgeCard(radius: CGFloat = 26, padding: CGFloat = 16) -> some View {
        modifier(ForgeCardModifier(radius: radius, padding: padding))
    }

    /// Small round or capsule glass control (header buttons, chips over a sky).
    func forgeGlassCapsule() -> some View {
        self.liquidGlass(in: Capsule())
    }
}

// MARK: - Header

/// The weekday and date above every large title ("SUNDAY, NOVEMBER 1").
enum ForgeHeaderDate {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }()
}

/// Apple-style large title with the date above it and the strap battery, optional extra buttons and the
/// profile button on the right.
struct ForgeLargeHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: String? = nil
    let onProfile: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    @EnvironmentObject private var profile: ProfileStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text((subtitle ?? ForgeHeaderDate.formatter.string(from: Date())).uppercased(with: AppLanguage.activeLocale))
                    .font(ForgeFont.overDate)
                    .foregroundStyle(ForgeColor.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                DashboardBatteryButton(size: 34)
                trailing()
                Button(action: onProfile) {
                    ProfileAvatarView(imageData: profile.avatarImageData, size: 32, fallbackTint: ForgeColor.accent)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Profile and settings"))
            }
            Text(title)
                .font(ForgeFont.largeTitle)
                .foregroundStyle(ForgeColor.text)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, 20)
    }
}

extension ForgeLargeHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, subtitle: String? = nil, onProfile: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, onProfile: onProfile, trailing: { EmptyView() })
    }
}

/// A section title in the redesign: bold, with an optional trailing link in the accent colour.
struct ForgeSectionTitle: View {
    let title: LocalizedStringKey
    var action: (label: LocalizedStringKey, run: () -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(ForgeFont.section).foregroundStyle(ForgeColor.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let action {
                Button(action: action.run) {
                    Text(action.label).font(.system(size: 17)).foregroundStyle(ForgeColor.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 14)
    }
}

/// Capsule chip in the redesign (reply chips, quick actions).
struct ForgeChip: View {
    let title: String
    var systemImage: String? = nil
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 14, weight: .semibold)) }
                Text(title).font(.system(size: 15, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(prominent ? ForgeColor.accent : ForgeColor.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(Capsule().fill(ForgeColor.fill))
        }
        .buttonStyle(.plain)
    }
}
#endif
