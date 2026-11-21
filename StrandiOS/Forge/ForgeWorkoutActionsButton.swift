#if os(iOS)
import SwiftUI
import StrandCore
import StrandAnalytics
import WhoopStore

/// The visible "•••" on a workout (owner, 2026-11-21): the shipped list showed one on every row, the redesign
/// only answered a long press, so removing a workout looked impossible. The same choices as the shipped list:
/// a detected bout is re-labelled, edited or dismissed, a manual one edited or deleted, imported history only
/// copied. Used on the Workouts page, the Training tab and a workout's own page.
struct ForgeWorkoutActionsButton: View {
    let row: WorkoutRow
    /// Called after the workout was deleted or dismissed, so a page showing only this workout can close.
    var onRemoved: () -> Void = {}
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var intelligence: IntelligenceEngine
    @State private var editor: ForgeWorkoutEditor.Target?

    var body: some View {
        Menu {
            ForgeWorkoutMenuItems(row: row, edit: { editor = $0 }, removed: onRemoved)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(ForgeColor.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Workout actions"))
        .sheet(item: $editor) { ForgeWorkoutEditor(target: $0) }
    }
}

/// The menu's entries, shared by the "•••" button and a row's long press.
struct ForgeWorkoutMenuItems: View {
    let row: WorkoutRow
    let edit: (ForgeWorkoutEditor.Target) -> Void
    var removed: () -> Void = {}
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var intelligence: IntelligenceEngine

    var body: some View {
        switch WorkoutSource.classify(row.source) {
        case .detected:
            Menu("Re-label as") {
                ForEach(WorkoutsView.relabelSports, id: \.self) { sport in
                    Button(sport) { Task { await repo.relabelDetected(row, sport: sport); await repo.refresh() } }
                }
            }
            Button("Edit details…") { edit(.init(editing: row)) }
            Divider()
            Button("Dismiss (not a workout)", role: .destructive) {
                Task { await repo.dismissDetected(row); await repo.refresh(); removed() }
            }
        case .manual, .confirmed:
            Button("Edit…") { edit(.init(editing: row)) }
            Divider()
            Button("Delete", role: .destructive, action: delete)
        case .whoop, .apple, .lifting, .activityFile, .hevy, .oura:
            Button("Duplicate as manual…") { edit(.init(editing: WorkoutsView.manualCopy(of: row), isCopy: true)) }
        }
    }

    private func delete() {
        RouteStore.remove(startTs: row.startTs, sport: row.sport)
        Task {
            await repo.deleteWorkout(row)
            // A workout mutation is invisible to the per-day fingerprint, so the day is re-derived by saying so.
            await intelligence.analyzeRecent(allowDayReuse: false)
            await repo.refresh()
            removed()
        }
    }
}
#endif
