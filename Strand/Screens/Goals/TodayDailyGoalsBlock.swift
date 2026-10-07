import SwiftUI
import StrandDesign
import StrandAnalytics

/// Today's daily goals on the goals card: "TODAY · 1 of 3 done ›" opening the goals page, then every
/// daily goal as a chip. A goal ticked by hand toggles on its chip.
struct TodayDailyGoalsBlock: View {
    let occurrences: [GoalActionOccurrence]
    let onToggleManual: (GoalActionOccurrence) -> Void

    var body: some View {
        let done = occurrences.filter(\.isCompleted).count
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            NavigationLink(value: TabRoute.goals) {
                HStack(spacing: NoopMetrics.space2) {
                    Text("Today").strandOverline()
                    Text(String(localized: "\(done) of \(occurrences.count) done"))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: NoopMetrics.space1)
                    Image(systemName: "chevron.right").font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary).accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            DailyGoalChips(occurrences: occurrences, onToggleManual: onToggleManual)
        }
    }
}
