import SwiftUI
import StrandAnalytics
import StrandDesign

/// Recorded sections only. Older workouts are not given interpolated, synthetic splits.
struct WorkoutRecordingSectionsView: View {
    let timeline: WorkoutRecordingTimeline
    let seconds: Double
    let sport: String
    var isLive = false
    @AppStorage(UnitPrefs.systemKey) private var units = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceUnits = ""

    private var system: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: units) ?? .metric, override: distanceUnits)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            if let guidance = timeline.guidance {
                WorkoutRecordedPhasesView(guidance: guidance, seconds: seconds, meters: timeline.distanceM,
                                         hasDistance: timeline.splitLengthM != nil, isLive: isLive)
            }
            sectionList(timeline.sections(at: seconds), title: "Distance splits")
            sectionList(timeline.manualSections(at: seconds), title: "Laps")
        }
    }

    @ViewBuilder
    private func sectionList(_ sections: [WorkoutRecordingTimeline.Section], title: LocalizedStringKey) -> some View {
        if !sections.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                ForEach(sections) { section in
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
                        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                            HStack(spacing: NoopMetrics.space1) {
                                Text("\(section.index)").font(StrandFont.captionNumber.weight(.semibold))
                                if section.partial {
                                    Text(isLive ? "Current section" : "Last section").font(StrandFont.caption)
                                }
                            }
                            if let meters = section.distanceM {
                                Text(UnitFormatter.distanceFromMeters(meters, system: system)).font(StrandFont.captionNumber)
                            }
                        }
                        Spacer(minLength: NoopMetrics.space2)
                        VStack(alignment: .trailing, spacing: NoopMetrics.space1) {
                            Text(ActiveWorkoutClock.clock(Int(section.duration))).font(StrandFont.captionNumber)
                            if section.interrupted {
                                Text("Measurement gap").font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.statusWarningForeground)
                            } else if let speed = section.speedMps {
                                Text(motion(speed)).font(StrandFont.captionNumber)
                            }
                        }
                        if let bpm = timeline.averageBpm(in: section) {
                            Text("\(bpm) bpm").font(StrandFont.captionNumber)
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

    private func motion(_ speed: Double) -> String {
        if WorkoutCatalog.usesSpeedReadout(for: sport) {
            return UnitFormatter.speedFromKilometersPerHour(speed * 3.6, system: system) ?? "—"
        }
        return UnitFormatter.paceFromSecPerKm(1000 / speed, system: system)
    }
}
