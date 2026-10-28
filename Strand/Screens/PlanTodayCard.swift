import SwiftUI
import StrandDesign

/// The single next committed session, made visible where you'll actually look each morning instead of
/// living only inside the coach. A tap opens the plan book. Silent (`EmptyView`) when there's nothing
/// to show — this augments the plan book, it doesn't duplicate it.
///
/// It sits LOW on Today (below the metric sections) on purpose: the undecided suggestion
/// (`MorningSuggestionCard`) owns the top, where a decision is needed; once accepted, the committed
/// session is an ambient reminder, not a demand — so it lives out of the way until its time draws near,
/// when it colours and pulses to reclaim attention (`emphasis`).
struct PlanTodayCard: View {
    /// #268: Effort is STORED on the canonical 0–100 axis; this is the wearer's chosen display axis, so a
    /// planned session's target reads on the same scale as every Effort ring in the app. `@AppStorage`
    /// rather than `UnitPrefs.currentEffortScale()` so flipping the setting redraws this card.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }


    @ObservedObject private var store = CoachPlanStore.shared
    @Binding var showPlan: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared
    /// Drives the ambient breathe when the session is approaching or due. Left false under Reduce Motion.
    @State private var pulsing = false

    private var today: String { Repository.localDayKey(Date()) }

    static let approachLead = PlanTodaySelection.approachLead
    static let graceAfter = PlanTodaySelection.graceAfter
    static let untimedMomentumReminderHour = PlanTodaySelection.untimedMomentumReminderHour
    typealias Emphasis = PlanTodaySelection.Emphasis

    /// The rules live in `PlanTodaySelection`, shared with the Android core.
    static func emphasis(for proposal: PlanProposal, now: Date) -> Emphasis {
        PlanTodaySelection.emphasis(for: proposal, now: now)
    }

    static func shouldFlagInMomentum(_ proposal: PlanProposal, now: Date, calendar: Calendar = .current) -> Bool {
        PlanTodaySelection.shouldFlagInMomentum(proposal, now: now, calendar: calendar)
    }

    static func next(from proposals: [PlanProposal], today: String, now: Date) -> PlanProposal? {
        PlanTodaySelection.next(from: proposals, today: today, now: now)
    }

    private var next: PlanProposal? {
        Self.next(from: store.proposals, today: today, now: Date())
    }

    private var unresolved: (PlanReconciliationResolution, PlanProposal)? {
        guard let resolution = store.reconciliationResolutions.first,
              let proposal = store.proposals.first(where: { $0.id == resolution.proposalId })
        else { return nil }
        return (resolution, proposal)
    }

    // The goal-attention branch that used to sit here is gone. It existed because Today's goal tile
    // showed no state at all, so an at-risk goal had to be announced somewhere else — and it did that
    // in an `else if`, REPLACING the next committed session, so a goal needing a decision made your
    // next planned workout disappear. The tile now carries the state itself (a `StatePill` on the
    // hero, a toned dot per row), and this card is about the plan again.

    var body: some View {
        if let (resolution, proposal) = unresolved {
            Button { showPlan = true } label: {
                NoopCard(padding: 14, tint: StrandPalette.statusWarning, kind: .state) {
                    HStack(spacing: 10) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(StrandPalette.statusWarningForeground)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Plan needs your check")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text(resolution.kind == .candidates
                                 ? String(localized: "Possible workout found for \(proposal.sport)")
                                 : String(localized: "\(proposal.sport) is still open"))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .lineLimit(1)
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
            .accessibilityLabel("Plan needs your check. Opens your plan.")
        } else if let p = next {
            let emphasis = Self.emphasis(for: p, now: Date())
            Button { showPlan = true } label: {
                NoopCard(padding: 14, tint: tint(for: emphasis)) {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar")
                            .foregroundStyle(emphasis == .none ? StrandPalette.accent : accent(for: emphasis))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Next up: \(p.summary(effortScale: effortScale))")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                            // A committed session with no time is a real commitment the user just hasn't
                            // scheduled — say so and let the tap route them to PlanTimeSheet, rather than
                            // showing a bare "Today" that reads as if it's already set.
                            Text(subtitle(for: p, emphasis: emphasis))
                                .font(StrandFont.footnote)
                                .foregroundStyle(emphasis == .none ? StrandPalette.textTertiary : accent(for: emphasis))
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    // Ambient breathe while approaching/due. The RESTING frame is full scale/opacity, so a
                    // non-emphasised card looks completely normal; only an active one pulses gently down
                    // and loops. Scoped to the content so it never re-animates a neighbouring card, and
                    // suppressed under Reduce Motion (pulsing stays false), leaving just the colour change.
                    .scaleEffect(pulsing ? 0.985 : 1.0)
                    .opacity(pulsing ? 0.9 : 1.0)
        .animation(StrandMotion.breathe(reduced: motion.poseStill(reduceMotion)), value: pulsing)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel(for: p, emphasis: emphasis))
            .onAppear { pulsing = (emphasis != .none) && !reduceMotion }
            .onChangeCompat(of: emphasis) { newEmphasis in pulsing = (newEmphasis != .none) && !reduceMotion }
        }
    }

    /// The card wash: neutral until the session nears, then accent (approaching) → warning (due).
    private func tint(for emphasis: Emphasis) -> Color {
        switch emphasis {
        case .none:        return StrandPalette.chargeColor
        case .approaching: return StrandPalette.accent
        case .due:         return StrandPalette.statusWarning
        }
    }

    private func accent(for emphasis: Emphasis) -> Color {
        emphasis == .due ? StrandPalette.statusWarning : StrandPalette.accent
    }

    private func subtitle(for p: PlanProposal, emphasis: Emphasis) -> String {
        switch emphasis {
        case .due:         return String(localized: "Due now")
        case .approaching: return String(localized: "Starting soon")
        case .none:
            return p.time == nil ? String(localized: "Today · no time set") : dayLabel(p.day)
        }
    }

    private func accessibilityLabel(for p: PlanProposal, emphasis: Emphasis) -> Text {
        let state: String
        switch emphasis {
        case .due:         state = String(localized: "due now")
        case .approaching: state = String(localized: "starting soon")
        case .none:        state = dayLabel(p.day)
        }
        return Text("Next planned session: \(p.summary(effortScale: effortScale)), \(state). Opens your plan.")
    }

    private func dayLabel(_ day: String) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        guard let date = df.date(from: day) else { return day }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        return day
    }
}
