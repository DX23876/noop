import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Live workout mode (#238) — the in-exercise screen, laid out like Apple's Workout app: one large centered
/// clock, then a plain list of live metrics (heart rate, Effort, route, sensors), the heart-rate zones as
/// bars that light up, and two large controls at the bottom. Every number comes from the SAME live feed and
/// scorers the rest of the app uses (no invented numbers). Presented while a manual workout is active.
///
/// Live HR is the smoothed `AppModel.bpm`; the zone is derived from the user's HR-max via the shared
/// `HRZones` model; elapsed time ticks from the workout's start (a TimelineView, no manual Timer); effort is
/// the running `ActiveWorkout.liveStrain` (StrainScorer over the captured window); time in zone is
/// `HRZones.timeInZone` over the session's own samples, the same reading the workout detail uses.
///
/// Nothing on this screen claims a heart-rate state it has not received: with no bpm the HR row reads "—"
/// with a waiting caption, and the zone rail stays hidden unless a target zone was chosen.
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

    private var zoneSet: HRZoneSet { model.profile.hrZoneSet }
    private var zone: Int { model.bpm.map { zoneSet.zoneNumber(forBPM: Double($0)) } ?? 0 }
    private var isPaused: Bool { model.activeWorkout?.isPaused == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                LiveWorkoutHeader(isPaused: isPaused, onMinimize: onClose, onDiscard: requestDiscard)
                if let workout = model.activeWorkout {
                    LiveWorkoutClock(workout: workout)
                }
                VStack(spacing: 0) {
                    LiveWorkoutHeartRateRow(bpm: model.bpm, zone: zone,
                                            avgHr: model.activeWorkout?.avgHr ?? 0,
                                            peakHr: model.activeWorkout?.peakHr ?? 0)
                    LiveWorkoutEffortRow(strain: model.activeWorkout?.liveStrain ?? 0,
                                         hasHeartRate: model.bpm != nil)
                    LiveWorkoutRouteCard(recorder: model.gpsRecorder,
                                         isEnabled: model.activeWorkoutUsesGPS)
                    LiveWorkoutSensorCard()
                }
                if let workout = model.activeWorkout, model.bpm != nil || workout.targetZone != nil {
                    LiveWorkoutZoneSection(zone: zone,
                                           targetZone: workout.targetZone,
                                           zoneSet: zoneSet,
                                           timeInZone: HRZones.timeInZone(workout.samples, zoneSet: zoneSet),
                                           coachStatus: workout.targetZone.map(zoneCoachStatus))
                        .padding(.top, NoopMetrics.space2)
                }
            }
            .screenPadding()
            .padding(.top, NoopMetrics.space2)
            .padding(.bottom, NoopMetrics.space6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        // #697/#horizontal-swipe parity, see ScreenScaffold. This is the full-screen in-exercise
        // tracker, up for the whole workout, so worth the same defensive fix.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LiveWorkoutControls(isPaused: isPaused, onTogglePause: togglePause, onEnd: requestEnd)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        // If the workout ended elsewhere (process restart cleared it), close the screen.
        .onChangeCompat(of: model.activeWorkout == nil) { gone in if gone { onClose() } }
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
            Button("End workout", action: endWorkout)
        } message: {
            Text("This stops recording and saves what's captured so far. It can't be resumed.")
        }
        .alert("Discard this workout?", isPresented: $showDiscardConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Discard workout", role: .destructive, action: discardWorkout)
        } message: {
            Text("Nothing from this session is saved.")
        }
    }

    private func zoneCoachStatus(target: Int) -> String {
        guard let bpm = model.bpm else { return String(localized: "Waiting for heart rate") }
        switch HRZoneTrainingEngine.state(forBPM: bpm, zoneSet: zoneSet, targetZone: target) {
        case .belowTarget: return String(localized: "Below target · increase intensity")
        case .inTarget: return String(localized: "In target zone")
        case .aboveTarget: return String(localized: "Above target · ease off")
        }
    }

    // MARK: - Actions

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
        // A finished session is the biggest landing this screen has, so it gets `.commit` — and it fires on
        // the CONFIRM, not on the control that opens this alert, so the tick means "saved" rather than "asked".
        StrandHaptic.commit.play()
        model.endWorkout()
        onClose()
    }

    private func discardWorkout() {
        model.discardWorkout()
        onClose()
    }
}
