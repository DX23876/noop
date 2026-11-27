import SwiftUI
import StrandDesign

/// The new design's head of a Settings page, as iOS Settings opens its own pages: the page's symbol on a
/// coloured tile, centred, with one plain line on what the page is for. The tile carries the same colour
/// as the page's row in the Settings index, so the row and the page it opens read as one thing.
struct SettingsPageBanner: View {
    let page: SettingsPage

    var body: some View {
        SettingsSymbolBanner(symbol: page.icon, tint: page.forgeTint, text: Text(page.subtitle))
    }
}

/// The same head for a page below a Settings page (Test Centre, Data sources): the symbol and colour are
/// handed in because such a page has no row of its own in the Settings index.
struct SettingsSymbolBanner: View {
    let symbol: String
    let tint: Color
    let text: Text

    var body: some View {
        VStack(spacing: NoopMetrics.space3) {
            Image(systemName: symbol)
                .font(.system(.title, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint))
                .accessibilityHidden(true)
            text
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.bottom, NoopMetrics.space2)
        .accessibilityElement(children: .combine)
    }
}

extension SettingsPage {
    /// The tile colour of this page in the new design, in the Settings index and on the page's own head.
    /// Four system colours only, so no area shouts louder than another; alerts keep red as iOS does.
    var forgeTint: Color {
        switch self {
        case .profile, .goals, .strap, .batteryRecording, .todayTrends, .calculations: return .green
        case .strapActions, .siri, .help, .training: return .orange
        case .notifications: return .red
        case .roadmap, .coach, .appearance, .languageUnits, .dataBackup, .lab, .about: return .indigo
        }
    }
}
