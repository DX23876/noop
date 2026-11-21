#if os(iOS)
import SwiftUI

/// The coach in a main page's header (owner, 2026-11-21), left of the search. It replaces the coach tab: an
/// iPhone's tab bar holds five, and Nutrition took the fifth place. Shown only while the coach is on (the tab
/// shell sets `forgeOpenCoach` then). A tap tells the coach the page and its day and opens the same chat, with
/// the page's suggestions as chips; a dot marks a message the coach wrote on its own.
struct ForgeCoachButton: View {
    let page: CoachEntryPage.Kind
    /// The day the page shows, `yyyy-MM-dd`.
    var day: String?
    @Environment(\.forgeOpenCoach) private var openCoach

    var body: some View {
        if let openCoach {
            Button(action: { openCoach(CoachEntryPage(kind: page, day: day, suggestions: Self.suggestions(for: page))) }) {
                Image(systemName: "sparkles")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(ForgeColor.text)
                    .frame(width: 36, height: 36)
                    .forgeGlassCapsule()
                    .overlay(alignment: .topTrailing) { ForgeCoachUnseenDot() }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Coach"))
            .accessibilityHint(Text("Opens the coach for this page"))
        }
    }

    /// Two questions per page, about what it shows.
    static func suggestions(for page: CoachEntryPage.Kind) -> [String] {
        switch page {
        case .today:
            return [String(localized: "How is my day looking?"), String(localized: "Should I train hard today?")]
        case .training:
            return [String(localized: "How was my training load this week?"), String(localized: "What should I train next?")]
        case .nutrition:
            return [String(localized: "What am I still missing today?"), String(localized: "How was my nutrition this week?")]
        case .sleep:
            return [String(localized: "Why was my night like this?"), String(localized: "When should I go to bed tonight?")]
        case .health:
            return [String(localized: "Is anything unusual?"), String(localized: "How are my values developing?")]
        }
    }
}
#endif
