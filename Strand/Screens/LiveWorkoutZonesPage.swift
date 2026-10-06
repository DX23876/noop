import SwiftUI
import StrandDesign
import StrandAnalytics

struct LiveWorkoutZonesPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            if let workout = model.activeWorkout {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = workout.elapsed(at: context.date)
                    let bpm = model.workoutHeartRate(at: context.date)
                    let zones = model.workoutZoneSet
                    let zone = bpm.map { zones.zoneNumber(forBPM: Double($0)) } ?? 0
                    VStack(alignment: .leading, spacing: NoopMetrics.space6) {
                        LiveWorkoutHeartRateRow(bpm: bpm, zone: zone, avgHr: workout.avgHr, peakHr: workout.peakHr)
                        if bpm != nil {
                            LabeledContent("Time in current zone", value: ActiveWorkoutClock.clock(Int(model.workoutRecording.currentZoneSeconds(at: seconds))))
                                .font(StrandFont.subhead).monospacedDigit()
                        }
                        LiveWorkoutZoneSection(zone: zone, targetZone: workout.targetZone, zoneSet: zones,
                            timeInZone: HRZones.timeInZone(workout.samples, zoneSet: zones), coachStatus: nil,
                            recordedSeconds: model.workoutRecording.zoneSeconds(at: seconds))
                        Text("Only received heart-rate readings count toward time in zone.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    }
                    .screenPadding().padding(.vertical, NoopMetrics.space4)
                }
            }
        }
    }
}
