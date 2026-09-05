import SwiftUI
import WhoopStore
import StrandDesign

/// The screen between a drafted routine and the user's Hevy account.
///
/// It exists because `PUT /v1/routines/{id}` is a full replace with no partial update: the exercise
/// list in a draft BECOMES the routine, and anything the draft omits is gone. No merging in the writer
/// could change that. So the protection is this screen — the routine as it stands, beside the routine
/// as it would become, and a button that has to be pressed.
///
/// Two things it deliberately does NOT do. It does not let the user edit the sets here: an editor
/// would be a second, worse Hevy, and the honest action on a draft that is nearly right is to say so
/// in the chat and get a better one. And it never sends automatically, on any timer or condition —
/// there is no path to `HevyRoutineWriter` that does not pass through this button.
struct HevyRoutineReviewView: View {
    let proposalId: UUID
    var onFinish: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var proposals = HevyRoutineProposalStore.shared

    @State private var sending = false
    @State private var errorMessage: String?
    @State private var sentTitle: String?

    private var proposal: HevyRoutineProposal? { proposals.proposal(id: proposalId) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    if let proposal {
                        header(proposal)
                        if !proposal.warnings.isEmpty { warnings(proposal) }
                        if proposal.operation == .update, let previous = proposal.previousExercises {
                            replacementNotice(previous: previous, next: proposal.exercises)
                        }
                        exercises(proposal)
                        if let errorMessage { errorBanner(errorMessage) }
                        actions(proposal)
                    } else {
                        missing
                    }
                }
                .padding(NoopMetrics.screenPadding)
            }
            .navigationTitle(Text("Routine draft"))
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss(); onFinish() }
                }
            }
        }
    }

    // MARK: - Header

    private func header(_ proposal: HevyRoutineProposal) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader(proposal.operation == .update ? "Change to a routine" : "New routine",
                          overline: "Hevy")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text(proposal.title)
                        .font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    Text("\(proposal.exercises.count) exercises · \(proposal.totalWorkingSets) working sets")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    if !proposal.rationale.isEmpty {
                        Divider().overlay(StrandPalette.hairline)
                        Text(proposal.rationale)
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Stated up front, every time. The whole design rests on the user knowing that
                    // nothing has happened yet.
                    Text("Nothing has been sent to Hevy. Your account is unchanged until you send this.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Warnings

    /// The gate's verdict, exactly as it was computed when the draft was made. It warns; it does not
    /// block — the same rule `GoalSafetyGate` follows, and for the same reason: a big jump can be
    /// entirely deliberate, and refusing those would be both paternalistic and wrong.
    private func warnings(_ proposal: HevyRoutineProposal) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Worth a look", overline: "Check")
            NoopCard(tint: StrandPalette.statusWarning) {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    ForEach(proposal.warnings, id: \.self) { warning in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(StrandPalette.statusWarning)
                                .accessibilityHidden(true)
                            Text(warning)
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("These come from NOOP's own check against your recent training, not from the coach. You can send it anyway.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - What would be replaced

    /// THE reason this screen exists. Hevy replaces the whole routine, so an update that lists fewer
    /// exercises DELETES the rest. Naming them individually — rather than showing a count — is what
    /// makes that a decision instead of a surprise.
    private func replacementNotice(previous: [HevyRoutineDraftExercise],
                                   next: [HevyRoutineDraftExercise]) -> some View {
        let keptIds = Set(next.map(\.templateId))
        let dropped = previous.filter { !keptIds.contains($0.templateId) }
        let addedIds = Set(previous.map(\.templateId))
        let added = next.filter { !addedIds.contains($0.templateId) }

        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("What changes", overline: "Before and after")
            NoopCard(tint: dropped.isEmpty ? StrandPalette.chargeColor : StrandPalette.statusWarning) {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text("Sending this replaces the whole routine in Hevy — the exercises below are the routine afterwards.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !dropped.isEmpty {
                        changeList(String(localized: "Removed"), dropped.map(\.title),
                                   tint: StrandPalette.statusWarning, symbol: "minus.circle.fill")
                    }
                    if !added.isEmpty {
                        changeList(String(localized: "Added"), added.map(\.title),
                                   tint: StrandPalette.statusPositive, symbol: "plus.circle.fill")
                    }
                    if dropped.isEmpty && added.isEmpty {
                        Text("Same exercises — only the sets change.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    private func changeList(_ title: String, _ names: [String],
                            tint: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary)
            ForEach(names, id: \.self) { name in
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint)
                        .accessibilityHidden(true)
                    Text(name).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                }
            }
        }
    }

    // MARK: - The routine itself

    private func exercises(_ proposal: HevyRoutineProposal) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("The routine", overline: "Sets")
            VStack(spacing: 8) {
                ForEach(proposal.exercises) { exercise in exerciseCard(exercise) }
            }
        }
    }

    private func exerciseCard(_ exercise: HevyRoutineDraftExercise) -> some View {
        NoopCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(exercise.title)
                        .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    if let superset = exercise.supersetId {
                        Text("Superset \(superset + 1)")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                // Every set on its own line, with its numbers unrounded. A reader has to be able to
                // check this against what they know they lift; a summary would hide the one wrong set.
                ForEach(Array(exercise.sets.enumerated()), id: \.offset) { index, set in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 16, alignment: .trailing)
                        Text(set.summary)
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                if let rest = exercise.restSeconds, rest > 0 {
                    Text("Rest \(rest)s").font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                if let notes = exercise.notes, !notes.isEmpty {
                    Text(notes).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Deciding

    private func actions(_ proposal: HevyRoutineProposal) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if let sentTitle {
                Text("Sent “\(sentTitle)” to Hevy.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.statusPositive)
            } else {
                HStack(spacing: NoopMetrics.space3) {
                    Button {
                        Task { await send(proposal) }
                    } label: {
                        Label(sending ? "Sending…" : "Send to Hevy", systemImage: "arrow.up.circle")
                    }
                    .buttonStyle(NoopButtonStyle(.primary))
                    .disabled(sending)
                    Button("Discard", role: .destructive) {
                        proposals.decide(proposal.id, as: .declined)
                        dismiss()
                        onFinish()
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))
                    .disabled(sending)
                    if sending { ProgressView().controlSize(.small) }
                }
                Text("The coach can't send this by itself — only this button does.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func errorBanner(_ text: String) -> some View {
        NoopCard(padding: 12, tint: StrandPalette.statusWarning) {
            Text(text).font(StrandFont.subhead).foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var missing: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("This draft has already been decided.")
                .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text("Ask the coach for a new one if you still want it.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    // MARK: - Sending

    private func send(_ proposal: HevyRoutineProposal) async {
        sending = true
        errorMessage = nil
        defer { sending = false }
        do {
            _ = try await HevyRoutineWriter.send(proposal, using: HevyAPIClient())
            proposals.decide(proposal.id, as: .sent)
            sentTitle = proposal.title
        } catch {
            // Recorded as `.failed`, not returned to `.proposed`: the difference is whether the user
            // is offered a retry or the draft quietly reappears as though nothing had been attempted.
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            proposals.decide(proposal.id, as: .failed, error: text)
            errorMessage = text
        }
    }
}
