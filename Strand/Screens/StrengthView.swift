import SwiftUI
import WhoopStore
import StrandAnalytics
import StrandDesign

// MARK: - Strength — what the Hevy log says, and nothing it doesn't
//
// The Workouts list answers "when did I train?". This screen answers what that list structurally
// cannot: what the sessions contained, whether the numbers are moving, and which muscles are actually
// getting the work.
//
// NO MATHS HAPPENS IN THIS FILE. Every figure comes from `StrengthSession` (StrandAnalytics — pure,
// unit-tested, database-free), for the same reason `WeightDetailView` derives nothing itself: a second
// calculation in a view is how a screen starts disagreeing with the coach about the same training.
//
// WHAT IS DELIBERATELY ABSENT is as much the design as what is here. There is no strength score, no
// "readiness to lift" number, and no relationship drawn between a session and the next morning's
// Charge. The first two would be invented; the third is a real question that needs the statistics to
// answer it (`EffectRanker`, already in the tree) rather than two lines on a chart and a reader left
// to infer causation. Both are follow-on work, not something to fake here.

struct StrengthView: View {
    @EnvironmentObject var repo: Repository

    /// Sessions in the window, newest first.
    @State private var workouts: [HevyWorkout] = []
    @State private var templates: [String: HevyExerciseTemplate] = [:]
    @State private var summaries: [StrengthSessionSummary] = []
    /// The exercise whose trend is charted. Defaults to the most-trained movement, which is the one a
    /// lifter is most likely to be tracking.
    @State private var selectedTemplateId: String?
    @State private var trend: [ExercisePerformancePoint] = []
    @State private var loaded = false

    /// How far back the screen reads. A quarter is enough to see a training block and cheap to load —
    /// a few hundred sessions at most, each a handful of rows.
    private let historyDays = 90
    /// The window the muscle-group tally covers. Weekly is the unit strength training is actually
    /// prescribed in, so a "this week" number is the one that can be acted on.
    private let muscleWindowDays = 7

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else if workouts.isEmpty {
                    emptyState
                } else {
                    thisWeek
                    exerciseTrend
                    recentSessions
                }
            }
            .padding(NoopMetrics.screenPadding)
        }
        .navigationTitle(Text("Strength"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let context = coachContext { CoachCardButton(context: context) }
            }
        }
        .task { await loadIfNeeded() }
    }

    /// What the coach is handed when "Ask coach" is tapped here (#P11).
    ///
    /// Built from figures this screen has ALREADY derived — nothing new is computed, and no raw set
    /// leaves the device beyond the compact line the coach could fetch through its own tools anyway.
    /// Without it the user would have to retype what they are looking at, which is the whole reason the
    /// card-context entry exists.
    ///
    /// Nil until the screen has something to talk about: an "ask coach" button over an empty screen
    /// promises a conversation neither side can have.
    private var coachContext: CoachCardContext? {
        guard loaded, let latest = summaries.first else { return nil }
        var parts: [String] = []
        parts.append("Last session \(Date(timeIntervalSince1970: TimeInterval(latest.startTs)).formatted(date: .abbreviated, time: .omitted)): "
                     + "\(latest.workingSetCount) working sets across \(latest.exerciseCount) exercises")
        if latest.volumeLoadKg > 0 {
            parts.append("volume \(HevySource.groupedKg(latest.volumeLoadKg)) kg")
        }
        if let rpe = latest.meanRpe {
            parts.append(String(format: "mean RPE %.1f over %d of %d sets", rpe,
                                latest.rpeSetCount, latest.workingSetCount))
        }
        let week = weeklyMuscles.prefix(4)
            .map { "\($0.group.label) \($0.primary)" }
            .joined(separator: ", ")
        if !week.isEmpty { parts.append("hard sets this week — " + week) }
        if let id = selectedTemplateId, let point = trend.last, let e1rm = point.bestE1RMKg {
            let title = templates[id]?.title ?? id
            parts.append(String(format: "%@ estimated 1RM %.1f kg", title, e1rm))
        }
        return CoachCardContext(
            title: String(localized: "Strength"),
            summary: parts.joined(separator: " · "),
            suggestions: [
                String(localized: "Is my volume where it should be?"),
                String(localized: "Which muscle group am I neglecting?"),
                String(localized: "How is my bench progressing?"),
            ])
    }

    // MARK: - Empty

    /// Two different "nothing here" states, because they need two different things from the reader.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Strength", overline: "Training")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    if HevyCredentials.isConnected {
                        Text("No strength sessions in the last \(historyDays) days.")
                            .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text("Hevy is connected. Sessions appear here after the next sync.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        Text("Connect Hevy to see your lifting here.")
                            .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text("NOOP reads your sets, reps, weights and RPE from Hevy and shows them beside what your strap measured. Data Sources → Hevy.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - This week

    private var thisWeek: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("This week", overline: "Training",
                          trailing: String(localized: "hard sets per muscle"))
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    if weeklyMuscles.isEmpty {
                        Text("No sessions in the last 7 days.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        ForEach(weeklyMuscles, id: \.group) { row in
                            muscleRow(row)
                        }
                        // Named rather than hidden: a per-muscle chart that silently omits part of the
                        // week reads as complete when it is not.
                        if weeklyUnattributed > 0 {
                            Text("\(weeklyUnattributed) sets couldn't be matched to a muscle group — their exercise isn't in the synced catalogue yet.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // The convention, stated where the numbers are, not buried in a help screen.
                        Text("A set counts once, on the exercise's primary muscle. Secondary involvement is shown separately, not added in.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func muscleRow(_ row: MuscleRow) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Text(row.group.label)
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 96, alignment: .leading)
            // Proportional to the busiest group this week, not to a prescribed target: NOOP has no
            // evidence for what any individual's target should be, and a bar drawn against an invented
            // one would read as a verdict.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.surfaceInset)
                    Capsule().fill(DomainTheme.effort.color)
                        .frame(width: max(2, geo.size.width * row.fraction))
                }
            }
            .frame(height: 8)
            Text("\(row.primary)")
                .font(StrandFont.number(15)).foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 28, alignment: .trailing)
            if row.secondary > 0 {
                Text("+\(row.secondary)")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .frame(width: 34, alignment: .leading)
                    .accessibilityLabel(Text("\(row.secondary) sets with this muscle as a secondary"))
            } else {
                Spacer().frame(width: 34)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - One exercise over time

    private var exerciseTrend: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Exercise", overline: "Progress", trailing: exercisePicker)
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    if trend.count < 2 {
                        Text("Not enough sessions of this exercise yet to show a trend.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        TrendChart(points: e1rmPoints,
                                   gradient: Gradient(colors: [DomainTheme.effort.color.opacity(0.35),
                                                               DomainTheme.effort.color]),
                                   valueRange: e1rmRange,
                                   height: 180,
                                   valueFormat: { String(format: "%.0f kg", $0) },
                                   dateFormat: { $0.formatted(date: .abbreviated, time: .omitted) },
                                   accessibilityLabel: String(localized: "Estimated one-rep max trend"))
                        // The caveat sits with the chart, not in a footnote: this line is a MODEL of a
                        // maximum the lifter never attempted, and reading it as a measurement is the
                        // mistake it invites.
                        Text("Estimated 1RM (Epley) from each session's best working set — a projection, not a lift you performed. Sets above 12 reps are left out, because the estimate stops being reliable there.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider().overlay(StrandPalette.hairline)
                        trendFacts
                    }
                }
            }
        }
    }

    /// The measured numbers under the modelled line: the heaviest set actually lifted, and what the
    /// effort felt like. These need no caveat, which is exactly why they are shown beside one that does.
    private var trendFacts: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let heaviest = trend.compactMap(\.heaviestSetKg).max() {
                factRow(String(localized: "Heaviest set"), String(format: "%.1f kg", heaviest))
            }
            if let latest = trend.last {
                factRow(String(localized: "Last session"),
                        "\(latest.workingSetCount) × \(latest.totalReps / max(latest.workingSetCount, 1)) "
                        + String(localized: "reps"))
                if let rpe = latest.meanRpe {
                    factRow(String(localized: "RPE last session"),
                            String(format: "%.1f", rpe) + " · \(latest.rpeSetCount)/\(latest.workingSetCount) "
                            + String(localized: "sets rated"))
                }
            }
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Text(value).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private var exercisePicker: String? {
        selectedTemplateId.flatMap { templates[$0]?.title }
            ?? selectedTemplateId.flatMap { id in
                workouts.lazy.flatMap(\.exercises).first { $0.templateId == id }?.title
            }
    }

    // MARK: - Sessions

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sessions", overline: "Recent", trailing: "\(summaries.count)")
            VStack(spacing: 8) {
                ForEach(summaries.prefix(20), id: \.workoutId) { sessionRow($0) }
            }
        }
    }

    private func sessionRow(_ s: StrengthSessionSummary) -> some View {
        NoopCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(s.title.isEmpty ? String(localized: "Strength session") : s.title)
                        .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Date(timeIntervalSince1970: TimeInterval(s.startTs))
                        .formatted(date: .abbreviated, time: .omitted))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Text(sessionDetail(s))
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// One line per session. Volume is stated with its coverage when it does not cover everything —
    /// "12 400 kg" over a session that was half bodyweight work would otherwise read as the whole story.
    private func sessionDetail(_ s: StrengthSessionSummary) -> String {
        var parts: [String] = []
        parts.append(s.workingSetCount == 1
                     ? String(localized: "1 working set")
                     : String(localized: "\(s.workingSetCount) working sets"))
        if s.exerciseCount > 0 {
            parts.append(s.exerciseCount == 1
                         ? String(localized: "1 exercise")
                         : String(localized: "\(s.exerciseCount) exercises"))
        }
        if s.volumeLoadKg > 0 {
            var volume = String(localized: "\(HevySource.groupedKg(s.volumeLoadKg)) kg volume")
            if s.volumeSetCount < s.workingSetCount {
                volume += " (\(s.volumeSetCount)/\(s.workingSetCount))"
            }
            parts.append(volume)
        }
        if let rpe = s.meanRpe {
            parts.append(String(localized: "RPE \(String(format: "%.1f", rpe))"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Derived shapes

    private struct MuscleRow {
        let group: HevyMuscleGroup
        let primary: Int
        let secondary: Int
        let fraction: Double
    }

    /// This week's per-muscle tally, busiest first.
    private var weeklyMuscles: [MuscleRow] {
        let cutoff = Int(Date().timeIntervalSince1970) - muscleWindowDays * 86_400
        let recent = workouts.filter { $0.startTs >= cutoff }
        guard !recent.isEmpty else { return [] }
        let tally = StrengthSession.hardSetsByMuscle(recent, templates: templates)
        let busiest = max(tally.primary.values.max() ?? 0, 1)
        return tally.primary
            .sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
            .map { MuscleRow(group: $0.key, primary: $0.value,
                             secondary: tally.secondary[$0.key] ?? 0,
                             fraction: Double($0.value) / Double(busiest)) }
    }

    private var weeklyUnattributed: Int {
        let cutoff = Int(Date().timeIntervalSince1970) - muscleWindowDays * 86_400
        return StrengthSession.hardSetsByMuscle(workouts.filter { $0.startTs >= cutoff },
                                                templates: templates).unattributed
    }

    private var e1rmPoints: [TrendPoint] {
        trend.compactMap { point in
            point.bestE1RMKg.map {
                TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(point.startTs)), value: $0)
            }
        }
    }

    /// Fitted with headroom rather than anchored at zero: a lifter's estimates span a few kilos over a
    /// block, and a 0-based axis would flatten every real gain into a flat line.
    private var e1rmRange: ClosedRange<Double> {
        let values = e1rmPoints.map(\.value)
        guard let lo = values.min(), let hi = values.max(), hi > lo else { return 0...100 }
        let pad = max(2.0, (hi - lo) * 0.25)
        return (lo - pad)...(hi + pad)
    }

    // MARK: - Loading

    private func loadIfNeeded() async {
        guard !loaded else { return }
        guard let store = await repo.storeHandle() else { loaded = true; return }
        let now = Int(Date().timeIntervalSince1970)
        let from = now - historyDays * 86_400

        let sessions = (try? await store.hevyWorkouts(from: from, to: now + 86_400)) ?? []
        let catalogue = (try? await store.hevyExerciseTemplates()) ?? [:]

        workouts = sessions
        templates = catalogue
        summaries = sessions.map { StrengthSession.summarize($0, templates: catalogue) }
        // The most-trained movement is the one most likely being tracked, so it is what the chart opens
        // on. The user can still be looking at a different one, hence the picker label.
        selectedTemplateId = StrengthSession.exerciseFrequency(sessions).first?.templateId
        if let id = selectedTemplateId {
            trend = StrengthSession.exerciseHistory(templateId: id, workouts: sessions,
                                                    templates: catalogue,
                                                    tzOffsetSeconds: TimeZone.current.secondsFromGMT())
        }
        loaded = true
    }
}
