import SwiftUI
import StrandDesign
import WhoopStore

/// The Coach entry both reference-matched dashboards show: "YOUR COACH {name}", a greeting, and one
/// recommendation sentence.
///
/// Shared rather than copied. The sentence is the SAME copy Momentum derives for a recovery-driven
/// training read (`MomentumCopy.stateDetail`), so no dashboard can tell the wearer something different
/// from what Today's own Momentum card says — and a second hand-built card would be exactly how that
/// starts. Trends had this inline; Overview had no Coach surface at all beyond the header icon.
///
/// `compact` trims the card for Overview, whose whole layout runs on a tighter scale (its own
/// `sectionSpacing`/`cardPadding`) so the screen reads without scrolling.
struct DashboardCoachCard: View {
    let day: DailyMetric?
    var compact: Bool = false
    let onOpen: () -> Void

    @EnvironmentObject private var profile: ProfileStore
    @ObservedObject private var identityStore = CoachIdentityStore.shared

    var body: some View {
        Button(action: onOpen) {
            NoopCard(padding: compact ? 12 : NoopMetrics.cardPadding, tint: StrandPalette.accent) {
                HStack(alignment: .top, spacing: compact ? 10 : 12) {
                    CoachEntryAvatar(size: compact ? 40 : 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(String(localized: "Your coach")) \(identityStore.identity.name)".uppercased())
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StrandPalette.statusPositive)
                        Text(greetingLine)
                            .font(compact ? StrandFont.headline : StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(MomentumCopy.stateDetail(day))
                            .font(compact ? StrandFont.footnote : StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Today's recommendation")
                        }
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.statusPositive)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(StrandPalette.statusPositive.opacity(0.14)))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// The greeting hour bucket, and an emoji that matches it — sun through the afternoon, moon after.
    private var greetingLine: String {
        let h = Calendar.current.component(.hour, from: Date())
        let emoji = h < 17 ? "☀️" : "🌙"
        let greeting = h < 12 ? String(localized: "Good morning")
            : h < 17 ? String(localized: "Good afternoon")
            : String(localized: "Good evening")
        guard let name = profile.displayName else { return "\(greeting) \(emoji)" }
        return "\(greeting), \(name). \(emoji)"
    }
}
