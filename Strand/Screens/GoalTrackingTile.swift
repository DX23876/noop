import SwiftUI
import StrandDesign

/// The goal read on Today: the goal that most needs looking at, drawn large, with the rest as compact
/// rows beneath it.
///
/// Replaces two earlier attempts. First a text block that showed one goal as a title, a grey status
/// word and a bare `ProgressView`. Then three equal ring columns — which fit three goals across an
/// iPhone only by stacking six elements into ~110pt of width, said the same thing twice (the ring AND
/// a "45 %" line under it) and, crucially, never showed the goal's STATE at all. That omission is why
/// a separate "Goal needs a decision" card had to exist elsewhere on Today.
///
/// So: one hero with the state on it, and one row per remaining goal. A row costs ~28pt, so every
/// active goal fits (the ceiling is `CoachGoalStore.maxActiveGoals`) instead of three plus a silent
/// remainder. Each element is its own button onto its own goal — you tap what you are looking at.
///
/// Deliberately not in the mockup's image: no streak flame, no trophy, no "you're on fire" banner.
/// The streak stays a plain number because the engine computes it anyway; the rest is the
/// gamification `JourneyMilestones` rules out in as many words.
struct GoalTrackingTile: View {
    /// Active goals, most-in-need-of-attention first. The first is the hero.
    let snapshots: [GoalTrackingSnapshot]
    /// The current week's action occurrences, for the day strip under a consistency goal.
    let weekActions: [GoalActionOccurrence]
    var onOpenGoal: (UUID) -> Void

    @AppStorage(AppleInspiredColorsPrefs.enabledKey)
    private var appleHealthColors = AppleInspiredColorsPrefs.defaultEnabled

    private static let ringDiameter: CGFloat = 64
    private static let ringWidth: CGFloat = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let hero = snapshots.first {
                Button { onOpenGoal(hero.id) } label: { heroBlock(hero) }
                    .buttonStyle(.plain)
            }
            if snapshots.count > 1 {
                Divider().overlay(StrandPalette.hairline)
                VStack(spacing: 8) {
                    ForEach(snapshots.dropFirst()) { snapshot in
                        Button { onOpenGoal(snapshot.id) } label: { row(snapshot) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Hero

    private func heroBlock(_ snapshot: GoalTrackingSnapshot) -> some View {
        let tint = colorFor(snapshot.goal.kind)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ring(snapshot, tint: tint)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: snapshot.goal.kind.icon)
                            .font(StrandFont.footnote).foregroundStyle(tint)
                            .accessibilityHidden(true)
                        Text(snapshot.displayTitle)
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    // The state, as a word in a toned pill — never colour alone. This is what the tile
                    // was missing, and what a second card on Today had to say instead.
                    StatePill(LocalizedStringKey(snapshot.health.label), tone: snapshot.health.tone)
                    Text(snapshot.headlineLine)
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            strip(for: snapshot, tint: tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(snapshot.displayTitle). \(snapshot.health.label). \(snapshot.headlineLine)"))
    }

    /// The scored ring, or the held one. A goal NOOP measures but does not score gets the ring's track
    /// with no arc on it: a 0-length arc and "no arc" look identical, but only one of them is a claim
    /// about progress. `GlowRing.centerFont` is exported for exactly this state.
    @ViewBuilder
    private func ring(_ snapshot: GoalTrackingSnapshot, tint: Color) -> some View {
        if let fraction = snapshot.progressFraction {
            GlowRing(fraction: fraction,
                     value: snapshot.measurement?.value ?? 0,
                     format: { Self.number($0) },
                     color: tint,
                     diameter: Self.ringDiameter,
                     lineWidth: Self.ringWidth)
        } else {
            ZStack {
                Circle()
                    .stroke(StrandPalette.textPrimary.opacity(0.10),
                            style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
                Text(snapshot.measurement.map { Self.number($0.value) } ?? "—")
                    .font(GlowRing.centerFont(diameter: Self.ringDiameter))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .padding(.horizontal, Self.ringWidth + 4)
            }
            .frame(width: Self.ringDiameter, height: Self.ringDiameter)
        }
    }

    // MARK: - The other goals

    /// One goal in a line: what it is, how far along, and how it's doing. The `PipBar` is the house
    /// bar for a 0…max value; a goal that isn't scored shows the honest words instead of an empty one.
    private func row(_ snapshot: GoalTrackingSnapshot) -> some View {
        let tint = colorFor(snapshot.goal.kind)
        return HStack(spacing: 9) {
            Image(systemName: snapshot.goal.kind.icon)
                .font(StrandFont.footnote).foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.displayTitle)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                if let fraction = snapshot.progressFraction {
                    PipBar(value: fraction * 100, segments: 14, tint: tint, height: 6)
                } else if let reason = snapshot.unscoredReason {
                    Text(reason)
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer(minLength: 8)
            if let fraction = snapshot.progressFraction {
                Text("\(Int((fraction * 100).rounded())) %")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
            } else if let value = snapshot.measurement?.value {
                Text("\(Self.number(value)) \(snapshot.goal.kind.unit)")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
            }
            ConnectionDot(tone: snapshot.health.tone, size: 7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(snapshot.displayTitle). \(snapshot.health.label)."))
    }

    // MARK: - Strips

    /// The strips a goal actually HAS, each gated on its own — not one chosen over the other. A goal
    /// with neither shows nothing, rather than an empty graphic that implies data.
    ///
    /// These were mutually exclusive, with the route winning. That silently cost every consistency
    /// goal its day strip: `.consistency` is `isQuantified`, so a baseline/target/date goal always has
    /// a route, so the `else` was unreachable for exactly the kind whose week is the interesting part.
    /// (`.strength` isn't quantified, never gets a route, and so happened to work.) The two answer
    /// different questions — the route is the whole arc, the days are this week — and a consistency
    /// goal is the one kind that wants both.
    @ViewBuilder
    private func strip(for snapshot: GoalTrackingSnapshot, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            if !snapshot.goal.milestones.isEmpty {
                waypointStrip(snapshot, tint: tint)
            }
            if snapshot.goal.kind == .consistency || snapshot.goal.kind == .strength {
                dayStrip(snapshot, tint: tint)
            }
        }
    }

    /// The route, in miniature: one segment per waypoint, filled once passed. Same data the journey
    /// sheet lists in full — full width now that it isn't crammed under a column.
    private func waypointStrip(_ snapshot: GoalTrackingSnapshot, tint: Color) -> some View {
        HStack(spacing: 4) {
            ForEach(snapshot.goal.milestones) { milestone in
                Capsule()
                    .fill(milestone.achievedAt != nil ? tint : StrandPalette.hairline)
                    .frame(height: 5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(snapshot.goal.milestones.filter { $0.achievedAt != nil }.count) of \(snapshot.goal.milestones.count) waypoints reached"))
    }

    /// This week, one chip per day, filled where an action was completed. Days ahead stay hollow —
    /// an unfinished Friday is not a missed one.
    private func dayStrip(_ snapshot: GoalTrackingSnapshot, tint: Color) -> some View {
        let calendar = Calendar.autoupdatingCurrent
        let today = GoalActionEvaluator.dayKey(Date(), calendar: calendar)
        let days = Self.weekDayKeys(calendar: calendar)
        let completed = Set(weekActions.filter { $0.isCompleted && $0.action.goalIds.contains(snapshot.id) }
            .map(\.day))
        return HStack(spacing: 4) {
            ForEach(days, id: \.self) { day in
                Capsule()
                    .fill(completed.contains(day) ? tint
                          : (day <= today ? StrandPalette.hairline : StrandPalette.hairline.opacity(0.5)))
                    .frame(height: 5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(completed.count) days completed this week"))
    }

    static func weekDayKeys(calendar: Calendar, now: Date = Date()) -> [String] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }
        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: week.start)
                .map { GoalActionEvaluator.dayKey($0, calendar: calendar) }
        }
    }

    /// Whole numbers stay whole; a decimal goal keeps one place. Avoids "8.0 kg" next to "8,200".
    static func number(_ value: Double) -> String {
        value == value.rounded()
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    private func colorFor(_ kind: CoachGoal.Kind) -> Color {
        appleHealthColors
            ? CoachIconColors.color(for: "coach.goal.\(kind.rawValue)")
            : StrandPalette.accent
    }
}
