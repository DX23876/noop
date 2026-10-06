import SwiftUI
import StrandDesign
import StrandAnalytics

/// A weekly or monthly goal drawn small by how it adds up, matching its card on the goals page: a count
/// or a sum as a track with the pace mark, days of a week as day dots, an average as columns.
struct PeriodShapeGlyph: View {
    let snapshot: PeriodGoalSnapshot

    var body: some View {
        let goal = snapshot.goal
        let r = snapshot.result
        let pace = snapshot.state == .achieved ? nil : r.paceFraction
        Group {
            switch goal.metric.aggregation {
            case .count, .sum:
                PaceTrack(fraction: r.fraction, paceFraction: pace, tint: snapshot.trackTint, height: 6,
                          segments: goal.metric.aggregation == .count ? snapshot.trackSegments : nil)
            case .hitDays:
                if goal.period == .week {
                    HStack(spacing: 0) {
                        DayDotStrip(days: snapshot.dayDots(diameter: 12), tint: snapshot.trackTint, diameter: 12)
                        Spacer(minLength: 0)
                    }
                } else {
                    PaceTrack(fraction: r.fraction, paceFraction: pace, tint: snapshot.trackTint, height: 6)
                }
            case .average:
                TargetColumns(values: snapshot.dayValues.enumerated().map { $0.offset <= snapshot.todayIndex ? $0.element : nil },
                              target: r.target, tint: snapshot.trackTint, height: GoalShapeGlyph.height + 6)
            }
        }
        .frame(minHeight: GoalShapeGlyph.height)
        .accessibilityHidden(true)
    }
}
