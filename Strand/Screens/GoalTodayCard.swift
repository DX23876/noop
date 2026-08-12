import SwiftUI
import StrandDesign

/// The active goal, on the screen you actually open in the morning.
///
/// Until now a goal lived only behind Coach → Goal & Journey, which meant the one thing the user said
/// they were working towards was the one thing Today never mentioned. This is the ambient version of
/// that page: the mark, the name, where they stand, how much runway is left — and a tap straight
/// through to the full journey.
///
/// Two rules shape it more than any layout decision:
///
/// * **No invented percentages.** The ring fills ONLY from a real `GoalProgress` reading. A goal NOOP
///   can hold but not measure (strength, stress, recovery, custom) gets its mark in a medallion and an
///   honest line about time, never a bar built on nothing.
/// * **No empty tiles.** With no active goal this renders nothing at all — except the one case where
///   silence would be wrong: the guided setup has never been offered, so a single invitation row takes
///   its place. Once the offer has been made and declined, the card stays quiet for good.
///
/// Its own leaf (like `PlanTodayCard`) so observing the goal store and loading evidence never re-renders
/// the whole Today body.
struct GoalTodayCard: View {
    @EnvironmentObject private var coach: AICoachEngine
    @EnvironmentObject private var router: NavRouter
    @ObservedObject private var goalStore = CoachGoalStore.shared

    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    @AppStorage(CoachEntryPrefs.uiEnabledKey) private var coachUIEnabled = true
    @AppStorage(AppleInspiredColorsPrefs.enabledKey) private var appleHealthColors = AppleInspiredColorsPrefs.defaultEnabled
    /// Set once the guided setup has been offered — saved or skipped. Read (not written) here, so the
    /// invitation disappears the moment the offer has been made anywhere else.
    @AppStorage(CoachView.goalOnboardingAskedKey) private var goalOnboardingAsked = false

    /// What the app can measure about the starting point. Empty until loaded, and an empty value simply
    /// means no ring — never a placeholder number.
    @State private var evidence = GoalFeasibility.Evidence()
    @State private var latestWeightKg: Double?
    @State private var loaded = false

    /// The goal this card is about. The rule lives on the store (`primaryActiveGoal`) so this card and
    /// the iOS goal widget lead with the same goal rather than each picking its own.
    private var primaryGoal: CoachGoal? { goalStore.primaryActiveGoal }

    private var otherGoals: [CoachGoal] {
        guard let primary = primaryGoal else { return [] }
        return goalStore.activeGoals.filter { $0.id != primary.id }
    }

    var body: some View {
        if coachFeatureEnabled, coachUIEnabled {
            if let goal = primaryGoal {
                goalCard(goal)
                    .task {
                        guard !loaded else { return }
                        loaded = true
                        evidence = await coach.goalEvidence()
                        latestWeightKg = await coach.latestLoggedWeightKg()
                    }
            } else if !goalOnboardingAsked {
                inviteRow
            }
        }
    }

    // MARK: - The card

    private func goalCard(_ goal: CoachGoal) -> some View {
        let reading = GoalProgress.reading(goal: goal, evidence: evidence, latestWeightKg: latestWeightKg)
        let overdue = (ProactiveCoach.daysPastTarget(goal) ?? 0) >= 1
        let goalTint = tint(for: goal)
        return Button { router.openGoalJourney() } label: {
            NoopCard(padding: 14, tint: overdue ? StrandPalette.statusWarning : goalTint) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        mark(for: goal, reading: reading, tint: goalTint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(goal.title.isEmpty ? goal.kind.label.localizedCatalogValue : goal.title)
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(2).multilineTextAlignment(.leading)
                            Text(subtitle(goal, reading: reading, overdue: overdue))
                                .font(StrandFont.footnote)
                                .foregroundStyle(overdue ? StrandPalette.statusWarning
                                                         : StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    if !otherGoals.isEmpty { otherGoalsRow }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverLabel(goal, reading: reading, overdue: overdue))
        .accessibilityHint("Opens Goal and Journey.")
    }

    /// The ring when there's a real measurement behind it, the goal's mark when there isn't. Both are
    /// the same size, so a measurable and an unmeasurable goal sit on the same grid.
    @ViewBuilder
    private func mark(for goal: CoachGoal, reading: GoalProgress.Reading, tint: Color) -> some View {
        if let fraction = reading.fraction {
            GlowRing(fraction: fraction,
                     value: fraction * 100,
                     format: { String(format: "%.0f%%", $0) },
                     color: tint,
                     diameter: 56, lineWidth: 6)
                .accessibilityHidden(true)
        } else {
            Image(systemName: goal.kind.icon)
                .font(.system(size: 22))
                .foregroundStyle(tint)
                .frame(width: 56, height: 56)
                .background(Circle().fill(tint.opacity(0.12)))
                .overlay(Circle().strokeBorder(tint.opacity(0.28), lineWidth: 1))
                .accessibilityHidden(true)
        }
    }

    /// The other active goals as their marks only — a reminder that they exist, not a second card. The
    /// ceiling is `CoachGoalStore.maxActiveGoals`, so this row can never grow unbounded.
    private var otherGoalsRow: some View {
        HStack(spacing: 8) {
            ForEach(otherGoals) { g in
                Image(systemName: g.kind.icon)
                    .font(StrandFont.caption)
                    .foregroundStyle(tint(for: g))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(tint(for: g).opacity(0.10)))
            }
            Text("Also active").strandOverline()
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    // MARK: - The invitation (the only thing shown without a goal)

    private var inviteRow: some View {
        Button { router.openGoalJourney() } label: {
            NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                HStack(spacing: 12) {
                    Image(systemName: "target")
                        .font(.system(size: 20))
                        .foregroundStyle(appleHealthColors
                                         ? CoachIconColors.color(for: "coach.goalJourney.newGoal")
                                         : StrandPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Set a goal")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text("A short, guided setup.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Set a goal")
    }

    // MARK: - Text

    /// One honest line: the measured reading when there is one, otherwise time. Never both, and never a
    /// number that isn't real.
    private func subtitle(_ goal: CoachGoal, reading: GoalProgress.Reading, overdue: Bool) -> String {
        if overdue { return String(localized: "Your target date has passed") }
        if let line = reading.line { return line }
        guard let weeks = reading.runwayWeeks else { return String(localized: "No target date set") }
        return String(localized: "\(Int(weeks.rounded())) weeks to go")
    }

    private func voiceOverLabel(_ goal: CoachGoal, reading: GoalProgress.Reading,
                                overdue: Bool) -> Text {
        let name = goal.title.isEmpty ? goal.kind.label.localizedCatalogValue : goal.title
        return Text("Goal: \(name). \(subtitle(goal, reading: reading, overdue: overdue))")
    }

    /// The goal kind's identity colour, honouring the same "Apple-inspired colors" switch the rest of
    /// Coach reads.
    private func tint(for goal: CoachGoal) -> Color {
        appleHealthColors ? CoachIconColors.color(for: "coach.goal.\(goal.kind.rawValue)")
                          : StrandPalette.accent
    }
}
