import SwiftUI

/// The 24 h body-clock dial's live-`AppModel` leaf (#1680).
///
/// PERF (chart-invalidation): `SleepView` used to hold `@EnvironmentObject var appModel: AppModel`
/// directly just to read `circadianPhase` for this one dial. `AppModel` publishes `bpm` at ~1 Hz
/// (AppModel.swift:202), and `@EnvironmentObject` subscribes to the WHOLE object's `objectWillChange`
/// regardless of which properties are actually read — so every tick re-evaluated `SleepView`'s entire
/// ~3000-line body (hero hypnogram, stat-tile sparklines, sleep-debt ledger, 30-day trend chart) even
/// though only this dial's visibility depends on `AppModel`. Isolating it here, mirroring `HealthView`'s
/// live-observing-leaf pattern (HealthView.swift:17-22, 44-46), means a tick re-renders only this leaf.
struct BodyClockDialSection: View {
    @EnvironmentObject var appModel: AppModel
    let actualBedHour: Double
    let actualWakeHour: Double

    /// Drawn only for a fit that is at least `.wide`: an `.unreadable` rhythm has no phase to compare a
    /// night against, and an empty ring would read as a broken chart rather than as "not enough data".
    var body: some View {
        if let phase = appModel.circadianPhase, phase.confidence != .unreadable {
            BodyClockDialCard(estimate: phase, actualBedHour: actualBedHour, actualWakeHour: actualWakeHour)
        }
    }
}
