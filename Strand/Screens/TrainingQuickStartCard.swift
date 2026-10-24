import SwiftUI
import StrandDesign
import StrandTraining
import StrandCore

/// The top of the Training tab: start what is planned or what was done recently with one tap, or open
/// the full start screen for anything else. Each activity states the route and zone-coach choice it
/// will start with and offers a visible button to change them first, so nothing hides behind a gesture.
struct TrainingQuickStartCard: View {
    /// The strength entry: today's plan when one is scheduled, otherwise freestyle.
    enum StrengthEntry {
        case today([TrainingRoutine])
        case freestyle
    }

    let strength: StrengthEntry
    let onStartStrength: ([TrainingRoutine]) -> Void
    let onShowAll: () -> Void

    @EnvironmentObject private var session: ActiveSessionController
    @State private var configuring: WorkoutCatalog.Sport?

    private var activities: [WorkoutCatalog.Sport] {
        WorkoutQuickStart.activities(recent: RecentSportsPrefs.recent())
    }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Start a workout")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                VStack(spacing: 0) {
                    strengthRow(strength)
                    Divider().padding(.leading, Self.textInset)
                    ForEach(activities) { sport in
                        activityRow(sport)
                        Divider().padding(.leading, Self.textInset)
                    }
                    allWorkoutsRow
                }
            }
        }
        .sheet(item: $configuring) { sport in
            QuickStartSettingsSheet(sport: sport) { settings in
                WorkoutQuickStart.start(sport, with: settings, session: session, closingSheet: true)
            }
        }
    }

    /// Icon column plus its gap, so dividers start under the text as in a system list.
    private static let iconSize: CGFloat = 40
    private static let textInset: CGFloat = iconSize + NoopMetrics.space3

    @ViewBuilder
    private func strengthRow(_ entry: StrengthEntry) -> some View {
        switch entry {
        case .today(let routines):
            QuickStartRow(title: Text("Start today's plan"),
                          detail: Text(verbatim: routines.map(\.title).joined(separator: " · ")),
                          onStart: { onStartStrength(routines) }) {
                symbolIcon("calendar")
            }
        case .freestyle:
            QuickStartRow(title: Text("Freestyle workout"), detail: Text("Add exercises as you go."),
                          onStart: { onStartStrength([]) }) {
                symbolIcon("dumbbell.fill")
            }
        }
    }

    private func activityRow(_ sport: WorkoutCatalog.Sport) -> some View {
        let settings = WorkoutStartSettings.remembered(for: sport)
        return QuickStartRow(title: Text(sport.displayName),
                             detail: Text(verbatim: Self.summary(settings, for: sport)),
                             onStart: { WorkoutQuickStart.start(sport, with: settings, session: session) },
                             onSettings: { configuring = sport }) {
            WorkoutTypeIcon(workoutType: sport.name, size: 20, weight: .semibold,
                            color: StrandPalette.effortColor)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .background(StrandPalette.effortColor.opacity(0.12), in: Circle())
        }
    }

    private var allWorkoutsRow: some View {
        Button(action: onShowAll) {
            HStack(spacing: NoopMetrics.space3) {
                Image(systemName: "magnifyingglass")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(width: Self.iconSize, height: Self.iconSize)
                    .background(StrandPalette.surfaceRaised, in: Circle())
                Text("All workouts")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: NoopMetrics.space2)
                Image(systemName: "chevron.right")
                    .font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.vertical, NoopMetrics.space2)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Strength, routines and every activity"))
    }

    private func symbolIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(StrandFont.subhead.weight(.semibold))
            .foregroundStyle(StrandPalette.accent)
            .frame(width: Self.iconSize, height: Self.iconSize)
            .background(StrandPalette.accent.opacity(0.12), in: Circle())
    }

    /// "Route · Zone 2", "No route · No zone coach", or only the zone part for an activity without a route.
    static func summary(_ settings: WorkoutStartSettings, for sport: WorkoutCatalog.Sport) -> String {
        var parts: [String] = []
        if sport.supportsRoute {
            parts.append(settings.gpsEnabled ? String(localized: "Route") : String(localized: "No route"))
        }
        if let zone = settings.targetZone {
            parts.append(String(localized: "Zone \(zone)"))
        } else {
            parts.append(String(localized: "No zone coach"))
        }
        return parts.joined(separator: " · ")
    }
}

/// One startable line: tapping it starts at once, the optional settings button opens the choices first.
private struct QuickStartRow<Icon: View>: View {
    let title: Text
    let detail: Text
    let onStart: () -> Void
    var onSettings: (() -> Void)?
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: NoopMetrics.space2) {
            Button(action: onStart) {
                HStack(spacing: NoopMetrics.space3) {
                    icon()
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        title
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                        detail
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: NoopMetrics.space2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Double tap to start"))

            // Settings sit left of Start so every Start button lines up on the trailing edge.
            if let onSettings {
                Button(action: onSettings) {
                    Image(systemName: "slider.horizontal.3")
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Workout settings"))
            }

            Button(action: onStart) {
                Image(systemName: "play.fill")
                    .font(StrandFont.footnote.weight(.bold))
                    .foregroundStyle(StrandPalette.goldDeepText)
                    .frame(width: 32, height: 32)
                    .background(StrandPalette.accent, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The row itself already starts the activity for VoiceOver.
            .accessibilityHidden(true)
        }
        .padding(.vertical, NoopMetrics.space2)
        .frame(minHeight: 56)
    }
}

/// The choices of one activity before it starts: zone coach, route and feedback, then Start.
private struct QuickStartSettingsSheet: View {
    let sport: WorkoutCatalog.Sport
    let onStart: (WorkoutStartSettings) -> Void

    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var settings: WorkoutStartSettings

    init(sport: WorkoutCatalog.Sport, onStart: @escaping (WorkoutStartSettings) -> Void) {
        self.sport = sport
        self.onStart = onStart
        _settings = State(initialValue: WorkoutStartSettings.remembered(for: sport))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    ZoneTrainingTargetPicker(selection: $settings.targetZone, zoneSet: profile.hrZoneSet)
                    WorkoutStartConfigurationPanel(sport: sport, gpsEnabled: $settings.gpsEnabled,
                                                   actionVerb: String(localized: "Start"),
                                                   onStart: {
                                                       onStart(settings)
                                                       dismiss()
                                                   },
                                                   targetZone: settings.targetZone)
                }
                .padding(NoopMetrics.screenPadding)
            }
            .background { StrandPalette.surfaceBase.ignoresSafeArea() }
            .navigationTitle(Text(sport.displayName))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }
}
