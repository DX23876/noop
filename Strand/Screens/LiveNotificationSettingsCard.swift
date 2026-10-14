#if os(iOS)
import SwiftUI
import StrandDesign

/// NOOP's live notifications — its Live Activities, on the Lock Screen and in the Dynamic Island — one
/// switch each: the live heart rate, a running workout and a strap sync. Upstream's third, the Lift Log
/// session, is left out because the Lift Log is dormant in this fork.
///
/// A switch only decides whether its notification is SHOWN: the heart rate is still measured, recorded
/// and scored, a session still runs and buzzes, a sync still runs, with any of them off. First card of
/// the Settings page "Notifications" since the 2026-10 reorganisation (it sat under Strap before).
struct LiveNotificationSettingsCard: View {
    // Live-HR Live Activity (#336). Default on.
    @AppStorage(UnitPrefs.liveActivityKey) private var liveActivityEnabled = true
    // Strap-sync Live Activity. Separate from the live-HR one on purpose. Default on.
    @AppStorage(UnitPrefs.syncLiveActivityKey) private var syncLiveActivityEnabled = true
    /// Unset follows the live-HR switch (`UnitPrefs.workoutLiveActivityEnabled`); the binding below shows that.
    @AppStorage(UnitPrefs.workoutLiveActivityKey) private var workoutLiveActivityStored: Bool?

    var body: some View {
        SettingsSection(
            icon: "bell.badge",
            title: "Live notifications",
            blurb: "Shown on the Lock Screen and in the Dynamic Island. A switch only hides one: NOOP still measures and records everything."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                liveNotificationSwitch("Live heart rate", isOn: $liveActivityEnabled,
                                       detail: "While the strap is connected.")
                divider
                liveNotificationSwitch("Workout", isOn: Binding(
                    get: { workoutLiveActivityStored ?? liveActivityEnabled },
                    set: { workoutLiveActivityStored = $0 }),
                                       detail: "Elapsed time, heart rate, sets and rest while a workout runs.")
                divider
                liveNotificationSwitch("Strap sync", isOn: $syncLiveActivityEnabled,
                                       detail: "Progress while NOOP pulls history from the strap.")
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(height: 1)
            .padding(.vertical, 4)
    }

    private func liveNotificationSwitch(_ title: LocalizedStringKey, isOn: Binding<Bool>,
                                        detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Toggle(isOn: isOn) {
                Text(title)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .toggleStyle(.switch)
            .appleInspiredTint("settings.controls")
            Text(detail)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
