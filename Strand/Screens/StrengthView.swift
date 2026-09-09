import SwiftUI
import WhoopStore
import StrandAnalytics
import StrandDesign

// MARK: - Strength — what the Hevy log says, and nothing it doesn't
//
// The Workouts list answers "when did I train?". This screen answers what that list structurally
// cannot: what the sessions contained, whether the numbers are moving, and which muscles are getting
// the work.
//
// NO MATHS HAPPENS IN THIS FILE. Every figure comes from `StrengthSession` (StrandAnalytics — pure,
// unit-tested, database-free), for the same reason `WeightDetailView` derives nothing itself: a second
// calculation in a view is how a screen starts disagreeing with the coach about the same training.
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
//
// ## And one it USED to make
//
// This screen briefly carried a "Recovery after training" section that compared leg days with upper
// days against the next morning's Charge, HRV and sleep need. It was removed, along with its
// analytics and tests, for two reasons worth recording so it does not come back by accident.
//
// It could not be right for everyone: a session was classified as legs or upper by where more than
// half its working sets landed, so a full-body session belonged to neither and its lifter read "5
// more sessions of this kind needed" forever — a promise that waiting would help, when waiting never
// would. No fixed taxonomy fixes that, because the split is the lifter's decision, not ours.
//
// And it measured the axis with the least support. HRV shows a dose-response to VOLUME (it moves at
// about five sets per muscle group, not below), but a randomised crossover trial found no HRV
// difference between two very different leg protocols, with RMSSD back at baseline within thirty
// minutes despite lasting neuromuscular fatigue. "Which muscle" is the weakest thing to read a
// recovery signal from, and it was the thing the card read.
//
// What replaced it claims less: the muscle map below shows LOAD — sets done, and when — and says
// nothing about what that load cost. A per-muscle freshness percentage would need an assumed decay
// curve applied to everyone, which is the universal formula this project rules out.

struct StrengthView: View {
    @EnvironmentObject var repo: Repository

    /// Everything this screen shows and the work that derives it. See `StrengthModel` for why it is
    /// not twenty pieces of `@State` in here any more.
    ///
    /// Internal rather than private because the cards in `StrengthCards.swift` read it, and `private`
    /// in Swift is file-scoped.
    @StateObject var model = StrengthModel()

    @State private var mapFace: MuscleLoadMap.Face = .front
    @State private var mapMode: MapMode = .now
    @State private var selectedRegion: MuscleLoadMap.Region?
    /// The two questions the map can answer. They are genuinely different — "what is still on me" is
    /// about now, "what did this week hold" is about a week — so they get a switch rather than one
    /// blended number that answers neither.
    enum MapMode: String, CaseIterable, Identifiable {
        case now, week
        var id: String { rawValue }
        var label: String {
            switch self {
            case .now:  return String(localized: "Right now")
            case .week: return String(localized: "This week")
            }
        }
    }

    @State private var infoTopic: InfoTopic?
    @State private var showingAllSessions = false
    @State private var showingFullScreenMap = false
    /// The session the detail sheet is showing, by Hevy workout id.
    @State private var openSession: SessionTarget?
    struct SessionTarget: Identifiable, Equatable { let id: String }
    private struct ExerciseMappingTarget: Identifiable { let name: String; var id: String { name } }
    @State private var mappingExercise: ExerciseMappingTarget?
    @State private var mappingPrimary: HevyMuscleGroup = .other
    @State private var mappingSecondary: Set<HevyMuscleGroup> = []

    private var tzOffset: Int { TimeZone.current.secondsFromGMT() }

    // MARK: - The model, read as plain properties
    //
    // Thin proxies rather than `model.` at every use site: the rendering below is unchanged from when
    // these were `@State`, and a mechanical prefix on two hundred lines would have made the move
    // impossible to review for what it actually changed.

    private var workouts: [HevyWorkout] { model.workouts }
    private var templates: [String: HevyExerciseTemplate] { model.templates }
    private var summaries: [StrengthSessionSummary] { model.summaries }
    private var loaded: Bool { model.loaded }
    private var unmappedExercises: [String] { model.unmappedExercises }
    private var lastWorked: [HevyMuscleGroup: (day: String, startTs: Int, exercise: String)] { model.lastWorked }
    private var fatigueNow: [HevyMuscleGroup: Double] { model.fatigueNow }
    private var typicalSession: [HevyMuscleGroup: Double] { model.typicalSession }
    private var weekStimulus: [HevyMuscleGroup: Double] { model.weekStimulus }
    private var typicalWeek: [HevyMuscleGroup: Double] { model.typicalWeek }
    private var ratedShare: Double { model.ratedShare }
    private var weekCharge: Double? { model.weekCharge }
    private var weekEffort: Double? { model.weekEffort }
    private var trend: [ExercisePerformancePoint] { model.trend }
    private var weekOffset: Int { model.weekOffset }

    @ViewBuilder
    var body: some View {
        #if os(macOS)
        strengthContent
            .sheet(isPresented: $showingFullScreenMap) { fullScreenMuscleMap }
        #else
        strengthContent
            .fullScreenCover(isPresented: $showingFullScreenMap) { fullScreenMuscleMap }
        #endif
    }

    private var strengthContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else if workouts.isEmpty {
                    emptyState
                } else {
                    thisWeek
                    muscleGroups
                    balanceCard
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
        .sheet(item: $mappingExercise) { exercise in exerciseMappingSheet(exercise.name) }
        .sheet(item: $openSession) { target in detailSheet(workoutId: target.id) }
        .task(id: repo.refreshSeq) { await model.load(repo: repo) }
        // `onChange`, not a second `.task(id:)`: a `.task(id:)` also fires on first appearance, so two
        // of them meant every launch of this screen loaded the whole history twice.
        .onChangeCompat(of: model.range) { _ in
            Task { await model.load(repo: repo) }
        }
    }

    /// The session detail, however it was reached.
    @ViewBuilder
    private func detailSheet(workoutId: String) -> some View {
        if let breakdown = model.breakdown(for: workoutId) {
            StrengthSessionDetailView(breakdown: breakdown,
                                      matchedRow: model.matchedRow(for: breakdown.summary))
        }
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
                        Text("No strength sessions in the last \(model.range.days) days.")
                            .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text("Hevy is connected. Sessions appear here after the next sync.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        Text("Connect Hevy or import a lifting file to see your training here.")
                            .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text("NOOP reads sets, reps, weights and RPE from Hevy, Hevy CSV or Liftosaur and shows them beside what your strap measured.")
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
                // Three across: seven small facts to scan. See `tile(_:)` for why the shared
                // Today tile could not simply be dropped in here at this size.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                          spacing: 10) {
                    tile(icon: "dumbbell.fill", label: String(localized: "Sessions"),
                         value: "\(week.sessionCount)", tint: DomainTheme.effort.color)
                    tile(icon: "square.3.layers.3d", label: String(localized: "Hard sets"),
                         value: "\(week.workingSetCount)", tint: DomainTheme.effort.color)
                    tile(icon: "scalemass.fill", label: String(localized: "Volume"),
                         value: volumeText(week.volumeLoadKg), tint: DomainTheme.effort.color)
                    bodyweightTile
                    strengthLoadTile
                    cardioLoadTile
                    chargeTile
                }
            }
            if let progress = weekProgressText {
                Label(progress, systemImage: "hourglass")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
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
            rangePicker
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

    /// How far back the screen reads.
    ///
    /// It exists because the questions this screen gained cannot be answered inside a quarter: a record
    /// set last spring, or a strength trend over a year, simply was not visible when the window was a
    /// fixed 120 days. Reloading on a change rather than reading everything up front keeps the default
    /// cheap for the people who never touch it.
    private var rangePicker: some View {
        Menu {
            ForEach(StrengthModel.HistoryRange.allCases) { option in
                Button {
                    model.range = option
                } label: {
                    if model.range == option {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 10, weight: .semibold))
                Text(model.range.label)
                    .font(StrandFont.caption)
            }
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(StrandPalette.surfaceInset,
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "History window"))
    }

    /// One tile of the weekly grid — compact, and every one the same size.
    ///
    /// Three across on a phone, deliberately small: this block is seven facts to be scanned, not seven
    /// cards to be read. Two earlier attempts were both worse for the same underlying reason — the
    /// shared `TodayMetricTile` sizes itself around its CONTENT, so a tile carrying a sparkline stood
    /// taller than one that did not, and widening the grid to stop the labels truncating made the whole
    /// block twice the height it needs.
    ///
    /// So: the modern surface and the coloured icon chip are the design system's (`TodayCardSurface`,
    /// the same one Today's tiles sit on), and the LAYOUT is local and fixed-height, which is what makes
    /// the grid line up. The eight-week history the sparklines used to show lives where there is room
    /// for it — the week stepper, and the exercise chart below.
    private func tile(icon: String, label: String, value: String,
                      tint: Color, caption: String? = nil,
                      info: InfoTopic? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                ZStack {
                    Circle().fill(tint.opacity(0.13))
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
                Spacer(minLength: 0)
                if let info { infoButton(info) }
            }
            Spacer(minLength: 0)
            Text(value)
                .font(StrandFont.number(26))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            // `subhead`, not `caption`: on iOS the scale runs subhead (13) → caption (12) → footnote
            // (11), and a tile label set in caption reads as a footnote to a number that is the point
            // of the tile. The caption line below stays a step smaller, which is what keeps the two
            // apart now that the label has grown.
            Text(label)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            // The caption line is RESERVED even when empty, so a tile that has nothing to add is the
            // same height as one that does. Without it the grid rows staggered by a line.
            Text(caption ?? " ")
                .font(StrandFont.caption)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .leading)
        .background(TodayCardSurface(tint: tint, cornerRadius: NoopMetrics.groupedRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)\(caption.map { ", " + $0 } ?? "")")
    }

    /// The week's bodyweight volume — the work a calisthenics day actually moved, which volume load
    /// counts as zero.
    ///
    /// Shown only when there IS some: a lifter who never does bodyweight work should not carry a
    /// permanently empty tile, and a dash here would read as missing data rather than as "not
    /// applicable". When weigh-ins were missing for some of it, the caption says how many sets went
    /// unpriced instead of quietly leaving them out.
    @ViewBuilder
    private var bodyweightTile: some View {
        if model.weekBodyweightKg > 0 || model.weekUnpricedBodyweightSets > 0 {
            tile(icon: "figure.strengthtraining.functional",
                 label: String(localized: "Bodyweight"),
                 value: model.weekBodyweightKg > 0 ? volumeText(model.weekBodyweightKg) : "—",
                 tint: StrandPalette.metricCyan,
                 caption: model.weekUnpricedBodyweightSets > 0
                    ? String(localized: "\(model.weekUnpricedBodyweightSets) sets unpriced")
                    : String(localized: "\(model.weekBodyweightSets) sets"),
                 info: .bodyweight)
        }
    }

    /// The acute:chronic ratio of working sets, AS OF the selected week rather than as of today.
    ///
    /// That distinction is the whole point of the stepper: reading a past week while the load figure
    /// silently describes the present would put two different weeks on one card and label them the same.
    @ViewBuilder
    private var strengthLoadTile: some View {
        let load = model.strengthLoad
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
            // TWO SECTIONS, because they count DIFFERENT THINGS — and that is worth a header each.
            //
            // The map shades an ESTIMATE: sets weighed by how heavy they were for this person and how
            // close to failure, with indirect work credited at half. The list counts SETS, once, on
            // each set's primary muscle. So the map's totals are larger than the sets performed, and
            // the two will never agree. One shared heading over both would quietly tell the reader
            // that a shaded region and a bar were the same number seen twice.
            SectionHeader("Muscle load", overline: "Estimated")
            bodyMapCard

            if !unmappedExercises.isEmpty {
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text("Assign imported exercises")
                            .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text("Choose muscles once for exercises the file could not match to the Hevy catalogue.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        ForEach(unmappedExercises, id: \.self) { exercise in
                            Button {
                                mappingPrimary = .other
                                mappingSecondary = []
                                mappingExercise = ExerciseMappingTarget(name: exercise)
                            } label: {
                                HStack {
                                    Text(exercise).foregroundStyle(StrandPalette.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(StrandPalette.textTertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack {
                SectionHeader("Working sets", trailing: weekRangeText)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text("Counted / your usual")
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
                        if weekProgressText != nil {
                            Text("This week is still running, and the band beside each muscle is made of your COMPLETE weeks — so a bar sitting below it today is not yet a shortfall.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Counted sets: each one counts once, on its exercise's primary muscle. The map above is a different figure — an estimate that also weighs how heavy the set was for you and credits indirect work, so its totals are larger than the sets you did.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The body map: an ESTIMATE of how much load each muscle is carrying.
    ///
    /// Shading is `MuscleStimulus` — each set weighed by how heavy it was relative to this person's own
    /// strength at the time and how close to failure it was taken — measured against their own usual.
    /// It is not a recovery percentage, and there is no shade that means "ready". Green means little
    /// load compared with a normal week, red means a lot; the legend says exactly that, because
    /// green-to-red reads as good-to-bad unless something states otherwise.
    ///
    /// The one number here with nothing behind it is how fast load fades, and that is why the wearer
    /// can answer back: a rating pulls their own time constant away from the assumed default.
    private var bodyMapCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Picker("", selection: $mapMode) {
                    ForEach(MapMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Picker("", selection: $mapFace) {
                    ForEach(MuscleLoadMap.Face.allCases, id: \.self) { face in
                        Text(face.label).tag(face)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)

                HStack {
                    Spacer()
                    Button { showingFullScreenMap = true } label: {
                        Label("Expand muscle map", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                }

                // The map is the point of the card, so it does not compete with the text for width.
                // Side by side with BOTH the scale and the "last worked" list, a 1:2 figure collapsed
                // to about a third of the card on a phone — the smallest thing in the section that
                // exists to be looked at. On a compact width the list drops underneath and only the
                // narrow colour scale stays beside it.
                let map = MuscleLoadMap(load: mapLoad,
                                        face: mapFace,
                                        onSelect: { selectedRegion = $0 },
                                        accessibilityValue: { mapAccessibility($0) })
                if isCompact {
                    map.frame(maxWidth: .infinity).frame(height: 520)
                    mapScale
                    mapLegend
                } else {
                    HStack(alignment: .top, spacing: NoopMetrics.space2) {
                        map.frame(maxWidth: 200)
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            mapScale
                            mapLegend
                        }
                    }
                }

                Divider().overlay(StrandPalette.hairline)
                if let selectedRegion, let text = selectedRegionText {
                    Text(text)
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Only in the "right now" view: the answer is about how a muscle feels TODAY, so
                    // offering it while the map shows a week three back would invite rating that week.
                    if mapMode == .now {
                        feedbackRow(for: selectedRegion)
                    }
                } else {
                    // The hint sits exactly where the detail will appear, so the affordance is where
                    // the eye already is. Tucked into the closing caption it was a clause in small
                    // tertiary text at the bottom of the card, which is a place people do not read
                    // before deciding a picture is not interactive.
                    Label(mapMode == .now
                          ? String(localized: "Tap a muscle for detail — and to correct how recovered it feels.")
                          : String(localized: "Tap a muscle to see what it did this week."),
                          systemImage: "hand.tap")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(modelCaveat)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var fullScreenMuscleMap: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Picker("", selection: $mapMode) {
                        ForEach(MapMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    Picker("", selection: $mapFace) {
                        ForEach(MuscleLoadMap.Face.allCases, id: \.self) { face in
                            Text(face.label).tag(face)
                        }
                    }
                    .pickerStyle(.segmented)
                    MuscleLoadMap(load: mapLoad, face: mapFace,
                                  onSelect: { selectedRegion = $0 },
                                  accessibilityValue: { mapAccessibility($0) })
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 620)
                    mapScale
                    mapLegend
                    if let selectedRegion, let text = selectedRegionText {
                        Text(text).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        if mapMode == .now { feedbackRow(for: selectedRegion) }
                    }
                }
                .padding(NoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle(Text("Muscle load"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingFullScreenMap = false }
                }
            }
        }
    }

    private func exerciseMappingSheet(_ exercise: String) -> some View {
        NavigationStack {
            List {
                Section("Primary muscle") {
                    Picker("Primary muscle", selection: $mappingPrimary) {
                        ForEach(HevyMuscleGroup.allCases, id: \.self) { group in
                            Text(group.label).tag(group)
                        }
                    }
                }
                Section("Secondary muscles") {
                    ForEach(HevyMuscleGroup.allCases.filter { $0 != mappingPrimary && $0 != .other }, id: \.self) { group in
                        Button {
                            if mappingSecondary.contains(group) { mappingSecondary.remove(group) }
                            else { mappingSecondary.insert(group) }
                        } label: {
                            HStack {
                                Text(group.label).foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                if mappingSecondary.contains(group) {
                                    Image(systemName: "checkmark").foregroundStyle(StrandPalette.accent)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(Text(exercise))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { mappingExercise = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await saveMapping(for: exercise) } }
                        .disabled(mappingPrimary == .other)
                }
            }
        }
    }

    private func saveMapping(for exercise: String) async {
        guard let store = await repo.storeHandle(), mappingPrimary != .other else { return }
        let mapping = StrengthExerciseMapping(
            normalizedTitle: strengthNormalizedTitle(exercise), displayTitle: exercise,
            primaryMuscleGroup: mappingPrimary,
            secondaryMuscleGroups: mappingSecondary.sorted { $0.rawValue < $1.rawValue })
        try? await store.upsertStrengthExerciseMapping(mapping)
        mappingExercise = nil
        await model.load(repo: repo)
    }

    /// What the colours mean, spelled out. Without this the ramp is read as a health verdict.
    private var mapScale: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach([MuscleLoadMap.Level.light, .building, .usual, .wellAbove], id: \.self) { level in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(level.color)
                        .frame(width: 12, height: 8)
                    Text(level.label)
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The three or four muscles worked most recently, as plain dates. This is the "when" half, and it
    /// stays in words: a date is a fact, a percentage would not be.
    private var mapLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            if recentlyWorked.isEmpty {
                Text("Nothing logged in the last 7 days.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(recentlyWorked, id: \.group) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.group.label)
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text(item.detail)
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Where the estimate is weakest, said out loud rather than left for the reader to discover.
    private var modelCaveat: String {
        var parts: [String] = []
        switch mapMode {
        case .now:
            parts.append(String(localized: "Estimated load still on each muscle, against what one of your usual sessions leaves behind. How fast that fades is assumed, not measured — your answers are what correct it."))
        case .week:
            parts.append(String(localized: "Estimated stimulus this week, against your own usual week. It weighs each set by how heavy it was for you and how close to failure — it is not a count of sets."))
            // Two artefacts of cutting a continuous load into calendar weeks, said out loud rather than
            // hidden, because on a colour ramp both of them read as a physiological claim:
            //
            //   • Mid-week everything shades light — not because the load is low, but because the week
            //     is two days old and the comparison is against FINISHED weeks.
            //   • Monday is a calendar boundary, not a physiological one. Sunday night's leg session is
            //     still on you on Monday morning, and this view shows zero for it.
            //
            // Neither is a defect in the arithmetic; both are why "Right now" exists, is the default,
            // and is the view that actually answers "what is still on me".
            if weekProgressText != nil {
                parts.append(String(localized: "This week is only \(weekElapsedDays) days old and your usual week is made of complete ones, so light shading here means the week is young, not that a muscle is fresh."))
            }
            parts.append(String(localized: "The week boundary is a calendar one: Sunday's session counts to last week even though it is still on you today. Switch to Right now for that question."))
        }
        if ratedShare < 0.5 {
            parts.append(String(localized: "Only \(Int((ratedShare * 100).rounded())) % of your sets carry an RPE, so the effort half of the estimate is mostly a default."))
        }
        return parts.joined(separator: " ")
    }

    /// The correction. Four coarse options, because a finer scale asks for a precision nobody has
    /// about their own triceps, and no unprompted nagging — it appears only once a muscle is tapped.
    @ViewBuilder
    private func feedbackRow(for region: MuscleLoadMap.Region) -> some View {
        if let group = groups(in: region).first ?? Self.anyGroup(for: region) {
            VStack(alignment: .leading, spacing: 6) {
                Text("How recovered does \(group.label.lowercased()) feel?")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                HStack(spacing: 6) {
                    ForEach(MuscleRecovery.Feeling.allCases, id: \.self) { feeling in
                        Button(Self.feelingLabel(feeling)) { record(feeling, for: group) }
                            .buttonStyle(.bordered)
                            .font(StrandFont.caption)
                    }
                }
            }
        }
    }

    private static func feelingLabel(_ feeling: MuscleRecovery.Feeling) -> String {
        switch feeling {
        case .fresh:         return String(localized: "Fresh")
        case .slightlyTired: return String(localized: "A bit tired")
        case .clearlyTired:  return String(localized: "Tired")
        case .stillWrecked:  return String(localized: "Wrecked")
        }
    }

    private func record(_ feeling: MuscleRecovery.Feeling, for group: HevyMuscleGroup) {
        Task { await model.record(feeling, for: group, repo: repo) }
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

    // MARK: - Exercise progress

    private var exerciseProgress: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Exercise progress", overline: "Per movement")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    exercisePicker
                    // The guard tests the PLOTTABLE points, not the sessions. A plank has plenty of
                    // sessions and no plottable value at all — no 1RM estimate (it is not a
                    // weight-and-reps movement) and no volume load (no weight was lifted) — so this
                    // drew an empty 0–100 grid under a caption explaining a line that was not there.
                    if chartPoints.count < 2 {
                        Text(trend.isEmpty
                             ? String(localized: "Not enough sessions of this exercise yet to show a trend.")
                             : String(localized: "This movement carries no number to plot: it has no one-rep-max estimate, and no weight to compute a volume load from. Sets and reps for it are in the sessions below."))
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        // Side by side only where there is room for both.
                        //
                        // A 132pt column of facts beside the chart leaves it about 200pt on a phone,
                        // and `TrendChart` asks for five x-axis labels regardless of its width — so
                        // "Jun 21" and "Jul 5" ran into each other and the axis read "Jun 21Jul 5".
                        // Shortening the dates would have hidden that; the cause is the column, so on a
                        // compact width the facts go underneath and the chart gets the full card.
                        let chart = TrendChart(
                            points: chartPoints,
                            gradient: Gradient(colors: [DomainTheme.effort.color.opacity(0.35),
                                                        DomainTheme.effort.color]),
                            valueRange: chartRange,
                            height: 150,
                            valueFormat: { String(format: "%.0f kg", $0) },
                            dateFormat: { $0.formatted(date: .abbreviated, time: .omitted) },
                            accessibilityLabel: model.trendIsVolume
                                ? String(localized: "Volume per session trend")
                                : String(localized: "Estimated one-rep max trend"))
                        if isCompact {
                            chart
                            trendFacts
                        } else {
                            HStack(alignment: .top, spacing: 12) {
                                chart
                                trendFacts.frame(width: 132)
                            }
                        }
                        Text(chartCaption)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        recordsStrip
                    }
                }
            }
        }
    }

    private var exercisePicker: some View {
        Menu {
            ForEach(model.exerciseChoices.prefix(30)) { entry in
                let exerciseLabel = exerciseTitle(entry.templateId) + "  ·  \(entry.sessions)×"
                Button {
                    Task { await model.select(entry.templateId) }
                } label: {
                    Text(verbatim: exerciseLabel)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(model.selectedTemplateId.map(exerciseTitle) ?? String(localized: "Pick an exercise"))
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
            if let line = model.trendLine {
                factRow(model.trendIsVolume ? String(localized: "Volume trend")
                                            : String(localized: "Strength trend"),
                        chip: TrendChip(text: trendChipText(line), color: trendChipColor(line)))
            }
            if let best = trend.compactMap(\.heaviestSetKg).max() {
                factRow(String(localized: "Best set"),
                        text: bestSetText(best))
            }
            factRow(String(localized: "RPE"), text: rpeTrendText)
        }
    }

    /// The trend as a rate, or as an admission that the points do not agree on a direction.
    ///
    /// A rate rather than a per cent, and a word rather than a small number when the middle half of the
    /// pairwise slopes straddles zero — see `StrengthTrendLine`. The reading this replaced was the
    /// first estimate against the last, which called a four-week climb a decline whenever the final
    /// session happened to be a bad one.
    private func trendChipText(_ line: StrengthTrendLine) -> String {
        guard !line.directionIsUnclear else { return String(localized: "no clear direction") }
        return model.trendIsVolume
            ? String(format: "%+.0f kg/wk", line.slopePerWeek)
            : String(format: "%+.1f kg/wk", line.slopePerWeek)
    }

    private func trendChipColor(_ line: StrengthTrendLine) -> Color {
        guard !line.directionIsUnclear else { return StrandPalette.textTertiary }
        return line.slopePerWeek >= 0 ? StrandPalette.statusPositive : StrandPalette.statusWarning
    }

    /// Label over value in the narrow column beside the chart; label and value on ONE line once the
    /// facts move under a full-width chart.
    ///
    /// Stacking is right at 132pt and wrong at 360: three facts became six lines with a card's worth of
    /// empty space to the right of every one of them. This is the same mistake as reusing `StatTile`'s
    /// icon variant three across — a layout carries an assumption about the width it was shaped for,
    /// and moving it somewhere wider does not carry that assumption along.
    @ViewBuilder
    private func factRow<Value: View>(_ label: String,
                                      @ViewBuilder value: () -> Value) -> some View {
        let caption = Text(label).font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
        if isCompact {
            HStack(alignment: .firstTextBaseline) {
                caption
                Spacer(minLength: 8)
                value()
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                caption
                value()
            }
        }
    }

    private func factRow(_ label: String, text: String) -> some View {
        factRow(label) {
            Text(text).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private func factRow(_ label: String, chip: TrendChip) -> some View {
        factRow(label) { chip }
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

    /// One session in the list. Tappable since #E1: the detail sheet is the only place in the app that
    /// says what a session actually contained, and a card that holds a summary of sets nobody can open
    /// is a dead end.
    private func sessionRow(_ s: StrengthSessionSummary) -> some View {
        Button {
            openSession = SessionTarget(id: s.workoutId)
        } label: {
            sessionRowBody(s)
        }
        .buttonStyle(.plain)
        .strandPressable()
    }

    private func sessionRowBody(_ s: StrengthSessionSummary) -> some View {
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
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the session, exercise by exercise"))
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

    /// Every session, in a stack of its own.
    ///
    /// The rows PUSH here rather than reusing `sessionRow`'s button: this list is already inside a
    /// sheet, and asking SwiftUI to present a second sheet from within one silently does nothing — so
    /// tapping a session in "All sessions" would have been a dead tap.
    private var allSessionsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(summaries, id: \.workoutId) { summary in
                        NavigationLink {
                            detailSheet(workoutId: summary.workoutId)
                        } label: {
                            sessionRowBody(summary)
                        }
                        .buttonStyle(.plain)
                        .strandPressable()
                    }
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
        case strengthLoad, cardioLoad, charge, muscleBands, balance, bodyweight
        var id: String { rawValue }
    }

    func infoButton(_ topic: InfoTopic) -> some View {
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
        case .balance:      return String(localized: "Balance")
        case .bodyweight:   return String(localized: "Bodyweight volume")
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
        case .balance:
            return String(localized: "Each bar splits this week's working sets between two sides — pushing against pulling, upper body against lower, quads against hips and hamstrings. A set counts once, on its exercise's primary muscle, exactly as in the list above.\n\nThe hatched region is YOUR usual ratio over the last eight training weeks. There is deliberately no target: '1:1 push to pull' is coaching advice, not a measurement, and printing it here would turn every week into a pass or a fail against a number nobody validated for you.\n\nThe groupings are conventions — a triceps set counts as pushing, a biceps set as pulling. They decide only how sets are added up.")
        case .bodyweight:
            return String(localized: "Volume load counts weight × reps, so a set of pull-ups counts as nothing: the log records no weight for it. This figure prices those sets at the body you actually moved, taken from your own weigh-ins around that session — never from your height, your age, or today's weight applied backwards.\n\nIt is reported BESIDE barbell tonnage and never added to it, because they are different measurements. And there is no leverage factor: a push-up is counted at your body weight like every other bodyweight movement, rather than at some fraction of it that nobody has measured for you.\n\nWith no weigh-in near a session, the sets it could not price are counted and shown instead of guessed.")
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

    private var week: StrengthSession.WeekSummary { model.week }

    private var typicalBands: [HevyMuscleGroup: ClosedRange<Double>] { model.typicalBands }

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

    /// Which body region a Hevy muscle group is drawn on.
    ///
    /// The artwork has no shape for two of Hevy's groups, and both get an anatomically defensible home
    /// rather than being dropped:
    ///
    ///   • `lats` shades the UPPER BACK, which is where the latissimus actually is.
    ///   • `abductors` shade the GLUTES, because gluteus medius and minimus are the hip abductors.
    ///
    /// `cardio`, `fullBody` and `other` map to NOTHING on purpose — there is no honest place to shade
    /// for them, and colouring a nearby muscle instead would put work on one that never did it. They
    /// stay visible in the list below the map, which is where their sets are counted.
    private static func region(for group: HevyMuscleGroup) -> MuscleLoadMap.Region? {
        switch group {
        case .neck:        return .neck
        case .traps:       return .traps
        case .shoulders:   return .shoulders
        case .chest:       return .chest
        case .biceps:      return .biceps
        case .triceps:     return .triceps
        case .forearms:    return .forearms
        case .abdominals:  return .abdominals
        case .upperBack:   return .upperBack
        case .lats:        return .upperBack
        case .lowerBack:   return .lowerBack
        case .glutes:      return .glutes
        case .abductors:   return .glutes
        case .quadriceps:  return .quadriceps
        case .hamstrings:  return .hamstrings
        case .calves:      return .calves
        case .adductors:   return .adductors
        case .cardio, .fullBody, .other: return nil
        }
    }

    /// Every Hevy group drawn on one region, busiest first.
    ///
    /// The mapping stopped being one-to-one the moment lats and abductors were folded onto shapes they
    /// share with another group, so anything reading back from a region has to expect a LIST. Taking
    /// the first match would have silently reported a lat pulldown as upper-back work and hidden the
    /// rest, which is the sort of wrong answer that looks perfectly reasonable on screen.
    /// Any muscle drawn on a region, even one with no recent work — the feedback row needs a subject
    /// for a muscle the wearer has not trained lately, which is exactly when "how does it feel?" is
    /// worth asking.
    private static func anyGroup(for target: MuscleLoadMap.Region) -> HevyMuscleGroup? {
        // `target`, not `region` — a parameter named `region` shadows the `region(for:)` resolver and
        // the call below would try to invoke the parameter.
        HevyMuscleGroup.allCases.first { Self.region(for: $0) == target }
    }

    private func groups(in region: MuscleLoadMap.Region) -> [HevyMuscleGroup] {
        // Whatever the map is CURRENTLY shading. Filtering on the trailing 7 days regardless of view
        // put a flat contradiction on screen: a muscle last trained nine days ago is still carrying
        // load in the "right now" view and was shaded accordingly, while tapping it answered
        // "nothing logged here in the last 7 days" — with "9 days ago · Squat" printed just above.
        let values = mapMode == .now ? fatigueNow : weekStimulus
        return HevyMuscleGroup.allCases
            .filter { Self.region(for: $0) == region && (values[$0] ?? 0) > 0 }
            .sorted { (values[$0] ?? 0) > (values[$1] ?? 0) }
    }

    /// What the map is shading: estimated load as a RATIO of this person's own usual, so 1.0 means
    /// "about a normal amount for you" in whichever view is showing.
    ///
    /// Without a personal yardstick there is no ratio to draw. Rather than invent one, the fallback is
    /// the busiest muscle in the same view — the shading is then relative to something real on screen,
    /// and `modelCaveat` is what tells the reader which of the two they are looking at.
    private var mapLoad: [MuscleLoadMap.Region: Double] {
        let values = mapMode == .now ? fatigueNow : weekStimulus
        let yardsticks = mapMode == .now ? typicalSession : typicalWeek
        let busiest = values.values.max() ?? 0
        var out: [MuscleLoadMap.Region: Double] = [:]
        for (group, value) in values where value > 0 {
            guard let region = Self.region(for: group) else { continue }
            let yardstick = yardsticks[group] ?? busiest
            guard yardstick > 0 else { continue }
            // Two Hevy groups can share one region; keep the larger so a many-to-one mapping cannot
            // silently lose work.
            out[region] = max(out[region] ?? 0, value / yardstick)
        }
        return out
    }

    /// The muscles worked most recently, newest first — the "when" half of the map.
    private var recentlyWorked: [(group: HevyMuscleGroup, detail: String)] {
        lastWorked
            .sorted { $0.value.startTs > $1.value.startTs }
            .prefix(4)
            .map { (group: $0.key, detail: Self.agoText($0.value.day, exercise: $0.value.exercise)) }
    }

    /// "2 days ago · Back Squat". Whole days only: the log records a start time, and "41 hours" would
    /// suggest a precision about when the load landed that a workout's start timestamp does not carry.
    private static func agoText(_ day: String, exercise: String) -> String {
        let today = AnalyticsEngine.dayString(Int(Date().timeIntervalSince1970), offsetSec: 0)
        let days = StrengthSession.daysBetween(day, and: today)
        let when: String
        switch days {
        case ..<1: when = String(localized: "today")
        case 1:    when = String(localized: "yesterday")
        default:   when = String(localized: "\(days) days ago")
        }
        return "\(when) · \(exercise)"
    }

    /// What a tapped region says: every muscle drawn there, in the words of the band it is in.
    ///
    /// The band's own label is reused rather than a number. "Well under your usual" is exactly as much
    /// as the estimate supports; "0.4×" invites arithmetic the figure cannot carry.
    private var selectedRegionText: String? {
        guard let selectedRegion else { return nil }
        let hits = groups(in: selectedRegion)
        guard !hits.isEmpty else {
            return mapMode == .now
                ? String(localized: "No load left on this one.")
                : String(localized: "Not trained in this week.")
        }
        let values = mapMode == .now ? fatigueNow : weekStimulus
        let yardsticks = mapMode == .now ? typicalSession : typicalWeek
        return hits.map { group in
            var line = "\(group.label): \(bandLabel(for: group, values: values, yardsticks: yardsticks))"
            if let last = lastWorked[group] {
                line += " · \(Self.agoText(last.day, exercise: last.exercise))"
            }
            return line
        }.joined(separator: "\n")
    }

    /// The band wording for one muscle in the active view.
    private func bandLabel(for group: HevyMuscleGroup,
                           values: [HevyMuscleGroup: Double],
                           yardsticks: [HevyMuscleGroup: Double]) -> String {
        let value = values[group] ?? 0
        guard let yardstick = yardsticks[group], yardstick > 0 else {
            // No personal yardstick yet, so there is no "usual" to compare against — say that rather
            // than pick a band off a scale that does not exist for this muscle.
            return String(localized: "not enough history to compare")
        }
        return MuscleLoadMap.Level.of(load: value / yardstick).label
    }

    private func mapAccessibility(_ region: MuscleLoadMap.Region) -> String {
        let hits = groups(in: region)
        guard !hits.isEmpty else {
            return mapMode == .now
                ? String(localized: "no load left")
                : String(localized: "not trained in this week")
        }
        let values = mapMode == .now ? fatigueNow : weekStimulus
        let yardsticks = mapMode == .now ? typicalSession : typicalWeek
        return hits.map { group in
            "\(group.label), \(bandLabel(for: group, values: values, yardsticks: yardsticks))"
        }.joined(separator: ", ")
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

    /// The charted series: estimated 1RM where the movement defines one, session volume where it does
    /// not. A bodyweight row or a plank used to draw an empty chart under a "1RM" caption — the axis was
    /// blank because the estimate is undefined, which reads as missing data rather than as a movement
    /// the estimate does not apply to.
    private var chartPoints: [TrendPoint] {
        trend.compactMap { point in
            let value = model.trendIsVolume ? (point.volumeLoadKg > 0 ? point.volumeLoadKg : nil)
                                            : point.bestE1RMKg
            return value.map {
                TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(point.startTs)), value: $0)
            }
        }
    }

    private var chartRange: ClosedRange<Double> {
        let values = chartPoints.map(\.value)
        guard let lo = values.min(), let hi = values.max(), hi > lo else { return 0...100 }
        let pad = max(2.0, (hi - lo) * 0.25)
        return (lo - pad)...(hi + pad)
    }

    private var chartCaption: String {
        if model.trendIsVolume {
            return String(localized: "Volume load per session (weight × reps). This movement has no one-rep-max estimate — the estimate is only defined for weight-and-reps exercises — so the honest progression question is whether you are doing more of it.")
        }
        return String(localized: "Estimated 1RM (Epley) from each session's best working set — a projection, not a lift you performed. Sets above 12 reps are left out, because the estimate stops being reliable there. The trend beside it is the median of every pairwise slope, so one bad session cannot flip it.")
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

    func volumeText(_ kg: Double) -> String {
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

    private func exerciseTitle(_ id: String) -> String {
        templates[id]?.title
            ?? workouts.lazy.flatMap(\.exercises).first { $0.templateId == id }?.title
            ?? id
    }

    private func matchedRow(_ summary: StrengthSessionSummary) -> WorkoutRow? {
        model.matchedRow(for: summary)
    }

    // MARK: - Week navigation

    private var minWeekOffset: Int { model.minWeekOffset }

    private var weekAnchorDay: String { model.weekAnchorDay }

    private var weekEndDate: Date { model.weekEndDate }

    private func stepWeek(_ delta: Int) {
        Task { await model.stepWeek(delta, repo: repo) }
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

    /// How far into the current week we are, or nil for a week that has finished.
    ///
    /// The week is the right UNIT — training is prescribed in weeks, the typical bands are built from
    /// complete weeks, and the digest is Monday-anchored — but the CURRENT week is being compared
    /// against bands made of finished ones. On a Tuesday that reads as "below your usual" when the only
    /// thing that has happened is that the week is not over.
    ///
    /// So the state is named rather than corrected. Prorating the band to the day would be the tempting
    /// fix and the wrong one: it assumes sets fall evenly across a week, which is not how anyone trains
    /// — most weeks are three sessions on particular days, and a Tuesday sits at a different fraction
    /// of the week's work for every person.
    /// Days elapsed in the current week, Monday counting as day 1.
    private var weekElapsedDays: Int {
        guard let monday = WeeklyDigestEngine.mondayOfWeek(containing: weekAnchorDay) else { return 7 }
        return StrengthSession.daysBetween(monday, and: Repository.localDayKey(Date())) + 1
    }

    private var weekProgressText: String? {
        guard weekOffset == 0,
              WeeklyDigestEngine.mondayOfWeek(containing: weekAnchorDay) != nil else { return nil }
        let elapsed = weekElapsedDays
        guard (1...6).contains(elapsed) else { return nil }   // a finished week needs no caveat
        return String(localized: "day \(elapsed) of 7 — the week is still running")
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
        if let load = model.strengthLoad {
            parts.append(String(format: "set load acute:chronic %.2f (%@)", load.ratio,
                                bandLabel(load.band)))
        }
        if let line = model.trendLine, let id = model.selectedTemplateId {
            parts.append(String(format: "%@ trend %+.1f kg/week%@", exerciseTitle(id),
                                line.slopePerWeek,
                                line.directionIsUnclear ? " (direction unclear)" : ""))
        }
        if model.weekBodyweightKg > 0 {
            parts.append("bodyweight volume \(HevySource.groupedKg(model.weekBodyweightKg)) kg")
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

}
