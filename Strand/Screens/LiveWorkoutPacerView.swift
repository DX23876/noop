import SwiftUI
import StrandDesign

struct LiveWorkoutPacerView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(UnitPrefs.systemKey) private var units = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceUnits = ""
    private var system: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: units) ?? .metric, override: distanceUnits)
    }

    var body: some View {
        if let pacer = model.workoutRecording.pacer, let workout = model.activeWorkout {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text("Pacer").font(StrandFont.headline)
                    Text("\(UnitFormatter.distanceFromMeters(pacer.meters, system: system)) in \(WorkoutAnnouncementText.duration(Int(pacer.seconds)))")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    if let delta = pacer.aheadSeconds(distanceM: model.workoutRecording.distanceM,
                        activeSeconds: workout.elapsed(at: context.date), fresh: model.workoutGPSIsFresh(at: context.date),
                        uninterrupted: model.workoutRecording.hasRouteGap != true) {
                        Text(delta >= 0 ? "Ahead by \(WorkoutAnnouncementText.duration(Int(delta)))"
                                       : "Behind by \(WorkoutAnnouncementText.duration(Int(-delta)))")
                            .font(StrandFont.subhead).monospacedDigit()
                    } else {
                        Text(model.workoutRecording.hasRouteGap == true ? "Pacer unavailable after a GPS gap."
                             : "Pacer waiting for fresh GPS.").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .padding(NoopMetrics.space4)
                .background(StrandPalette.surfaceRaised, in: .rect(cornerRadius: NoopMetrics.cardRadius))
            }
        }
    }
}
