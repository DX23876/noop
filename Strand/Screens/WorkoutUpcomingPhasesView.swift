import SwiftUI
import StrandDesign
import StrandAnalytics

struct WorkoutUpcomingPhasesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var expectedCurrentID: UUID?
    @State private var phases: [WorkoutGuidance.Phase] = []
    @State private var changedWhileEditing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Only upcoming phases change. The current phase and recorded sections stay unchanged.")
                        .foregroundStyle(.secondary)
                    ForEach($phases) { $phase in
                        WorkoutPhaseEditorRow(phase: $phase, gpsEnabled: model.activeWorkoutUsesGPS)
                    }
                    .onDelete { phases.remove(atOffsets: $0) }
                    Button("Add work and recovery", systemImage: "plus", action: addIntervals)
                        .disabled(phases.count >= 60)
                }
                if changedWhileEditing {
                    Text("The phase changed while editing. Reload before applying your changes.")
                        .foregroundStyle(StrandPalette.statusWarningForeground)
                    Button("Reload upcoming phases", action: reload)
                }
            }
            .navigationTitle("Upcoming phases")
            .tint(StrandPalette.accent)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Apply plan", action: apply).disabled(expectedCurrentID == nil)
            } }
            .task { reload() }
        }
    }

    private func reload() {
        guard let guidance = model.workoutRecording.guidance else { expectedCurrentID = nil; return }
        expectedCurrentID = guidance.current?.id
        phases = Array(guidance.phases.dropFirst(guidance.index + 1))
        changedWhileEditing = false
    }
    private func addIntervals() { phases += [.init(kind: .work, seconds: 180), .init(kind: .recovery, seconds: 120)] }
    private func apply() {
        guard let id = expectedCurrentID else { return }
        if model.replaceUpcomingWorkoutPhases(expectedCurrentID: id, phases: phases) { dismiss() }
        else { changedWhileEditing = true }
    }
}
