import SwiftUI
import WhoopStore
import StrandAnalytics
import StrandDesign

// MARK: - Strength — what the Hevy log says, and nothing it doesn't
//
// The Workouts list answers "when did I train?". This screen answers what that list structurally
// cannot: what the sessions contained, whether the numbers are moving, which muscles are getting the
// work, and how a kind of session sits with the next morning.
//
// NO MATHS HAPPENS IN THIS FILE. Every figure comes from `StrengthSession` and
// `StrengthRecoveryResponse` (StrandAnalytics — pure, unit-tested, database-free), for the same reason
// `WeightDetailView` derives nothing itself: a second calculation in a view is how a screen starts
// disagreeing with the coach about the same training.
//
// ## Three numbers this screen refuses to invent
//
// It was designed from a mockup that showed a "Strength Load 72", a "Recovery Capacity 68", and a
// per-muscle target of "12 / 14". None of the three could be produced honestly, and each has a
// replacement that can:
//
//   • The per-muscle reference is the user's OWN p25–p75 band over their last completed weeks, drawn
//     as `TypicalRangeBar`'s hatch. NOOP has no evidence about anyone's correct weekly volume; it does
//     know what this person has been doing.
//   • "Strength Load" is the acute:chronic RATIO of working sets, in the same windows and the same
//     bands `ReadinessEngine` uses for heart-rate strain. A ratio says something checkable; a "72"
//     would be a number with no unit and nothing a reader could disagree with.
//   • "Recovery Capacity" is the week's mean Charge with the Readiness level beside it. The value
//     already existed and already had a name — inventing a fourth term for it is the "more scores
//     without explanation" this screen is meant to avoid.

struct StrengthView: View {
    @EnvironmentObject var repo: Repository

    /// Every session in the read window, newest first.
    @State private var workouts: [HevyWorkout] = []
    @State private var templates: [String: HevyExerciseTemplate] = [:]
    @State private var summaries: [StrengthSessionSummary] = []
    /// The mirrored `WorkoutRow`s, which is where the strap's heart rate lands — the "how did the body
    /// answer" half of the pairing this whole lane exists for.
    @State private var rows: [WorkoutRow] = []
    /// The outcome series the recovery analysis reads.
    @State private var chargeByDay: [String: Double] = [:]
    @State private var hrvByDay: [String: Double] = [:]
    @State private var sleepNeedByDay: [String: Double] = [:]
    /// Mean Charge and the Readiness level for the selected week.
    @State private var weekCharge: Double?
    @State private var weekEffort: Double?

    @State private var selectedTemplateId: String?
    @State private var loaded = false
    /// 0 = the week containing today; each step back is one Monday–Sunday week earlier. Same shape as
    /// `TrendsView`'s digest stepper, so the two navigate identically.
    @State private var weekOffset = 0
    @State private var infoTopic: InfoTopic?
    @State private var showingAllSessions = false

    /// How far back the screen reads. A quarter covers a training block and the eight-week bands.
    private let historyDays = 120
    private var tzOffset: Int { TimeZone.current.secondsFromGMT() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else if workouts.isEmpty {
                    emptyState
                } else {
                    thisWeek
                    muscleGroups
                    recoveryAfterTraining
                    exerciseProgress
                    recentSessions
                    actionRow
                }
            }
            .padding(NoopMetrics.screenPadding)
        }
        .navigationTitle(Text("Strength"))
        .safeAreaInset(edge: .top) { syncStatusBar }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let context = coachContext { CoachCardButton(context: context) }
            }
        }
        .sheet(item: $infoTopic) { topic in infoSheet(topic) }
        .sheet(isPresented: $showingAllSessions) { allSessionsSheet }
        .task { await loadIfNeeded() }
    }

    // MARK: - Sync status

    /// The line under the title: is this screen looking at current data?
    ///
    /// It leads to Data Sources rather than explaining itself here, because every question it raises
    /// ("why is nothing new?", "what failed?") is answered there and nowhere else.
    @ViewBuilder
    private var syncStatusBar: some View {
        let status = HevySyncState.load()
        if HevyCredentials.isConnected {
            NavigationLink(value: TabRoute.dataSources) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.lastError == nil ? StrandPalette.statusPositive
                                                      : StrandPalette.statusWarning)
                        .frame(width: 7, height: 7)
                    Text(status.lastError == nil
                         ? String(localized: "Hevy sync active")
                         : String(localized: "Hevy sync needs attention"))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(.horizontal, NoopMetrics.screenPadding)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Empty

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
            weekNavBar
            NoopCard {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                          spacing: 10) {
                    tile(icon: "dumbbell.fill", label: String(localized: "Sessions"),
                         value: "\(week.sessionCount)", tint: DomainTheme.effort.color)
                    tile(icon: "square.3.layers.3d", label: String(localized: "Hard sets"),
                         value: "\(week.workingSetCount)", tint: DomainTheme.effort.color)
                    tile(icon: "scalemass.fill", label: String(localized: "Volume"),
                         value: volumeText(week.volumeLoadKg), tint: DomainTheme.effort.color)
                    strengthLoadTile
                    cardioLoadTile
                    chargeTile
                }
            }
        }
    }

    /// Week navigation, matching `TrendsView`'s digest stepper exactly — same clamping, same Monday
    /// anchoring, so stepping a week means the same thing on both screens.
    private var weekNavBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Training").strandOverline()
                Text("This week").font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Button { stepWeek(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(weekOffset <= minWeekOffset)
                Text(weekRangeText)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
                Button { stepWeek(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(weekOffset >= 0)
            }
            .buttonStyle(.plain)
            .foregroundStyle(StrandPalette.accent)
        }
    }

    /// One tile of the weekly grid.
    ///
    /// Laid out here rather than with `StatTile`: that component's icon variant reserves its width for
    /// Today's two-column grid, and at three across every label truncated to "Sessi…" / "Hard…" —
    /// which is worse than a local layout, because a tile whose label cannot be read is a number with
    /// no name. The tokens are the design system's; only the arrangement is local.
    private func tile(icon: String, label: String, value: String,
                      tint: Color, caption: String? = nil,
                      info: InfoTopic? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                if let info { infoButton(info) }
            }
            Text(value)
                .font(StrandFont.number(24))
                .foregroundStyle(StrandPalette.textPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.75)
            if let caption {
                Text(caption)
                    .font(StrandFont.caption)
                    .foregroundStyle(tint)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(StrandPalette.surfaceInset,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)\(caption.map { ", " + $0 } ?? "")")
    }

    /// The acute:chronic ratio of working sets, AS OF the selected week rather than as of today.
    ///
    /// That distinction is the whole point of the stepper: reading a past week while the load figure
    /// silently describes the present would put two different weeks on one card and label them the same.
    @ViewBuilder
    private var strengthLoadTile: some View {
        let load = StrengthSession.setLoadRatio(workouts, asOf: weekEndDate, tzOffsetSeconds: tzOffset)
        tile(icon: "chart.bar.fill",
             label: String(localized: "Strength load"),
             value: load.map { String(format: "%.2f", $0.ratio) } ?? "—",
             tint: load.map { bandColor($0.band) } ?? StrandPalette.textTertiary,
             caption: load.map { bandLabel($0.band) } ?? String(localized: "needs 4 weeks"),
             info: .strengthLoad)
    }

    /// The week's cardiovascular Effort, stated beside the strength figure precisely so the two read as
    /// SEPARATE things. Lifting volume never becomes Effort, and a screen that showed only one number
    /// would invite exactly that conflation.
    @ViewBuilder
    private var cardioLoadTile: some View {
        tile(icon: "heart.fill",
             label: String(localized: "Cardio load"),
             value: weekEffort.map { String(format: "%.0f", $0) } ?? "—",
             tint: StrandPalette.effortColor,
             caption: String(localized: "Effort"),
             info: .cardioLoad)
    }

    /// Mean Charge for the week, named as Charge. The mockup called this "Recovery Capacity"; a fourth
    /// word for a number the app already has would be one more thing to learn and nothing more to know.
    @ViewBuilder
    private var chargeTile: some View {
        tile(icon: "battery.100percent",
             label: String(localized: "Charge"),
             value: weekCharge.map { "\(Int($0.rounded()))" } ?? "—",
             tint: StrandPalette.chargeColor,
             caption: String(localized: "average"),
             info: .charge)
    }

    // MARK: - Muscle groups

    private var muscleGroups: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack {
                SectionHeader("Muscle groups", overline: "This week")
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text("Working sets / your usual")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    infoButton(.muscleBands)
                }
            }
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    if muscleRows.isEmpty {
                        Text("No sessions in this week.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        ForEach(muscleRows, id: \.group) { row in muscleRow(row) }
                        if week.unattributedSetCount > 0 {
                            Text("\(week.unattributedSetCount) sets couldn't be matched to a muscle group — their exercise isn't in the synced catalogue yet.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("A set counts once, on its exercise's primary muscle. Secondary involvement is counted separately, never added in.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// One muscle-group row: name, the bar with the user's own band behind it, and the count.
    ///
    /// Laid out here rather than with `TypicalRangeRow` for the same reason as the tiles: that row
    /// reserves 96 pt for a label and uppercases it, which suits the sleep stages it was built for
    /// ("DEEP", "REM") and hyphenates "Hamstrings" across two lines. The BAR — the part that carries
    /// the meaning — is the shared `TypicalRangeBar`, unchanged.
    private func muscleRow(_ row: MuscleRow) -> some View {
        HStack(spacing: 10) {
            Text(row.group.label)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 104, alignment: .leading)
            TypicalRangeBar(value: row.fraction, typical: row.band,
                            color: DomainTheme.effort.color, height: 8)
            Text("\(row.sets)")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 26, alignment: .trailing)
            Text(row.usualText ?? "")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .frame(width: 62, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityText)
    }

    // MARK: - Recovery after training

    /// How the two kinds of session sit with the following morning.
    ///
    /// Everything here comes from `EffectRanker` through `StrengthRecoveryResponse`, including the
    /// refusal: below the group threshold the card says how many sessions are still missing rather than
    /// showing a number. There is no placeholder state — a figure on a health card is read as a
    /// measurement whatever caption sits above it.
    private var recoveryAfterTraining: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack {
                SectionHeader("Recovery after training", overline: "Your own record")
                Spacer(minLength: 8)
                Text("last 8 weeks")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            HStack(alignment: .top, spacing: 10) {
                recoveryCard(.upper)
                recoveryCard(.legs)
            }
            // Said once, under the pair, because the numbers invite the wrong reading otherwise.
            //
            // Each figure is a COMPARISON against the user's other training days, not the absolute cost
            // of a session — that is the whole reason rest days are not the control (they would make
            // every session look expensive by simply not being rest). With two kinds of session, each is
            // the other's control, so the two cards are one finding shown from both sides and their
            // numbers mirror. Two cards side by side otherwise read as two independent measurements.
            if recovery.hasAnyReading {
                Text("Each figure compares that kind of session with your OTHER training days — not with rest days. The two cards are the same comparison seen from both sides.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let sentence = comparisonSentence {
                NoopCard(padding: 12, tint: StrandPalette.chargeColor) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(StrandPalette.chargeColor)
                            .accessibilityHidden(true)
                        Text(sentence)
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The six measured responses, worked out ONCE.
    ///
    /// Computing these in `body` is the obvious way to write this section and the wrong one. Each call
    /// re-classifies every session — `summarize` over the whole history — and then runs three lags of
    /// Welch's t-test, and the section asks for ten of them (two cards x three outcomes, the comparison
    /// sentence, the framing line). SwiftUI re-evaluates a body whenever anything it touches changes,
    /// so that cost is paid on every scroll and every tap of the week stepper, on a screen whose input
    /// history only grows. None of it depends on view state: the inputs are the loaded sessions and the
    /// loaded day series, so the analysis belongs at the end of the load.
    struct RecoveryReadings: Equatable {
        var legs: [StrengthRecoveryResponse.Response] = []
        var upper: [StrengthRecoveryResponse.Response] = []
        var comparison: String?

        func triple(_ kind: StrengthSessionKind) -> [StrengthRecoveryResponse.Response] {
            kind == .legs ? legs : upper
        }
        /// Charge is the gate for the whole card, so it leads both triples.
        var hasAnyReading: Bool {
            (legs.first?.isReady ?? false) || (upper.first?.isReady ?? false)
        }
    }

    @State private var recovery = RecoveryReadings()

    private func recoveryCard(_ kind: StrengthSessionKind) -> some View {
        let triple = recovery.triple(kind)
        let charge = triple.first
        let hrv = triple.dropFirst().first
        let need = triple.dropFirst(2).first

        return NoopCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: kind == .legs ? "figure.strengthtraining.functional"
                                                     : "figure.arms.open")
                        .font(.system(size: 15))
                        .foregroundStyle(DomainTheme.effort.color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind == .legs ? "Legs" : "Upper body")
                            .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text(kind == .legs ? "quad & hamstring focus" : "push & pull sessions")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                if let charge, charge.isReady, let hrv, let need {
                    Divider().overlay(StrandPalette.hairline)
                    effectRow(String(localized: "Charge next day"), charge)
                    effectRow(String(localized: "HRV"), hrv)
                    effectRow(String(localized: "Sleep need"), need)
                    if let confidence = charge.effect?.confidence {
                        Text(confidenceText(confidence, sessions: charge.sessionCount))
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                } else if let charge {
                    Divider().overlay(StrandPalette.hairline)
                    Text(shortfallText(charge))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func effectRow(_ label: String, _ response: StrengthRecoveryResponse.Response) -> some View {
        let delta = response.effect?.effect.delta
        return HStack {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            if let delta {
                Text(signed(delta, outcome: response.outcome))
                    .font(StrandFont.subhead)
                    .foregroundStyle(costColor(delta, outcome: response.outcome))
            } else {
                Text("—").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    /// Which direction is the costly one — and it is NOT the same for every row.
    ///
    /// Lower Charge and lower HRV are costs, so a negative delta is the amber one. Sleep NEED runs the
    /// other way: needing MORE sleep after a session is the cost, and colouring "+22 min" green because
    /// the number went up would tell the reader the opposite of what happened. One shared rule for all
    /// three rows is how that mistake gets made.
    private func costColor(_ delta: Double, outcome: String) -> Color {
        let costly = outcome == "Sleep need" ? delta > 0 : delta < 0
        if abs(delta) < 0.5 { return StrandPalette.textSecondary }
        return costly ? StrandPalette.statusWarning : StrandPalette.statusPositive
    }

    // MARK: - Exercise progress

    private var exerciseProgress: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Exercise progress", overline: "Per movement")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    exercisePicker
                    if trend.count < 2 {
                        Text("Not enough sessions of this exercise yet to show a trend.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        // Side by side only where there is room for both.
                        //
                        // A 132pt column of facts beside the chart leaves it about 200pt on a phone,
                        // and `TrendChart` asks for five x-axis labels regardless of its width — so
                        // "Jun 21" and "Jul 5" ran into each other and the axis read "Jun 21Jul 5".
                        // Shortening the dates would have hidden that; the cause is the column, so on a
                        // compact width the facts go underneath and the chart gets the full card.
                        let chart = TrendChart(
                            points: e1rmPoints,
                            gradient: Gradient(colors: [DomainTheme.effort.color.opacity(0.35),
                                                        DomainTheme.effort.color]),
                            valueRange: e1rmRange,
                            height: 150,
                            valueFormat: { String(format: "%.0f kg", $0) },
                            dateFormat: { $0.formatted(date: .abbreviated, time: .omitted) },
                            accessibilityLabel: String(localized: "Estimated one-rep max trend"))
                        if isCompact {
                            chart
                            trendFacts
                        } else {
                            HStack(alignment: .top, spacing: 12) {
                                chart
                                trendFacts.frame(width: 132)
                            }
                        }
                        Text("Estimated 1RM (Epley) from each session's best working set — a projection, not a lift you performed. Sets above 12 reps are left out, because the estimate stops being reliable there.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var exercisePicker: some View {
        Menu {
            ForEach(StrengthSession.exerciseFrequency(workouts).prefix(30), id: \.templateId) { entry in
                Button {
                    selectedTemplateId = entry.templateId
                    recomputeTrend()
                } label: {
                    Text(exerciseTitle(entry.templateId) + "  ·  \(entry.sessions)×")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(selectedTemplateId.map(exerciseTitle) ?? String(localized: "Pick an exercise"))
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }

    /// The measured facts beside the modelled line. They need no caveat, which is exactly why they sit
    /// next to one that does.
    private var trendFacts: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let change = e1rmChangePercent {
                factRow(String(localized: "e1RM trend"),
                        chip: TrendChip(text: String(format: "%+.0f %%", change),
                                        color: change >= 0 ? StrandPalette.statusPositive
                                                           : StrandPalette.statusWarning))
            }
            if let best = trend.compactMap(\.heaviestSetKg).max() {
                factRow(String(localized: "Best set"),
                        text: bestSetText(best))
            }
            factRow(String(localized: "RPE"), text: rpeTrendText)
        }
    }

    private func factRow(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(text).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private func factRow(_ label: String, chip: TrendChip) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            chip
        }
    }

    // MARK: - Sessions

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack {
                SectionHeader("Recent sessions", overline: "Log")
                Spacer(minLength: 8)
                Button(String(localized: "Show all")) { showingAllSessions = true }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.accent)
                    .buttonStyle(.plain)
            }
            VStack(spacing: 8) {
                ForEach(summaries.prefix(4), id: \.workoutId) { sessionRow($0) }
            }
        }
    }

    private func sessionRow(_ s: StrengthSessionSummary) -> some View {
        NoopCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(DomainTheme.effort.color)
                        .accessibilityHidden(true)
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
                HStack(spacing: 6) {
                    SourceBadge("Hevy", tint: StrandPalette.zone2)
                    // Only when the strap actually covered the window. The badge is a claim about
                    // evidence, so it appears when there IS evidence and not because the row exists.
                    if matchedRow(s)?.avgHr != nil {
                        SourceBadge("Matched with WHOOP", tint: StrandPalette.statusPositive)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// One line per session. Volume states its coverage when it does not cover everything — "8,400 kg"
    /// over a session that was half bodyweight work would otherwise read as the whole story.
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
            var volume = String(localized: "\(HevySource.groupedKg(s.volumeLoadKg)) kg")
            if s.volumeSetCount < s.workingSetCount {
                volume += " (\(s.volumeSetCount)/\(s.workingSetCount))"
            }
            parts.append(volume)
        }
        if let rpe = s.meanRpe {
            parts.append(String(localized: "RPE \(String(format: "%.1f", rpe))"))
        }
        if let hr = matchedRow(s)?.avgHr {
            parts.append(String(localized: "\(hr) bpm avg"))
        }
        return parts.joined(separator: " · ")
    }

    private var allSessionsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(summaries, id: \.workoutId) { sessionRow($0) }
                }
                .padding(NoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(Text("All sessions"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingAllSessions = false }
                }
            }
        }
    }

    // MARK: - Actions

    /// Three ways on, all into paths that already exist. The middle one names the muscle group that is
    /// furthest below its own band — and is hidden entirely when there isn't one, because a question
    /// about a problem nobody has is worse than no button.
    private var actionRow: some View {
        HStack(spacing: 8) {
            actionButton(icon: "chart.bar.fill",
                         title: String(localized: "Analyse training"),
                         subtitle: String(localized: "your data in full")) {
                showingAllSessions = true
            }
            if let laggard = groupBelowItsBand {
                actionButton(icon: "questionmark.circle.fill",
                             title: String(localized: "Why is \(laggard.label.lowercased()) low?"),
                             subtitle: String(localized: "ask the coach")) {
                    askCoach(about: laggard)
                }
            }
            actionButton(icon: "list.bullet",
                         title: String(localized: "Adjust routine"),
                         subtitle: String(localized: "coach suggests, you send")) {
                askCoachForRoutine()
            }
        }
    }

    private func actionButton(icon: String, title: String, subtitle: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NoopCard(padding: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text(title).font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(subtitle).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Info sheets

    /// Every derived figure on this screen can be asked "where does that come from?".
    ///
    /// Without these the three tiles would be three new words with no explanation — which is the thing
    /// this screen was rebuilt to avoid, not something to add on the way.
    enum InfoTopic: String, Identifiable {
        case strengthLoad, cardioLoad, charge, muscleBands
        var id: String { rawValue }
    }

    private func infoButton(_ topic: InfoTopic) -> some View {
        Button { infoTopic = topic } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("What this means")
    }

    private func infoSheet(_ topic: InfoTopic) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    Text(infoTitle(topic))
                        .font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    Text(infoBody(topic))
                        .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(NoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { infoTopic = nil } }
            }
        }
    }

    private func infoTitle(_ topic: InfoTopic) -> String {
        switch topic {
        case .strengthLoad: return String(localized: "Strength load")
        case .cardioLoad:   return String(localized: "Cardio load")
        case .charge:       return String(localized: "Charge")
        case .muscleBands:  return String(localized: "Working sets / your usual")
        }
    }

    private func infoBody(_ topic: InfoTopic) -> String {
        switch topic {
        case .strengthLoad:
            return String(localized: "Your working sets over the last 7 days, divided by your average over the last 28. Around 1.0 means this week looks like your usual weeks; well above means you are ramping up faster than your body has been prepared for, well below means you are doing less than usual.\n\nIt is the same comparison NOOP makes for heart-rate load, in sets instead — the same windows, the same bands. It is a ratio, not a score: there is no scale to memorise, and you can check it against what you did.\n\nIt stays blank until there are four weeks of history, because a ratio taken from a fortnight mostly describes how little data there is.")
        case .cardioLoad:
            return String(localized: "The Effort your heart rate earned this week — the cardiovascular side, kept deliberately separate from your lifting.\n\nLifting volume never becomes Effort. A heavy session raises your heart rate and that heart rate is already in this number; the sets and kilos are not added on top. Showing the two figures side by side is how you can see which kind of load a week actually carried.")
        case .charge:
            return String(localized: "Your average Charge across this week — the same Charge as everywhere else in NOOP, not a new score.\n\nRead it beside the two load figures: a week of high load and falling Charge is a different week from one of high load and steady Charge, and that comparison is the reason all three sit together.")
        case .muscleBands:
            return String(localized: "The bar is this week's working sets for that muscle. The shaded band behind it is what YOU usually do — the middle half of your last eight training weeks.\n\nIt is not a target. NOOP has no way of knowing what your right weekly volume is, and a number from a textbook presented as your goal would be a guess wearing a uniform. What it can tell you is when a week is unusual for you, and that is what the band shows.\n\nWeeks with no training are left out, so a holiday does not drag the band down and then make your return look excessive.")
        }
    }

    // MARK: - Derived shapes

    private struct MuscleRow {
        let group: HevyMuscleGroup
        let sets: Int
        let band: ClosedRange<Double>?
        let fraction: Double
        let usualText: String?

        var accessibilityText: String {
            var parts = ["\(group.label): \(sets) working sets"]
            if let usualText { parts.append(usualText) }
            return parts.joined(separator: ", ")
        }
    }

    /// "usual 7" when the band has collapsed to one value, "usual 5–8" when it is a range.
    ///
    /// A steady lifter's quartiles genuinely coincide, and "usual 7–7" reads as a range that is not one
    /// — a small thing that makes the reader wonder what they are looking at.
    private static func usualText(_ band: ClosedRange<Double>) -> String {
        let lo = Int(band.lowerBound.rounded()), hi = Int(band.upperBound.rounded())
        return lo == hi
            ? String(localized: "usual \(lo)")
            : String(localized: "usual \(lo)–\(hi)")
    }

    private var week: StrengthSession.WeekSummary {
        StrengthSession.week(containing: weekAnchorDay, workouts: workouts,
                             templates: templates, tzOffsetSeconds: tzOffset)
    }

    private var typicalBands: [HevyMuscleGroup: ClosedRange<Double>] {
        StrengthSession.typicalWeeklySets(workouts, templates: templates,
                                          endingBefore: weekAnchorDay, tzOffsetSeconds: tzOffset)
    }

    /// Rows, busiest first. The bar's scale is the busiest group OR the top of its own band, whichever
    /// is larger, so a group sitting inside its band never renders as a full bar.
    private var muscleRows: [MuscleRow] {
        let current = week.setsByMuscle
        let bands = typicalBands
        let groups = Set(current.keys).union(bands.keys)
        guard !groups.isEmpty else { return [] }
        let scale = max(Double(current.values.max() ?? 0),
                        bands.values.map(\.upperBound).max() ?? 0, 1)
        return groups
            .map { group -> MuscleRow in
                let sets = current[group] ?? 0
                let band = bands[group]
                return MuscleRow(
                    group: group, sets: sets, band: band.map { ($0.lowerBound / scale)...($0.upperBound / scale) },
                    fraction: Double(sets) / scale,
                    usualText: band.map(Self.usualText))
            }
            .sorted { $0.sets == $1.sets ? $0.group.rawValue < $1.group.rawValue : $0.sets > $1.sets }
    }

    /// The group furthest BELOW its own band, if any. Drives the middle action button.
    private var groupBelowItsBand: HevyMuscleGroup? {
        muscleRows
            .compactMap { row -> (HevyMuscleGroup, Double)? in
                guard let band = typicalBands[row.group], band.lowerBound > 0,
                      Double(row.sets) < band.lowerBound else { return nil }
                return (row.group, band.lowerBound - Double(row.sets))
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// Runs the analysis. Static and parameterised so it takes no view state and can be called from the
    /// load before the corresponding `@State` has been assigned.
    private static func readings(workouts: [HevyWorkout],
                                 templates: [String: HevyExerciseTemplate],
                                 charge: [String: Double], hrv: [String: Double],
                                 sleepNeed: [String: Double],
                                 tzOffsetSeconds: Int) -> RecoveryReadings {
        // Charge FIRST in each triple: it is the gate the card checks and the series the comparison
        // sentence is built from.
        let outcomes: [(String, [String: Double])] =
            [("Charge", charge), ("HRV", hrv), ("Sleep need", sleepNeed)]
        func triple(_ kind: StrengthSessionKind) -> [StrengthRecoveryResponse.Response] {
            outcomes.map { name, series in
                StrengthRecoveryResponse.response(kind: kind, outcome: name, workouts: workouts,
                                                  templates: templates, outcomeByDay: series,
                                                  tzOffsetSeconds: tzOffsetSeconds)
            }
        }
        let legs = triple(.legs)
        let upper = triple(.upper)
        var readings = RecoveryReadings(legs: legs, upper: upper, comparison: nil)
        if let l = legs.first, let u = upper.first {
            readings.comparison = StrengthRecoveryResponse.comparison(legs: l, upper: u)
        }
        return readings
    }

    private var comparisonSentence: String? { recovery.comparison }

    @State private var trend: [ExercisePerformancePoint] = []

    private var e1rmPoints: [TrendPoint] {
        trend.compactMap { point in
            point.bestE1RMKg.map {
                TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(point.startTs)), value: $0)
            }
        }
    }

    private var e1rmRange: ClosedRange<Double> {
        let values = e1rmPoints.map(\.value)
        guard let lo = values.min(), let hi = values.max(), hi > lo else { return 0...100 }
        let pad = max(2.0, (hi - lo) * 0.25)
        return (lo - pad)...(hi + pad)
    }

    /// Percent change from the first estimate to the last, over the charted window.
    private var e1rmChangePercent: Double? {
        let values = e1rmPoints.map(\.value)
        guard let first = values.first, let last = values.last, first > 0, values.count >= 2 else {
            return nil
        }
        return (last - first) / first * 100
    }

    private func bestSetText(_ kg: Double) -> String {
        guard let point = trend.first(where: { $0.heaviestSetKg == kg }),
              point.workingSetCount > 0 else { return String(format: "%.1f kg", kg) }
        return String(format: "%.1f kg × %d", kg, point.totalReps / point.workingSetCount)
    }

    /// Rising / steady / easing, or an honest note when RPE was rarely logged. Compares the mean RPE of
    /// the first and last third of the window.
    private var rpeTrendText: String {
        let rated = trend.filter { $0.meanRpe != nil }
        guard rated.count >= 3 else { return String(localized: "rarely rated") }
        let third = max(1, rated.count / 3)
        let early = rated.prefix(third).compactMap(\.meanRpe)
        let late = rated.suffix(third).compactMap(\.meanRpe)
        guard !early.isEmpty, !late.isEmpty else { return String(localized: "rarely rated") }
        let delta = (late.reduce(0, +) / Double(late.count)) - (early.reduce(0, +) / Double(early.count))
        if abs(delta) < 0.5 { return String(localized: "steady") }
        return delta > 0 ? String(localized: "rising") : String(localized: "easing")
    }

    // MARK: - Wording

    private func volumeText(_ kg: Double) -> String {
        kg >= 1000 ? String(format: "%.1f t", kg / 1000) : "\(HevySource.groupedKg(kg)) kg"
    }

    private func bandLabel(_ band: ReadinessEngine.LoadBand) -> String {
        switch band {
        case .rampingDown:  return String(localized: "ramping down")
        case .steady:       return String(localized: "steady")
        case .buildingFast: return String(localized: "building fast")
        case .spiking:      return String(localized: "spiking")
        }
    }

    private func bandColor(_ band: ReadinessEngine.LoadBand) -> Color {
        switch band {
        case .rampingDown:  return StrandPalette.textSecondary
        case .steady:       return StrandPalette.statusPositive
        case .buildingFast: return StrandPalette.statusWarning
        case .spiking:      return StrandPalette.statusCritical
        }
    }

    /// A signed delta with the unit the outcome actually has. Charge is points, HRV milliseconds, sleep
    /// need minutes — one shared formatter would silently label all three the same.
    private func signed(_ delta: Double, outcome: String) -> String {
        switch outcome {
        case "HRV":        return String(format: "%+.0f ms", delta)
        case "Sleep need": return String(format: "%+.0f min", delta)
        default:           return String(format: "%+.0f", delta)
        }
    }

    private func confidenceText(_ confidence: ScoreConfidence, sessions: Int) -> String {
        String(localized: "from \(sessions) sessions · \(confidence.rawValue)")
    }

    /// What is still missing, in sessions. Names the CONTROL shortfall too — people expect to need more
    /// leg days and are surprised that the comparison also needs other training days.
    private func shortfallText(_ response: StrengthRecoveryResponse.Response) -> String {
        if response.missingSessions > 0 {
            return String(localized: "\(response.missingSessions) more sessions of this kind needed before NOOP can say anything.")
        }
        if response.missingControls > 0 {
            return String(localized: "\(response.missingControls) more sessions of the OTHER kind needed — the comparison is against your other training days, not your rest days.")
        }
        return String(localized: "Not enough overlap with your recovery data yet.")
    }

    private func exerciseTitle(_ id: String) -> String {
        templates[id]?.title
            ?? workouts.lazy.flatMap(\.exercises).first { $0.templateId == id }?.title
            ?? id
    }

    private func matchedRow(_ summary: StrengthSessionSummary) -> WorkoutRow? {
        rows.first { abs($0.startTs - summary.startTs) <= 3600 }
    }

    // MARK: - Week navigation

    private var earliestDay: String? {
        workouts.map { AnalyticsEngine.dayString($0.startTs, offsetSec: tzOffset) }.min()
    }

    private var minWeekOffset: Int {
        guard let earliest = earliestDay,
              let earliestMon = WeeklyDigestEngine.mondayOfWeek(containing: earliest),
              let thisMon = WeeklyDigestEngine.mondayOfWeek(containing: Repository.localDayKey(Date()))
        else { return 0 }
        var offset = 0
        var monday = thisMon
        while monday > earliestMon && offset > -520 {
            monday = WeeklyDigestEngine.addDays(monday, -7)
            offset -= 1
        }
        return offset
    }

    private var weekAnchorDay: String {
        WeeklyDigestEngine.addDays(Repository.localDayKey(Date()), weekOffset * 7)
    }

    /// The instant the selected week is read "as of": NOON on its Sunday, or now for the current week.
    /// Every week-scoped figure takes this, so stepping back cannot leave one tile describing the present.
    ///
    /// Noon, not the end of the day. `WeightSeries.date(forDay:)` already returns local noon, and adding
    /// a day's worth of seconds to it — which this did at first — lands at 11:59 the FOLLOWING morning.
    /// The whole acute window then slid forward by one day, and a week that exactly matched the user's
    /// average reported a ratio of 0.68. Mid-day is the anchor precisely because it cannot be pushed
    /// across a boundary by a timezone offset in either direction.
    private var weekEndDate: Date {
        guard let monday = WeeklyDigestEngine.mondayOfWeek(containing: weekAnchorDay),
              let sunday = WeightSeries.date(forDay: WeeklyDigestEngine.addDays(monday, 6)) else {
            return Date()
        }
        return min(sunday, Date())
    }

    private func stepWeek(_ delta: Int) {
        weekOffset = max(minWeekOffset, min(0, weekOffset + delta))
        Task { await refreshWeekScores() }
    }

    private var weekRangeText: String {
        guard let monday = WeeklyDigestEngine.mondayOfWeek(containing: weekAnchorDay),
              let start = WeightSeries.date(forDay: monday),
              let end = WeightSeries.date(forDay: WeeklyDigestEngine.addDays(monday, 6)) else {
            return weekAnchorDay
        }
        let format = Date.FormatStyle().day().month(.abbreviated)
        return "\(start.formatted(format)) – \(end.formatted(format))"
    }

    // MARK: - Coach

    private var coachContext: CoachCardContext? {
        guard loaded, let latest = summaries.first else { return nil }
        var parts: [String] = []
        parts.append("This week: \(week.sessionCount) sessions, \(week.workingSetCount) working sets")
        if week.volumeLoadKg > 0 { parts.append("volume \(volumeText(week.volumeLoadKg))") }
        let muscles = muscleRows.prefix(4)
            .map { row in row.usualText.map { "\(row.group.label) \(row.sets) (\($0))" }
                       ?? "\(row.group.label) \(row.sets)" }
            .joined(separator: ", ")
        if !muscles.isEmpty { parts.append("hard sets — " + muscles) }
        if let load = StrengthSession.setLoadRatio(workouts, asOf: weekEndDate,
                                                   tzOffsetSeconds: tzOffset) {
            parts.append(String(format: "set load acute:chronic %.2f (%@)", load.ratio,
                                bandLabel(load.band)))
        }
        if let rpe = latest.meanRpe {
            parts.append(String(format: "last session mean RPE %.1f", rpe))
        }
        return CoachCardContext(
            title: String(localized: "Strength"),
            summary: parts.joined(separator: " · "),
            suggestions: [
                String(localized: "Is my volume where it should be?"),
                String(localized: "Which muscle group am I neglecting?"),
                String(localized: "How is my strength progressing?"),
            ])
    }

    private func askCoach(about group: HevyMuscleGroup) {
        guard var context = coachContext else { return }
        context = CoachCardContext(
            title: String(localized: "Strength"),
            summary: context.summary,
            suggestions: [String(localized: "Why is my \(group.label.lowercased()) volume below my usual?")])
        openCoach(with: context)
    }

    private func askCoachForRoutine() {
        guard let context = coachContext else { return }
        openCoach(with: CoachCardContext(
            title: String(localized: "Strength"),
            summary: context.summary,
            suggestions: [String(localized: "Draft me a routine that fixes my weak spots")]))
    }

    /// The same hand-off `CoachCardButton` performs, reused rather than reimplemented so a card opened
    /// from a button and one opened from this row reach the coach identically.
    private func openCoach(with context: CoachCardContext) {
        coach.openedFromCard(context)
        NotificationCenter.default.post(name: .noopOpenCoachCard, object: nil)
    }

    @EnvironmentObject private var coach: AICoachEngine

    /// iPhone portrait. macOS and iPad report `.regular`, so the wide layout stays the default there.
    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

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
        rows = (try? await store.workouts(deviceId: HevySource.id, from: from, to: now + 86_400,
                                          limit: 500)) ?? []

        // The outcome series the recovery analysis reads. `repo.days` is already loaded; sleep need is
        // a metric series, so it needs its own bounded read.
        var charge: [String: Double] = [:]
        var hrv: [String: Double] = [:]
        for day in repo.days {
            if let value = day.recovery { charge[day.day] = value }
            if let value = day.avgHrv { hrv[day.day] = value }
        }
        chargeByDay = charge
        hrvByDay = hrv
        let needRows = await repo.series(key: "sleep_need_min", source: Repository.whoopSource,
                                         days: historyDays)
        sleepNeedByDay = Dictionary(needRows.map { ($0.day, $0.value) },
                                    uniquingKeysWith: { _, last in last })

        recovery = Self.readings(workouts: sessions, templates: catalogue, charge: charge, hrv: hrv,
                                 sleepNeed: sleepNeedByDay, tzOffsetSeconds: tzOffset)

        selectedTemplateId = StrengthSession.exerciseFrequency(sessions).first?.templateId
        recomputeTrend()
        await refreshWeekScores()
        loaded = true
    }

    private func recomputeTrend() {
        guard let id = selectedTemplateId else { trend = []; return }
        trend = StrengthSession.exerciseHistory(templateId: id, workouts: workouts,
                                                templates: templates, tzOffsetSeconds: tzOffset)
    }

    /// Mean Charge and total Effort for the SELECTED week — recomputed on each step so the tiles follow
    /// the chevrons rather than always describing today.
    private func refreshWeekScores() async {
        guard let monday = WeeklyDigestEngine.mondayOfWeek(containing: weekAnchorDay) else { return }
        let sunday = WeeklyDigestEngine.addDays(monday, 6)
        let inWeek = repo.days.filter { $0.day >= monday && $0.day <= sunday }
        let charges = inWeek.compactMap(\.recovery)
        weekCharge = charges.isEmpty ? nil : charges.reduce(0, +) / Double(charges.count)
        let efforts = inWeek.compactMap(\.strain)
        weekEffort = efforts.isEmpty ? nil : efforts.reduce(0, +)
    }
}
