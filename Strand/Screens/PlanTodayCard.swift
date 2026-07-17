import SwiftUI
import StrandDesign

/// "A plan with a time is a plan you keep" — made visible where you'll actually look each morning,
/// instead of living only inside the coach. Shows just the SINGLE next committed, timed session; a tap
/// opens the plan book. Silent (`EmptyView`) when there's nothing timed to show — this augments the
/// plan book, it doesn't duplicate it.
struct PlanTodayCard: View {
    @ObservedObject private var store = CoachPlanStore.shared
    @Binding var showPlan: Bool

    private var today: String { Repository.localDayKey(Date()) }

    /// The soonest committed session with a time still ahead, within the next two days. Anything
    /// further out is the plan book's job to show, not Today's.
    private var next: PlanProposal? {
        let horizon = Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date()
        return store.commitments(fromDay: today)
            .filter { p in
                guard let t = p.time else { return false }
                return t > Date() && t < horizon
            }
            .min { ($0.time ?? .distantFuture) < ($1.time ?? .distantFuture) }
    }

    var body: some View {
        if let p = next {
            Button { showPlan = true } label: {
                NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Next up: \(p.summary())")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                            Text(dayLabel(p.day))
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next planned session: \(p.summary()), \(dayLabel(p.day)). Opens your plan.")
        }
    }

    private func dayLabel(_ day: String) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        guard let date = df.date(from: day) else { return day }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        return day
    }
}
