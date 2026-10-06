import SwiftUI
import StrandDesign

/// Content paging is separate from lifecycle/confirmation modifiers to keep SwiftUI type checking bounded.
struct LiveWorkoutContentView: View {
    enum Page: Hashable { case metrics, zones, sections }
    @Binding var page: Page
    @EnvironmentObject private var model: AppModel
    let onMinimize: () -> Void
    let onDiscard: () -> Void
    let onSettings: () -> Void
    let onUpcomingPhases: (() -> Void)?

    var body: some View {
        VStack(spacing: NoopMetrics.space3) {
            LiveWorkoutHeader(isPaused: model.activeWorkout?.isPaused == true, onMinimize: onMinimize,
                              onDiscard: onDiscard, onSettings: onSettings, onUpcomingPhases: onUpcomingPhases)
                .screenPadding().padding(.top, NoopMetrics.space2)
            if model.workoutAutomaticallyPaused {
                Label("Automatically paused · move to resume", systemImage: "pause.circle")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary).screenPadding()
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let warning = model.workoutWarning, context.date.timeIntervalSince(warning.date) < 8 {
                    Label(warning.text, systemImage: "exclamationmark.circle")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.statusWarningForeground)
                        .screenPadding().accessibilityElement(children: .combine)
                }
            }
            Picker("Workout view", selection: $page) {
                Text("Metrics").tag(Page.metrics)
                Text("Zones").tag(Page.zones)
                Text("Laps").tag(Page.sections)
            }
            .pickerStyle(.segmented).screenPadding()
            #if os(iOS)
            TabView(selection: $page) {
                LiveWorkoutMetricsPage().tag(Page.metrics)
                LiveWorkoutZonesPage().tag(Page.zones)
                LiveWorkoutSectionsPage().tag(Page.sections)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            #else
            Group {
                switch page {
                case .metrics: LiveWorkoutMetricsPage()
                case .zones: LiveWorkoutZonesPage()
                case .sections: LiveWorkoutSectionsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
        }
    }
}
