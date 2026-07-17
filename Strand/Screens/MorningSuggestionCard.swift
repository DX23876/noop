import SwiftUI
import StrandDesign

/// The coach's suggestion for today's session, surfaced on Today each morning for an opt-in user, with
/// Accept / Change / Decline right there. This is the "make it visible AND acceptable" half of the
/// feature; once decided it hands off to `PlanTodayCard` (the answer), so there's one card for the
/// question and one for the answer, never two rows for the same session.
///
/// It carries its own opt-in trigger: on a new logical day, opening (or resuming) Today generates the
/// brief — which, with tools live, records exactly one proposal (W5). The generation itself is entirely
/// `AICoachEngine.startBriefIfNeeded()`, which already owns the once-per-logical-day lock; nothing new
/// happens in the engine.
///
/// Deliberately NO dismiss control: it's opt-in, it self-hides the moment the proposal is decided, and
/// Decline IS the dismiss. That also sidesteps TodayView's dismiss-switch `default: break` trap and
/// LiquidTodayView's lack of a dismiss path entirely.
struct MorningSuggestionCard: View {
    @EnvironmentObject private var coach: AICoachEngine
    @ObservedObject private var store = CoachPlanStore.shared
    @Binding var showPlan: Bool
    @AppStorage("coach.morningSuggestion") private var morningOn = false
    @Environment(\.scenePhase) private var scenePhase

    /// `localDayKey`, NOT `logicalDayKey`: the card looks for a proposal on the *calendar* day, matching
    /// `propose_plan`'s default day. Between 00:00–04:00 the brief's own `logicalDayKey` gate still says
    /// "yesterday", so the card is briefly empty until 04:00 — correct for a *morning* card, and getting
    /// this backwards would silently empty it for four hours every day.
    private var today: String { Repository.localDayKey(Date()) }

    private var state: MorningSuggestionState {
        MorningSuggestionState.resolve(
            morningOn: morningOn, configured: coach.isConfigured, consent: coach.dataConsent,
            toolsActive: coach.toolCallingActive, sending: coach.sending,
            pending: store.pending, today: today)
    }

    var body: some View {
        content
            .task(id: coach.dataConsent) { await maybeGenerate() }
            // Resume (phone in pocket overnight → back on Today next morning) is the day-change signal
            // that matters in practice. Deliberately NOT keyed on the day itself: TodayView.body
            // re-evaluates ~1 Hz while a strap streams, which would re-fire the trigger every tick.
            .onChangeCompat(of: scenePhase) { phase in
                if phase == .active { Task { await maybeGenerate() } }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .generating:
            NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(StrandPalette.accent)
                    Text("Working out today's session…")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 0)
                }
            }
        case .waiting(let p):
            waitingCard(p)
        }
    }

    private func waitingCard(_ p: PlanProposal) -> some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Today's session")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 4)
                }
                Text(p.summary())
                    .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !p.rationale.isEmpty {
                    Text(p.rationale)
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    // Accept records no time (a yes, not a scheduling act) — W4 makes the resulting
                    // untimed commitment stay visible on PlanTodayCard.
                    actionButton(icon: "checkmark", prominent: true) { store.accept(p.id) } label: {
                        Text("Accept")
                    }
                    // Change opens the plan book rather than an inline swap sheet: the swap sheet needs
                    // the whole workout history (coach.planInputs()), too heavy to load on Today for a
                    // rarely-taken branch — and "Change" is the deliberate detour anyway.
                    actionButton(icon: "arrow.triangle.2.circlepath") { showPlan = true } label: {
                        Text("Change")
                    }
                    actionButton(icon: "xmark") { store.decline(p.id) } label: {
                        Text("Not this one")
                    }
                }
            }
        }
    }

    /// A pill action, written with a @ViewBuilder label so its title stays a literal `Text(...)` at the
    /// call site (visible to the i18n scanner), not a `String` routed through a parameter.
    private func actionButton<L: View>(
        icon: String, prominent: Bool = false, run: @escaping () -> Void, @ViewBuilder label: () -> L
    ) -> some View {
        Button(action: run) {
            HStack(spacing: 5) {
                Image(systemName: icon).accessibilityHidden(true)
                label()
            }
            .font(StrandFont.footnote)
            .foregroundStyle(prominent ? .white : StrandPalette.textSecondary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(prominent ? StrandPalette.accent : StrandPalette.surfaceInset,
                        in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func maybeGenerate() async {
        guard morningOn, coach.isConfigured, coach.dataConsent, !coach.sending else { return }
        await coach.startBriefIfNeeded()
    }
}

/// The card's visible state, resolved purely so it can be tested without SwiftUI.
enum MorningSuggestionState: Equatable {
    case hidden
    case generating
    case waiting(PlanProposal)

    /// A waiting proposal for today wins over everything: if one already exists, show it (even mid-send,
    /// since it IS the outcome). Otherwise show the spinner only while a send is actually in flight and
    /// the user has opted in. Everything else — opt-in off, not configured, no consent, a provider that
    /// can't run tools (so no proposal could ever exist), or nothing pending — is hidden.
    static func resolve(
        morningOn: Bool, configured: Bool, consent: Bool, toolsActive: Bool,
        sending: Bool, pending: [PlanProposal], today: String
    ) -> MorningSuggestionState {
        guard morningOn, configured, consent, toolsActive else { return .hidden }
        if let p = pending.first(where: { $0.day == today }) { return .waiting(p) }
        if sending { return .generating }
        return .hidden
    }
}
