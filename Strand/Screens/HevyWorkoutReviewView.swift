import SwiftUI
import WhoopStore
import StrandDesign

struct HevyWorkoutReviewView: View {
    let proposalId: UUID
    let onDone: () -> Void
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var proposals = HevyWorkoutProposalStore.shared
    @State private var sending = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if let proposal = proposals.proposal(id: proposalId) {
                    LazyVStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                        SectionHeader(proposal.operation == .update ? "Workout correction" : "Completed workout",
                                      overline: "Review before sending")
                        if let previous = proposal.previousWorkout {
                            workoutCard(previous, title: String(localized: "Before"))
                        }
                        workoutCard(proposal.workout, title: proposal.operation == .update
                                    ? String(localized: "After") : String(localized: "Workout"))
                        if proposal.operation == .create {
                            Text("The documented Hevy API does not provide workout deletion. Check this new workout carefully before sending.")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
                        }
                        if let error = proposal.lastError {
                            Text(error).font(StrandFont.caption).foregroundStyle(StrandPalette.statusCritical)
                        }
                        HStack {
                            Button("Decline") { proposals.decide(proposal.id, as: .declined); onDone() }
                            Spacer()
                            Button(sending ? "Sending…" : "Send to Hevy") {
                                Task { await send(proposal) }
                            }
                            .disabled(sending)
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(NoopMetrics.screenPadding)
                }
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle(Text("Hevy workout"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: onDone) } }
        }
    }

    private func workoutCard(_ workout: HevyWorkout, title: String) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text(title).strandOverline()
                Text(workout.title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text(Date(timeIntervalSince1970: TimeInterval(workout.startTs)).formatted(date: .abbreviated, time: .shortened))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                ForEach(workout.exercises, id: \.index) { exercise in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(exercise.title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text(exercise.sets.map(setText).joined(separator: " · "))
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                let volume = workout.exercises.flatMap(\.workingSets).compactMap(\.volumeLoadKg).reduce(0, +)
                let volumeValue = ": \(String(format: "%.0f", volume)) kg"
                (Text("Volume") + Text(verbatim: volumeValue))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private func setText(_ set: HevySet) -> String {
        var text = "\(set.weightKg.map { String(format: "%.1f kg", $0) } ?? "bodyweight") × \(set.reps.map(String.init) ?? "—")"
        if let rpe = set.rpe { text += " @ RPE \(String(format: "%.1f", rpe))" }
        return text
    }

    private func send(_ proposal: HevyWorkoutProposal) async {
        sending = true
        defer { sending = false }
        do {
            let saved = try await HevyWorkoutWriter.send(proposal, using: HevyAPIClient())
            if let store = await repo.storeHandle() { try await store.upsertHevyWorkouts([saved]) }
            proposals.decide(proposal.id, as: .sent)
            await repo.refresh()
            onDone()
        } catch {
            proposals.decide(proposal.id, as: .failed, error: error.localizedDescription)
        }
    }
}
