import SwiftUI
import StrandDesign

/// #459: "Start Workout" used to live ONLY on the Live screen, so a user reaching Workouts (via the
/// Quick-action FAB or the tab) had no way to begin one from the obvious place. This button starts a live
/// session and presents the in-exercise view directly.
///
/// PERF (chart-invalidation): this is the ONE place `WorkoutsView` needs live `AppModel` state
/// (`activeWorkout`) — everything else it needs (`hrMax`, `analyzeRecent()`) lives on sub-objects that
/// don't publish at live-tick frequency. `AppModel` publishes `bpm` at ~1 Hz (AppModel.swift:202), and
/// `@EnvironmentObject` subscribes to the WHOLE object's `objectWillChange`, so if `WorkoutsView` itself
/// held `model: AppModel`, every tick would re-evaluate its entire ~1900-line body (chart + grids +
/// sorting) even though only this button and its sport picker read `model`. Isolating it here
/// (mirroring `HealthView`'s live-observing-leaf pattern, HealthView.swift:17-22, 44-46) means a tick
/// re-renders only this small leaf. Owns its own sport-picker state so nothing about it needs to live on
/// the parent either.
struct WorkoutStartControl: View {
    @EnvironmentObject var model: AppModel
    @State private var showStartSport = false

    var body: some View {
        NoopButton(model.activeWorkout == nil ? "Start workout" : "View active workout",
                   systemImage: model.activeWorkout == nil ? "figure.run" : "timer",
                   kind: .primary,
                   fullWidth: true) {
            // No active session → pick a named sport first (#519), then the sheet's onStart begins it
            // and opens the in-exercise view. Already active → jump straight back into the live view.
            if model.activeWorkout == nil { showStartSport = true }
            else { model.session.present() }
        }
        .accessibilityLabel(model.activeWorkout == nil ? "Start a workout" : "View the active workout")
        // #519: name the sport before a live session starts, then open the in-exercise view directly
        // (same direct present as the button's already-active path — no cross-view auto-present race).
        // The in-exercise view itself is presented by the shared `ActiveSessionController`, so this leaf
        // owns no sheet of its own.
        .workoutSelectionCover(isPresented: $showStartSport) {
            StartWorkoutSheet(offersZoneTraining: true) { name, targetZone in
                model.session.requestCardio(sport: name, targetZone: targetZone)
            }
        }
    }
}
