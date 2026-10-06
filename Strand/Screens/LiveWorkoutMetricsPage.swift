import SwiftUI
import StrandDesign

struct LiveWorkoutMetricsPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: NoopMetrics.space4) {
                if let workout = model.activeWorkout { LiveWorkoutClock(workout: workout) }
                LiveWorkoutGuidanceView()
                LiveWorkoutPacerView()
                VStack(spacing: 0) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let bpm = model.workoutHeartRate(at: context.date)
                        LiveWorkoutHeartRateRow(bpm: bpm,
                            zone: bpm.map { model.workoutZoneSet.zoneNumber(forBPM: Double($0)) } ?? 0,
                            avgHr: model.activeWorkout?.avgHr ?? 0, peakHr: model.activeWorkout?.peakHr ?? 0)
                    }
                    LiveWorkoutEffortRow(strain: model.activeWorkout?.liveStrain ?? 0, hasHeartRate: model.bpm != nil)
                    LiveWorkoutRouteCard(recorder: model.gpsRecorder, isEnabled: model.activeWorkoutUsesGPS)
                    LiveWorkoutSensorCard()
                }
                if model.workoutSaveFailed {
                    Text("Could not secure the recording. It is still open. Try ending it again.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarningForeground)
                }
            }
            .screenPadding().padding(.vertical, NoopMetrics.space4)
        }
    }
}
