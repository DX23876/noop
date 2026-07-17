import SwiftUI
import StrandDesign

/// The single next committed session, made visible where you'll actually look each morning instead of
/// living only inside the coach. A tap opens the plan book. Silent (`EmptyView`) when there's nothing
/// to show — this augments the plan book, it doesn't duplicate it.
struct PlanTodayCard: View {
    @ObservedObject private var store = CoachPlanStore.shared
    @Binding var showPlan: Bool

    private var today: String { Repository.localDayKey(Date()) }

    /// The soonest committed session worth showing. Pure + static so the selection rule is testable
    /// without a `View`.
    ///
    /// A timed session shows when its time is still ahead, within the next two days. An UNTIMED
    /// commitment shows too, but only for TODAY: accepting a proposal from the morning card or the plan
    /// book records no time (accept is a yes, not a scheduling act), and excluding untimed sessions made
    /// Accept look like it did nothing — the session vanished from Today until the user separately
    /// opened PlanTimeSheet to give it a time. An untimed session two days out isn't "next up", so it
    /// stays out.
    static func next(from proposals: [PlanProposal], today: String, now: Date) -> PlanProposal? {
        let horizon = Calendar.current.date(byAdding: .day, value: 2, to: now) ?? now
        return proposals
            .filter { $0.status.isCommitment && $0.day >= today }
            .filter { p in
                if let t = p.time { return t > now && t < horizon }
                return p.day == today
            }
            .min { ($0.time ?? .distantFuture) < ($1.time ?? .distantFuture) }
    }

    private var next: PlanProposal? {
        Self.next(from: store.proposals, today: today, now: Date())
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
                            // A committed session with no time is a real commitment the user just hasn't
                            // scheduled — say so and let the tap route them to PlanTimeSheet, rather than
                            // showing a bare "Today" that reads as if it's already set.
                            if p.time == nil {
                                Text("Today · no time set")
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            } else {
                                Text(dayLabel(p.day))
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            }
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
