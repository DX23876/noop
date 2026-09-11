import SwiftUI
import WhoopStore
import StrandDesign
import StrandAnalytics

// MARK: - One session, exercise by exercise and set by set
//
// The gap this fills: until now nothing in NOOP could say what a session CONTAINED. The Strength screen
// summarised it ("18 working sets · 5 exercises · 8,400 kg"), the Workouts list carried the same line as
// a note, and anyone who wanted to know what they actually benched on Tuesday had to open Hevy.
//
// So this is deliberately a TRANSCRIPT first and an analysis second:
//
//   • every exercise in performance order, supersets grouped as they were performed,
//   • every set — including warmups, dimmed and marked, because a session that starts at its top set is
//     not the session that happened,
//   • the per-set estimate where one is defined, in the same "est." wording the rest of the lane uses,
//   • and the strap's answer beside it: what the heart rate did while the sets were being lifted.
//
// What it does NOT do is reconstruct anything the log does not hold. There are no rest times and no set
// timestamps, because Hevy records neither — inferring them from heart-rate peaks would draw a precise
// picture of something nobody measured.

struct StrengthSessionDetailView: View {
    let breakdown: StrengthSessionBreakdown
    /// The mirrored `WorkoutRow`, when the strap covered this window. Nil is a normal case, not an error.
    let matchedRow: WorkoutRow?

    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    /// The session's heart-rate curve, loaded from the strap trace over the exact window.
    @State private var hrPoints: [TrendPoint] = []
    /// Minutes per %HRmax zone over the same window, from the strap's own samples. Nil when the strap
    /// did not cover the session.
    @State private var zoneMinutes: [Double]?
    @State private var loadedHR = false
    @StateObject private var profile = ProfileStore()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    header
                    statStrip
                    heartRateCard
                    zonesCard
                    SessionRPECard(startTs: breakdown.startTs, sport: title,
                                   durationS: breakdown.durationS)
                    exercisesSection
                    if let notes = breakdown.notes, !notes.isEmpty { notesCard(notes) }
                    provenance
                }
                .padding(NoopMetrics.screenPadding)
                DemoScrollBottomAnchor()
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(Text(title))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                await loadHeartRate()
                await scrollToDemoBottom(proxy)
            }
            }
        }
    }

    private var title: String {
        breakdown.title.isEmpty ? String(localized: "Strength session") : breakdown.title
    }

    // MARK: - Header

    private var header: some View {
        NoopCard(tint: DomainTheme.effort.color) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DomainTheme.effort.color)
                    .frame(width: 44, height: 44)
                    .background(DomainTheme.effort.color.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(2)
                    Text(dateLine)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var dateLine: String {
        let start = Date(timeIntervalSince1970: TimeInterval(breakdown.startTs))
        let end = Date(timeIntervalSince1970: TimeInterval(breakdown.endTs))
        let day = start.formatted(date: .abbreviated, time: .omitted)
        let times = "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
        return "\(day) · \(times)"
    }

    // MARK: - Stats

    private var statStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: NoopMetrics.gap)],
                  alignment: .leading, spacing: NoopMetrics.gap) {
            StatTile(label: "Working sets",
                     value: "\(breakdown.summary.workingSetCount)",
                     caption: String(localized: "\(breakdown.summary.exerciseCount) exercises"),
                     accent: DomainTheme.effort.color)
            StatTile(label: "Volume",
                     value: volumeText(breakdown.summary.volumeLoadKg),
                     caption: volumeCoverage,
                     accent: StrandPalette.metricAmber)
            if breakdown.bodyweightVolumeKg > 0 {
                StatTile(label: "Bodyweight",
                         value: volumeText(breakdown.bodyweightVolumeKg),
                         caption: String(localized: "your own mass"),
                         accent: StrandPalette.metricCyan)
            }
            StatTile(label: "Duration",
                     value: durationText,
                     caption: densityCaption,
                     accent: StrandPalette.accent)
            if let rpe = breakdown.summary.meanRpe {
                StatTile(label: "Mean RPE",
                         value: String(format: "%.1f", rpe),
                         caption: String(localized: "\(breakdown.summary.rpeSetCount)/\(breakdown.summary.workingSetCount) rated"),
                         accent: StrandPalette.metricRose)
            }
            if let hr = matchedRow?.avgHr {
                StatTile(label: "Avg HR",
                         value: "\(hr)",
                         caption: matchedRow?.maxHr.map { String(localized: "max \($0)") } ?? "bpm",
                         accent: StrandPalette.metricRose)
            }
        }
    }

    /// Volume states its coverage whenever it does not cover the whole session — the same rule the
    /// summary line follows, for the same reason.
    private var volumeCoverage: String {
        let summary = breakdown.summary
        guard summary.volumeSetCount < summary.workingSetCount else {
            return String(localized: "weight × reps")
        }
        return String(localized: "\(summary.volumeSetCount) of \(summary.workingSetCount) sets")
    }

    private var durationText: String {
        guard let seconds = breakdown.durationS, seconds > 0 else { return "–" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return String(localized: "\(minutes) min") }
        return "\(minutes / 60):\(String(format: "%02d", minutes % 60)) h"
    }

    /// Work per minute — measured on both sides, and only offered when volume covers most of the
    /// session. Over a bodyweight day it would be a number about a third of the sets.
    private var densityCaption: String? {
        let summary = breakdown.summary
        guard summary.workingSetCount > 0,
              Double(summary.volumeSetCount) / Double(summary.workingSetCount) >= 0.6,
              let density = breakdown.densityKgPerMinute else { return nil }
        return String(localized: "\(HevySource.groupedKg(density)) kg/min")
    }

    // MARK: - Heart rate

    /// What the body did while the sets were being lifted.
    ///
    /// This is the pairing the whole Hevy lane exists for — Hevy says WHAT was done, the strap says how
    /// the body answered — and until now it appeared as three words on a list row. The curve is the
    /// strap's own samples over the exact session window; when the strap was not worn, the card simply
    /// does not appear.
    @ViewBuilder
    private var heartRateCard: some View {
        if hrPoints.count >= 3 {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Heart rate", overline: "What your body did",
                              trailing: matchedRow?.avgHr.map { String(localized: "avg \($0) bpm") })
                NoopCard(tint: StrandPalette.metricRose) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        TrendChart(points: hrPoints,
                                   gradient: Gradient(colors: [StrandPalette.metricRose.opacity(0.30),
                                                               StrandPalette.metricRose]),
                                   valueRange: hrRange,
                                   height: 130,
                                   valueFormat: { String(format: "%.0f bpm", $0) },
                                   dateFormat: { $0.formatted(date: .omitted, time: .shortened) },
                                   accessibilityLabel: String(localized: "Heart rate during the session"))
                        Text("Recorded by your strap over this session's window. Lifting never becomes Effort on its own — the heart rate here is already counted in the day's Effort, and the sets are not added on top.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else if loadedHR, matchedRow?.avgHr == nil {
            NoopCard {
                Label("No strap data covers this session — Hevy records the sets, not your heart rate.",
                      systemImage: "heart.slash")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var hrRange: ClosedRange<Double> {
        let values = hrPoints.map(\.value)
        guard let lo = values.min(), let hi = values.max(), hi > lo else { return 40...180 }
        let pad = max(5.0, (hi - lo) * 0.15)
        return max(30, lo - pad)...(hi + pad)
    }

    private func loadHeartRate() async {
        let source = matchedRow?.source ?? HevySource.id
        let buckets = await repo.workoutHrBuckets(from: breakdown.startTs, to: breakdown.endTs,
                                                  source: source)
        hrPoints = buckets.map {
            TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm)
        }
        zoneMinutes = await repo.workoutZoneMinutes(from: breakdown.startTs, to: breakdown.endTs,
                                                    zoneSet: profile.hrZoneSet, source: source)
        loadedHR = true
    }

    // MARK: - Zones

    /// Where the heart rate actually sat while the sets were being lifted.
    ///
    /// The same split the workout detail shows for a run, and it says something specific about a
    /// lifting session: a strength day that spent most of its minutes in zone 1–2 with brief spikes is
    /// what heavy, well-rested work looks like, while a session sitting in zone 3 for an hour was
    /// something closer to circuit training. NOTHING is scored from this — it is the measured split,
    /// derived from the strap's own samples over the session window.
    ///
    /// Never shown for an unmatched session: with no strap coverage there is nothing to split.
    @ViewBuilder
    private var zonesCard: some View {
        if let zones = zoneMinutes, zones.count == 5, zones.reduce(0, +) > 0 {
            let total = zones.reduce(0, +)
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("HR Zones", overline: "From strap HR",
                              trailing: String(localized: "\(Int(total.rounded()))m in zone"))
                NoopCard(tint: StrandPalette.effortColor) {
                    VStack(alignment: .leading, spacing: 12) {
                        GeometryReader { geo in
                            HStack(spacing: 2) {
                                ForEach(0..<5, id: \.self) { index in
                                    Rectangle()
                                        .fill(StrandPalette.hrZoneColor(index + 1))
                                        .frame(width: max(0, CGFloat(zones[index] / total) * geo.size.width))
                                }
                            }
                        }
                        .frame(height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(String(localized: "Heart-rate zone split: \((1...5).map { String(localized: "zone \($0) \(Int((zones[$0 - 1] / total * 100).rounded())) percent") }.joined(separator: ", "))"))
                        HStack(spacing: 0) {
                            ForEach(0..<5, id: \.self) { index in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                                            .fill(StrandPalette.hrZoneColor(index + 1))
                                            .frame(width: 9, height: 9)
                                        Text("Z\(index + 1)" as String).strandOverline()
                                    }
                                    Text("\(Int((zones[index] / total * 100).rounded()))%")
                                        .font(StrandFont.number(15))
                                        .foregroundStyle(StrandPalette.textPrimary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityElement(children: .combine)
                            }
                        }
                        Text("Time in each %HRmax zone over this session, from your strap's own samples (approximate). It is not scored into anything — a lifting session's Effort already comes from that same heart rate.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - The exercises

    private var exercisesSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("What you did", overline: "Exercise by exercise")
            ForEach(Array(breakdown.groups.enumerated()), id: \.offset) { _, group in
                if group.count > 1 {
                    supersetCard(group)
                } else if let block = group.first {
                    exerciseCard(block)
                }
            }
            if breakdown.unpricedBodyweightSetCount > 0 {
                Text("\(breakdown.unpricedBodyweightSetCount) bodyweight sets carry no volume figure — there is no weigh-in near this session to price them with.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A superset, kept as one card because that is how it was performed — and kept as separate blocks
    /// inside it because they are different movements.
    private func supersetCard(_ group: [StrengthExerciseBlock]) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Superset").strandOverline()
                }
                ForEach(Array(group.enumerated()), id: \.offset) { index, block in
                    if index > 0 { Divider().overlay(StrandPalette.hairline) }
                    exerciseBody(block)
                }
            }
        }
    }

    private func exerciseCard(_ block: StrengthExerciseBlock) -> some View {
        NoopCard { exerciseBody(block) }
    }

    private func exerciseBody(_ block: StrengthExerciseBlock) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(block.title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(muscleLine(block))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if let top = block.topSetKg {
                        // Signed for a bodyweight movement, exactly as its set rows are: an unsigned
                        // "11.6 kg" over a weighted dip reads as the whole load, when it is the plate
                        // that was hung on. The caption then names which number it is.
                        Text(topSetText(top, kind: block.kind))
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(block.kind.carriesBodyweight
                             ? String(localized: "top set, added")
                             : String(localized: "top set"))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    } else if block.workingSetCount > 0 {
                        Text("\(block.workingSetCount)×")
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("sets")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }

            VStack(spacing: 4) {
                ForEach(block.sets, id: \.index) { line in setRow(line, in: block) }
            }

            if let notes = block.notes, !notes.isEmpty {
                Text(notes)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Chest · also triceps, shoulders", or an honest note when the catalogue has not resolved it.
    private func muscleLine(_ block: StrengthExerciseBlock) -> String {
        guard let primary = block.primaryMuscle else {
            return String(localized: "Not in the exercise catalogue — its sets count, its muscles cannot")
        }
        var text = primary.label
        if !block.secondaryMuscles.isEmpty {
            text += " · " + String(localized: "also \(block.secondaryMuscles.map(\.label).joined(separator: ", "))")
        }
        return text
    }

    /// One set: number, what was lifted, RPE, and the estimate where one exists.
    ///
    /// A warmup is DIMMED and labelled rather than hidden. Hiding it would misrepresent the session;
    /// counting it would misrepresent the numbers. Both wrong in different directions, so the row shows
    /// it and every figure above continues to exclude it.
    private func setRow(_ line: StrengthSetLine, in block: StrengthExerciseBlock) -> some View {
        HStack(spacing: 10) {
            Text(line.isWorking ? "\(workingIndex(of: line, in: block))" : "W")
                .font(StrandFont.caption)
                .foregroundStyle(line.isWorking ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                .frame(width: 20, alignment: .center)
                .padding(.vertical, 3)
                .background(line.isWorking ? StrandPalette.surfaceInset : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(loadText(line, kind: block.kind))
                .font(StrandFont.subhead)
                .foregroundStyle(line.isWorking ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 4)

            if let rpe = line.rpe {
                Text(String(localized: "RPE \(String(format: "%.1f", rpe))"))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.metricRose)
            }
            if let estimate = line.e1rmKg, line.isWorking {
                // The ≈ carries the "this is an estimate" meaning, so the whole token is translatable
                // rather than a bare number with a symbol glued on in code.
                Text(String(localized: "≈\(Int(estimate.rounded()))"))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityLabel(String(localized: "estimated one-rep max \(Int(estimate)) kilograms"))
            }
            if line.type == .dropset || line.type == .failure {
                Text(setTypeLabel(line.type))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.accent)
            }
        }
        .padding(.vertical, 2)
        .opacity(line.isWorking ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }

    /// The heaviest working set, in the same notation its rows use.
    private func topSetText(_ kg: Double, kind: StrengthMovementKind) -> String {
        switch kind {
        case .assistedBodyweight: return String(format: "−%.1f kg", kg)
        case .weightedBodyweight, .bodyweightReps: return String(format: "+%.1f kg", kg)
        default: return String(format: "%.1f kg", kg)
        }
    }

    /// The set's number among the WORKING sets — what a lifter counts. Warmups carry a "W" instead.
    private func workingIndex(of line: StrengthSetLine, in block: StrengthExerciseBlock) -> Int {
        block.sets.filter { $0.isWorking && $0.index <= line.index }.count
    }

    /// What the set actually moved, in the units the movement is logged in.
    private func loadText(_ line: StrengthSetLine, kind: StrengthMovementKind) -> String {
        var parts: [String] = []
        if let weight = line.weightKg, weight > 0 {
            switch kind {
            case .assistedBodyweight: parts.append(String(format: "−%.1f kg", weight))
            case .bodyweightReps, .weightedBodyweight: parts.append(String(format: "+%.1f kg", weight))
            default: parts.append(String(format: "%.1f kg", weight))
            }
        } else if kind.carriesBodyweight, let load = line.bodyweightLoadKg {
            parts.append(String(format: "%.0f kg %@", load, String(localized: "bodyweight")))
        }
        if let reps = line.reps { parts.append("× \(reps)") }
        if let seconds = line.durationS, seconds > 0 {
            parts.append(seconds >= 60 ? String(localized: "\(Int(seconds / 60)) min")
                                       : String(localized: "\(Int(seconds)) s"))
        }
        if let distance = line.distanceM, distance > 0 {
            parts.append(String(format: "%.0f m", distance))
        }
        return parts.isEmpty ? String(localized: "logged") : parts.joined(separator: " ")
    }

    private func setTypeLabel(_ type: HevySetType) -> String {
        switch type {
        case .dropset: return String(localized: "drop")
        case .failure: return String(localized: "to failure")
        default:       return ""
        }
    }

    // MARK: - Notes & provenance

    private func notesCard(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Session note", overline: "From your log")
            NoopCard {
                Text(notes)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var provenance: some View {
        HStack(spacing: 6) {
            SourceBadge("Hevy", tint: StrandPalette.zone2)
            if matchedRow?.avgHr != nil {
                SourceBadge("Matched with WHOOP", tint: StrandPalette.statusPositive)
            }
            Spacer(minLength: 0)
        }
    }

    private func volumeText(_ kg: Double) -> String {
        kg >= 1000 ? String(format: "%.1f t", kg / 1000) : "\(HevySource.groupedKg(kg)) kg"
    }
}
