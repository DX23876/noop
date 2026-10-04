import SwiftUI
import StrandDesign
import StrandAnalytics

/// A weekly or monthly goal as one compact row — Today's goals section, the overview's sections.
///
///     [icon] Workouts                       ● On track
///     [██████████░░░░│░░░░░░░░░░░░░░░░░░]
///     2 to go · 4 days left                         2/4
///
/// Name, state word and the pace track carry the whole reading; the line under it names what is left,
/// numbers first.
struct PeriodGoalRow: View {
    let snapshot: PeriodGoalSnapshot
    var trackHeight: CGFloat = 6

    @AppStorage(AppleInspiredColorsPrefs.enabledKey)
    private var appleColors = AppleInspiredColorsPrefs.defaultEnabled

    var body: some View {
        let style = snapshot.style
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { name; Spacer(minLength: 6); stateLabel(style) }
                VStack(alignment: .leading, spacing: 2) { name; stateLabel(style) }
            }
            PaceTrack(fraction: snapshot.result.fraction,
                      paceFraction: snapshot.state == .achieved ? nil : snapshot.result.paceFraction,
                      tint: snapshot.trackTint, height: trackHeight, segments: snapshot.trackSegments,
                      isEmpty: snapshot.state == .noData,
                      animationKey: "period-\(snapshot.id)-\(snapshot.periodStart)")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(GoalFormat.remainingLine(snapshot))
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Text(GoalFormat.progress(snapshot))
                    .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(GoalFormat.accessibility(snapshot)))
        .accessibilityAddTraits(.isButton)
    }

    private var name: some View {
        HStack(spacing: 6) {
            Image(systemName: snapshot.goal.metric.icon)
                .font(StrandFont.footnote)
                .foregroundStyle(goalIdentityColor(snapshot.goal.metric, appleColors: appleColors))
                .accessibilityHidden(true)
            Text(GoalFormat.shortName(snapshot.goal))
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
        }
    }

    private func stateLabel(_ style: GoalStatusStyle) -> some View {
        HStack(spacing: 4) {
            Image(systemName: style.symbol)
                .font(.system(size: style.symbol == "circle.fill" ? 6 : 10, weight: .semibold))
                .accessibilityHidden(true)
            Text(style.word)
        }
        .font(StrandFont.footnote)
        .foregroundStyle(style.foreground)
    }
}

/// A long-term goal in the same row shape: the route from start to target is the track, the plan's
/// position today is the mark.
struct LongTermGoalRow: View {
    let snapshot: GoalTrackingSnapshot

    @AppStorage(AppleInspiredColorsPrefs.enabledKey)
    private var appleColors = AppleInspiredColorsPrefs.defaultEnabled

    var body: some View {
        let style = GoalStatusStyle.of(snapshot.health)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: snapshot.goal.kind.icon)
                    .font(StrandFont.footnote)
                    .foregroundStyle(appleColors ? CoachIconColors.color(for: "coach.goal.\(snapshot.goal.kind.rawValue)")
                                                 : StrandPalette.accent)
                    .accessibilityHidden(true)
                Text(snapshot.displayTitle)
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary).lineLimit(1)
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    Image(systemName: style.symbol).font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(style.word)
                }
                .font(StrandFont.footnote).foregroundStyle(style.foreground)
            }
            if let fraction = snapshot.progressFraction {
                PaceTrack(fraction: fraction, paceFraction: planFraction, tint: style.color, height: 6,
                          animationKey: "long-\(snapshot.id)")
            }
            Text(snapshot.routeLine ?? snapshot.measurementLine ?? snapshot.nextAction)
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(snapshot.displayTitle). \(style.wordText). \(snapshot.routeLine ?? snapshot.nextAction)"))
        .accessibilityAddTraits(.isButton)
    }

    /// Where the plan says the goal should be today, on the start-to-target scale.
    private var planFraction: Double? {
        guard let course = snapshot.course, let baseline = snapshot.goal.baseline,
              let target = snapshot.goal.target, target != baseline else { return nil }
        return min(1, max(0, (course.plannedNow - baseline) / (target - baseline)))
    }
}

/// A weekly or monthly goal as a full card, its middle drawn by how the goal adds up (design §6.3).
struct PeriodGoalCard: View {
    let snapshot: PeriodGoalSnapshot

    @AppStorage(AppleInspiredColorsPrefs.enabledKey)
    private var appleColors = AppleInspiredColorsPrefs.defaultEnabled

    var body: some View {
        let goal = snapshot.goal
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                let identity = goalIdentityColor(goal.metric, appleColors: appleColors)
                Image(systemName: goal.metric.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(identity)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(identity.opacity(0.14)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(GoalFormat.title(goal))
                        .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(periodCaption)
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 6)
                StatePill(snapshot.style.word, tone: snapshot.style.tone)
            }
            middle
            Text(GoalFormat.remainingLine(snapshot))
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(GoalFormat.accessibility(snapshot)))
        .accessibilityAddTraits(.isButton)
    }

    private var periodCaption: String {
        let goal = snapshot.goal
        var parts: [String] = [goal.period == .week ? String(localized: "Week") : String(localized: "Month")]
        if goal.oneOffPeriodStart != nil {
            parts.append(goal.period == .week ? String(localized: "only this week") : String(localized: "only this month"))
        }
        if snapshot.currentStreak > 1 {
            parts.append(goal.period == .week ? String(localized: "\(snapshot.currentStreak) weeks in a row")
                                              : String(localized: "\(snapshot.currentStreak) months in a row"))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var middle: some View {
        let goal = snapshot.goal
        let r = snapshot.result
        switch goal.metric.aggregation {
        case .count:
            VStack(alignment: .leading, spacing: 8) {
                PaceTrack(fraction: r.fraction, paceFraction: snapshot.state == .achieved ? nil : r.paceFraction,
                          tint: snapshot.trackTint, height: 8, segments: snapshot.trackSegments,
                          animationKey: "card-\(snapshot.id)-\(snapshot.periodStart)")
                if goal.period == .week {
                    DayDotStrip(days: snapshot.dayDots(), tint: snapshot.trackTint,
                                suggested: Set(snapshot.suggestedDays))
                }
            }
        case .sum:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(GoalFormat.number(r.current, goal.metric))
                        .font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary).monospacedDigit()
                    Text(String(localized: "of \(GoalFormat.amount(r.target, goal.metric))"))
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
                PaceTrack(fraction: r.fraction, paceFraction: snapshot.state == .achieved ? nil : r.paceFraction,
                          tint: snapshot.trackTint, height: 8,
                          animationKey: "card-\(snapshot.id)-\(snapshot.periodStart)")
            }
        case .hitDays:
            if goal.period == .week {
                HStack(alignment: .center, spacing: 12) {
                    DayDotStrip(days: snapshot.dayDots(diameter: 18), tint: snapshot.trackTint, diameter: 18,
                                suggested: Set(snapshot.suggestedDays))
                    Text(GoalFormat.progress(snapshot))
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary).monospacedDigit()
                }
            } else {
                PaceTrack(fraction: r.fraction, paceFraction: snapshot.state == .achieved ? nil : r.paceFraction,
                          tint: snapshot.trackTint, height: 8,
                          animationKey: "card-\(snapshot.id)-\(snapshot.periodStart)")
            }
        case .average:
            TargetColumns(values: snapshot.dayValues.enumerated().map { $0.offset <= snapshot.todayIndex ? $0.element : nil },
                          target: r.target, tint: snapshot.trackTint, height: goal.period == .week ? 40 : 34)
        }
    }
}
