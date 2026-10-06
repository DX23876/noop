import SwiftUI
import StrandDesign
import StrandAnalytics

/// A long-term goal drawn small in its own shape, for the rows on Today and the goals page.
///
/// A ring only says "x % of a sum", which fits none of the goals but one. So each shape gets the line
/// that matches what it measures:
/// - a sum (kilometres, hours): a filled track with a mark where the plan says it should be by now;
/// - a target value (body weight, waist): the way from the start to the target, with its waypoints and
///   where the latest measurement stands;
/// - a best value (longest run): the best so far against the target distance;
/// - consistency: the last finished weeks as dots, missed ones grey, never red;
/// - an average (sleep, pace): the recent days as columns against the target line;
/// - holding a value: the band, and where the latest reading sits in it.
struct GoalShapeGlyph: View {
    let reading: GoalShapeReading
    let tint: Color

    static let height: CGFloat = 14

    /// A consistency goal before its first finished week has nothing to draw yet.
    private var isEmpty: Bool {
        if case .consistency(let d) = reading { return d.lastWeeks.isEmpty }
        return false
    }

    var body: some View {
        if !isEmpty {
            Group {
                switch reading {
                case .sum(let d):
                    let r = d.reading
                    PaceTrack(fraction: min(1, max(0, r.fraction)),
                              paceFraction: r.target > 0 ? min(1, max(0, r.plannedByNow / r.target)) : nil,
                              tint: tint, height: 6)
                case .target(let d):
                    GoalShapeTargetWay(progress: d.progress,
                                       marks: Self.marks(d.milestones, from: d.baseline, to: d.target), tint: tint)
                case .best(let d):
                    PaceTrack(fraction: min(1, max(0, d.reading.fraction ?? 0)), tint: tint, height: 6,
                              isEmpty: d.reading.best == nil)
                case .consistency(let d):
                    GoalShapeWeekDots(weeks: d.lastWeeks, tint: tint)
                case .average(let d):
                    TargetColumns(values: Array(d.days.suffix(14)), target: d.target, tint: tint,
                                  height: Self.height + 6, higherIsBetter: d.higherIsBetter)
                case .maintain(let d):
                    GoalShapeBandPosition(latest: d.reading.latest, center: d.center, band: d.band, tint: tint)
                }
            }
            .frame(minHeight: Self.height)
            .accessibilityHidden(true)
        }
    }

    /// Waypoints between the start and the target, as 0…1 positions along the way.
    static func marks(_ window: LongTermGoalMath.MilestoneWindow?, from start: Double, to end: Double) -> [Double] {
        guard let window, abs(end - start) > 1e-9 else { return [] }
        return window.values
            .map { ($0 - start) / (end - start) }
            .filter { $0 > 0.001 && $0 < 0.999 }
    }
}
