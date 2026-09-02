import SwiftUI
import StrandDesign

/// The one-time "you can rearrange this" note for the two reference-matched dashboards.
///
/// Both hide their layout editor behind a long-press on the NOOP wordmark, deliberately: the reference
/// screens carry no visible edit affordance. The cost is that the gesture is undiscoverable — nothing on
/// screen suggests it exists, and Settings' "Arrange dashboard" row names the destination without ever
/// mentioning the gesture. So say it once, on the screen where the gesture lives, and never again.
///
/// Per style, not per app: someone who has used Trends for months and then tries Overview has not been
/// told about Overview's wordmark. Storage is a plain `@AppStorage` bool keyed by dashboard.
enum DashboardArrangeHint {
    static func seenKey(_ dashboard: String) -> String { "\(dashboard).dashboard.arrangeHintSeen" }
}

/// The sheet itself. Deliberately a small, dismissible note rather than a tutorial: one sentence, the
/// gesture, and a way out.
struct DashboardArrangeHintSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(StrandPalette.accent.opacity(0.16))
                    Image(systemName: "hand.tap")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
                Text("Rearrange this dashboard")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
            }

            Text("Press and hold the NOOP wordmark at the top to change the order of the sections, or to show and hide them.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("You can also reach it in Settings under Dashboard style.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            NoopButton("Got it", kind: .primary, fullWidth: true) { dismiss() }
        }
        .padding(NoopMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }
}

extension View {
    /// Show `DashboardArrangeHintSheet` the FIRST time this dashboard is displayed, then never again.
    ///
    /// The flag is written when the sheet is raised, not when it is dismissed: a user who swipes it away
    /// has still been told, and re-raising it on the next launch would make a one-time note feel like a
    /// nag.
    func dashboardArrangeHint(dashboard: String, isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) { DashboardArrangeHintSheet() }
    }
}
