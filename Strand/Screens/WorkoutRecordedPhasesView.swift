import SwiftUI
import StrandAnalytics
import StrandDesign

/// The same original phase history appears live, at completion and in workout detail.
struct WorkoutRecordedPhasesView: View {
    let guidance: WorkoutGuidance
    let seconds: Double
    let meters: Double
    let hasDistance: Bool
    let isLive: Bool
    @AppStorage(UnitPrefs.systemKey) private var units = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceUnits = ""

    private var system: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: units) ?? .metric, override: distanceUnits)
    }

    var body: some View {
        let phases = guidance.recordedPhases(seconds: seconds, meters: meters)
        if !phases.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Training phases").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                ForEach(phases) { recorded in
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
                        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                            Text(WorkoutGuidanceText.title(recorded.phase.kind)).font(StrandFont.subhead)
                            if recorded.skipped {
                                Text("Skipped").font(StrandFont.caption)
                            } else if recorded.inProgress {
                                Text(isLive ? "Current section" : "Last section").font(StrandFont.caption)
                            }
                        }
                        Spacer(minLength: NoopMetrics.space2)
                        VStack(alignment: .trailing, spacing: NoopMetrics.space1) {
                            Text(ActiveWorkoutClock.clock(Int(recorded.seconds))).font(StrandFont.captionNumber)
                            if hasDistance {
                                Text(UnitFormatter.distanceFromMeters(recorded.meters, system: system)).font(StrandFont.captionNumber)
                            }
                        }
                    }
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.vertical, NoopMetrics.space2)
                    .overlay(alignment: .bottom) { Divider() }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
