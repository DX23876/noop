import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Live Activity shown on the Lock Screen and in the Dynamic Island: the running workout while a session is
/// live, otherwise the plain live-HR summary.
struct NOOPLiveActivity: Widget {
    /// The heart rate to draw: none once iOS has marked the banner stale. Each push is fresh for 30 s
    /// (`LiveActivityController.staleAfter`) and NOOP re-pushes a steady number well inside that, so a stale banner
    /// means the readings stopped — the strap off the wrist, or out of reach — even while NOOP itself is asleep and
    /// cannot say so: iOS redraws the banner at the stale date on its own.
    static func shownBpm(_ context: ActivityViewContext<NOOPActivityAttributes>) -> Int? {
        context.isStale ? nil : context.state.bpm
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NOOPActivityAttributes.self) { context in
            Group {
                if let workout = context.state.workout {
                    WorkoutActivityBanner(workout: workout, bpm: NOOPLiveActivity.shownBpm(context))
                } else {
                    LiveHeartRateBanner(context: context)
                }
            }
            .padding()
            .activityBackgroundTint(StrandPalette.surfaceBase)
            .activitySystemActionForegroundColor(StrandPalette.textPrimary)
            .widgetURL(context.state.workout == nil ? nil : WorkoutActivityLink.url)
        } dynamicIsland: { context in
            if let workout = context.state.workout {
                return workoutIsland(workout, bpm: NOOPLiveActivity.shownBpm(context))
            }
            return liveHeartRateIsland(context)
        }
    }

    private func workoutIsland(_ workout: NOOPActivityAttributes.Workout, bpm: Int?) -> DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                WorkoutHeartRate(bpm: bpm, zone: workout.zone, compact: false)
            }
            DynamicIslandExpandedRegion(.trailing) {
                WorkoutSecondaryStat(workout: workout).font(.headline)
            }
            DynamicIslandExpandedRegion(.center) {
                Text(workout.title).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            }
            DynamicIslandExpandedRegion(.bottom) {
                WorkoutClock(workout: workout, style: .large)
            }
        } compactLeading: {
            Image(systemName: WorkoutActivityLink.symbol(workout.kind))
                .foregroundStyle(StrandPalette.accent)
        } compactTrailing: {
            WorkoutClock(workout: workout, style: .compact)
        } minimal: {
            Image(systemName: WorkoutActivityLink.symbol(workout.kind))
                .foregroundStyle(StrandPalette.accent)
        }
        .widgetURL(WorkoutActivityLink.url)
    }

    private func liveHeartRateIsland(_ context: ActivityViewContext<NOOPActivityAttributes>) -> DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                Label("\(NOOPLiveActivity.shownBpm(context).map(String.init) ?? "–")", systemImage: "heart.fill")
                    .foregroundStyle(StrandPalette.statusCritical)
            }
            DynamicIslandExpandedRegion(.trailing) {
                // Charge + Effort (#446) — one more stat alongside the leading live HR.
                HStack(spacing: 10) {
                    if let r = context.state.recovery {
                        statColumn(label: "Charge", value: "\(r)%")
                    }
                    if let e = context.state.effort {
                        statColumn(label: "Effort", value: "\(e)")
                    }
                }
            }
            DynamicIslandExpandedRegion(.bottom) {
                Text(context.attributes.title).font(.caption).foregroundStyle(.secondary)
            }
        } compactLeading: {
            Image(systemName: "heart.fill").foregroundStyle(StrandPalette.statusCritical)
        } compactTrailing: {
            Text("\(NOOPLiveActivity.shownBpm(context).map(String.init) ?? "–")")
        } minimal: {
            Image(systemName: "heart.fill").foregroundStyle(StrandPalette.statusCritical)
        }
    }
}

/// Where a tap on the workout activity lands, and its symbol.
enum WorkoutActivityLink {
    static let url = URL(string: "noop://workout/active")

    static func symbol(_ kind: NOOPActivityAttributes.Workout.Kind) -> String {
        kind == .strength ? "dumbbell.fill" : "figure.run"
    }
}

private struct LiveHeartRateBanner: View {
    let context: ActivityViewContext<NOOPActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg")
                .font(.title2)
                .foregroundStyle(StrandPalette.statusCritical)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.title)
                    .font(.caption).foregroundStyle(StrandPalette.textSecondary)
                Text("\(NOOPLiveActivity.shownBpm(context).map(String.init) ?? "–") bpm")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer()
            // Charge + Effort (#446) on the banner, mirroring the Dynamic Island expanded stats.
            HStack(spacing: 12) {
                if let r = context.state.recovery {
                    bannerStat(label: "Charge", value: "\(r)%")
                }
                if let e = context.state.effort {
                    bannerStat(label: "Effort", value: "\(e)")
                }
            }
        }
    }
}

private struct WorkoutActivityBanner: View {
    let workout: NOOPActivityAttributes.Workout
    let bpm: Int?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: WorkoutActivityLink.symbol(workout.kind))
                .font(.title2)
                .foregroundStyle(StrandPalette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.title)
                    .font(.caption).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
                WorkoutClock(workout: workout, style: .large)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                WorkoutHeartRate(bpm: bpm, zone: workout.zone, compact: false)
                WorkoutSecondaryStat(workout: workout)
                    .font(.subheadline).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}

/// Elapsed time, frozen while paused, or the rest countdown while one runs. Both are counted by the system.
private struct WorkoutClock: View {
    enum Style { case large, compact }
    let workout: NOOPActivityAttributes.Workout
    let style: Style

    var body: some View {
        if let restEnds = workout.restEndsAt, restEnds > Date() {
            HStack(spacing: 4) {
                if style == .large {
                    Text("Rest").font(.caption.weight(.semibold)).foregroundStyle(StrandPalette.accent)
                }
                Text(timerInterval: Date()...restEnds, countsDown: true)
                    .monospacedDigit()
                    .font(font)
                    .foregroundStyle(StrandPalette.accent)
                    .frame(maxWidth: style == .compact ? 52 : nil)
            }
        } else if let paused = workout.pausedElapsedSeconds {
            HStack(spacing: 4) {
                Text(Self.clock(paused)).monospacedDigit().font(font)
                if style == .large {
                    Text("Paused").font(.caption.weight(.semibold)).foregroundStyle(StrandPalette.statusWarning)
                }
            }
        } else {
            Text(timerInterval: workout.elapsedAnchor...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .font(font)
                .frame(maxWidth: style == .compact ? 52 : nil)
        }
    }

    private var font: Font {
        style == .large ? .system(size: 26, weight: .bold, design: .rounded) : .caption.weight(.semibold)
    }

    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3_600
            ? String(format: "%d:%02d:%02d", s / 3_600, (s % 3_600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct WorkoutHeartRate: View {
    let bpm: Int?
    let zone: Int?
    let compact: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "heart.fill")
            Text(bpm.map { "\($0)" } ?? "–").monospacedDigit()
        }
        .font(.headline)
        .foregroundStyle(zone.map { StrandPalette.hrZoneColor($0) } ?? StrandPalette.statusCritical)
    }
}

/// Distance and pace for a route, sets for strength.
private struct WorkoutSecondaryStat: View {
    let workout: NOOPActivityAttributes.Workout

    var body: some View {
        if let done = workout.setsDone, let total = workout.setsTotal {
            Text("\(done) / \(total) sets").monospacedDigit()
        } else if let meters = workout.distanceM {
            Text(Self.distance(meters, pace: workout.paceSecPerKm)).monospacedDigit()
        }
    }

    static func distance(_ meters: Double, pace: Double?) -> String {
        let km = Measurement(value: meters / 1_000, unit: UnitLength.kilometers)
            .formatted(.measurement(width: .abbreviated, usage: .road,
                                    numberFormatStyle: .number.precision(.fractionLength(2))))
        guard let pace, pace.isFinite, pace > 0 else { return km }
        let seconds = Int(pace.rounded())
        return "\(km) · \(seconds / 60):\(String(format: "%02d", seconds % 60))/km"
    }
}

/// Lock-Screen banner stat column (label over value). File-scope because the `ActivityConfiguration`
/// content closure isn't a method of `NOOPLiveActivity`.
///
/// #759 - the label and value are CENTRE-aligned so each value sits directly under its own label. The
/// old `.trailing` alignment right-pinned both to the column's edge: when the value was narrower than
/// the label (e.g. "12" under "Effort") it drifted to the label's right edge instead of under it, which
/// read as "the number doesn't line up with its label". `fixedSize` stops either line truncating so the
/// pairing is never clipped at narrow widths.
@ViewBuilder
private func bannerStat(label: String, value: String) -> some View {
    VStack(alignment: .center, spacing: 2) {
        Text(label).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
        Text(value).font(.headline).foregroundStyle(StrandPalette.textPrimary)
    }
    .multilineTextAlignment(.center)
    .fixedSize()
}

/// Dynamic Island expanded-region stat column (label over value). File-scope for the same reason as
/// `bannerStat`. #759 - centre-aligned + `fixedSize` for the same value-under-its-label fix as the banner.
@ViewBuilder
private func statColumn(label: String, value: String) -> some View {
    VStack(alignment: .center, spacing: 1) {
        Text(label).font(.caption2).foregroundStyle(.secondary)
        Text(value).font(.headline)
    }
    .multilineTextAlignment(.center)
    .fixedSize()
}
