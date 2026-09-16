import SwiftUI
import StrandAnalytics
import StrandDesign
import StrandTraining

// MARK: - Header

/// Where the session stands at a glance: active time without pauses, completed sets and progress.
struct WorkoutLoggerHeader: View {
    @ObservedObject var model: NativeWorkoutSessionModel

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack(alignment: .firstTextBaseline) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(ActiveSessionMiniBar.clock(model.activeSeconds(now: Int(context.date.timeIntervalSince1970))))
                            .font(StrandFont.number(34)).monospacedDigit()
                            .foregroundStyle(StrandPalette.textPrimary)
                            .accessibilityLabel(Text("Active time"))
                    }
                    if model.draft.state != .active {
                        Text("Paused").font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(StrandPalette.statusWarning)
                    }
                    Spacer()
                    if !model.isRetrospective {
                        Button { model.toggleWorkoutPause() } label: {
                            Image(systemName: model.draft.state == .active ? "pause.fill" : "play.fill")
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .background(StrandPalette.surfaceRaised, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .accessibilityLabel(Text(model.draft.state == .active ? "Pause" : "Resume"))
                    }
                }
                let done = model.completedSetCount, total = model.totalSetCount
                HStack {
                    Text("\(done) / \(total) sets")
                        .font(StrandFont.subhead.monospacedDigit())
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                }
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .tint(StrandPalette.chargeColor)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Live heart rate

/// Effort built up by the running strength session, read from the strap's stored heart rate for the
/// session window — the same source the finished workout uses — so it does not restart at zero when the
/// logger is reopened. Refreshed every 30 seconds while on screen, about as often as the strap flushes.
@MainActor
final class StrengthLiveEffort: ObservableObject {
    @Published private(set) var strain: Double?
    private var task: Task<Void, Never>?

    func start(repo: Repository, draft: @escaping () -> WorkoutDraft, profile: ProfileStore) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                let current = draft()
                let now = Int(Date().timeIntervalSince1970)
                let pauses = (current.pauseIntervals ?? []).map { ($0.startedAtTs, $0.endedAtTs ?? now) }
                let samples = StrengthSessionHeartRate.activeSamples(
                    await repo.hrSamples(from: current.startedAt, to: now, limit: 20_000), pauses: pauses)
                let value = StrainScorer.strain(samples, maxHR: Double(profile.hrMax),
                                                method: PuffinExperiment.effortMethod, sex: profile.sex)
                self?.strain = value
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Compact live heart rate for the strength logger, built from the same parts as the cardio live screen:
/// the value in its zone colour, the zone, the effort so far and the zone rail. A tap opens the full view.
/// It observes the 1 Hz heart-rate sources itself, so a new sample redraws this card and not the sets.
struct StrengthLiveHeartRatePanel: View {
    let provider: WorkoutPhysiologyProvider
    let sourceText: String
    @ObservedObject var watchFeed: WatchHeartRateFeed
    @ObservedObject var effort: StrengthLiveEffort
    @EnvironmentObject private var app: AppModel
    @State private var showingDetail = false

    private var bpm: Int? { provider == .appleWatch ? watchFeed.bpm : app.bpm }
    private var zone: Int { bpm.map { app.profile.hrZoneSet.zoneNumber(forBPM: Double($0)) } ?? 0 }

    var body: some View {
        Button { showingDetail = true } label: {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack(alignment: .center, spacing: NoopMetrics.space3) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            LiveHeartRateValue(bpm: bpm, zone: zone, size: 40)
                            Text("bpm").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                        if bpm != nil {
                            Text(LiveHeartRateStyle.zoneTitle(zone))
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(LiveHeartRateStyle.tint(zone: zone))
                        }
                    }
                    Spacer()
                    if effort.strain != nil { LiveEffortReadout(strain: effort.strain, size: 26) }
                }
                if bpm != nil { HeartRateZoneRail(zone: zone, compact: true) }
                Text(sourceText).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            .padding()
            .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Shows heart rate full screen"))
        .sheet(isPresented: $showingDetail) {
            StrengthLiveHeartRateDetail(bpm: bpm, zone: zone, strain: effort.strain, sourceText: sourceText)
                .presentationDetents([.medium, .large])
        }
    }
}

private struct StrengthLiveHeartRateDetail: View {
    let bpm: Int?
    let zone: Int
    let strain: Double?
    let sourceText: String

    var body: some View {
        VStack(spacing: NoopMetrics.sectionGap) {
            VStack(spacing: NoopMetrics.space1) {
                Text("HEART RATE").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                LiveHeartRateValue(bpm: bpm, zone: zone, size: 72)
                Text(LiveHeartRateStyle.zoneTitle(zone)).font(StrandFont.subhead)
                    .foregroundStyle(LiveHeartRateStyle.tint(zone: zone))
            }
            LiveEffortReadout(strain: strain, size: 48)
            HeartRateZoneRail(zone: zone)
            Text(sourceText).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(NoopMetrics.screenPadding)
    }
}

// MARK: - Effort

/// One choice in the effort picker: a value, its plain-language meaning and a colour from the zone scale,
/// so "how hard was that set" reads at a glance rather than as a bare number.
struct EffortChoice: Identifiable, Hashable {
    let value: Double
    let title: String
    let color: Color
    var id: Double { value }

    /// The same six levels on either scale: RPE is 10 minus reps in reserve.
    static func choices(for scale: TrainingEffortScale) -> [EffortChoice] {
        let levels: [(rir: Double, title: String, color: Color)] = [
            (0, String(localized: "Nothing left, went to failure"), StrandPalette.metricPurple),
            (0.5, String(localized: "Maybe half a rep left"), StrandPalette.zone5),
            (1, String(localized: "One more rep in the tank"), StrandPalette.zone4),
            (2, String(localized: "Two more reps"), StrandPalette.zone3),
            (3, String(localized: "Three more reps"), StrandPalette.zone2),
            (4, String(localized: "Easy, warm-up territory"), StrandPalette.zone1),
        ]
        return levels.map { level in
            EffortChoice(value: scale == .rir ? level.rir : 10 - level.rir, title: level.title, color: level.color)
        }
    }

    /// The index of the level nearest to a stored rating on its scale.
    static func level(for rating: TrainingEffortRating) -> Int {
        let values = choices(for: rating.scale).map(\.value)
        return values.indices.min { abs(values[$0] - rating.value) < abs(values[$1] - rating.value) } ?? 0
    }

    /// The colour for a stored rating, from the nearest level on its scale.
    static func color(for rating: TrainingEffortRating) -> Color {
        choices(for: rating.scale)[level(for: rating)].color
    }
}

/// A value on its effort colour: tinted fill, coloured edge and the normal text colour, which stays
/// readable on every level in light and dark appearance.
struct EffortBadge: View {
    let text: String
    let color: Color?

    var body: some View {
        Text(text)
            .font(StrandFont.subhead.weight(.bold).monospacedDigit())
            .foregroundStyle(color == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background((color ?? StrandPalette.surfaceRaised).opacity(color == nil ? 1 : 0.28),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color ?? .clear, lineWidth: 1.5))
    }
}

struct EffortPickerRequest: Identifiable {
    let exerciseIndex: Int
    let setIndex: Int
    let scale: TrainingEffortScale
    let current: TrainingEffortRating?
    var id: String { "\(exerciseIndex)-\(setIndex)" }
}

/// "How hard was that set?" — tap a described level, or set an exact value.
struct EffortPickerSheet: View {
    let request: EffortPickerRequest
    let onPick: (Double?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var exact: Double

    init(request: EffortPickerRequest, onPick: @escaping (Double?) -> Void) {
        self.request = request
        self.onPick = onPick
        _exact = State(initialValue: request.current?.value ?? (request.scale == .rir ? 2 : 8))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(EffortChoice.choices(for: request.scale)) { choice in
                        Button {
                            onPick(choice.value)
                            dismiss()
                        } label: {
                            HStack(spacing: NoopMetrics.space3) {
                                EffortBadge(text: choice.value.formatted(.number.precision(.fractionLength(0...1))),
                                            color: choice.color)
                                    .frame(width: 44, height: 32)
                                Text(choice.title).foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                if request.current?.value == choice.value {
                                    Image(systemName: "checkmark").foregroundStyle(StrandPalette.accent)
                                }
                            }
                        }
                    }
                } footer: {
                    Text(request.scale == .rir
                         ? "Reps in reserve: how many more clean reps you could have done."
                         : "Rate of perceived exertion: 10 means nothing was left.")
                }
                Section("Exact value") {
                    Stepper(value: $exact, in: request.scale == .rir ? 0...10 : 1...10, step: 0.5) {
                        Text(exact.formatted(.number.precision(.fractionLength(0...1)))).monospacedDigit()
                    }
                    Button("Use \(exact.formatted(.number.precision(.fractionLength(0...1))))") {
                        onPick(exact)
                        dismiss()
                    }
                }
                if request.current != nil {
                    Section {
                        Button("Clear rating", role: .destructive) {
                            onPick(nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(Text("How hard was that set?"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

// MARK: - Rest dock

/// The running rest or timed set, pinned above the bottom edge so it never scrolls away while logging.
struct WorkoutRestDock: View {
    let timer: WorkoutTimerState
    @ObservedObject var model: NativeWorkoutSessionModel
    let onFinished: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = Int(context.date.timeIntervalSince1970)
            let remaining = WorkoutTimerCoordinator.remaining(timer, now: now)
            let total = max(1, timer.endsAtTs - timer.startedAtTs)
            VStack(spacing: NoopMetrics.space2) {
                HStack(alignment: .center, spacing: NoopMetrics.space3) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(timer.kind == .timedSet ? "Time" : "Rest")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        Text(ActiveSessionMiniBar.clock(remaining))
                            .font(StrandFont.number(30)).monospacedDigit()
                            .accessibilityLabel(Text(timer.kind == .timedSet ? "Time remaining" : "Rest remaining"))
                    }
                    Spacer()
                    Button("−15") { model.adjustTimer(by: -15) }
                        .accessibilityLabel(Text("Subtract 15 seconds"))
                    Button("+15") { model.adjustTimer(by: 15) }
                        .accessibilityLabel(Text("Add 15 seconds"))
                    Button {
                        if timer.pausedRemainingSeconds == nil { model.pauseTimer() } else { model.resumeTimer() }
                    } label: {
                        Image(systemName: timer.pausedRemainingSeconds == nil ? "pause.fill" : "play.fill")
                    }
                    .accessibilityLabel(Text(timer.pausedRemainingSeconds == nil ? "Pause" : "Resume"))
                    Button(timer.kind == .timedSet ? "Finish" : "Skip") {
                        if timer.kind == .timedSet { model.finishTimedSet() } else { model.skipRest() }
                    }
                    .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                }
                .font(StrandFont.subhead.weight(.semibold))
                ProgressView(value: Double(total - remaining), total: Double(total))
                    .tint(StrandPalette.accent)
                    .accessibilityHidden(true)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(StrandPalette.hairline))
            .padding(.horizontal, NoopMetrics.screenPadding)
            .padding(.bottom, NoopMetrics.space2)
            .onChange(of: remaining == 0) { finished in
                if finished, timer.pausedRemainingSeconds == nil { onFinished() }
            }
        }
    }
}

// MARK: - Progression reason

/// Plain-language reason for a prefilled target, or nil where there is nothing worth saying.
enum ProgressionReasonText {
    static func text(_ reason: ProgressionReason) -> String? {
        switch reason {
        case .disabled, .firstSession: return nil
        case .repeatTarget: return String(localized: "Same target as last time")
        case .successfulSession: return String(localized: "Every rep last time, load goes up")
        case .topOfRepRange: return String(localized: "Top of the rep range, load goes up")
        case .exceptionalAMRAP: return String(localized: "Strong last set, bigger step up")
        case .stalledDeload: return String(localized: "Stalled, load goes down to rebuild")
        case .addRepetition: return String(localized: "One more rep than last time")
        case .addSet: return String(localized: "One more set than last time")
        case .addLoadOrVariation: return String(localized: "Ready for more load or a harder variation")
        case .addTime: return String(localized: "A little longer than last time")
        }
    }
}
