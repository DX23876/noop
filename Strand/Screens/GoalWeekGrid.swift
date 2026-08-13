import SwiftUI
import StrandDesign

/// The six evaluated goal weeks plus the running one, as a row of state chips.
///
/// `GoalTrackingEngine` has always computed `recentWeeks` — six weeks of successful / unsuccessful /
/// protected / neutral / pending — and nothing rendered them. This is that row: the fastest read of
/// whether a goal is actually being served, which is why it sits at the top of a goal card.
///
/// Not built on `PipBar`: that is a value bar (one magnitude spread across segments), while this is a
/// sequence of DISCRETE states, each with its own meaning and colour. Kept in the app target rather
/// than `StrandDesign` until a third caller appears — today it is the goal card and the journey sheet.
///
/// The running week is separated by a small gap and drawn hollow: `pending` is not a verdict, and a
/// week still in progress must not read as a failed one.
struct GoalWeekGrid: View {

    let weeks: [GoalTrackingSnapshot.GoalWeek]
    let currentWeek: GoalTrackingSnapshot.GoalWeek

    private static let chipWidth: CGFloat = 22
    private static let chipHeight: CGFloat = 8

    var body: some View {
        HStack(spacing: 4) {
            ForEach(weeks) { week in
                chip(for: week.state, isCurrent: false)
                    .accessibilityLabel(Self.label(for: week.state))
            }
            if !weeks.isEmpty {
                Spacer().frame(width: 4)
            }
            chip(for: currentWeek.state, isCurrent: true)
                .accessibilityLabel(Text("This week: ") + Text(Self.label(for: currentWeek.state)))
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func chip(for state: GoalTrackingSnapshot.WeekState, isCurrent: Bool) -> some View {
        let shape = Capsule(style: .continuous)
        let tint = Self.tint(for: state)
        if isCurrent {
            // Hollow: in progress, not yet judged.
            shape.strokeBorder(tint, lineWidth: 1.5)
                .frame(width: Self.chipWidth, height: Self.chipHeight)
        } else {
            shape.fill(tint)
                .frame(width: Self.chipWidth, height: Self.chipHeight)
        }
    }

    /// Design-system tokens only — no ad-hoc colours. `protected` (ill / injured / travelling, or a
    /// paused stretch) deliberately reads as neutral-accent rather than a failure: the week was
    /// excused, and colouring it like a miss would punish exactly the weeks the engine set out to
    /// protect.
    static func tint(for state: GoalTrackingSnapshot.WeekState) -> Color {
        switch state {
        case .successful:   return StrandPalette.statusPositive
        case .unsuccessful: return StrandPalette.statusWarning
        case .protected:    return StrandPalette.accent.opacity(0.45)
        case .neutral:      return StrandPalette.hairline
        case .pending:      return StrandPalette.textTertiary
        }
    }

    static func label(for state: GoalTrackingSnapshot.WeekState) -> LocalizedStringKey {
        switch state {
        case .successful:   return "week met"
        case .unsuccessful: return "week missed"
        case .protected:    return "week protected"
        case .neutral:      return "nothing planned"
        case .pending:      return "week in progress"
        }
    }
}
