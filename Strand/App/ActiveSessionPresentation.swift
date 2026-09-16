import SwiftUI
#if os(iOS)
import UIKit
#endif
import StrandDesign
import StrandTraining

/// Presents the one active session wherever it was started from: the full-screen logger or live
/// workout, the start choice, the collision and forgotten-session questions, and the summary.
/// Applied once to the app shell (`RootTabView` on iOS, `RootView` on macOS).
struct ActiveSessionPresentation: ViewModifier {
    @EnvironmentObject private var session: ActiveSessionController
    @EnvironmentObject private var app: AppModel

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .fullScreenCover(isPresented: $session.isPresented) { ActiveSessionScreen() }
            #else
            .sheet(isPresented: $session.isPresented) { ActiveSessionScreen().frame(minWidth: 620, minHeight: 720) }
            #endif
            .sheet(isPresented: $session.isChoosingStrengthStart) { StrengthStartSheet() }
            .sheet(item: $session.completedWorkout) { workout in
                StrengthWorkoutSummaryView(workout: workout, exercises: session.context.exercises,
                                           performance: session.context.performance)
            }
            .confirmationDialog(
                Text("A workout is already running"),
                isPresented: Binding(get: { session.pendingStart != nil },
                                     set: { if !$0 { session.pendingStart = nil } }),
                titleVisibility: .visible,
                presenting: session.pendingStart
            ) { pending in
                Button("Return to \(pending.runningTitle)") {
                    Task { await session.resolvePendingStart(pending, .returnToRunning) }
                }
                Button("Finish it and start") {
                    Task { await session.resolvePendingStart(pending, .finishAndStart) }
                }
                Button("Discard it and start", role: .destructive) {
                    Task { await session.resolvePendingStart(pending, .discardAndStart) }
                }
                Button("Cancel", role: .cancel) { session.pendingStart = nil }
            } message: { _ in
                Text("Only one workout can run at a time.")
            }
            .alert(
                Text("Unfinished workout"),
                isPresented: Binding(get: { session.staleDraft != nil },
                                     set: { if !$0 { session.staleDraft = nil } }),
                presenting: session.staleDraft
            ) { draft in
                Button("Save") { Task { await session.resolveStaleDraft(draft, .save) } }
                Button("Resume") { Task { await session.resolveStaleDraft(draft, .resume) } }
                Button("Discard", role: .destructive) { Task { await session.resolveStaleDraft(draft, .discard) } }
            } message: { draft in
                let started = Date(timeIntervalSince1970: TimeInterval(draft.startedAt))
                Text("\(draft.title) from \(started.formatted(date: .abbreviated, time: .shortened)) was never finished. Saving ends it at its last logged change.")
            }
            .alert(Text("Keep tracking in the background"), isPresented: $session.showsHealthBackgroundHint) {
                #if os(iOS)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                #endif
                Button("Not now", role: .cancel) {}
            } message: {
                Text("Your workout is recording. Allowing NOOP to share workouts with Apple Health lets iOS treat it as a running workout while you use other apps.")
            }
            .alert(Text("Workout"),
                   isPresented: Binding(get: { session.errorMessage != nil },
                                        set: { if !$0 { session.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(session.errorMessage ?? "") }
    }
}

extension View {
    func activeSessionPresentation() -> some View { modifier(ActiveSessionPresentation()) }
}

/// The full-screen content for the running session.
private struct ActiveSessionScreen: View {
    @EnvironmentObject private var session: ActiveSessionController
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if let strength = session.strength {
            NativeWorkoutLoggerView(model: strength, exercises: session.context.exercises,
                                    performance: session.context.performance)
        } else if app.activeWorkout != nil {
            LiveWorkoutView(onClose: { session.minimize() })
                .environmentObject(app.live)
        } else {
            Color.clear.onAppear { session.minimize() }
        }
    }
}

/// Freestyle or a routine. Shared by every entry that starts strength without its own plan choice.
struct StrengthStartSheet: View {
    @EnvironmentObject private var session: ActiveSessionController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await session.startStrength(routines: []) }
                    } label: {
                        Label("Freestyle workout", systemImage: "play.fill")
                            .font(StrandFont.headline)
                    }
                } footer: {
                    Text("Add exercises as you go.")
                }
                Section("Routines") {
                    if !session.contextLoaded {
                        HStack { ProgressView(); Text("Loading routines") }
                            .foregroundStyle(StrandPalette.textSecondary)
                    } else if session.context.plan.routines.isEmpty {
                        Text("No routines yet. Create one in the Training tab.")
                            .foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        ForEach(orderedRoutines, id: \.id) { routine in
                            Button {
                                Task { await session.startStrength(routines: [routine]) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(routine.title).font(StrandFont.headline)
                                            .foregroundStyle(StrandPalette.textPrimary)
                                        Text("\(routine.exercises.count) exercises")
                                            .font(StrandFont.caption)
                                            .foregroundStyle(StrandPalette.textSecondary)
                                    }
                                    Spacer()
                                    if todayIds.contains(routine.id) {
                                        Text("Today").font(StrandFont.caption.weight(.semibold))
                                            .foregroundStyle(StrandPalette.accent)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(Text("Strength workout"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task { await session.loadContextIfNeeded() }
    }

    private var todayIds: Set<UUID> {
        let date = Date()
        let weekday = TrainingHubModel.weekday(date)
        return Set(session.context.plan.routines(day: TrainingHubModel.dayString(date), weekday: weekday).map(\.id))
    }

    /// Today's scheduled routines first, then the rest in plan order.
    private var orderedRoutines: [TrainingRoutine] {
        let today = todayIds
        return session.context.plan.routines.filter { today.contains($0.id) }
            + session.context.plan.routines.filter { !today.contains($0.id) }
    }
}

/// The minimized running session: a bar above the tab bar on every tab.
struct ActiveSessionMiniBar: View {
    @EnvironmentObject private var session: ActiveSessionController

    var body: some View {
        if session.hasLiveSession, !session.isPresented {
            Group {
                if let strength = session.strength {
                    StrengthMiniBarContent(model: strength)
                } else {
                    CardioMiniBarContent()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { session.present() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Opens the running workout"))
        }
    }
}

private struct StrengthMiniBarContent: View {
    @ObservedObject var model: NativeWorkoutSessionModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = Int(context.date.timeIntervalSince1970)
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: "dumbbell.fill").foregroundStyle(StrandPalette.accent)
                if let timer = model.draft.timer, timer.kind != .timedSet {
                    let remaining = WorkoutTimerCoordinator.remaining(timer, now: now)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Rest").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        Text(ActiveSessionMiniBar.clock(remaining))
                            .font(StrandFont.headline.monospacedDigit())
                    }
                    Spacer()
                    Button("Skip") { model.skipRest() }
                        .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.draft.title).font(StrandFont.subhead.weight(.semibold)).lineLimit(1)
                        Text("\(completed) / \(total) sets")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                    if model.draft.state != .active {
                        Text("Paused").font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(StrandPalette.statusWarning)
                    }
                    Text(ActiveSessionMiniBar.clock(activeSeconds(now: now)))
                        .font(StrandFont.headline.monospacedDigit())
                    Image(systemName: "chevron.up").foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .padding(.horizontal, NoopMetrics.space3)
            .padding(.vertical, NoopMetrics.space2)
        }
    }

    private var completed: Int { model.draft.exercises.flatMap(\.sets).filter(\.isCompleted).count }
    private var total: Int { model.draft.exercises.flatMap(\.sets).count }

    private func activeSeconds(now: Int) -> Int {
        let pauses = (model.draft.pauseIntervals ?? []).map { ($0.startedAtTs, $0.endedAtTs ?? now) }
        return StrengthSessionHeartRate.activeSeconds(start: model.draft.startedAt, end: now, pauses: pauses)
    }
}

private struct CardioMiniBarContent: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: "figure.run").foregroundStyle(StrandPalette.accent)
                Text(app.activeWorkout?.sport ?? "").font(StrandFont.subhead.weight(.semibold)).lineLimit(1)
                Spacer()
                if app.activeWorkout?.isPaused == true {
                    Text("Paused").font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.statusWarning)
                }
                if let workout = app.activeWorkout {
                    Text(ActiveSessionMiniBar.clock(Int(workout.elapsed(at: context.date))))
                        .font(StrandFont.headline.monospacedDigit())
                }
                Image(systemName: "chevron.up").foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, NoopMetrics.space3)
            .padding(.vertical, NoopMetrics.space2)
        }
    }
}

extension ActiveSessionMiniBar {
    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3_600
            ? String(format: "%d:%02d:%02d", s / 3_600, (s % 3_600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

#if os(iOS)
/// Hosts the mini bar where iOS expects a persistent player-style control: the tab bar's bottom
/// accessory on iOS 26.1 and later, a card floating just above the tab bar before that.
private struct ActiveSessionMiniBarHost: ViewModifier {
    @EnvironmentObject private var session: ActiveSessionController

    func body(content: Content) -> some View {
        let visible = session.hasLiveSession && !session.isPresented
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: visible) { ActiveSessionMiniBar() }
        } else {
            content.overlay(alignment: .bottom) {
                if visible {
                    ActiveSessionMiniBar()
                        .background(StrandPalette.surfaceRaised, in: Capsule())
                        .overlay(Capsule().strokeBorder(StrandPalette.hairline, lineWidth: 1))
                        .padding(.horizontal, NoopMetrics.screenPadding)
                        .padding(.bottom, 58)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
}

extension View {
    func activeSessionMiniBar() -> some View { modifier(ActiveSessionMiniBarHost()) }
}
#endif
