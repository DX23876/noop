import SwiftUI
import StrandDesign

/// Final, glanceable confirmation for a selected live workout. The route choice lives here instead of
/// being inferred invisibly from the sport name, so the wearer knows what the phone will record before
/// the session starts.
struct WorkoutStartConfigurationPanel: View {
    let sport: WorkoutCatalog.Sport
    @Binding var gpsEnabled: Bool
    let actionVerb: String
    let onStart: () -> Void
    var targetZone: Int? = nil
    /// Announcements are opt-in and remembered; detailed choices share the in-workout settings.
    @AppStorage(WorkoutVoiceCoach.enabledKey) private var voiceEnabled = false
    @State private var showsFeedbackSettings = false
    @State private var showsPlan = false
    @AppStorage(WorkoutGuidancePreferences.enabledKey) private var planEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(spacing: NoopMetrics.space3) {
                WorkoutTypeIcon(workoutType: sport.name, size: 24, weight: .semibold,
                                color: StrandPalette.effortColor)
                    .frame(width: 44, height: 44)
                    .background(StrandPalette.effortColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text(sport.displayName)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Selected")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: NoopMetrics.space2)
            }

            if sport.supportsRoute {
                Divider()
                Toggle(isOn: $gpsEnabled) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Label("Record route", systemImage: "location.fill")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(gpsEnabled
                             ? "GPS adds live distance, pace and a route."
                             : "The workout keeps its duration and heart rate without a route.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
            }

            // Strength sessions run their own logger and do not speak, so they get no switch for it.
            if !ActiveSessionController.isStrengthSport(sport.name) {
                Divider()
                Toggle(isOn: $voiceEnabled) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Label("Voice feedback", systemImage: "speaker.wave.2.fill")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Offline, through headphones unless you allow the speaker.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                HStack(spacing: NoopMetrics.space3) {
                    Button("Workout settings", systemImage: "slider.horizontal.3") { showsFeedbackSettings = true }
                    Spacer(minLength: 0)
                    Button("Training plan", systemImage: "list.number") { showsPlan = true }
                }
                .font(StrandFont.footnote).frame(minHeight: 44).tint(StrandPalette.accent)
                if planEnabled, WorkoutGuidancePreferences.plan(gpsEnabled: gpsEnabled) != nil {
                    Text("A copy of your selected plan starts with this workout.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
            }

            Button(action: onStart) {
                Label(actionVerb, systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
            .accessibilityHint(Text("Starts the selected workout"))
        }
        .padding(NoopMetrics.space4)
        .background(NoopPanelSurface(tint: StrandPalette.effortColor,
                                     cornerRadius: NoopMetrics.cardRadius, elevated: true))
        .sheet(isPresented: $showsFeedbackSettings) {
            WorkoutFeedbackSettingsView(sport: sport.name, gpsEnabled: gpsEnabled,
                                        hasTargetZone: targetZone != nil)
        }
        .sheet(isPresented: $showsPlan) { WorkoutPlanEditorView(gpsEnabled: gpsEnabled) }
    }
}
