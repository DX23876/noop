import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - Weight (v43) — the history behind the Today tile
//
// The Today tile answers "what do I weigh?" in one number. This screen answers the question that
// number cannot: which way is it going, and is that a real move or last night's dinner.
//
// Everything shown here is derived ONCE, in `WeightTrendSummary` (StrandAnalytics, pure and unit-
// tested), from the canonical `Repository.weightSeries()` — the union of weigh-ins logged in NOOP
// over Apple Health. No maths happens in this file: a second smoothing in a view is how a screen
// starts disagreeing with the goal card about the same body.
//
// The raw reading and the trend are shown as two DIFFERENT things, deliberately. The scale is not
// wrong when it reads 1.4 kg higher than yesterday — it is measuring water. Presenting the trend as
// "your weight" while hiding what was actually measured, or the reverse, would each be a lie of a
// different kind.

struct WeightDetailView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    @State private var entries: [WeightEntry] = []
    @State private var summary: WeightTrendSummary?
    @State private var chartPoints: [TrendPoint] = []
    /// The smoothed trend drawn over the weigh-ins — same fold as the headline number, so the line and
    /// the figure beside it can never disagree.
    @State private var trendPoints: [TrendPoint] = []
    @State private var loaded = false
    /// Drives the goal ring's draw-in; `BevelGauge` takes the animated value from its host.
    @State private var drawnProgress: Double = 0

    /// The goal store, observed so the ring appears the moment a weight goal is created elsewhere.
    @ObservedObject private var goalStore = CoachGoalStore.shared

    /// The entry being edited, or a fresh one when logging. Nil = no sheet.
    @State private var editing: WeightLogDraft?

    /// How far back the screen reads. Matches `GoalMeasure.weightWindowDays`' spirit for the summary
    /// while still showing a year of history in the list — a year of weigh-ins is a few hundred rows.
    private let historyDays = 365

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                headline
                if !chartPoints.isEmpty { chart }
                history
            }
            .padding(NoopMetrics.screenPadding)
        }
        .navigationTitle(Text("Weight"))
        .task { await loadIfNeeded() }
        .sheet(item: $editing) { draft in
            WeightLogSheet(draft: draft, unitSystem: unitSystem,
                           onSave: { kg, at, note in await save(draft: draft, kg: kg, at: at, note: note) },
                           onDelete: draft.isExisting ? { await delete(id: draft.id) } : nil)
        }
    }

    // MARK: - Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Weight", overline: "Body")
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    if let s = summary {
                        heroRow(s)
                        Divider().overlay(StrandPalette.hairline)
                        changeRow(s)
                        if !s.isTrendReliable { settlingNote }
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            logButton
        }
    }

    /// With an active weight goal the hero is a goal-progress ring; without one it stays the plain
    /// number pair. Body weight has no natural 0–100 domain, so a ring without a target would be
    /// decoration that implies a scale nobody set.
    @ViewBuilder
    private func heroRow(_ s: WeightTrendSummary) -> some View {
        if let goal = weightGoal, let baseline = goal.baseline, let target = goal.target {
            HStack(alignment: .center, spacing: 18) {
                goalGauge(s, baseline: baseline, target: target)
                VStack(alignment: .leading, spacing: 6) {
                    numberPair(s)
                }
                Spacer(minLength: 0)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                numberPair(s)
                Spacer()
            }
        }
    }

    /// The measured reading and the smoothed trend, always both and always labelled apart — the scale
    /// is not wrong when it disagrees with the trend, it is measuring water.
    private func numberPair(_ s: WeightTrendSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(UnitFormatter.massFromKilograms(s.latestKg, system: unitSystem))
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Last weigh-in \(relative(latestWeighInAt ?? s.latestAt))")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            if weightGoal == nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text(UnitFormatter.massFromKilograms(s.trendKg, system: unitSystem))
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("trend").font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    /// Progress from the goal's baseline to its target, read off the TREND — the same number goal
    /// tracking judges the goal on, so this ring and the Goals card cannot disagree.
    private func goalGauge(_ s: WeightTrendSummary, baseline: Double, target: Double) -> some View {
        let span = target - baseline
        let travelled = span == 0 ? 1 : (s.trendKg - baseline) / span
        return BevelGauge(
            fraction: min(1, max(0, travelled)),
            stops: StrandPalette.strainStops,
            tipColor: StrandPalette.metricAmber,
            numberText: UnitFormatter.massFromKilograms(s.trendKg, system: unitSystem),
            captionText: String(localized: "to \(UnitFormatter.massFromKilograms(target, system: unitSystem))"),
            stateText: s.isTrendReliable ? String(localized: "TREND") : String(localized: "SETTLING"),
            diameter: 132,
            lineWidth: 11,
            animatedFraction: drawnProgress,
            // Not yet a trustworthy trend ⇒ a dashed frame, the same signal the Energy card uses for
            // a modelled number.
            trackDash: s.isTrendReliable ? nil : [3, 5])
    }

    private func changeRow(_ s: WeightTrendSummary) -> some View {
        HStack(spacing: 8) {
            changePill(label: String(localized: "7 d"), delta: s.change7dKg)
            changePill(label: String(localized: "30 d"), delta: s.change30dKg)
            changePill(label: String(localized: "per week"), delta: s.ratePerWeekKg)
            Spacer(minLength: 0)
        }
    }

    /// One change figure as a pill. A missing one reads "—", never "0.0": a history too short to
    /// compare has no answer, and zero would claim a stability nobody measured.
    private func changePill(label: String, delta: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            StatePill(LocalizedStringKey(delta.map { signedMass($0) } ?? "—"),
                      tone: tone(for: delta), showsDot: false)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    /// Which way is "good"?
    ///
    /// **Only a goal can answer that.** Tinting weight loss green without knowing what the person is
    /// working toward is a value judgement the app has no business making — someone building mass
    /// would see their progress rendered as a warning. Without a goal every pill stays neutral, the
    /// same restraint `GoalSafetyGate` shows when it declines to judge a rate it cannot contextualise.
    private func tone(for delta: Double?) -> StrandTone {
        guard let delta, abs(delta) > 0.05,
              let goal = weightGoal, let target = goal.target, let baseline = goal.baseline,
              target != baseline else { return .neutral }
        let towardTarget = (target - baseline) > 0 ? delta > 0 : delta < 0
        return towardTarget ? .positive : .warning
    }

    /// The active weight goal, if there is one.
    private var weightGoal: CoachGoal? {
        goalStore.activeGoals.first { $0.kind == .weight }
    }

    private var settlingNote: some View {
        Text("The trend is still settling — a few more weigh-ins and it will follow real changes without chasing daily swings.")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No weigh-ins yet").font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Log one and NOOP will track the trend behind the daily ups and downs. Weigh-ins from Apple Health show up here too.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var logButton: some View {
        Button {
            editing = WeightLogDraft(seedKg: summary?.latestKg ?? profile.weightKg)
        } label: {
            Label("Log weight", systemImage: "plus.circle.fill")
                .font(StrandFont.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(StrandPalette.accent)
    }

    // MARK: - Chart

    private var chart: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Weigh-ins", trailing: String(localized: "last 90 days"))
            NoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    TrendChart(points: chartPoints,
                               gradient: Gradient(colors: [StrandPalette.accent.opacity(0.35),
                                                           StrandPalette.accent]),
                               valueRange: chartRange,
                               height: 200,
                               valueFormat: { UnitFormatter.massFromKilograms($0, system: unitSystem) },
                               dateFormat: { $0.formatted(date: .abbreviated, time: .omitted) },
                               accessibilityLabel: String(localized: "Weight trend"),
                               overlayPoints: trendPoints,
                               overlayColor: StrandPalette.textSecondary)
                    // The dashed line has no legend anywhere else on the screen, and an unexplained
                    // second line invites the reading "two metrics" rather than "one, smoothed".
                    if !trendPoints.isEmpty {
                        Text("Solid: what the scale said. Dashed: the trend.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
    }

    /// Fitted to the data with a little headroom, not a fixed 50…100: a person's weigh-ins span a few
    /// kilos, and a fixed axis would flatten every real move into a straight line.
    private var chartRange: ClosedRange<Double> {
        let values = chartPoints.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return 50...100 }
        let pad = max(1.0, (hi - lo) * 0.2)
        return (lo - pad)...(hi + pad)
    }

    // MARK: - History

    private var history: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("History", trailing: entries.isEmpty ? nil : "\(entries.count)")
            if entries.isEmpty {
                Text("Nothing logged yet.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(entries) { entry in historyRow(entry) }
                }
            }
        }
    }

    private func historyRow(_ entry: WeightEntry) -> some View {
        NoopCard(padding: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(UnitFormatter.massFromKilograms(entry.value, system: unitSystem))
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                    HStack(spacing: 6) {
                        Text(entry.takenAt?.formatted(date: .abbreviated, time: .shortened)
                             ?? entry.day)
                        Text("·")
                        Text(sourceLabel(entry.source))
                    }
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    if let note = entry.note, !note.isEmpty {
                        Text(note).font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Spacer()
                if entry.isEditable {
                    Button { editing = WeightLogDraft(entry: entry) } label: {
                        Image(systemName: "pencil").foregroundStyle(StrandPalette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Edit weigh-in"))
                }
            }
        }
        // Apple-imported days carry no edit affordance at all: the measurement lives in Health, and a
        // delete button that deletes nothing is worse than no button.
        .contentShape(Rectangle())
        .onTapGesture { if entry.isEditable { editing = WeightLogDraft(entry: entry) } }
    }

    private func sourceLabel(_ source: WeightSource) -> String {
        switch source {
        case .manual:      return String(localized: "Logged in NOOP")
        case .appleHealth: return String(localized: "Apple Health")
        }
    }

    // MARK: - Formatting

    /// A change, always signed, so "−0.3 kg" and "+0.3 kg" are never mistaken for one another.
    private func signedMass(_ kg: Double) -> String {
        let formatted = UnitFormatter.massFromKilograms(abs(kg), system: unitSystem)
        if kg > 0.05 { return "+" + formatted }
        if kg < -0.05 { return "−" + formatted }
        return formatted
    }

    /// When the newest weigh-in was taken, for the caption under the hero.
    ///
    /// NOT `summary.latestAt`: the summary is derived from the DAILY series, whose day keys are
    /// anchored at noon (so a timezone shift cannot move a reading onto the neighbouring day). For the
    /// trend maths that anchor is right and invisible; as a caption it is a bug — a weigh-in logged at
    /// 00:51 read "in 11 hours", a measurement in the future. The history list carries the real
    /// instant, so prefer it, and clamp what's left to the past for the same reason.
    private var latestWeighInAt: Date? {
        guard let summary else { return nil }
        return entries.first?.takenAt ?? min(summary.latestAt, Date())
    }

    private func relative(_ date: Date) -> String {
        min(date, Date()).formatted(.relative(presentation: .named))
    }

    // MARK: - Load & mutate

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        await reload()
    }

    /// Animate the goal ring in once the summary has landed.
    private func animateGoalRing(_ s: WeightTrendSummary?) {
        guard let s, let goal = weightGoal,
              let baseline = goal.baseline, let target = goal.target, target != baseline else {
            drawnProgress = 0
            return
        }
        let travelled = min(1, max(0, (s.trendKg - baseline) / (target - baseline)))
        withAnimation(.easeOut(duration: 0.6)) { drawnProgress = travelled }
    }

    private func reload() async {
        let series = await repo.weightSeries(days: historyDays)
        let dated = series.compactMap { point -> (date: Date, value: Double)? in
            WeightSeries.date(forDay: point.day).map { ($0, point.value) }
        }
        summary = WeightTrendSummary.summarize(dated)
        // The chart shows the last 90 days of what the scale actually said; the trend figure above it
        // is the smoothed read of the same series.
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        chartPoints = dated.filter { $0.date >= cutoff }.map { TrendPoint(date: $0.date, value: $0.value) }
        // Smoothed over the FULL window, then windowed for display: folding only the last 90 days
        // would restart the EWMA at the window edge and draw a trend that climbs out of nowhere.
        trendPoints = WeightTrendSummary.smoothedSeries(dated)
            .filter { $0.date >= cutoff }
            .map { TrendPoint(date: $0.date, value: $0.value) }
        entries = await repo.weightEntries(days: historyDays)
        animateGoalRing(summary)
    }

    private func save(draft: WeightLogDraft, kg: Double, at: Date, note: String?) async {
        if draft.isExisting {
            _ = await repo.updateWeight(id: draft.id, kg: kg, at: at, note: note)
        } else {
            _ = await repo.logWeight(kg: kg, at: at, note: note)
        }
        // The Apple Health mirror is NOT called here: the repository posts `.noopWeightLogged` and
        // `StrandiOSApp` writes the sample under the weigh-in's own day. One observer for every write
        // path keeps future writers from having to repeat this call site.
        await syncProfileWeight()
        await reload()
    }

    private func delete(id: String) async {
        _ = await repo.deleteWeight(id: id)
        await syncProfileWeight()
        await reload()
    }

    /// Keep `ProfileStore.weightKg` — which HR zones and the calorie model read — on the newest
    /// measurement. Assigned only when it actually changed, so the iOS `profile.$weightKg` publisher
    /// (which writes back to Health) does not fire a second, redundant write for the one this screen
    /// just made itself.
    private func syncProfileWeight() async {
        guard let latest = await repo.latestWeightKg(), latest > 10 else { return }
        if abs(profile.weightKg - latest) > 0.005 { profile.weightKg = latest }
    }
}

// MARK: - Draft

/// What the sheet edits: a new weigh-in or an existing one. `Identifiable` so `.sheet(item:)` can
/// present it, which also guarantees the sheet is rebuilt when the user taps a different row.
struct WeightLogDraft: Identifiable {
    let id: String
    let kg: Double
    let at: Date
    let note: String?
    /// False for a brand-new weigh-in — the sheet hides Delete and the save path inserts.
    let isExisting: Bool

    /// A fresh weigh-in, seeded with the last known weight so the field starts somewhere sensible
    /// rather than empty.
    init(seedKg: Double) {
        self.id = UUID().uuidString
        self.kg = seedKg
        self.at = Date()
        self.note = nil
        self.isExisting = false
    }

    init(entry: WeightEntry) {
        self.id = entry.id
        self.kg = entry.value
        self.at = entry.takenAt ?? WeightSeries.date(forDay: entry.day) ?? Date()
        self.note = entry.note
        self.isExisting = true
    }
}

// MARK: - Log sheet

/// One screen, no wizard: a number, when it was taken, an optional note. Entering a weight should
/// cost one tap more than opening the app.
struct WeightLogSheet: View {
    let draft: WeightLogDraft
    let unitSystem: UnitSystem
    let onSave: (Double, Date, String?) async -> Void
    /// Nil for a new weigh-in — there is nothing to delete yet.
    let onDelete: (() async -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var at: Date = Date()
    @State private var note: String = ""
    @State private var saving = false

    /// The typed value converted back to kilograms, or nil when it isn't a usable number. Accepts a
    /// comma decimal separator: a German keyboard's number pad offers "," and rejecting it would make
    /// the field feel broken for half the shipped locales.
    private var parsedKg: Double? {
        let normalised = text.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let entered = Double(normalised), entered > 0 else { return nil }
        let kg = unitSystem == .imperial ? entered / UnitFormatter.poundsPerKilogram : entered
        // Same plausibility bounds the trend fold applies, so a value the maths would silently drop
        // can't be saved in the first place.
        return GoalMeasure.isPlausible(kg, cfg: GoalMeasure.weightTrend) ? kg : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Weight", text: $text)
                            .font(StrandFont.title2)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                        Text(UnitFormatter.massUnit(unitSystem))
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    DatePicker("When", selection: $at, in: ...Date())
                } footer: {
                    if !text.isEmpty && parsedKg == nil {
                        Text("Enter a weight between \(Int(GoalMeasure.weightTrend.minVal)) and \(Int(GoalMeasure.weightTrend.maxVal)) kg.")
                            .foregroundStyle(StrandPalette.metricAmber)
                    }
                }
                Section("Note") {
                    TextField("Optional", text: $note, axis: .vertical)
                }
                if let onDelete {
                    Section {
                        Button(role: .destructive) {
                            Task { saving = true; await onDelete(); dismiss() }
                        } label: {
                            Text("Delete weigh-in").frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle(Text(draft.isExisting ? "Edit weigh-in" : "Log weight"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let kg = parsedKg else { return }
                        Task {
                            saving = true
                            await onSave(kg, at, note.isEmpty ? nil : note)
                            dismiss()
                        }
                    }
                    .disabled(parsedKg == nil || saving)
                }
            }
        }
        .onAppear {
            let shown = unitSystem == .imperial ? UnitFormatter.kgToPounds(draft.kg) : draft.kg
            text = String(format: "%.1f", shown)
            at = draft.at
            note = draft.note ?? ""
        }
    }
}
