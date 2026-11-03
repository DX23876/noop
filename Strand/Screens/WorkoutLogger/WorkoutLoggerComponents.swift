import SwiftUI
import StrandAnalytics
import StrandDesign
import StrandTraining
import WhoopProtocol

// MARK: - Header

/// Where the session stands at a glance: active time without pauses, completed sets and progress.
struct WorkoutLoggerHeader<HeartRate: View>: View {
    @ObservedObject var model: NativeWorkoutSessionModel
    private let heartRate: HeartRate

    init(model: NativeWorkoutSessionModel, @ViewBuilder heartRate: () -> HeartRate) {
        self.model = model
        self.heartRate = heartRate()
    }

    /// One slim row of running figures, so the sets start high on the screen.
    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(alignment: .center, spacing: NoopMetrics.space3) {
                    let paused = model.draft.state != .active
                    WorkoutHeaderStat(title: paused ? String(localized: "Paused") : String(localized: "Duration"),
                                      titleColor: paused ? StrandPalette.statusWarningForeground : nil) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(ActiveSessionMiniBar.clock(model.activeSeconds(now: Int(context.date.timeIntervalSince1970))))
                                .accessibilityLabel(Text("Active time"))
                        }
                    }
                    WorkoutHeaderStat(title: String(localized: "Volume")) {
                        Text(TrainingPreferences.formattedVolume(model.completedVolumeKg))
                    }
                    WorkoutHeaderStat(title: String(localized: "Sets")) {
                        Text("\(model.completedSetCount)/\(model.totalSetCount)")
                    }
                    heartRate
                    Spacer(minLength: 0)
                    if !model.isRetrospective {
                        Button { model.toggleWorkoutPause() } label: {
                            Label(model.draft.state == .active ? "Pause" : "Resume",
                                  systemImage: model.draft.state == .active ? "pause.fill" : "play.fill")
                                .labelStyle(.iconOnly)
                                .font(.headline)
                                .frame(width: 40, height: 40)
                                .background(StrandPalette.surfaceInset, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                ProgressView(value: Double(model.completedSetCount), total: Double(max(model.totalSetCount, 1)))
                    .tint(StrandPalette.chargeColor)
                    .accessibilityHidden(true)
            }
        }
    }
}

#if DEBUG
/// Screenshot QA of the live logger (`--demo-logger`): a session with a heart rate and a few sets done.
enum WorkoutLoggerDemo {
    static let isOn = ProcessInfo.processInfo.arguments.contains("--demo-logger")
    static var trace: [HRSample] {
        let now = Int(Date().timeIntervalSince1970)
        return (0..<120).map { i in
            let phase = Double(i).truncatingRemainder(dividingBy: 24) / 24
            let bpm = phase < 0.3 ? 132 + 8 * sin(phase * 10) : 104 + 22 * (1 - phase)
            return HRSample(ts: now - (120 - i) * 12, bpm: Int(bpm))
        }
    }
}
#endif

/// The new design's head of a running session: the heart rate and the effort so far with the session's
/// trace, then the running figures. Without a heart-rate source only the figures remain.
struct ForgeLoggerHeartCard: View {
    let provider: WorkoutPhysiologyProvider
    let sourceText: String
    @ObservedObject var model: NativeWorkoutSessionModel
    @ObservedObject var watchFeed: WatchHeartRateFeed
    @ObservedObject var effort: StrengthLiveEffort
    @EnvironmentObject private var app: AppModel
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @State private var showingDetail = false

    private var bpm: Int? {
        #if DEBUG
        if WorkoutLoggerDemo.isOn { return 128 }
        #endif
        return provider == .appleWatch ? watchFeed.bpm : app.bpm
    }
    private var zone: Int { bpm.map { app.profile.hrZoneSet.zoneNumber(forBPM: Double($0)) } ?? 0 }

    private var effortText: String {
        guard let strain = effort.strain else { return "—" }
        let scale = UnitPrefs.resolveEffortScale(effortScaleRaw)
        let shown = UnitFormatter.effortValue(strain, scale: scale)
        // The same digits as the Effort ring on Today.
        return scale == .whoop ? UnitFormatter.localizedMark(String(format: "%.1f", shown)) : "\(Int(shown.rounded()))"
    }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                if provider != .none {
                    Button { showingDetail = true } label: { heartReadout }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Shows heart rate full screen"))
                        .sheet(isPresented: $showingDetail) {
                            StrengthLiveHeartRateDetail(bpm: bpm, zone: zone, strain: effort.strain, sourceText: sourceText)
                                .presentationDetents([.medium, .large])
                        }
                }
                figures
            }
        }
    }

    private var heartReadout: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    // "Live" only with a reading to show for it.
                    Group {
                        if bpm == nil { Text(sourceText) } else { Text("\(sourceText) · live") }
                    }
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        LiveHeartRateValue(bpm: bpm, zone: zone, size: 40)
                        Text(verbatim: "bpm")
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(LiveHeartRateStyle.tint(zone: zone))
                    }
                }
                Spacer(minLength: NoopMetrics.space2)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Effort so far")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text(effortText)
                        .font(StrandFont.rounded(28, weight: .semibold).monospacedDigit())
                        .foregroundStyle(StrandPalette.effortColor)
                }
            }
            .accessibilityElement(children: .combine)
            ForgeHeartTrace(samples: effort.trace)
                .frame(height: 44)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private var figures: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space4) {
            WorkoutHeaderStat(title: String(localized: "Volume")) {
                Text(TrainingPreferences.formattedVolume(model.completedVolumeKg))
            }
            WorkoutHeaderStat(title: String(localized: "Sets")) {
                Text("\(model.completedSetCount)/\(model.totalSetCount)")
            }
            Spacer(minLength: 0)
            if !model.isRetrospective {
                Button { model.toggleWorkoutPause() } label: {
                    Label(model.draft.state == .active ? "Pause" : "Resume",
                          systemImage: model.draft.state == .active ? "pause.fill" : "play.fill")
                        .labelStyle(.iconOnly)
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .background(StrandPalette.surfaceInset, in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }
}

/// The session's heart rate as one thin line. A gap in the stored samples stays a gap.
struct ForgeHeartTrace: View {
    let samples: [HRSample]

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1, let first = samples.first, let last = samples.last, last.ts > first.ts else { return }
            let low = Double(samples.map(\.bpm).min() ?? 0) - 4
            let high = Double(samples.map(\.bpm).max() ?? 0) + 4
            var path = Path()
            var previous: HRSample?
            for sample in samples {
                let x = size.width * Double(sample.ts - first.ts) / Double(last.ts - first.ts)
                let y = size.height * (1 - (Double(sample.bpm) - low) / max(1, high - low))
                let point = CGPoint(x: x, y: y)
                if let previous, sample.ts - previous.ts <= 120 { path.addLine(to: point) } else { path.move(to: point) }
                previous = sample
            }
            context.stroke(path, with: .color(StrandPalette.effortColor),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

/// A small caption over a figure, the unit of the logger's header row.
struct WorkoutHeaderStat<Value: View>: View {
    let title: String
    var titleColor: Color?
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(StrandFont.caption)
                .foregroundStyle(titleColor ?? StrandPalette.textTertiary)
                .lineLimit(1)
            value
                .font(StrandFont.number(17).monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Live heart rate

/// Effort built up by the running strength session, read from the strap's stored heart rate for the
/// session window — the same source the finished workout uses — so it does not restart at zero when the
/// logger is reopened. Refreshed every 30 seconds while on screen, about as often as the strap flushes.
@MainActor
final class StrengthLiveEffort: ObservableObject {
    @Published private(set) var strain: Double?
    /// The session's heart rate so far, thinned for a small trace on the new design's card.
    @Published private(set) var trace: [HRSample] = []
    private var task: Task<Void, Never>?

    func start(repo: Repository, draft: @escaping () -> WorkoutDraft, profile: ProfileStore) {
        task?.cancel()
        #if DEBUG
        if WorkoutLoggerDemo.isOn {
            trace = WorkoutLoggerDemo.trace
            strain = 42
            return
        }
        #endif
        task = Task { [weak self] in
            while !Task.isCancelled {
                let current = draft()
                let now = Int(Date().timeIntervalSince1970)
                let pauses = (current.pauseIntervals ?? []).map { ($0.startedAtTs, $0.endedAtTs ?? now) }
                let samples = StrengthSessionHeartRate.activeSamples(
                    await repo.hrSamples(from: current.startedAt, to: now, limit: 20_000), pauses: pauses)
                let value = StrainScorer.strain(samples, maxHR: Double(profile.hrMax), lowIntensity: .counted)
                self?.strain = value
                let stride = max(1, samples.count / 240)
                self?.trace = samples.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
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

    /// The live value as one more figure in the header row; nothing without a source. A tap opens the
    /// full view with the zone and the effort so far.
    var body: some View {
        if provider != .none {
            Button { showingDetail = true } label: {
                // The unit is the caption: "Herzfrequenz" would not fit beside three figures on a phone.
                WorkoutHeaderStat(title: "bpm") {
                    LiveHeartRateValue(bpm: bpm, zone: zone, size: 17)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Shows heart rate full screen"))
            .sheet(isPresented: $showingDetail) {
                StrengthLiveHeartRateDetail(bpm: bpm, zone: zone, strain: effort.strain, sourceText: sourceText)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

fileprivate struct StrengthLiveHeartRateDetail: View {
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
            .background((color ?? StrandPalette.surfaceInset).opacity(color == nil ? 1 : 0.28),
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
            .forgeListBackground()
            .navigationTitle(Text("How hard was that set?"))
            // A large title cut the question off ("Wie schwer war der S…") in a half-height sheet.
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
    /// The live trace the new design's rest page draws. Absent where no strap or watch feeds the session.
    var effort: StrengthLiveEffort?
    var provider: WorkoutPhysiologyProvider = .none
    var watchFeed: WatchHeartRateFeed?
    @State private var showsRestPage = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = Int(context.date.timeIntervalSince1970)
            let remaining = WorkoutTimerCoordinator.remaining(timer, now: now)
            let total = max(1, timer.endsAtTs - timer.startedAtTs)
            if NoopVisualStyle.skin == .forge {
                forgeDock(remaining: remaining, total: total)
            } else {
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
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).noopRestingRim())
            .padding(.horizontal, NoopMetrics.screenPadding)
            .padding(.bottom, NoopMetrics.space2)
            }
        }
    }

    /// The new design's dock: one slim row, the time left first and every control of the shipped dock.
    private func forgeDock(remaining: Int, total: Int) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            Button { showsRestPage = true } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(ActiveSessionMiniBar.clock(remaining))
                        .font(StrandFont.number(22)).monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                        .accessibilityLabel(Text(timer.kind == .timedSet ? "Time remaining" : "Rest remaining"))
                    Text(timer.kind == .timedSet ? "Time" : "Rest")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens the rest page"))
            .sheet(isPresented: $showsRestPage) {
                ForgeRestPage(model: model, effort: effort, provider: provider, watchFeed: watchFeed)
                    .presentationDetents([.large])
            }
            Spacer(minLength: 0)
            dockButton("−15") { model.adjustTimer(by: -15) }
                .accessibilityLabel(Text("Subtract 15 seconds"))
            dockButton("+15") { model.adjustTimer(by: 15) }
                .accessibilityLabel(Text("Add 15 seconds"))
            Button {
                if timer.pausedRemainingSeconds == nil { model.pauseTimer() } else { model.resumeTimer() }
            } label: {
                Image(systemName: timer.pausedRemainingSeconds == nil ? "pause.fill" : "play.fill")
                    .frame(width: 44, height: 44)
                    .background(StrandPalette.surfaceInset, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(StrandPalette.textPrimary)
            .accessibilityLabel(Text(timer.pausedRemainingSeconds == nil ? "Pause" : "Resume"))
            Button {
                if timer.kind == .timedSet { model.finishTimedSet() } else { model.skipRest() }
            } label: {
                // "Überspringen" has to fit beside the other controls.
                Text(timer.kind == .timedSet ? "Finish" : "Skip")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(StrandPalette.forgeOnAccent)
                    .padding(.horizontal, NoopMetrics.space3)
                    .frame(minHeight: 44)
                    .background(StrandPalette.forgeAccent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .font(StrandFont.subhead.weight(.semibold))
        .padding(.horizontal, NoopMetrics.space3)
        .padding(.vertical, NoopMetrics.space2)
        .background(alignment: .bottom) {
            GeometryReader { proxy in
                Capsule()
                    .fill(StrandPalette.accent)
                    .frame(width: proxy.size.width * Double(total - remaining) / Double(total), height: 3)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .accessibilityHidden(true)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).noopRestingRim())
        .padding(.horizontal, NoopMetrics.screenPadding)
        .padding(.bottom, NoopMetrics.space2)
    }

    private func dockButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(minWidth: 44, minHeight: 44)
                .background(StrandPalette.surfaceInset, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The rest at full size: the clock, what comes next, the heart settling, the same controls as the dock.
struct ForgeRestPage: View {
    @ObservedObject var model: NativeWorkoutSessionModel
    var effort: StrengthLiveEffort?
    var provider: WorkoutPhysiologyProvider = .none
    var watchFeed: WatchHeartRateFeed?
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    private var liveBpm: Int? {
        switch provider {
        case .none: return nil
        case .appleWatch: return watchFeed?.bpm
        default: return app.bpm
        }
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let timer = model.activeTimer {
                    content(timer, now: Int(context.date.timeIntervalSince1970))
                } else {
                    Text("Rest is over.")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .forgeScreenBackground()
            .navigationTitle(Text("Rest"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hide") { dismiss() } }
            }
        }
    }

    private func content(_ timer: WorkoutTimerState, now: Int) -> some View {
        let remaining = WorkoutTimerCoordinator.remaining(timer, now: now)
        let total = max(1, timer.endsAtTs - timer.startedAtTs)
        return ScrollView {
            VStack(spacing: NoopMetrics.gap) {
                Text(ActiveSessionMiniBar.clock(remaining))
                    .font(StrandFont.number(84).monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.top, NoopMetrics.space4)
                    .accessibilityLabel(Text("Rest remaining"))
                Text(caption(total: total))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(StrandPalette.surfaceInset)
                        Capsule().fill(StrandPalette.forgeAccent)
                            .frame(width: proxy.size.width * Double(total - min(remaining, total)) / Double(total))
                    }
                }
                .frame(height: 8)
                .accessibilityHidden(true)
                if let effort, effort.trace.count > 1 || liveBpm != nil {
                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            Text("Heart rate").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                            ForgeHeartTrace(samples: effort.trace)
                                .frame(height: 90)
                                .accessibilityHidden(true)
                            if let liveBpm {
                                Text(verbatim: "\(liveBpm) bpm")
                                    .font(StrandFont.subhead.monospacedDigit())
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack(spacing: NoopMetrics.space2) {
                    control("−15") { model.adjustTimer(by: -15) }
                        .accessibilityLabel(Text("Subtract 15 seconds"))
                    control("+15") { model.adjustTimer(by: 15) }
                        .accessibilityLabel(Text("Add 15 seconds"))
                    Button {
                        if timer.pausedRemainingSeconds == nil { model.pauseTimer() } else { model.resumeTimer() }
                    } label: {
                        Image(systemName: timer.pausedRemainingSeconds == nil ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityLabel(Text(timer.pausedRemainingSeconds == nil ? "Pause" : "Resume"))
                }
                Button {
                    if timer.kind == .timedSet { model.finishTimedSet() } else { model.skipRest() }
                    dismiss()
                } label: {
                    Text(timer.kind == .timedSet ? "Finish" : "Skip")
                        .font(StrandFont.subhead.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(StrandPalette.forgeOnAccent)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(StrandPalette.forgeAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(NoopMetrics.screenPadding)
        }
    }

    private func caption(total: Int) -> String {
        let length = ActiveSessionMiniBar.clock(total)
        guard let next = model.nextSetReadout else { return String(localized: "of \(length)") }
        return String(localized: "of \(length) · next: \(next.exercise)")
    }

    private func control(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(StrandFont.subhead.weight(.semibold).monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Progression reason

/// Plain-language reason for a prefilled target, or nil where there is nothing worth saying.
enum ProgressionReasonText {
    /// One or two words for the chip above the sets; the full sentence is `text`.
    static func short(_ reason: ProgressionReason) -> String? {
        switch reason {
        case .disabled, .firstSession: return nil
        case .repeatTarget: return String(localized: "Hold")
        case .successfulSession, .topOfRepRange, .exceptionalAMRAP: return String(localized: "Increase")
        case .stalledDeload: return String(localized: "Rebuild")
        case .addRepetition: return String(localized: "+1 rep")
        case .addSet: return String(localized: "+1 set")
        case .addLoadOrVariation: return String(localized: "Harder")
        case .addTime: return String(localized: "Longer")
        }
    }

    /// The arrow says which way the load moves: up, level or down.
    static func symbol(_ reason: ProgressionReason) -> String {
        switch reason {
        case .repeatTarget: return "equal"
        case .stalledDeload: return "arrow.down.right"
        default: return "arrow.up.right"
        }
    }

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
