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
    static func dyn(_ light: UInt32, _ dark: UInt32, light la: CGFloat = 1, dark da: CGFloat = 1) -> Color {
        Color(UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            let alpha = trait.userInterfaceStyle == .dark ? da : la
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        })
    }

    static let canvas = NoopVisualStyle.canvas
    static let card = NoopVisualStyle.surface
    static let raised = NoopVisualStyle.inset
    static let text = dyn(0x000000, 0xFFFFFF)
    static let secondary = dyn(0x3C3C43, 0xEBEBF5, light: 0.62, dark: 0.62)
    /// Secondary text on a see-through surface: the picture behind it takes contrast the plain tone cannot spare.
    static let secondaryOnPicture = dyn(0x000000, 0xFFFFFF, light: 0.72, dark: 0.78)
    static let tertiary = dyn(0x3C3C43, 0xEBEBF5, light: 0.42, dark: 0.42)
    static let fill = dyn(0x767680, 0x767680, light: 0.13, dark: 0.26)
    static let separator = dyn(0x3C3C43, 0x545458, light: 0.18, dark: 0.55)
    static let hairline = dyn(0xFFFFFF, 0xFFFFFF, light: 0.9, dark: 0.12)
    static var accent: Color { StrandPalette.forgeAccent }
    static var onAccent: Color { StrandPalette.forgeOnAccent }
    /// The Training area's one accent, OpenGym's green (#248A3D light, #30D158 dark): everything to press in
    /// Training wears it, on neutral cards, the way the owner preferred that app's training screens.
    static let trainingAccent = dyn(0x248A3D, 0x30D158)
    /// Text on the training accent: white on the darker light-mode green, black on the bright dark-mode one.
    static let onTrainingAccent = dyn(0xFFFFFF, 0x000000)
    /// Training's data colour beside the green: OpenGym's teal for strength (volume, muscles, routines).
    /// Controls stay green; data and pictures take their own matched colours, Effort and energy orange.
    static let trainingData = dyn(0x0E8AA3, 0x40C8E0)

    static let charge = dyn(0x13896B, 0x3DDC97)
    static let effort = dyn(0xD45F28, 0xFF8A3D)
    static let rest = dyn(0x5B4DBF, 0xA996FF)
    static let chargeInk = dyn(0x0E5C4A, 0x7FE3B4)
    static let effortInk = dyn(0x8C3911, 0xFFB07A)
    static let restInk = dyn(0x3F3398, 0xC2B5FB)

    /// Cycle phases. The luteal half reads in Rest violet; the others have their own hues so a phase is
    /// never mistaken for a score.
    static let cyclePeriod = dyn(0xC94A63, 0xFF7A93)
    static let cycleFollicular = dyn(0x21877B, 0x5FD3C4)
    static let cycleShift = dyn(0xB07A0C, 0xE8B64A)
    static let cycleFertile = dyn(0x4E9F2E, 0x9BDB6B)

    /// The per-tab wash at the top of a plain screen. Colorful gives each area its own colour; the calm
    /// profiles stay close to their canvas and differ only slightly from tab to tab.
    static func wash(_ tab: ForgeTab) -> Color {
        let table: [ForgeTab: (UInt32, UInt32)]
        switch NoopVisualStyle.forgeProfile {
        case .colorful:
            // Each tab in the colour of what it holds: Sleep is Rest, Health is Charge. Training takes
            // OpenGym's plain look, Apple's grouped grey and black, its green the only colour to press.
            table = [.today: (0xCFE4FF, 0x12335F), .training: (0xF2F2F7, 0x000000),
                     .sleep: (0xE0DAFF, 0x2A2270), .health: (0xCDEFDC, 0x0D4A2F)]
        case .stone:
            table = [.today: (0xC9D6E8, 0x22314A), .training: (0xF0D2BC, 0x3A2418),
                     .sleep: (0xDCD4F0, 0x241F44), .health: (0xCFE2E0, 0x173040)]
        case .slate:
            table = [.today: (0xD3DBE6, 0x1E2835), .training: (0xD6DEE4, 0x1F2A32),
                     .sleep: (0xD8D9E8, 0x20233A), .health: (0xD4E0E3, 0x1C2C33)]
        case .sage:
            table = [.today: (0xD6E0D2, 0x1F2C25), .training: (0xDCE3CE, 0x262D1E),
                     .sleep: (0xD6DDD8, 0x20292A), .health: (0xCFE0D4, 0x1A2E25)]
        }
        let colors = table[tab] ?? (0xE5E5EA, 0x1C1C1E)
        return dyn(colors.0, colors.1)
    }

    /// The Energy page's wash: a warm amber glow in Colorful, the Health wash in the calm profiles.
    static var energyWash: Color {
        NoopVisualStyle.forgeProfile == .colorful ? dyn(0xFFE4C2, 0x4A2509) : wash(.health)
    }

    /// The tab bar's colour for the open tab. Colorful gives each area its own, as Apple's apps do.
    static func tabTint(_ tab: ForgeTab?) -> Color {
        guard NoopVisualStyle.forgeProfile == .colorful else { return accent }
        switch tab {
        case .today: return dyn(0x007AFF, 0x0A84FF)
        case .training: return dyn(0x248A3D, 0x30D158)   // the shipped design's Training green
        case .sleep: return dyn(0x5856D6, 0x7D7AFF)
        case .health: return dyn(0x13896B, 0x3DDC97)
        case nil: return dyn(0x0071A4, 0x64D2FF)
        }
    }
}

/// The four primary areas of the redesign.
enum ForgeTab: Int, CaseIterable {
    case today, training, sleep, health
}

enum ForgeFont {
    /// SF Rounded at `size`, grown with the reader's text size. Figures under 34 points follow Dynamic Type
    /// up to half again their size; larger ones sit inside rings of a fixed diameter and keep their size.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: scaled(size), weight: weight, design: .rounded)
    }

    /// The point size for the current text size. Read per body evaluation, so a change of text size reaches
    /// every figure the next time its view draws.
    static func scaled(_ size: CGFloat, category: UIContentSizeCategory = UIApplication.shared.preferredContentSizeCategory) -> CGFloat {
        guard size < 34 else { return size }
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let grown = UIFontMetrics(forTextStyle: .body).scaledValue(for: size, compatibleWith: traits)
        return min(grown, size * 1.5)
    }
    /// Titles in SF Rounded, the face of the ring figures, so the words and the numbers belong together.
    static let largeTitle = StrandFont.title1
    /// A tab's title in its one-row header: small, the picture and the rings are the page.
    static let headerTitle = Font.system(.title3, design: .rounded, weight: .bold)
    static let section = Font.system(.title3, weight: .bold)
    static let cardTitle = Font.system(.headline)
    /// A value in a card: SF Rounded at medium weight, so the figure is large without shouting; its unit
    /// sits beside it in footnote grey.
    static func figure(_ size: CGFloat) -> Font { rounded(size, .medium).monospacedDigit() }
    static let body = Font.system(.subheadline)
    static let caption = Font.system(.footnote)
    static let overDate = Font.system(.footnote, weight: .semibold)
}

// MARK: - Background

extension EnvironmentValues {
    /// The tab a page was pushed from, so a shared screen takes its tab's wash under the new design.
    @Entry var forgeTab: ForgeTab = .today
    /// Today sets how solid its surfaces are over the picture; nil leaves a card to Card transparency.
    @Entry var forgeSurfaceOpacity: Double? = nil
}

/// `ForgeBackground` for shared screens: the tab comes from the environment.
struct ForgeSharedScreenBackground: View {
    @Environment(\.forgeTab) private var tab
    var body: some View { ForgeBackground(tab: tab) }
}

/// `ForgeStatusBarScrim` in the colour of the area a shared screen was opened from.
struct ForgeSharedStatusBarScrim: View {
    @Environment(\.forgeTab) private var tab
    var body: some View { ForgeStatusBarScrim(tab: tab) }
}

/// The page backdrop. Precedence follows the shipped app: the custom photo, then the day-cycle sky, then
/// the plain canvas with a faint per-tab wash. The sky reads the SAME switch the shipped design uses, but
/// defaults it off here (see `ForgeDesignPrefs.skyDefaultInNewDesign`).
struct ForgeBackground: View {
    let tab: ForgeTab
    /// A page's own wash in place of its tab's (Energy's amber).
    var wash: Color? = nil
    /// Only Today's own page carries the motif; everything pushed from it takes the area's colour.
    var showsMotif = false
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var sky = ForgeDesignPrefs.skyDefaultInNewDesign
    @ObservedObject private var photo = BackgroundImageStore.shared

    var body: some View {
        ZStack(alignment: .top) {
            ForgeColor.canvas
            if photo.isActive {
                // Today's own page keeps the photo clear; every other page veils it for its text.
                BackgroundImageBackdrop(veil: !showsMotif)
            } else if sky && showsMotif {
                ForgeTodayMotif()
            }
            // Otherwise the plain system canvas, Apple's grouped grey or black: the colour belongs to the
            // content, not to a wash behind every page. A photo or the sky is the opt-in backdrop.
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The band under the status bar on a tab's own page: the page's own backdrop again, shown over the status
/// bar's height and fading out just under it, so cards scrolled up stop under the clock instead of running
/// through it. Today keeps its own edges (`ForgeTodayEdges`), drawn the same way.
struct ForgeStatusBarScrim: View {
    let tab: ForgeTab
    /// How far below the status bar the backdrop fades out.
    private static let fade: CGFloat = 10

    var body: some View {
        // The status bar's height comes from the window: a view that ignores the safe area, as this one must
        // to reach the top edge, is told an inset of zero.
        let top = Self.statusBarHeight
        ForgeBackground(tab: tab)
            .mask(alignment: .top) {
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: top / max(top + Self.fade, 1)),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: top + Self.fade)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private static var statusBarHeight: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        return window?.safeAreaInsets.top ?? 0
    }
}

/// Today's day-cycle picture, whole: no fade and no veil, the day's sheet ends it. A light page takes no night
/// sky, which would leave the status bar's dark clock unreadable, so its evening stays at sunset and its small
/// hours at dawn. On a dark page the night keeps its moon, raised past the title.
private struct ForgeTodayMotif: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        if colorScheme == .light {
            SceneScreenBackground(hour: ForgeToday.lightPageSceneHour(hour), height: Self.height, fades: false)
        } else if hour >= 21 || hour <= 4 {
            SceneScreenBackground(hour: hour, height: Self.height + 110, fades: false).offset(y: -110)
        } else {
            SceneScreenBackground(hour: hour, height: Self.height, fades: false)
        }
    }

    /// Taller than any iPhone, so the picture always reaches the sheet.
    private static let height: CGFloat = 960
}

// MARK: - Glass cards

/// A redesign card: a clear, unblurred fill that follows the existing Card transparency setting, with a soft
/// shadow in light mode. When the person never set a transparency, the redesign uses its
/// own glass default (the prototype's look) instead of the shipped design's solid 100 %.
struct ForgeCardModifier: ViewModifier {
    var radius: CGFloat = 26
    var padding: CGFloat = 16
    /// The redesign's glass when no Card transparency was ever chosen.
    static let defaultGlassPercent = 78
    @AppStorage(CardAppearancePrefs.opacityKey) private var opacityPercent = ForgeCardModifier.defaultGlassPercent
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.forgeSurfaceOpacity) private var surfaceOpacity

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let opacity = reduceTransparency ? 1 : surfaceOpacity ?? max(0.35, Double(opacityPercent) / 100)
        let light = colorScheme == .light
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(shape)
            .background {
                ZStack {
                    shape.fill(ForgeColor.card.opacity(opacity))
                }
                .shadow(color: .black.opacity(light ? 0.07 : 0), radius: 14, x: 0, y: 5)
            }
    }
}

/// Corner radii of the redesign: one for every card, one for a filled block inside a card. Small marks (bars,
/// ticks) keep their own few-point rounding.
enum ForgeRadius {
    // Apple's grouped cards are tight: 14 and 10, where 22 and 16 read as soft and bubbly.
    static let card: CGFloat = 14
    static let inner: CGFloat = 10
}

/// Opacities of the redesign, by role, instead of a dozen near-equal literals.
enum ForgeOpacity {
    /// A domain colour washed behind an icon or a small figure.
    static let wash: Double = 0.16
    /// A band or range drawn behind marks (a target, a zone).
    static let band: Double = 0.24
}

extension View {
    func forgeCard(radius: CGFloat = ForgeRadius.card, padding: CGFloat = 16) -> some View {
        modifier(ForgeCardModifier(radius: radius, padding: padding))
    }

    /// Small round or capsule glass control (header buttons, chips over a sky).
    func forgeGlassCapsule() -> some View {
        self.liquidGlass(in: Capsule())
    }
}

// MARK: - Header

/// A tab's header in one row: the title with the date beside it, the strap's ring, optional extra buttons and
/// the profile. One row leaves the height to the page. The date gives way first when space runs out.
struct ForgeLargeHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: String? = nil
    let onProfile: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    @EnvironmentObject private var profile: ProfileStore

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    titleText
                    Text(subtitle ?? Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(AppLanguage.activeLocale)))
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(ForgeColor.text.opacity(0.75))
                        .lineLimit(1)
                }
                titleText
            }
            .legibleOnPhoto()
            Spacer(minLength: 8)
            // The level as a figure beside the ring, as the prototype shows it: a ring alone had to be read.
            DashboardBatteryButton(size: 34, showsPercent: true)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            trailing()
            Button(action: onProfile) {
                ProfileAvatarView(imageData: profile.avatarImageData, size: 32, fallbackTint: ForgeColor.accent)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Profile and settings"))
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
    }

    private var titleText: some View {
        Text(title)
            .font(ForgeFont.headerTitle)
            .foregroundStyle(ForgeColor.text)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
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
            Text(title).font(ForgeFont.section).foregroundStyle(ForgeColor.text).legibleOnPhoto()
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let action {
                Button(action: action.run) {
                    Text(action.label).font(.system(.subheadline)).foregroundStyle(ForgeColor.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 12)
        .legibleOnPhoto()
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
                if let systemImage { Image(systemName: systemImage).font(.system(.subheadline, weight: .semibold)) }
                Text(title).font(.system(.subheadline, weight: .medium)).lineLimit(1)
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

#if os(iOS)
extension ForgeDesignPrefs {
    /// System lists (`List`, `Form`) paint their own grouped grey, which reads cool against the redesign's
    /// warm canvas. Under the redesign they draw clear, so the canvas behind every pushed screen shows
    /// through and their rows keep the system card fill. The standard design never sets the proxy, so its
    /// lists are untouched; turning the redesign off takes full effect at the next launch.
    static func applyListChrome() {
        guard NoopVisualStyle.skin == .forge else { return }
        UICollectionView.appearance().backgroundColor = .clear
    }
}
#endif
