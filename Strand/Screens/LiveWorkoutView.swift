import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Three focused recording pages with persistent pause/end controls. Fresh HR and pace use shared
/// supplied-clock gates; recorded zones, laps and phases retain their original capture evidence.
struct LiveWorkoutView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: ActiveSessionController
    // PERF (scroll/recompose): this screen deliberately does NOT observe `LiveState` directly. A connected
    // strap publishes `LiveState` ~1 Hz (HR + each R-R packet, plus sensor frames), and an
    // `@EnvironmentObject live` here would invalidate the WHOLE body on every tick even though it reads from
    // `model` (smoothed bpm + scorers), not `live`. The only region that genuinely needs `live` is the
    // additive sensor readout (speed / cadence / power), so it's the small `LiveWorkoutSensorCard` leaf below
    // that owns its OWN `@EnvironmentObject live`. A sensor/R-R packet re-renders just those rows.
    let onClose: () -> Void

    /// Keep the screen awake while recording (#703). Opt-in, default off; the toggle lives in Settings.
    /// Read here so we can hold the idle timer off only while this in-exercise screen is up and release it
    /// the moment it leaves, which is exactly the bounded usage Apple asks for. iOS-only (no-op on Mac).
    @AppStorage("workoutKeepScreenOn") private var keepScreenOn = false

    /// Guards the End action behind a confirm (#517) — a stray tap must not end the workout instantly.
    @State private var showEndConfirm = false
    @State private var showDiscardConfirm = false
    @State private var activeSheet: Sheet?
    private enum Sheet: String, Identifiable { case settings, upcoming; var id: String { rawValue } }
    @State private var page: LiveWorkoutContentView.Page = .metrics

    private var isPaused: Bool { model.activeWorkout?.isPaused == true }

    var body: some View {
        LiveWorkoutContentView(page: $page, onMinimize: onClose, onDiscard: requestDiscard,
                               onSettings: openSettings, onUpcomingPhases: upcomingPhasesAction)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LiveWorkoutControls(isPaused: isPaused, onTogglePause: togglePause, onEnd: requestEnd)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings:
                WorkoutFeedbackSettingsView(sport: model.activeWorkout?.sport ?? "", gpsEnabled: model.activeWorkoutUsesGPS,
                                            hasTargetZone: model.activeWorkout?.targetZone != nil)
            case .upcoming:
                WorkoutUpcomingPhasesView()
            }
        }
        // If the workout ended elsewhere (process restart cleared it), close the screen.
        .onChangeCompat(of: model.activeWorkout == nil) { gone in
            if gone, model.workoutCompletion == nil { onClose() }
        }
        // The Lock Screen "End" link opens this screen and asks here, never ends on its own.
        .onChangeCompat(of: session.endConfirmationRequested) { requested in
            if requested { requestEnd() }
        }
        // Arm the realtime HR stream while the in-exercise screen is up (#681). On a WHOOP 5/MG live HR
        // only flows while the puffin realtime stream is armed; previously only the Live tab armed it, so
        // starting a manual workout straight from Workouts (Live never opened) left `model.bpm == nil` —
        // captureWorkoutSample bailed on every sample and endWorkout silently discarded the empty
        // session. Ref-counted in AppModel, so when this sheet sits over an already-armed Live tab the
        // two balance and neither disarms the other (mirrors Android LiveWorkoutScreen's DisposableEffect
        // requestRealtimeHr/releaseRealtimeHr). Balanced: one start on appear, one stop on disappear.
        .onAppear(perform: screenAppeared)
        .onDisappear(perform: screenDisappeared)
        .alert("End this workout?", isPresented: $showEndConfirm) {
            Button("Cancel", role: .cancel) { }
            if isShortRecording {
                Button("Save short recording", action: endWorkout)
                Button("Discard workout", role: .destructive, action: discardWorkout)
            } else {
                Button("End workout", action: endWorkout)
            }
        } message: {
            if isShortRecording {
                Text("Less than one minute recorded. Save it if this was intentional, or discard it.")
            } else {
                Text("This stops recording and saves what's captured so far. It can't be resumed.")
            }
        }
        .alert("Discard this workout?", isPresented: $showDiscardConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Discard workout", role: .destructive, action: discardWorkout)
        } message: {
            Text("Nothing from this session is saved.")
        }
    }

    // MARK: - Actions

    private var upcomingPhasesAction: (() -> Void)? {
        guard model.workoutRecording.guidance?.current != nil else { return nil }
        return openUpcomingPhases
    }

    private func openSettings() { activeSheet = .settings }
    private func openUpcomingPhases() { activeSheet = .upcoming }

    private func screenAppeared() {
        model.startRealtimeHR()
        // Hold the display awake for the session only if the user opted in (#703).
        if keepScreenOn { ScreenIdle.keepAwake(true) }
        if session.endConfirmationRequested { requestEnd() }
    }

    private func screenDisappeared() {
        model.stopRealtimeHR()
        // Always release on the way out so the system idle timer resumes. Even if the toggle was flipped
        // off mid-workout, this clears any hold we placed.
        ScreenIdle.keepAwake(false)
    }

    private func togglePause() {
        model.toggleWorkoutPause()
    }

    private func requestEnd() {
        session.endConfirmationRequested = false
        showEndConfirm = true
    }

    private func requestDiscard() {
        showDiscardConfirm = true
    }

    private func endWorkout() {
        model.endWorkout()
    }

    private var isShortRecording: Bool {
        model.activeWorkout.map { AppModel.isTooShortToSave(elapsedSeconds: $0.elapsed(at: .now)) } ?? false
    }

    private func discardWorkout() {
        model.discardWorkout()
        onClose()
    }
}
