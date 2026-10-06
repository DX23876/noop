import SwiftUI
import StrandDesign
import StrandAnalytics

struct WorkoutPhaseEditorRow: View {
    @Binding var phase: WorkoutGuidance.Phase
    let gpsEnabled: Bool
    @State private var usesDistance: Bool
    @State private var amount: Double
    @AppStorage(UnitPrefs.systemKey) private var units = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceUnits = ""
    private var system: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: units) ?? .metric, override: distanceUnits)
    }

    init(phase: Binding<WorkoutGuidance.Phase>, gpsEnabled: Bool) {
        _phase = phase
        self.gpsEnabled = gpsEnabled
        _usesDistance = State(initialValue: phase.wrappedValue.meters != nil)
        _amount = State(initialValue: phase.wrappedValue.meters ?? phase.wrappedValue.seconds ?? 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Picker("Phase", selection: $phase.kind) {
                Text("Warm-up").tag(WorkoutGuidance.Phase.Kind.warmup)
                Text("Work interval").tag(WorkoutGuidance.Phase.Kind.work)
                Text("Recovery interval").tag(WorkoutGuidance.Phase.Kind.recovery)
                Text("Cool-down").tag(WorkoutGuidance.Phase.Kind.cooldown)
            }
            if gpsEnabled || usesDistance {
                Picker("Phase target", selection: $usesDistance) {
                    Text("Duration").tag(false)
                    Text("Distance").tag(true).disabled(!gpsEnabled)
                }.pickerStyle(.segmented)
            }
            Stepper(value: $amount, in: usesDistance ? 50...10000 : 30...3600, step: usesDistance ? 50 : 30) {
                Text(usesDistance ? UnitFormatter.distanceFromMeters(amount, system: system) : ActiveWorkoutClock.clock(Int(amount)))
                    .font(StrandFont.headline).monospacedDigit()
            }
        }
        .onChangeCompat(of: usesDistance) { _ in
            amount = usesDistance ? 400 : 60
            updatePhase()
        }
        .onChangeCompat(of: amount) { _ in updatePhase() }
    }

    private func updatePhase() {
        phase.seconds = usesDistance ? nil : amount
        phase.meters = usesDistance ? amount : nil
    }
}
