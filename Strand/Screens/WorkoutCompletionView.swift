import SwiftUI
import StrandDesign

/// The finished recording remains visible until its durable save has succeeded.
struct WorkoutCompletionView: View {
    let completion: WorkoutCompletion
    let onDone: () -> Void
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var session: ActiveSessionController
    @AppStorage(UnitPrefs.systemKey) private var units = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceUnits = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    Text(WorkoutSource.localizedDisplaySport(completion.recording.row.sport))
                        .font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
                    saveStatus
                    metrics
                    if let personalBest = completion.personalBest { WorkoutPersonalBestView(result: personalBest) }
                    WorkoutRecordingSectionsView(timeline: completion.recording.timeline,
                                                 seconds: completion.recording.row.durationS ?? 0,
                                                 sport: completion.recording.row.sport)
                    zones
                }
                .screenPadding()
                .padding(.vertical, NoopMetrics.space4)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle(Text("Workout summary"))
            .toolbar {
                if completion.status == .failed {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { session.minimize() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone).disabled(completion.status != .saved)
                }
            }
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var saveStatus: some View {
        switch completion.status {
        case .saving:
            HStack { ProgressView(); Text("Saving recording…") }
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        case .saved:
            Label("Recording saved", systemImage: "checkmark.circle.fill")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusPositive)
        case .failed:
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Label("Not saved yet", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(StrandPalette.statusWarningForeground)
                Text("Your recording is kept on this device. Try saving again.")
                    .foregroundStyle(StrandPalette.textSecondary)
                Button("Try saving again") { app.retryWorkoutCompletion() }
                    .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
            }
            .font(StrandFont.footnote)
        }
    }

    private var metrics: some View {
        let row = completion.recording.row
        let system = UnitPrefs.resolveDistance(system: UnitSystem(rawValue: units) ?? .metric, override: distanceUnits)
        return VStack(spacing: 0) {
            LiveWorkoutMetricRow(value: ActiveWorkoutClock.clock(Int(row.durationS ?? 0)), unit: "",
                                 caption: String(localized: "Active time"), symbol: "stopwatch")
            if let distance = row.distanceM {
                let parts = LiveWorkoutMetricRow.split(UnitFormatter.distanceFromMeters(distance, system: system))
                LiveWorkoutMetricRow(value: parts.value, unit: parts.unit, caption: String(localized: "Distance"))
                if let duration = row.durationS, duration > 0, distance > 0 {
                    let speed = distance / duration
                    let value = WorkoutCatalog.usesSpeedReadout(for: row.sport)
                        ? (UnitFormatter.speedFromKilometersPerHour(speed * 3.6, system: system) ?? "—")
                        : UnitFormatter.paceFromSecPerKm(1000 / speed, system: system)
                    let motion = LiveWorkoutMetricRow.split(value)
                    LiveWorkoutMetricRow(value: motion.value, unit: motion.unit,
                                         caption: String(localized: "Workout average"))
                }
            }
            if let bpm = row.avgHr {
                LiveWorkoutMetricRow(value: String(bpm), unit: "bpm", caption: String(localized: "Average heart rate"))
            }
        }
    }

    @ViewBuilder
    private var zones: some View {
        let seconds = completion.recording.timeline.zoneSeconds(at: completion.recording.row.durationS ?? 0)
        if seconds.count == 5 {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Heart rate zones").font(StrandFont.headline)
                HStack(alignment: .bottom, spacing: NoopMetrics.space2) {
                    ForEach(1...5, id: \.self) { zone in
                        LiveWorkoutZoneBar(number: zone, isCurrent: false, isTarget: false,
                                           seconds: Int(seconds[zone - 1]),
                                           share: seconds[zone - 1] / max(1, seconds.reduce(0, +)))
                    }
                }
            }
        }
    }
}
