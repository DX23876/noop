#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandCore
import WhoopStore
import StrandTraining

/// The redesigned Today (2026-11, "New design (preview)"): the three organic rings, Log and Start, the wearer's
/// tiles, then one sheet over the motif with what happened, newest first.
///
/// Every number is read through the same resolvers the shipped Today uses (`ChargeDisplay`,
/// `DashboardRestScore`/`freshRestScore`, `LiveEffort` floored by `effectiveEffort`), so the two designs can
/// never disagree about a score. The timeline is assembled by `ForgeTimeline` from stored rows and works
/// fully with the coach off; coach notes only join it when the coach is on.
struct ForgeTodayView: View {
    @ObservedObject var coach: AICoachEngine
    /// Live inputs for the Momentum feed: the raised alert, the strap battery, the cycle phase.
    var model: AppModel?
    let onProfile: () -> Void
    let onLog: () -> Void
    let onWorkout: () -> Void
    let onCoach: () -> Void
    let onSleep: () -> Void
    /// Opens Coach settings (memory, usage, data access) on the Today stack.
    var onCoachSettings: () -> Void = {}
    /// Sends a quick reply or question to the coach (inline consent handled by the shell).
    var onAsk: (String) -> Void = { _ in }

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var router: NavRouter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceSystem: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric, override: distanceSystemRaw)
    }
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    // The dwell and snooze bookkeeping every Today shares.
    @AppStorage(DashboardMomentum.Keys.lastKind) private var momentumLastKind = ""
    @AppStorage(DashboardMomentum.Keys.lastAt) private var momentumLastAt: Double = 0
    @AppStorage(DashboardMomentum.Keys.snoozed) private var momentumSnoozedRaw = ""
    @AppStorage(DashboardMomentum.Keys.stepGoal) private var momentumStepGoal = 0

    @AppStorage(SceneBackgroundPrefs.enabledKey) private var motifOn = ForgeDesignPrefs.skyDefaultInNewDesign
    @ObservedObject private var backdropPhoto = BackgroundImageStore.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var snapshot = Snapshot()
    @State private var showPlan = false
    @State private var showCoachSheet = false
    @State private var rowWidth: CGFloat = 0
    @State private var whyEntry: ForgeTimeline.Entry?
    /// True once the rings have scrolled out of view; a compact glass bar then keeps the three scores.
    @State private var heroHidden = false
    @AppStorage(ForgeDesignPrefs.todaySurfaceKey) private var surfacePercent = ForgeDesignPrefs.todaySurfaceDefault
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var editingWidgets = false
    @ObservedObject private var widgetStore = ForgeTodayWidgetStore.shared
    /// Today's session the morning note proposed, opened from the note itself.
    @ObservedObject private var planStore = CoachPlanStore.shared
    @AppStorage(ForgeTodayWidgetStore.belowTimelineKey) private var tilesBelowTimeline = false
    /// Bumped by a tap on the pinned bar: back to the rings.
    @State private var backToTop = 0
    /// Long notes opened in place: figures and a few lines first, the rest on request.
    @State private var openedNotes: Set<String> = []
    /// Older days the reader opened from their one-line summary.
    @State private var openedDays: Set<String> = []
    /// When the reader last left Today; entries after it carry a dot until they leave again.
    @AppStorage("forge.timeline.seenAt") private var seenAt: Double = 0
    @State private var seenBefore: Double = 0
    /// Entries the reader hid, newline-separated ids.
    @AppStorage("forge.timeline.hidden") private var hiddenRaw = ""
    /// Ratings the reader gave coach notes: "messageId:origin:+1" lines.
    @AppStorage("forge.coach.ratings") private var ratingsRaw = ""
    /// The note under which "less often?" is asked after a second thumbs down for its kind.
    @State private var askLessOften: String?
    /// An entry the day strip asked to scroll to.
    @State private var scrollTarget: String?
    /// Entries whose "explain this" or inline answer is being written.
    @State private var asking: Set<String> = []
    @ObservedObject private var goalStore = CoachGoalStore.shared

    /// A driver's night placed on the wearer's usual range (`ForgeChargeDetailView.usualRange`).
    struct DriverRange: Equatable {
        let text: String
        let position: Double
        let band: ClosedRange<Double>
    }

    /// One day of the week card.
    struct WeekBar: Equatable {
        let day: String
        let charge: Double?
        let effort: Double?
        let sleepMinutes: Double?
    }

    /// One past day folded to a line: its Charge, Effort and night.
    struct DaySummary: Equatable {
        var charge: Double?
        var effort: Double?
        var asleepMinutes: Double?
    }

    struct Snapshot: Equatable {
        var loaded = false
        var charge: ChargeDisplay = .noData
        var rest: Double?
        var effortStored: Double?
        var effortDay = ""
        var timeline: [ForgeTimeline.Day] = []
        var workouts: [String: WorkoutRow] = [:]
        /// Nights by their wake moment, as the Sleep tab resolves them.
        var nights: [Int: ForgeRecentSleep.Night] = [:]
        var restByDay: [String: Double] = [:]
        var notes: [String: ChatMessage] = [:]
        /// The Charge drivers for the row the ring shows, bound under the morning note.
        var drivers: [ChargeDriver] = []
        /// The weight trend's 30-day change, shown under a weigh-in.
        var weightChange30d: Double?
        /// What today's notes are measured against (`ForgeNoteBasis`).
        var basis: String?
        var daySummaries: [String: DaySummary] = [:]
        /// Each driver's night on the usual range, by the driver's label.
        var driverRanges: [String: DriverRange] = [:]
        /// The median Effort of a sport over the last four months, stored scale, for sports with 3 sessions.
        var usualEffort: [String: Double] = [:]
        var week: [WeekBar] = []
        /// What the What works analysis found most clearly, for the week card.
        var weekPattern: String?
        /// The day of the last weigh-in.
        var lastWeighDay: String?
        /// Answers to "explain this", by entry key, written today.
        var explanations: [String: String] = [:]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForgeLargeHeader(title: "Today", onProfile: onProfile)
                            .id("forge-today-top")
                        VStack(alignment: .leading, spacing: 14) {
                            HealthAlertBanner()
                            ActiveWorkoutIndicatorSection()
                            if snapshot.loaded && repo.days.isEmpty {
                                // First run: nothing recorded or imported yet. The same calm state Health and
                                // Live show, with the one next step.
                                WearableConnectionStateCard(
                                    title: "No biometrics yet",
                                    detail: "Connect a wearable to begin collecting live vitals and history. Existing records can still be imported from Data Sources.",
                                    actionTitle: "Connect a device",
                                    action: { router.openDevices() })
                            }
                            hero
                                // Holding the rings starts the tile editor too, for a page with no tile to hold.
                                .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in startEditingWidgets() })
                                .onGeometryChange(for: Bool.self) { $0.frame(in: .named("forge-today")).maxY < 40 } action: { hidden in
                                    withAnimation(.easeOut(duration: 0.2)) { heroHidden = hidden }
                                }
                            dayAnswer
                            actions
                        }
                        .padding(.horizontal, 16)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        if !tilesBelowTimeline || editingWidgets {
                            ForgeTodayWidgetArea(editing: $editingWidgets)
                        }
                        ForgeCycleSummaryCard(showsLogButtons: false)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 12)
                    dayList
                }
                .padding(.top, 6)
                .environment(\.forgeSurfaceOpacity, surfaceOpacity)
            }
            .scrollIndicators(.hidden)
            // Cards dissolve before they reach the clock and the tab bar, leaving the picture there, with nothing
            // painted over it. The picture lies over the two edges instead of a mask on the scroll view, which
            // drew every card and the rings off screen on each frame.
            .overlay { ForgeTodayEdges(heroHidden: heroHidden) }
            .coordinateSpace(name: "forge-today")
            .overlay(alignment: .top) {
                if heroHidden {
                    pinnedBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onChange(of: scrollToTopSignal) { _, _ in
                withAnimation(.smooth) { proxy.scrollTo("forge-today-top", anchor: .top) }
            }
            .onChange(of: backToTop) { _, _ in
                withAnimation(.smooth) { proxy.scrollTo("forge-today-top", anchor: .top) }
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.smooth) { proxy.scrollTo(target, anchor: .center) }
                scrollTarget = nil
            }
        }
        .background(ForgeBackground(tab: .today, showsMotif: true))
        .refreshable { await repo.refresh(); await load() }
        // `task` also starts over each time Today comes back into view, so what was just logged on another page
        // is read then. A reload waits for the page's transition and for the rest of a burst of changes.
        .task(id: reloadKey) {
            if snapshot.loaded {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            await load()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                seenBefore = seenAt
                Task { await load() }
            } else {
                seenAt = Date().timeIntervalSince1970
            }
        }
        .onAppear { seenBefore = seenAt }
        .onDisappear { seenAt = Date().timeIntervalSince1970 }
        .coachDashboardPresentations(showCoach: $showCoachSheet, showPlan: $showPlan)
        .sheet(item: $whyEntry) { entry in
            ForgeCoachWhySheet(entry: entry, message: entry.sourceId.flatMap { snapshot.notes[$0] },
                               onCoachSettings: {
                                   whyEntry = nil
                                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onCoachSettings() }
                               })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// Re-read when the day list, today's stored row or the coach transcript moves.
    private var reloadKey: String {
        let lastNote = coach.conversations.last?.messages.last?.id.uuidString ?? ""
        return "\(repo.days.count)|\(repo.today?.day ?? "")|\(repo.today?.strain ?? -1)|\(repo.today?.recovery ?? -1)|\(lastNote)|\(coachFeatureEnabled)|\(repo.refreshSeq)|\(repo.hydrationSeq)|\(repo.sleepPresentationRevision)|\(repo.workoutAnnotationRevision)"
    }

    private var onPicture: Bool { motifOn || backdropPhoto.isActive }
    /// How solid every surface on this page is over the picture. The one reading of the setting here.
    private var surfaceOpacity: Double { reduceTransparency ? 1 : Double(surfacePercent) / 100 }

    private func startEditingWidgets() {
        withAnimation(.snappy) { editingWidgets = true }
        backToTop += 1
    }

    /// Log and Start in one row under the rings, where a thumb finds them. Editing starts by holding a tile.
    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: onLog) { actionLabel("Add entry", systemImage: "plus") }
                .buttonStyle(.plain)
            Button(action: onWorkout) { actionLabel("Start", systemImage: "figure.run") }
                .buttonStyle(.plain)
        }
    }

    private func actionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(ForgeColor.accent)
            Text(title).foregroundStyle(ForgeColor.text)
        }
        .font(.system(.subheadline, weight: .semibold))
        .frame(maxWidth: .infinity, minHeight: 46)
        .modifier(ForgeTodayActionSurface())
        .contentShape(Capsule())
    }

    // MARK: - Hero

    private var chargeScore: Double? { snapshot.loaded ? snapshot.charge.pct : nil }
    private var effortScore: Double? { snapshot.effortStored.map { UnitFormatter.effortValue($0, scale: effortScale) } }
    private var effortTarget: ClosedRange<Double>? { ForgeToday.effortTargetStored(charge: chargeScore) }

    /// The rings on their own: three equal rings with their names, no card and no sentence.
    private var hero: some View {
        let diameter = LiquidHeroRingLayout.diameter(rowWidth: rowWidth)
        let hit = LiquidHeroRingLayout.hitDiameter(rowWidth: rowWidth)
        // Worked out here, once per change of the page: the clock's closure runs 60 times a second.
        let charge = ringFace(metric: .charge, label: DomainTheme.charge.productName, score: chargeScore,
                              tint: chargeScore == nil ? StrandPalette.organicMissing : StrandPalette.chargeColor)
        let effort = ringFace(metric: .effort, label: DomainTheme.effort.productName, score: effortScore,
                              tint: StrandPalette.organicEffort,
                              maxValue: effortScale == .whoop ? 21 : 100, decimals: effortScale == .whoop ? 1 : 0)
        let rest = ringFace(metric: .rest, label: DomainTheme.rest.productName, score: snapshot.loaded ? snapshot.rest : nil,
                            tint: StrandPalette.organicRest)
        let effortRoute = ForgeRoute.effort(stored: snapshot.effortStored, charge: chargeScore)
        let restRoute = ForgeRoute.rest(snapshot.loaded ? snapshot.rest : nil)
        return OrganicScoreHeroClock(dataReady: snapshot.loaded || effortScore != nil) { frame in
            HStack(alignment: .top, spacing: 0) {
                ringCell(charge, frame: frame, diameter: diameter, hit: hit, route: ForgeRoute.charge)
                ringCell(effort, frame: frame, diameter: diameter, hit: hit, route: effortRoute)
                ringCell(rest, frame: frame, diameter: diameter, hit: hit, route: restRoute)
            }
        }
        .frame(maxWidth: .infinity)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { rowWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in rowWidth = w }
        })
        .padding(.vertical, 4)
    }

    /// Under the rings, the day's answer in one line, coach or no coach: where Effort stands against today's
    /// target, worked out on the device. A carried Charge says whose night it is, as `ChargeDisplay` requires
    /// of every screen that draws a carried score.
    @ViewBuilder private var dayAnswer: some View {
        let caption = snapshot.loaded ? snapshot.charge.carriedCaption : nil
        // A carried Charge belongs to an earlier night, so it sets no target for today: the line stays away
        // rather than call that night's target today's.
        let line: String? = caption != nil ? nil
            : ForgeToday.summary(effortStored: snapshot.effortStored, charge: chargeScore, scale: effortScale)
            ?? ForgeToday.effortTargetStored(charge: chargeScore).map {
                let t = ForgeToday.targetText($0, scale: effortScale)
                return String(localized: "Today's Effort target: \(t.low) to \(t.high).")
            }
        if line != nil || caption != nil {
            VStack(spacing: 2) {
                if let line {
                    Text(line).font(.system(.subheadline, weight: .semibold))
                }
                if let caption {
                    Text(verbatim: "\(DomainTheme.charge.productName) · \(caption)").font(ForgeFont.caption)
                }
            }
            .foregroundStyle(onPicture ? AnyShapeStyle(.white) : AnyShapeStyle(ForgeColor.text))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background {
                if onPicture { Color.clear.liquidGlass(in: RoundedRectangle(cornerRadius: ForgeRadius.inner, style: .continuous)) }
            }
            .environment(\.colorScheme, onPicture ? .dark : colorScheme)
        }
    }

    /// The three scores in one glass bar while the rings are scrolled away. Tapping returns to the top.
    private var pinnedBar: some View {
        HStack(spacing: 16) {
            pinnedValue(DomainTheme.charge.productName, chargeScore.map { "\(Int($0.rounded()))" }, ForgeColor.charge)
            pinnedValue(DomainTheme.effort.productName,
                        snapshot.effortStored.map { ForgeToday.effortText($0, scale: effortScale) }, ForgeColor.effort)
            pinnedValue(DomainTheme.rest.productName,
                        (snapshot.loaded ? snapshot.rest : nil).map { "\(Int($0.rounded()))" }, ForgeColor.rest)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        // Backed, so the timeline scrolling under the bar never reads through its figures.
        .background(Capsule().fill(ForgeColor.card.opacity(0.88)))
        .liquidGlass(in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { backToTop += 1 }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Back to the rings"))
    }

    private func pinnedValue(_ label: String, _ value: String?, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(value ?? "–").font(ForgeFont.rounded(16, .bold)).foregroundStyle(ForgeColor.text)
            Text(label).font(.system(.caption)).foregroundStyle(ForgeColor.secondary)
        }
    }

    /// The ring's name in its domain colour, as in the prototype.
    private static func labelTint(_ metric: OrganicScoreMetric) -> Color {
        switch metric {
        case .charge: return ForgeColor.chargeInk
        case .effort: return ForgeColor.effortInk
        case .rest: return ForgeColor.restInk
        }
    }

    /// What one ring shows, apart from the frame it is drawn at.
    private struct RingFace {
        let metric: OrganicScoreMetric
        let label: String
        let score: Double?
        let tint: Color
        let decimals: Int
        let model: OrganicScoreVisualModel
        let spokenValue: String
    }

    private func ringFace(metric: OrganicScoreMetric, label: String, score: Double?, tint: Color,
                          maxValue: Double = 100, decimals: Int = 0) -> RingFace {
        RingFace(metric: metric, label: label, score: score, tint: tint, decimals: decimals,
                 model: OrganicScoreVisualModel.resolve(metric: metric, value: score, scaleMaximum: maxValue),
                 spokenValue: spoken(score: score, maxValue: maxValue, decimals: decimals))
    }

    private func ringCell<Route: Hashable>(_ face: RingFace, frame: OrganicScoreFrame, diameter: CGFloat, hit: CGFloat,
                                           route: Route) -> some View {
        NavigationLink(value: route) {
            VStack(spacing: 2) {
                ScoreRing(model: face.model, tint: face.tint, score: face.score, decimals: face.decimals, frame: frame,
                                 diameter: diameter, hitDiameter: hit)
                    .frame(width: hit, height: diameter)
                    // A soft shade under the ring on a picture, so a faint glow still parts from a bright sky.
                    .background {
                        if onPicture {
                            Circle()
                                .fill(RadialGradient(colors: [.black.opacity(0.26), .black.opacity(0.14), .clear],
                                                     center: .center, startRadius: 0, endRadius: diameter * 0.62))
                                .frame(width: diameter * 1.24, height: diameter * 1.24)
                                .allowsHitTesting(false)
                        }
                    }
                Text(face.label)
                    .font(.system(.subheadline, weight: .semibold))
                    // On the picture a name sits on a small glass capsule, as the buttons below do: white on
                    // its own crossed snow and rock and was lost there.
                    .foregroundStyle(onPicture ? AnyShapeStyle(.white) : AnyShapeStyle(Self.labelTint(face.metric)))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, onPicture ? 10 : 0)
                    .padding(.vertical, onPicture ? 3 : 0)
                    .background { if onPicture { Color.clear.forgeGlassCapsule() } }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            // A ring and its name on a picture take the dark drawing: the light one turns the glow to a blur
            // with black figures, and dark ink is lost on the mountains.
            .environment(\.colorScheme, onPicture ? .dark : colorScheme)
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(face.label))
        .accessibilityValue(Text(face.spokenValue))
        .accessibilityHint(Text("Opens the trend and readings"))
        .accessibilityAddTraits(.isButton)
    }

    private func spoken(score: Double?, maxValue: Double, decimals: Int) -> String {
        guard let score else { return String(localized: "no data yet") }
        if maxValue == 100 {
            return String(localized: "\(Int(score.rounded())) percent")
        }
        let number = String(format: "%.\(decimals)f", locale: AppLanguage.activeLocale, score)
        return String(localized: "\(number) out of \(Int(maxValue))")
    }

    // MARK: - Timeline

    /// The day directly on the picture: only what carries text has a surface, each entry its own.
    private var dayList: some View {
        VStack(alignment: .leading, spacing: 14) {
            timeline
            if tilesBelowTimeline && !editingWidgets {
                ForgeTodayWidgetArea(editing: $editingWidgets)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 130)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            if snapshot.loaded && snapshot.timeline.isEmpty {
                Text("Workouts, nights and notes from the coach appear here as the day goes on.")
                    .font(ForgeFont.body)
                    .foregroundStyle(ForgeColor.secondaryOnPicture)
                    .forgeCard(radius: ForgeRadius.card, padding: 14)
            }
            let todayKey = Repository.logicalDayKey(Date())
            let yesterdayKey = Repository.logicalDayKey(Date().addingTimeInterval(-86_400))
            let hidden = Set(hiddenRaw.split(separator: "\n").map(String.init))
            ForEach(Array(snapshot.timeline.enumerated()), id: \.element.id) { index, day in
                if TimelineFeed.isFolded(day: day.id, today: todayKey, yesterday: yesterdayKey, opened: openedDays) {
                    foldedDay(day)
                } else {
                    if index > 0 || day.id != todayKey {
                        dayDivider(day.date)
                    }
                    ForgeDayStrip(spans: stripSpans(day), marks: stripMarks(day), dayStart: Self.calendarStart(day.date)) { id in
                        scrollTarget = id
                    }
                    if day.id == todayKey {
                        // A detected activity waiting for an answer is today's first entry.
                        ActivitySuggestionPrompt(compact: true)
                        openCard
                        if calmSoFar(day) {
                            Text("A calm day so far: your values are within your range.")
                                .font(ForgeFont.body)
                                .foregroundStyle(ForgeColor.secondaryOnPicture)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .forgeCard(radius: ForgeRadius.card, padding: 14)
                        }
                    }
                    ForEach(ForgeTimeline.blocks(day.entries.filter { !hidden.contains($0.id) })) { block in
                        switch block {
                        case .card(let entry): timelineEntry(entry).id(entry.id)
                        case .rows(let entries): rowsCard(entries)
                        }
                    }
                }
            }
        }
    }

    /// An older day in one line: Charge, Effort and the night, in the rings' colours, and how many entries
    /// open behind it.
    private func foldedDay(_ day: ForgeTimeline.Day) -> some View {
        let summary = snapshot.daySummaries[day.id] ?? DaySummary()
        return Button {
            withAnimation(.snappy) { _ = openedDays.insert(day.id) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(dayTitle(day.date)).font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Text(day.date, format: .dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale))
                        .font(.system(.caption)).foregroundStyle(ForgeColor.secondaryOnPicture)
                }
                Spacer(minLength: 6)
                pinnedValue(DomainTheme.charge.productName, summary.charge.map { "\(Int($0.rounded()))" }, ForgeColor.charge)
                pinnedValue(DomainTheme.effort.productName, summary.effort.map { ForgeToday.effortText($0, scale: effortScale) }, ForgeColor.effort)
                pinnedValue(String(localized: "Sleep"), summary.asleepMinutes.map(Self.hoursMinutes), ForgeColor.rest)
                Text("\(day.entries.count)")
                    .font(.system(.caption, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ForgeColor.secondaryOnPicture)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(ForgeColor.fill))
                    .accessibilityLabel(Text("\(day.entries.count) entries"))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .forgeCard(radius: ForgeRadius.card, padding: 12)
        .accessibilityHint(Text("Shows the day's entries"))
    }

    private func dayDivider(_ date: Date) -> some View {
        (Text(dayTitle(date)).font(.system(.subheadline, weight: .semibold)).foregroundColor(ForgeColor.text)
         + Text(verbatim: "  ") + Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(AppLanguage.activeLocale))
            .font(.system(.subheadline)).foregroundColor(ForgeColor.secondaryOnPicture))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(ForgeColor.card.opacity(surfaceOpacity)))
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func dayTitle(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return String(localized: "Today") }
        if cal.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return date.formatted(.dateTime.weekday(.wide).locale(AppLanguage.activeLocale))
    }

    private static func timeText(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(AppLanguage.activeLocale))
    }

    /// One of the day's large entries on its own card: the morning, the evening, a coach note, a notice.
    /// Its time sits in its own top line, as in Mail.
    private func timelineEntry(_ entry: ForgeTimeline.Entry) -> some View {
        entryCard(entry)
            .forgeCard(radius: ForgeRadius.card, padding: 14)
            // New since the reader last left Today, like an unread mail.
            .overlay(alignment: .topTrailing) {
                if isNew(entry) { newDot.padding(5) }
            }
            .contextMenu { entryMenu(entry) }
    }

    /// Neighbouring small events (a session, walks, a weigh-in, drinks, an ECG, a nap) as rows of one card,
    /// divided by a hairline, so a busy day reads as a few blocks rather than a dozen equal cards.
    private func rowsCard(_ entries: [ForgeTimeline.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    Rectangle().fill(ForgeColor.separator).frame(height: 0.5).padding(.leading, 60)
                }
                entryCard(entry)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .id(entry.id)
                    .overlay(alignment: .topLeading) {
                        if isNew(entry) { newDot.padding(.leading, 8).padding(.top, 10) }
                    }
                    .contentShape(Rectangle())
                    .contextMenu { entryMenu(entry) }
            }
        }
        .forgeCard(radius: ForgeRadius.card, padding: 0)
    }

    private func isNew(_ entry: ForgeTimeline.Entry) -> Bool {
        seenBefore > 0 && entry.date.timeIntervalSince1970 > seenBefore
    }

    private var newDot: some View {
        Circle().fill(ForgeColor.accent).frame(width: 8, height: 8)
            .accessibilityLabel(Text("New"))
    }

    /// The time an entry shows in its top line, nil for a figure that only knows its day.
    private func time(_ entry: ForgeTimeline.Entry) -> String? {
        entry.timed ? Self.timeText(entry.date) : nil
    }

    /// Holding an entry: hide it, ask why, hear its kind less often or not at all, or correct what it shows.
    @ViewBuilder private func entryMenu(_ entry: ForgeTimeline.Entry) -> some View {
        Button { hide(entry.id) } label: { Label("Hide", systemImage: "eye.slash") }
        switch entry.kind {
        case .coach(let origin):
            Button { whyEntry = entry } label: { Label("Why am I seeing this?", systemImage: "info.circle") }
            if let kind = Self.noteKind(origin) {
                Button { ForgeNotices.add(kind.rawValue, to: ForgeNotices.lessOftenKey) } label: {
                    Label("Less often", systemImage: "tortoise")
                }
                Button(role: .destructive) { UserDefaults.standard.set(false, forKey: kind.enabledKey) } label: {
                    Label("Turn this kind off", systemImage: "bell.slash")
                }
            }
        case .notice:
            if let topic = entry.notice?.topic, entry.notice?.key != ForgeNotices.nightPendingKey {
                Button { ForgeNotices.add(topic, to: ForgeNotices.lessOftenKey) } label: {
                    Label("Less often", systemImage: "tortoise")
                }
                Button(role: .destructive) { ForgeNotices.add(topic, to: ForgeNotices.mutedKey); Task { await load() } } label: {
                    Label("Turn this kind off", systemImage: "bell.slash")
                }
            }
        case .wake, .nap:
            Button(action: onSleep) { Label("Correct the night", systemImage: "pencil") }
        default:
            EmptyView()
        }
    }

    private func hide(_ id: String) {
        var ids = hiddenRaw.split(separator: "\n").map(String.init)
        ids.append(id)
        hiddenRaw = ids.suffix(200).joined(separator: "\n")
    }

    static func noteKind(_ origin: ForgeTimeline.CoachNote.Origin) -> ForgeCoachNotes.Kind? {
        switch origin {
        case .brief: return .morning
        case .afterWorkout: return .afterWorkout
        case .evening: return .evening
        default: return nil
        }
    }

    // MARK: Ratings

    private func rating(_ id: String) -> Int {
        ratingsRaw.split(separator: "\n").first { $0.hasPrefix(id + ":") }
            .flatMap { $0.split(separator: ":").last.flatMap { Int($0) } } ?? 0
    }

    private func rate(_ entry: ForgeTimeline.Entry, origin: ForgeTimeline.CoachNote.Origin, _ value: Int) {
        guard let id = entry.sourceId else { return }
        var lines = ratingsRaw.split(separator: "\n").map(String.init).filter { !$0.hasPrefix(id + ":") }
        if rating(id) != value { lines.append("\(id):\(origin.rawValue):\(value)") }
        ratingsRaw = lines.suffix(300).joined(separator: "\n")
        // A second thumbs down for a kind asks, once, whether to hear it less often. Nothing changes by itself.
        let downs = lines.filter { $0.hasSuffix(":\(origin.rawValue):-1") }.count
        if value < 0, downs >= 2, let kind = Self.noteKind(origin),
           !ForgeNotices.list(ForgeNotices.lessOftenKey).contains(kind.rawValue) {
            askLessOften = entry.id
        }
    }

    @ViewBuilder private func entryCard(_ entry: ForgeTimeline.Entry) -> some View {
        switch entry.kind {
        case .coach(let origin): coachCard(entry, origin: origin)
        case .workout: workoutCard(entry)
        case .wake: wakeCard(entry)
        case .nap: napCard(entry)
        case .weight: weightCard(entry)
        case .dayLog(let kind): dayLogCard(entry, kind: kind)
        case .ecg: ecgCard(entry)
        case .notice: if let notice = entry.notice { noticeCard(notice) }
        case .dayEnd: if let end = entry.dayEnd { dayEndCard(end) }
        case .walks: walksCard(entry)
        case .week: weekCard(coachLine: nil)
        }
    }

    /// A notice from the data: what it is about, one line of why, and the one thing to do about it.
    private func noticeCard(_ notice: ForgeTimeline.Notice) -> some View {
        let tint: Color = {
            switch notice.tone {
            case .positive: return ForgeColor.charge
            case .neutral: return ForgeColor.accent
            case .caution: return ForgeColor.effort
            // Red only for the raised body-signal warning; anything else that needs care is amber.
            case .critical: return notice.key == MomentumKind.healthAlert.rawValue ? StrandPalette.statusCritical : ForgeColor.effort
            }
        }()
        let symbol: String = {
            switch TimelineFeed.Topic(rawValue: notice.topic) {
            case .sleep: return "moon.zzz.fill"
            case .load: return "flame.fill"
            case .bodySignals: return "waveform.path.ecg"
            case .movement: return "figure.walk"
            case .goals: return "flag.checkered"
            case .device: return "dot.radiowaves.left.and.right"
            case nil: return "info.circle.fill"
            }
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(tint)
                    // A reached goal greets the reader once, the first time it shows.
                    .symbolEffect(.pulse, options: .repeat(2),
                                  isActive: notice.tone == .positive && seenBefore > 0 && notice.date.timeIntervalSince1970 > seenBefore)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(tint.opacity(ForgeOpacity.wash)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(notice.headline)
                            .font(.system(.body, weight: .semibold)).foregroundStyle(ForgeColor.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        Text(Self.timeText(notice.date)).font(.system(.footnote).monospacedDigit())
                            .foregroundStyle(ForgeColor.secondaryOnPicture)
                    }
                    if !notice.detail.isEmpty {
                        Text(notice.detail)
                            .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondaryOnPicture)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if notice.topic == TimelineFeed.Topic.bodySignals.rawValue {
                let body = snapshot.drivers.filter { Self.bodyLabels.contains($0.label) }
                if !body.isEmpty { rangeRows(body) }
                causeChips.padding(.leading, 52)
            }
            explainBlock(key: notice.key, title: notice.headline, figures: notice.detail)
            if let title = notice.actionTitle, notice.action != .none {
                Group {
                    if notice.action == .charge {
                        NavigationLink(value: ForgeRoute.charge) {
                            Text(title).font(.system(.subheadline, weight: .medium)).foregroundStyle(ForgeColor.accent)
                                .padding(.horizontal, 14).frame(minHeight: 36)
                                .background(Capsule().fill(ForgeColor.fill))
                        }
                        .buttonStyle(.plain)
                    } else {
                        ForgeChip(title: title, prominent: true) { perform(notice.action) }
                    }
                }
                .padding(.leading, 52)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// What may explain raised signals, one tap each: a journal entry for today with a fixed key, which the
    /// warning reads in every language, so it calms down when the cause is known.
    private var causeChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Something that explains it?").font(.system(.footnote, weight: .medium))
                .foregroundStyle(ForgeColor.secondaryOnPicture)
            FlowRows(spacing: 8) {
                ForEach(JournalCause.chips, id: \.self) { cause in
                    ForgeChip(title: cause.chipTitle) { log(cause) }
                }
            }
        }
    }

    private func log(_ cause: JournalCause) {
        Task {
            await repo.saveJournalAnswer(day: Repository.logicalDayKey(Date()), question: cause.question,
                                         answeredYes: true, notes: cause.key)
            model?.reevaluateIllness()
            await load()
        }
    }

    private func perform(_ action: ForgeTimeline.Notice.Action) {
        switch action {
        case .none: break
        case .charge: break
        case .plan: showPlan = true
        case .goals: router.openGoals()
        case .sleep: onSleep()
        case .confirmWake:
            CoachBriefStamp.confirmWake(day: Repository.logicalDayKey(Date()))
            Task { await load() }
        }
    }

    /// Up to here a note shows whole: about four lines of body text.
    private static let shortNoteLength = 180

    private func coachLabel(_ entry: ForgeTimeline.Entry, origin: ForgeTimeline.CoachNote.Origin) -> String {
        // The label says what kind of note it is, in the app's language, whatever first line the stored
        // text carries (older notes start with an English label).
        let label: String
        switch origin {
        case .brief: label = String(localized: "Coach · morning")
        case .checkIn: label = String(localized: "Coach · check-in")
        case .nudge: label = String(localized: "Coach")
        case .weeklyReview: label = String(localized: "Coach · weekly review")
        case .afterWorkout: label = String(localized: "Coach · after your workout")
        case .evening: label = String(localized: "Coach · evening")
        }
        return "\(Self.timeText(entry.date)) · \(label)"
    }

    private func coachCard(_ entry: ForgeTimeline.Entry, origin: ForgeTimeline.CoachNote.Origin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(coachLabel(entry, origin: origin), systemImage: "waveform.path.ecg")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(ForgeColor.accent)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                Button { whyEntry = entry } label: {
                    Image(systemName: "info.circle")
                        .font(.system(.subheadline))
                        .foregroundStyle(ForgeColor.tertiary)
                        .frame(width: 32, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Why am I seeing this?"))
            }
            Text(entry.title)
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(ForgeColor.text)
                .fixedSize(horizontal: false, vertical: true)
            if ForgeNoteBasis.isOutdated(stored: entry.basis, current: snapshot.basis) {
                outdatedLine(origin: origin)
            }
            if askLessOften == entry.id, let kind = Self.noteKind(origin) {
                HStack(spacing: 8) {
                    Text("Hear notes like this less often?").font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(ForgeColor.text)
                    Spacer(minLength: 4)
                    ForgeChip(title: String(localized: "Yes"), prominent: true) {
                        ForgeNotices.add(kind.rawValue, to: ForgeNotices.lessOftenKey); askLessOften = nil
                    }
                    ForgeChip(title: String(localized: "No")) { askLessOften = nil }
                }
            }
            // The figures first, then the words about them.
            noteFigures(entry, origin: origin)
            if usedMemory(entry) {
                Button { onCoachSettings() } label: {
                    Label("From your memory", systemImage: "brain")
                        .font(.system(.footnote, weight: .medium))
                        .foregroundStyle(ForgeColor.secondaryOnPicture)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 32)
            }
            if !entry.detail.isEmpty {
                let opened = openedNotes.contains(entry.id) || entry.detail.count <= Self.shortNoteLength
                Text(Self.markdown(entry.detail))
                    .font(ForgeFont.body)
                    .foregroundStyle(ForgeColor.secondaryOnPicture)
                    .lineLimit(opened ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                if !opened {
                    Button("Read more") { withAnimation(.snappy) { _ = openedNotes.insert(entry.id) } }
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(ForgeColor.accent)
                        .buttonStyle(.plain)
                        .frame(minHeight: 44, alignment: .leading)
                }
            }
            followUps(entry)
            FlowRows(spacing: 8) {
                if origin == .brief, Calendar.current.isDateInToday(entry.date), hasTodaysProposal {
                    ForgeChip(title: String(localized: "See the suggestion"), systemImage: "calendar.badge.plus",
                              prominent: true) { showPlan = true }
                }
                if coachFeatureEnabled {
                    // Only what the coach offered with this note: a note that asks nothing offers nothing.
                    // The answer comes under the note, not in a chat the reader has to open.
                    ForEach(entry.replies, id: \.self) { reply in
                        ForgeChip(title: reply) { answer(entry, reply) }
                    }
                }
                ForgeChip(title: String(localized: "Reply"), systemImage: "square.and.pencil", prominent: true) {
                    focusNote(entry); onCoach()
                }
                thumbs(entry, origin: origin)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { focusNote(entry); onCoach() }
        .accessibilityElement(children: .contain)
    }

    /// A reply to a note goes to the thread the note is in, so the coach reads it with the note in view
    /// rather than in whatever chat happened to be open.
    private func focusNote(_ entry: ForgeTimeline.Entry) {
        guard let id = entry.sourceId.flatMap(UUID.init(uuidString:)) else { return }
        coach.focusConversation(containing: id)
    }

    /// The night or Charge moved after the note was written: the figures under it are current, the words
    /// may not be. The morning note can be written again on request, never by itself.
    private func outdatedLine(origin: ForgeTimeline.CoachNote.Origin) -> some View {
        HStack(spacing: 8) {
            Label("Figures updated since this note", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(ForgeColor.secondaryOnPicture)
            if origin == .brief, coachFeatureEnabled {
                Spacer(minLength: 4)
                Button("Write again") {
                    CoachBriefStamp.invalidateForNewFigures()
                    Task { _ = await coach.startBriefIfNeeded() }
                }
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(ForgeColor.accent)
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }
        }
    }

    // MARK: Coach under an entry (2026-11-07)

    private func thumbs(_ entry: ForgeTimeline.Entry, origin: ForgeTimeline.CoachNote.Origin) -> some View {
        let rated = entry.sourceId.map(rating) ?? 0
        return HStack(spacing: 0) {
            Button { rate(entry, origin: origin, 1) } label: {
                Image(systemName: rated > 0 ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .font(.system(.subheadline)).foregroundStyle(rated > 0 ? ForgeColor.accent : ForgeColor.tertiary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Helpful"))
            Button { rate(entry, origin: origin, -1) } label: {
                Image(systemName: rated < 0 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.system(.subheadline)).foregroundStyle(rated < 0 ? ForgeColor.accent : ForgeColor.tertiary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Not helpful"))
        }
    }

    /// A reply chip: answered under the note when the coach can, else in the chat with the note in view.
    private func answer(_ entry: ForgeTimeline.Entry, _ reply: String) {
        guard let id = entry.sourceId.flatMap(UUID.init(uuidString:)), coach.isConfigured, coach.dataConsent else {
            focusNote(entry); onAsk(reply); return
        }
        asking.insert(entry.id)
        Task {
            await coach.answerInline(to: id, question: reply)
            asking.remove(entry.id)
            await load()
        }
    }

    /// Questions asked under a note and the coach's answers, two sentences each; the chat has the rest.
    @ViewBuilder private func followUps(_ entry: ForgeTimeline.Entry) -> some View {
        if !entry.followUps.isEmpty || asking.contains(entry.id) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(entry.followUps.suffix(2).enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.question).font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                        Text(Self.markdown(Self.firstSentences(item.answer, 2)))
                            .font(ForgeFont.body).foregroundStyle(ForgeColor.secondaryOnPicture)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if asking.contains(entry.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("More in the chat") { focusNote(entry); onCoach() }
                        .font(.system(.footnote, weight: .semibold)).foregroundStyle(ForgeColor.accent)
                        .buttonStyle(.plain).frame(minHeight: 36, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: ForgeRadius.inner, style: .continuous).fill(ForgeColor.fill))
        }
    }

    /// The first sentences of an answer on one line: the rest is in the chat.
    static func firstSentences(_ text: String, _ count: Int) -> String {
        ForgeNoteFigures.sentences(text.split(whereSeparator: \.isNewline).joined(separator: " "))
            .prefix(count).joined(separator: " ")
    }

    /// Whether the coach drew on what it remembers about the reader for this note.
    private func usedMemory(_ entry: ForgeTimeline.Entry) -> Bool {
        guard let message = entry.sourceId.flatMap({ snapshot.notes[$0] }) else { return false }
        let memory: Set<ChatMessage.LocalContextCategory> = [.conversationMemory, .semanticMemory, .keywordMemory]
        return !message.memoryWrites.isEmpty || message.localContextUsed.contains(where: memory.contains)
            || message.toolsUsed.contains { $0.contains("fact") || $0.contains("memory") }
    }

    /// "Explain this" on an entry, and the coach's two sentences once written. Nothing without a coach.
    @ViewBuilder private func explainBlock(key: String, title: String, figures: String) -> some View {
        if let text = snapshot.explanations[key] {
            Text(Self.markdown(text))
                .font(ForgeFont.body).foregroundStyle(ForgeColor.secondaryOnPicture)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: ForgeRadius.inner, style: .continuous).fill(ForgeColor.fill))
        } else if coachFeatureEnabled, coach.isConfigured {
            if asking.contains(key) {
                ProgressView().controlSize(.small)
            } else {
                ForgeChip(title: String(localized: "Explain this"), systemImage: "sparkles") {
                    asking.insert(key)
                    Task {
                        await coach.explainInline(key: key, title: title, figures: figures)
                        asking.remove(key)
                        await load()
                    }
                }
            }
        }
    }

    // MARK: Without a coach (2026-11-07)

    /// A session's Effort against the median of that sport's sessions over four months, when there are
    /// three to compare with; close to usual says so instead of a small number.
    private func versusUsual(_ row: WorkoutRow) -> String? {
        guard let strain = row.strain, let usual = snapshot.usualEffort[row.sport] else { return nil }
        let delta = UnitFormatter.effortValue(strain, scale: effortScale) - UnitFormatter.effortValue(usual, scale: effortScale)
        let step = effortScale == .whoop ? 0.6 : 3
        guard abs(delta) >= step else { return String(localized: "as usual") }
        let amount = effortScale == .whoop
            ? String(format: "%.1f", locale: AppLanguage.activeLocale, abs(delta)) : String(Int(abs(delta).rounded()))
        return delta > 0 ? String(localized: "\(amount) above usual") : String(localized: "\(amount) below usual")
    }

    /// What tomorrow needs most, from the same rules as the rest of the report: a growing sleep debt first,
    /// then a day above its Effort target. Nothing when neither holds.
    private func tomorrowHelp(_ end: ForgeTimeline.DayEnd) -> String? {
        if end.bedtime != nil { return String(localized: "What helps most tomorrow: an early night tonight.") }
        if let effort = snapshot.effortStored, let target = effortTarget, snapshot.charge.carriedCaption == nil,
           ForgeToday.position(effortStored: effort, target: target) == .above {
            return String(localized: "What helps most tomorrow: an easy day after today's load.")
        }
        return nil
    }

    /// What waits for the reader today, in one place: a proposed session and a weigh-in a weight goal misses.
    @ViewBuilder private var openCard: some View {
        let proposal = hasTodaysProposal
        let weighIn = goalStore.activeGoals.contains { $0.kind == .weight }
            && (snapshot.lastWeighDay.map { $0 < Repository.localDayKey(Date().addingTimeInterval(-7 * 86_400)) } ?? true)
        if snapshot.loaded, proposal || weighIn {
            VStack(alignment: .leading, spacing: 0) {
                Label("Open", systemImage: "tray")
                    .font(.system(.footnote, weight: .semibold)).foregroundStyle(ForgeColor.accent)
                    .padding(.bottom, 6)
                if proposal {
                    Button { showPlan = true } label: {
                        factRow(symbol: "calendar.badge.plus", tint: ForgeColor.accent,
                                title: String(localized: "A suggestion waits for your answer"), detail: nil, value: nil, unit: "")
                    }
                    .buttonStyle(.plain).padding(.vertical, 6)
                }
                if weighIn {
                    NavigationLink(value: TabRoute.weight) {
                        factRow(symbol: "figure.stand", tint: ForgeColor.rest,
                                title: String(localized: "No weigh-in for a week"),
                                detail: String(localized: "Your weight goal needs one now and then."), value: nil, unit: "")
                    }
                    .buttonStyle(.plain).padding(.vertical, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .forgeCard(radius: ForgeRadius.card, padding: 14)
        }
    }

    /// True when today has no notice and every night figure with a range lies inside it.
    private func calmSoFar(_ day: ForgeTimeline.Day) -> Bool {
        guard snapshot.loaded, !day.entries.contains(where: { $0.kind == .notice }), !snapshot.driverRanges.isEmpty else {
            return false
        }
        return snapshot.driverRanges.values.allSatisfy { $0.band.contains($0.position) }
    }

    /// The week in seven bars per score, drawn from the stored days, with one plain line or the coach's.
    private func weekCard(coachLine: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your week", systemImage: "calendar")
                .font(.system(.footnote, weight: .semibold)).foregroundStyle(ForgeColor.accent)
            weekBars
            if let pattern = snapshot.weekPattern {
                Text(pattern).font(ForgeFont.body).foregroundStyle(ForgeColor.secondaryOnPicture)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var weekBars: some View {
        let week = snapshot.week
        let maxSleep = max(week.compactMap(\.sleepMinutes).max() ?? 1, 1)
        func column(_ title: String, _ tint: Color, _ value: @escaping (WeekBar) -> Double?, _ scale: Double, _ mean: String) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(.caption, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Spacer(minLength: 4)
                    Text(mean).font(.system(.caption).monospacedDigit()).foregroundStyle(ForgeColor.secondaryOnPicture)
                }
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(week, id: \.day) { bar in
                        let v = value(bar).map { min(max($0 / scale, 0.04), 1) }
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(v == nil ? ForgeColor.fill : tint)
                            .frame(height: 34 * (v ?? 0.08))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 34, alignment: .bottom)
            }
        }
        func mean(_ xs: [Double?]) -> Double? { ForgeToday.weekMean(xs) }
        return HStack(alignment: .top, spacing: 14) {
            column(DomainTheme.charge.productName, ForgeColor.charge, { $0.charge }, 100,
                   mean(week.map(\.charge)).map { "\(Int($0.rounded()))" } ?? "–")
            column(DomainTheme.effort.productName, ForgeColor.effort, { $0.effort }, 100,
                   mean(week.map(\.effort)).map { ForgeToday.effortText($0, scale: effortScale) } ?? "–")
            column(String(localized: "Sleep"), ForgeColor.rest, { $0.sleepMinutes }, maxSleep,
                   mean(week.map(\.sleepMinutes)).map(Self.hoursMinutes) ?? "–")
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Day strip (2026-11-07)

    /// The calendar start of a timeline day's date.
    static func calendarStart(_ date: Date) -> Date { Calendar.current.startOfDay(for: date) }

    /// Sleep and sessions of a day as spans on its strip.
    private func stripSpans(_ day: ForgeTimeline.Day) -> [ForgeDayStrip.Span] {
        var out: [ForgeDayStrip.Span] = []
        for entry in day.entries {
            switch entry.kind {
            case .wake:
                if let night = snapshot.nights[Int(entry.date.timeIntervalSince1970)] {
                    out.append(.init(start: night.start, end: night.end, tint: ForgeColor.rest, target: entry.id))
                }
            case .nap:
                if let minutes = entry.value {
                    out.append(.init(start: entry.date.addingTimeInterval(-minutes * 60), end: entry.date,
                                     tint: ForgeColor.rest, target: entry.id))
                }
            case .workout:
                if let row = entry.sourceId.flatMap({ snapshot.workouts[$0] }) {
                    out.append(.init(start: Date(timeIntervalSince1970: TimeInterval(row.startTs)),
                                     end: Date(timeIntervalSince1970: TimeInterval(row.endTs)), tint: ForgeColor.effort, target: entry.id))
                }
            case .walks:
                for row in entry.walkIds.compactMap({ snapshot.workouts[$0] }) {
                    out.append(.init(start: Date(timeIntervalSince1970: TimeInterval(row.startTs)),
                                     end: Date(timeIntervalSince1970: TimeInterval(row.endTs)), tint: ForgeColor.effort, target: entry.id))
                }
            default:
                break
            }
        }
        return out
    }

    /// Notes and notices of a day as marks on its strip.
    private func stripMarks(_ day: ForgeTimeline.Day) -> [ForgeDayStrip.Mark] {
        day.entries.compactMap { entry in
            switch entry.kind {
            case .coach: return .init(at: entry.date, tint: ForgeColor.accent, target: entry.id)
            case .notice: return .init(at: entry.date, tint: ForgeColor.text, target: entry.id)
            default: return nil
            }
        }
    }

    /// The coach's emphasis rendered (bold figures), never raw asterisks.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    // MARK: Figures under a coach note (read on the device, never written by the model)

    @ViewBuilder private func noteFigures(_ entry: ForgeTimeline.Entry, origin: ForgeTimeline.CoachNote.Origin) -> some View {
        if origin == .brief || origin == .checkIn, !snapshot.drivers.isEmpty,
           Calendar.current.isDateInToday(entry.date) {
            driverRows
        } else if let row = entry.workoutId.flatMap({ snapshot.workouts[$0] }) {
            NavigationLink(value: ForgeRoute.workout(startTs: row.startTs, sport: row.sport)) {
                HStack(spacing: 10) {
                    WorkoutTypeIcon(workoutType: row.sport, size: 15, weight: .semibold,
                                    color: AppleInspiredColors.role(forSport: row.sport).color)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(ForgeColor.fill))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(WorkoutSource.localizedDisplaySport(row.sport))
                            .font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                        Text(workoutDetail(row)).font(.system(.caption)).foregroundStyle(ForgeColor.secondaryOnPicture)
                    }
                    Spacer()
                    if let strain = row.strain {
                        Text(ForgeToday.effortText(strain, scale: effortScale))
                            .font(ForgeFont.rounded(20, .bold)).foregroundStyle(ForgeColor.text)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: ForgeRadius.inner, style: .continuous).fill(ForgeColor.fill))
            }
            .buttonStyle(.plain)
            if let zones = WorkoutZones.percents(row.zonesJSON) {
                ForgeZoneBar(percents: zones,
                             minutes: (row.durationS ?? Double(max(row.endTs - row.startTs, 0))) / 60)
            }
        } else if origin == .weeklyReview, Calendar.current.isDateInToday(entry.date), !snapshot.week.isEmpty {
            weekBars
        } else if origin == .evening, let effort = snapshot.effortStored,
                  let target = effortTarget, Calendar.current.isDateInToday(entry.date) {
            ForgeEffortTargetBar(effort: effort, target: target, scale: effortScale)
        }
        // The night a morning note reads, inside the note instead of beside it.
        if let night = entry.wake.flatMap({ snapshot.nights[Int($0.timeIntervalSince1970)] }) {
            Button(action: onSleep) { nightSummary(night) }
                .buttonStyle(.plain)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: ForgeRadius.inner, style: .continuous).fill(ForgeColor.fill))
        }
    }

    /// Today's three strongest Charge drivers, as the morning note and the morning report show them: each
    /// night placed on the wearer's usual range, read through the Charge page's own function.
    private var driverRows: some View {
        rangeRows(Array(snapshot.drivers.prefix(3)))
    }

    /// Driver rows with the usual range behind the night's figure, where there is one.
    private func rangeRows(_ drivers: [ChargeDriver]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(drivers.enumerated()), id: \.offset) { index, driver in
                if index > 0 { Rectangle().fill(ForgeColor.separator).frame(height: 0.5) }
                let range = snapshot.driverRanges[driver.label]
                ForgeWhyRow(label: driver.label, value: ForgeToday.driverValue(driver.valueText), delta: driver.deltaPoints,
                            usual: range?.text ?? (driver.baselineText.isEmpty ? nil : ForgeToday.driverUsual(driver.baselineText)),
                            track: range.map { ($0.position, nil) }, band: range?.band)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(ChargeBreakdownFormat.driverAccessibilityLabel(driver)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: ForgeRadius.inner, style: .continuous).fill(ForgeColor.fill))
    }

    /// The body signals a warning is about, on the usual range.
    private static let bodyLabels: Set<String> = ["Heart rate variability", "Resting heart rate", "Respiratory rate", "Skin temperature"]

    private var hasTodaysProposal: Bool {
        planStore.pending.contains(where: { $0.day == Repository.localDayKey(Date()) })
    }

    @ViewBuilder private func workoutCard(_ entry: ForgeTimeline.Entry) -> some View {
        if let row = entry.sourceId.flatMap({ snapshot.workouts[$0] }) {
            let tint = AppleInspiredColors.role(forSport: row.sport).color
            NavigationLink(value: ForgeRoute.workout(startTs: row.startTs, sport: row.sport)) {
                factRow(icon: AnyView(WorkoutTypeIcon(workoutType: row.sport, size: 15, weight: .semibold, color: tint)),
                        tint: tint, title: WorkoutSource.localizedDisplaySport(row.sport),
                        detail: [workoutDetail(row), versusUsual(row)].compactMap { $0 }.joined(separator: " · "),
                        time: time(entry), value: row.strain.map { ForgeToday.effortText($0, scale: effortScale) },
                        unit: DomainTheme.effort.productName)
                    .forgeEventTile()
            }
            .buttonStyle(LiquidPressStyle())
        }
    }

    /// A weigh-in with its time (only entries that record one reach the timeline).
    private func weightCard(_ entry: ForgeTimeline.Entry) -> some View {
        let system = UnitSystem(rawValue: unitSystemRaw) ?? .metric
        return NavigationLink(value: TabRoute.weight) {
            factRow(symbol: "figure.stand", tint: ForgeColor.rest, title: String(localized: "Weight logged"),
                    detail: snapshot.weightChange30d.map {
                        String(localized: "\(UnitFormatter.massFromKilograms($0, system: system).replacingOccurrences(of: "-", with: "−")) in 30 days")
                    },
                    time: time(entry), value: entry.value.map { UnitFormatter.massFromKilograms($0, system: system) }, unit: "")
                .forgeEventTile()
        }
        .buttonStyle(LiquidPressStyle())
    }

    private func workoutDetail(_ row: WorkoutRow) -> String {
        var parts: [String] = []
        let secs = row.durationS ?? Double(max(row.endTs - row.startTs, 0))
        parts.append(String(localized: "\(Int(secs / 60)) min"))
        if let dm = row.distanceM, dm > 0 { parts.append(UnitFormatter.distanceFromMeters(dm, system: distanceSystem)) }
        if parts.count < 2, let k = row.energyKcal, k > 0 { parts.append("\(Int(k.rounded())) kcal") }
        return parts.joined(separator: " · ")
    }

    private func wakeCard(_ entry: ForgeTimeline.Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onSleep) {
                Group {
                    if let night = snapshot.nights[Int(entry.date.timeIntervalSince1970)] {
                        nightSummary(night)
                    } else {
                        factRow(symbol: "sun.horizon.fill", tint: ForgeColor.rest, title: String(localized: "Woke up"), detail: nil,
                                value: entry.value.map(Self.hoursMinutes), unit: String(localized: "h asleep"))
                    }
                }
                .frame(maxWidth: .infinity)
                .forgeEventTile()
            }
            .buttonStyle(LiquidPressStyle())
            // This morning's night with no coach note over it is the morning report: what moved the
            // Charge, and what it means for training, in the words Momentum uses for the same band.
            if Repository.logicalDayKey(entry.date.addingTimeInterval(4 * 3600)) == Repository.logicalDayKey(Date()) {
                if !snapshot.drivers.isEmpty { driverRows }
                if hasTodaysProposal {
                    ForgeChip(title: String(localized: "See the suggestion"), systemImage: "calendar.badge.plus",
                              prominent: true) { showPlan = true }
                } else if snapshot.charge.carriedCaption == nil, let charge = chargeScore,
                          let line = MomentumBuilder.recoveryActionLine(charge) {
                    Text(line).font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    // The line leads somewhere: a calm breath on a low day, a session on a good one.
                    if [ChargeBand.depleted, .low].contains(ChargeBand.of(score: charge)) {
                        ForgeChip(title: String(localized: "Breathe for two minutes"), systemImage: "wind", prominent: true) {
                            router.openBreathe()
                        }
                    } else {
                        ForgeChip(title: String(localized: "Start a session"), systemImage: "figure.run", prominent: true,
                                  action: onWorkout)
                    }
                }
                if snapshot.charge.carriedCaption == nil, let charge = chargeScore,
                   [ChargeBand.depleted, .low].contains(ChargeBand.of(score: charge)) {
                    causeChips
                }
                if let charge = chargeScore {
                    explainBlock(key: "morning", title: String(localized: "This morning's Charge"),
                                 figures: (["Charge \(Int(charge.rounded()))"]
                                           + snapshot.drivers.prefix(3).map { "\($0.label) \($0.valueText)" }).joined(separator: ", "))
                }
            }
        }
    }

    /// The day's detected and imported walks in one entry; opened, each one leads to its own page.
    @ViewBuilder private func walksCard(_ entry: ForgeTimeline.Entry) -> some View {
        let rows = entry.walkIds.compactMap { snapshot.workouts[$0] }
        let open = openedNotes.contains(entry.id)
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { toggle(entry.id) } } label: {
                factRow(symbol: "figure.walk", tint: AppleInspiredColors.role(forSport: "Walking").color,
                        title: String(localized: "\(rows.count) walks"),
                        detail: rows.compactMap(\.distanceM).reduce(0, +) > 0
                            ? UnitFormatter.distanceFromMeters(rows.compactMap(\.distanceM).reduce(0, +), system: distanceSystem) : nil,
                        time: time(entry), value: entry.value.map(Self.hoursMinutes), unit: String(localized: "h walked"))
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(open ? "Hides the walks" : "Shows each walk"))
            if open {
                ForEach(rows, id: \.startTs) { row in
                    NavigationLink(value: ForgeRoute.workout(startTs: row.startTs, sport: row.sport)) {
                        HStack {
                            Text(Self.timeText(Date(timeIntervalSince1970: TimeInterval(row.startTs))))
                                .font(.system(.subheadline).monospacedDigit()).foregroundStyle(ForgeColor.secondaryOnPicture)
                            Text(workoutDetail(row)).font(.system(.subheadline)).foregroundStyle(ForgeColor.text)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(ForgeColor.tertiary)
                        }
                        .frame(minHeight: 36)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if openedNotes.contains(id) { openedNotes.remove(id) } else { openedNotes.insert(id) }
    }

    /// The evening report: Effort against today's target, the sessions, tomorrow's plan, and the bedtime
    /// only while sleep debt grows.
    private func dayEndCard(_ end: ForgeTimeline.DayEnd) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Your day", systemImage: "moon.stars.fill")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(ForgeColor.accent)
                Spacer(minLength: 6)
                Text(Self.timeText(end.date)).font(.system(.footnote).monospacedDigit())
                    .foregroundStyle(ForgeColor.secondaryOnPicture)
            }
            if let effort = snapshot.effortStored, let target = effortTarget, snapshot.charge.carriedCaption == nil {
                ForgeEffortTargetBar(effort: effort, target: target, scale: effortScale)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(end.sessions == 0 ? String(localized: "No session recorded today.")
                     : end.sessions == 1 ? String(localized: "One session today.")
                     : String(localized: "\(end.sessions) sessions today."))
                if let tomorrow = end.tomorrow { Text(tomorrow) }
                if let bed = end.bedtime {
                    Text("For your sleep need, in bed by \(Self.timeText(bed)).")
                }
                if let help = tomorrowHelp(end) {
                    Text(help).font(.system(.body, weight: .semibold)).foregroundStyle(ForgeColor.text)
                }
            }
            .font(ForgeFont.body)
            .foregroundStyle(ForgeColor.secondaryOnPicture)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The night in one block: when it ran, its Rest, how long, its stages.
    private func nightSummary(_ night: ForgeRecentSleep.Night) -> some View {
        var parts = [String(localized: "\(night.start.formatted(.dateTime.hour().minute().locale(AppLanguage.activeLocale))) to \(night.end.formatted(.dateTime.hour().minute().locale(AppLanguage.activeLocale)))")]
        if let rest = snapshot.restByDay[Repository.localDayKey(night.end)] {
            parts.append("\(DomainTheme.rest.productName) \(Int(rest.rounded()))")
        }
        return VStack(spacing: 10) {
            factRow(symbol: "sun.horizon.fill", tint: ForgeColor.rest, title: String(localized: "Woke up"),
                    detail: parts.joined(separator: " · "), value: Self.hoursMinutes(night.asleepMinutes),
                    unit: String(localized: "h asleep"))
            if night.deep + night.rem + night.light + night.awake > 0 {
                ForgeStageStrip(deep: night.deep, rem: night.rem, light: night.light, awake: night.awake)
            }
        }
    }

    private func napCard(_ entry: ForgeTimeline.Entry) -> some View {
        Button(action: onSleep) {
            factRow(symbol: "moon.zzz.fill", tint: ForgeColor.rest, title: String(localized: "Nap"), detail: nil,
                    time: time(entry), value: entry.value.map(Self.hoursMinutes), unit: String(localized: "h asleep"))
                .forgeEventTile()
        }
        .buttonStyle(LiquidPressStyle())
    }

    @ViewBuilder private func dayLogCard(_ entry: ForgeTimeline.Entry, kind: ForgeTimeline.DayLog.Kind) -> some View {
        let value = entry.value ?? 0
        switch kind {
        case .drink:
            NavigationLink(value: TabRoute.hydration) {
                factRow(symbol: "drop.fill", tint: ForgeColor.accent, title: String(localized: "Drink"), detail: nil,
                        time: time(entry), value: UnitFormatter.localizedMark(String(format: "%.1f", HydrationGoal.litres(fromML: value))), unit: "L")
                    .forgeEventTile()
            }
            .buttonStyle(LiquidPressStyle())
        case .food:
            NavigationLink(value: TabRoute.energy) {
                factRow(symbol: "fork.knife", tint: ForgeColor.effort, title: String(localized: "Food"), detail: nil,
                        time: time(entry), value: "\(Int(value.rounded()))", unit: "kcal")
                    .forgeEventTile()
            }
            .buttonStyle(LiquidPressStyle())
        case .journal:
            NavigationLink(value: MoreDestination.insights) {
                factRow(symbol: "book.closed.fill", tint: ForgeColor.accent, title: String(localized: "Journal"), detail: nil,
                        time: time(entry), value: "\(Int(value))", unit: String(localized: "entries"))
                    .forgeEventTile()
            }
            .buttonStyle(LiquidPressStyle())
        }
    }

    private func ecgCard(_ entry: ForgeTimeline.Entry) -> some View {
        NavigationLink(value: MoreDestination.ecg) {
            factRow(symbol: "waveform.path.ecg.rectangle", tint: ForgeColor.accent, title: String(localized: "ECG"), detail: nil,
                    time: time(entry), value: entry.value.map { "\(Int($0))" }, unit: "bpm")
                .forgeEventTile()
        }
        .buttonStyle(LiquidPressStyle())
    }

    /// The timeline's plain event, laid out like a mail: what happened and its time on the first line,
    /// the detail and its figure on the second, beside a round icon.
    private func factRow(symbol: String, tint: Color, title: String, detail: String?, time: String? = nil,
                         value: String?, unit: String) -> some View {
        factRow(icon: AnyView(Image(systemName: symbol).font(.system(.subheadline, weight: .semibold)).foregroundStyle(tint)),
                tint: tint, title: title, detail: detail, time: time, value: value, unit: unit)
    }

    private func factRow(icon: AnyView, tint: Color, title: String, detail: String?, time: String?,
                         value: String?, unit: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            icon
                .frame(width: 34, height: 34)
                .background(Circle().fill(tint.opacity(ForgeOpacity.wash)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.system(.body, weight: .semibold)).foregroundStyle(ForgeColor.text).lineLimit(1)
                    Spacer(minLength: 6)
                    if let time {
                        Text(time).font(.system(.footnote).monospacedDigit()).foregroundStyle(ForgeColor.secondaryOnPicture)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let detail {
                        Text(detail).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondaryOnPicture).lineLimit(2)
                    }
                    Spacer(minLength: 6)
                    if let value {
                        (Text(value).font(ForgeFont.rounded(19, .bold)).foregroundColor(ForgeColor.text)
                         + Text(unit.isEmpty ? "" : " " + unit).font(.system(.caption)).foregroundColor(ForgeColor.secondaryOnPicture))
                            .lineLimit(1)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The moment the note policy judges against. DEBUG `--forge-notes-at HH:MM` pins it to that time of
    /// today, so the after-workout and evening notes can be exercised in the simulator outside their hours.
    private static func notesClock(_ now: Date) -> Date {
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--forge-notes-at"), i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").compactMap { Int($0) }
            if parts.count == 2,
               let pinned = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now) {
                return pinned
            }
        }
        #endif
        return now
    }

    #if DEBUG
    private static func demoCoachNotes(now: Date) -> [ForgeTimeline.CoachNote] {
        let cal = Calendar.current
        func at(_ hour: Int, _ minute: Int, daysAgo: Int = 0) -> Date {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? now
        }
        return [
            .init(id: "demo-evening", date: at(20, 55), text: String(localized: "Evening recap") + "\n\nStrong day, inside your Effort target. Strength took most of it; an early night keeps tomorrow's Charge up.", origin: .evening),
            .init(id: "demo-workout", date: at(11, 5), text: String(localized: "After your workout") + "\n\nSteady walk, heart rate stayed easy. Good recovery work after yesterday's strength session.", origin: .afterWorkout),
            .init(id: "demo-brief", date: at(7, 52), text: "Well recovered, push a bit today. HRV is above your usual range and resting heart rate is low. A harder session fits.", origin: .brief),
            .init(id: "demo-weekly", date: at(21, 30, daysAgo: 1), text: String(localized: "Weekly review") + "\n\nFive sessions this week, the plan is on track. Sleep held at about seven and a half hours.", origin: .weeklyReview),
        ].filter { $0.date <= now }
    }
    #endif

    /// A walk the wearer did not start: detected by the strap or the app, or imported. Those of a day share
    /// one entry; a walk started here, logged by hand or from a file stays an entry of its own.
    static func bundlesAsWalk(_ row: WorkoutRow) -> Bool {
        guard row.sport.localizedCaseInsensitiveContains("walk") else { return false }
        switch WorkoutSource.classify(row.source) {
        case .whoop, .apple, .detected, .confirmed, .oura: return true
        case .manual, .lifting, .activityFile, .hevy: return false
        }
    }

    /// The clearest finding of What works, in the words that page uses: only a solid one, else nothing.
    @MainActor static func weekPattern(repo: Repository) async -> String? {
        let hub = InsightsHubViewModel()
        await hub.load(repo: repo)
        guard let best = hub.ranked.first(where: { $0.confidence == .solid }) else { return nil }
        return "\(best.behavior): \(ForgeEffectWording.line(delta: best.effect.delta, percent: best.effect.pctChange)) (\(ForgeEffectWording.lag(best.lag)))"
    }

    static func hoursMinutes(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Load

    /// How far back the timeline reaches.
    private static let timelineDays = 7

    /// Where a figure that only knows its day sits: the start of that logical day, below what has a time.
    private static func endOfTimelineDay(_ day: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day).flatMap { Calendar.current.date(byAdding: .hour, value: 4, to: $0) }
    }

    /// Per day, one line each for drinks, food and the journal, so a day of small entries stays one row.
    private static func dayLogs(repo: Repository, now: Date) async -> [ForgeTimeline.DayLog] {
        var logs: [ForgeTimeline.DayLog] = []
        let cal = Calendar.current
        let keys = (0..<timelineDays).compactMap { cal.date(byAdding: .day, value: -$0, to: now) }.map(Repository.localDayKey)
        for day in keys {
            let total = await repo.hydrationTotal(day: day)
            guard total > 0 else { continue }
            if let last = repo.hydrationEntries(day: day).map(\.loggedAt).max() {
                logs.append(.init(kind: .drink, date: last, value: total))
            } else if let at = endOfTimelineDay(day) {
                logs.append(.init(kind: .drink, date: at, value: total, timed: false))
            }
        }
        if let from = keys.last, let to = keys.first {
            for (day, nutrition) in await repo.nutritionByDay(from: from, to: to) {
                if let kcal = nutrition.calories, kcal > 0, let at = endOfTimelineDay(day) {
                    logs.append(.init(kind: .food, date: at, value: kcal, timed: false))
                }
            }
        }
        let journal = Dictionary(grouping: await repo.journalEntries(days: timelineDays + 1), by: \.day)
        for (day, entries) in journal where keys.contains(day) {
            if let at = endOfTimelineDay(day) {
                logs.append(.init(kind: .journal, date: at, value: Double(entries.count), timed: false))
            }
        }
        return logs
    }

    private func load() async {
        let now = Date()
        let allDays = repo.days
        let todayKey = Repository.logicalDayKey(now)
        let displayDay = repo.today ?? allDays.last(where: { $0.day == todayKey })
        var next = Snapshot()
        next.charge = ChargeDisplay.resolve(days: allDays, displayDay: displayDay, selectedDayKey: todayKey, isToday: true)
        let restSeries = await repo.exploreSeries(key: "sleep_performance", source: Repository.whoopSource, days: 30)
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        next.rest = DashboardRestScore.value(day: todayKey, days: allDays, importedSleep: repo.importedSleep)
            ?? TodayView.freshRestScore(todayValue: displayDay.flatMap { restByDay[$0.day] },
                                        lastDay: restSeries.last?.day, lastValue: restSeries.last?.value,
                                        isTodaySelected: true, todayKey: todayKey)
        next.effortDay = todayKey
        // Keeps today's ring while the live figure is worked out below: a reload never blanks it to a dash.
        if snapshot.effortDay == todayKey { next.effortStored = snapshot.effortStored }
        let calibrating: Bool = { if case .calibrating = next.charge { return true } else { return false } }()
        let chargeRow = TodayView.lastScoredRecoveryDay(days: allDays, selectedDayKey: todayKey, isToday: true,
                                                        todayScored: displayDay?.recovery != nil,
                                                        isCalibrating: calibrating) ?? displayDay
        next.drivers = ChargeBreakdownFormat.compute(row: chargeRow, baselines: repo.chargeBaselines,
                                                     restScore: next.rest)?.drivers ?? []
        // Each driver's night on the usual range, through the Charge page's own function.
        if let chargeRow {
            for label in Set(next.drivers.map(\.label)).union(Self.bodyLabels) {
                if let r = ForgeChargeDetailView.usualRange(label, row: chargeRow, days: allDays) {
                    next.driverRanges[label] = DriverRange(text: r.text, position: r.position, band: r.band)
                }
            }
        }

        next.restByDay = restByDay
        let workouts = await repo.workoutRows(days: Self.timelineDays + 1, reconcileHrCap: 0)
        var input = ForgeTimeline.Input()
        // Weigh-ins that carry their own time (NOOP's own entries; Apple's daily cells have none).
        for w in await repo.weightEntries(days: Self.timelineDays + 1) {
            next.lastWeighDay = max(next.lastWeighDay ?? "", w.day)
            if let at = w.takenAt {
                input.weights.append(.init(date: at, kg: w.value))
            } else if let at = Self.endOfTimelineDay(w.day) {
                input.weights.append(.init(date: at, kg: w.value, timed: false))
            }
        }
        next.weightChange30d = await repo.weightTrendSummary(days: 91)?.change30dKg
        if next.lastWeighDay == nil {
            next.lastWeighDay = await repo.weightEntries(days: 60).map(\.day).max()
        }
        // Each sport's usual Effort: the median of its sessions over four months, from three sessions on.
        let longer = await repo.workoutRows(days: 120, reconcileHrCap: 0)
        for (sport, rows) in Dictionary(grouping: longer.filter { $0.strain != nil }, by: \.sport) where rows.count >= 3 {
            let xs = rows.compactMap(\.strain).sorted()
            next.usualEffort[sport] = xs.count % 2 == 1 ? xs[xs.count / 2] : (xs[xs.count / 2 - 1] + xs[xs.count / 2]) / 2
        }
        // The last seven days for the week card.
        next.week = (0..<7).reversed().compactMap { back -> WeekBar? in
            guard let date = Calendar.current.date(byAdding: .day, value: -back, to: now) else { return nil }
            let key = Repository.logicalDayKey(date)
            let row = allDays.last { $0.day == key }
            return WeekBar(day: key, charge: row?.recovery, effort: row?.strain, sleepMinutes: row?.totalSleepMin)
        }
        for w in workouts {
            let id = "\(w.startTs)|\(w.sport)"
            next.workouts[id] = w
            input.workouts.append(.init(id: id, start: Date(timeIntervalSince1970: TimeInterval(w.startTs)),
                                        end: Date(timeIntervalSince1970: TimeInterval(w.endTs)), sport: w.sport,
                                        effort: w.strain, distanceM: w.distanceM, energyKcal: w.energyKcal,
                                        bundles: Self.bundlesAsWalk(w)))
        }
        // The same nights the Sleep tab shows, a short one included: a bad night is the one that matters.
        let recent = await ForgeRecentSleep.load(repo: repo, days: Self.timelineDays + 1)
        for night in recent.nights {
            next.nights[Int(night.end.timeIntervalSince1970)] = night
            input.sleeps.append(.init(start: night.start, end: night.end, minutesAsleep: night.asleepMinutes, rest: nil))
        }
        input.naps = recent.naps
        // What a note written now stands over, and what earlier notes of today are compared against.
        let lastNight = recent.nights.filter { Repository.logicalDayKey($0.end.addingTimeInterval(4 * 3600)) == todayKey }
            .max { $0.end < $1.end }
        next.basis = ForgeNoteBasis.make(day: todayKey, charge: next.charge.pct, asleepMinutes: lastNight?.asleepMinutes)
        ForgeNoteBasis.current = next.basis
        input.dayLogs = await Self.dayLogs(repo: repo, now: now)
        if let store = await repo.storeHandle(), let readings = try? await store.ecgReadings() {
            let cutoff = now.addingTimeInterval(-Double(Self.timelineDays + 1) * 86_400)
            input.ecgs = readings.map { .init(id: $0.id, date: Date(timeIntervalSince1970: TimeInterval($0.endTs)), averageHr: $0.averageHr) }
                .filter { $0.date >= cutoff }
        }
        // Answers to "explain this" written today, by entry key; they are not follow-ups of a note.
        let explainPrefix = ForgeCoachNotes.explanationKey("", day: todayKey)
        var explanationIds = Set<String>()
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix(explainPrefix) {
            if let id = value as? String { explanationIds.insert(id); next.explanations[String(key.dropFirst(explainPrefix.count))] = id }
        }
        if coachFeatureEnabled {
            let cutoff = now.addingTimeInterval(-Double(Self.timelineDays + 1) * 86_400)
            for conversation in coach.conversations {
                for m in conversation.messages where explanationIds.contains(m.id.uuidString) {
                    if let key = next.explanations.first(where: { $0.value == m.id.uuidString })?.key {
                        next.explanations[key] = m.text
                    }
                }
                for (index, m) in conversation.messages.enumerated() where m.role == .assistant && m.date >= cutoff {
                    let origin: ForgeTimeline.CoachNote.Origin
                    switch m.origin {
                    case .brief: origin = .brief
                    case .checkIn: origin = .checkIn
                    case .nudge: origin = ForgeTimeline.CoachNote.Origin.legacy(nudgeText: m.text)
                    case .afterWorkout: origin = .afterWorkout
                    case .evening: origin = .evening
                    case .weeklyReview: origin = .weeklyReview
                    case .reply: continue
                    }
                    // What the reader asked after this note and what the coach answered, until the coach
                    // speaks up on its own again.
                    var followUps: [ForgeTimeline.FollowUp] = []
                    var j = index + 1
                    let thread = conversation.messages
                    while j < thread.count, !(thread[j].role == .assistant && thread[j].origin.isCoachInitiated) {
                        if thread[j].role == .user, j + 1 < thread.count, thread[j + 1].role == .assistant,
                           !explanationIds.contains(thread[j + 1].id.uuidString) {
                            followUps.append(.init(question: thread[j].text, answer: thread[j + 1].text))
                            j += 2
                        } else {
                            j += 1
                        }
                    }
                    input.coach.append(.init(id: m.id.uuidString, date: m.date, text: m.text, origin: origin,
                                             workoutId: m.workoutId, replies: m.replies, basis: m.basis,
                                             followUps: followUps))
                    next.notes[m.id.uuidString] = m
                }
            }
        }
        #if DEBUG
        // `--demo-coach`: canned notes so screenshots show coach cards without a provider key. Shown only,
        // never written to the transcript.
        if CommandLine.arguments.contains("--demo-coach") {
            input.coach += Self.demoCoachNotes(now: now)
        }
        #endif
        next.explanations = next.explanations.filter { !explanationIds.contains($0.value) }
        // The data's own notices: the Momentum signals worth an entry and a night still on the strap, each
        // through the week-long cooldown of its topic.
        let momentumContext = DashboardMomentum.context(
            displayDay: displayDay, allDays: allDays, hrvBaseline: repo.chargeBaselines?.hrv,
            dayKey: todayKey, isToday: true,
            steps: DailyStepsReading.resolve(strapSteps: displayDay?.steps, appleSteps: nil, estimatedSteps: nil),
            stepGoal: momentumStepGoal, live: DashboardMomentum.LiveInput(model: model))
        let momentum = MomentumResolver.feed(context: momentumContext, snoozedRaw: momentumSnoozedRaw,
                                             lastKind: momentumLastKind, lastAt: momentumLastAt, retrospective: false)
        let nightPending = await coach.unconfirmedWakeNeedingReview(now: now) != nil
        input.notices = ForgeNotices.notices(momentum: momentum, nightPending: nightPending, day: todayKey, now: now)
        // The evening report, once the evening has begun: two hours before the planned bedtime, from 19:00.
        let bedtime = ForgeToday.plannedBedtime(now: now)
        let eveningStart = ForgeToday.eveningStart(now: now, bedtime: bedtime)
        if now >= eveningStart, !ForgeCoachNotes.isQuiet(eveningStart) {
            let tomorrowKey = Calendar.current.date(byAdding: .day, value: 1, to: now).map(Repository.localDayKey)
            let planned = planStore.proposals.first { $0.day == tomorrowKey && $0.status.isCommitment }
            let tomorrow = planned.map { p in
                p.durationMin.map { String(localized: "Tomorrow: \(WorkoutSource.localizedDisplaySport(p.sport)), \($0) min.") }
                    ?? String(localized: "Tomorrow: \(WorkoutSource.localizedDisplaySport(p.sport)).")
            }
            let sessions = workouts.filter { Repository.logicalDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == todayKey }.count
            input.dayEnd = .init(date: eveningStart, sessions: sessions, tomorrow: tomorrow,
                                 bedtime: momentum.contains { $0.kind == .sleepCatchUp } ? bedtime : nil)
        }
        // The week card on Sunday from 18:00, beside the coach's weekly review or in its place.
        let cal = Calendar.current
        if cal.component(.weekday, from: now) == 1, let six = cal.date(bySettingHour: 18, minute: 0, second: 0, of: now) {
            input.week = six
            if snapshot.weekPattern == nil || snapshot.week.last?.day != todayKey {
                next.weekPattern = await Self.weekPattern(repo: repo)
            } else {
                next.weekPattern = snapshot.weekPattern
            }
        }
        next.timeline = ForgeTimeline.build(input, now: now, days: Self.timelineDays, dayKey: { Repository.logicalDayKey($0) })
        for day in next.timeline {
            let row = allDays.last { $0.day == day.id }
            let night = recent.nights.filter { Repository.logicalDayKey($0.end.addingTimeInterval(4 * 3600)) == day.id }
                .max { $0.end < $1.end }
            next.daySummaries[day.id] = DaySummary(charge: row?.recovery, effort: row?.strain, asleepMinutes: night?.asleepMinutes)
        }
        next.loaded = true

        // The heaviest read last, as on the shipped Today: Effort floors at the stored row, so the live
        // refinement can only raise the ring, never pull it back. A read that changed nothing redraws nothing.
        guard !Task.isCancelled else { return }
        if next != snapshot { snapshot = next }
        let live = await LiveEffort.today(repo: repo, profile: profile, restingHr: displayDay?.restingHr)
        let effort = StrainScorer.effectiveEffort(live: live, stored: displayDay?.day == todayKey ? displayDay?.strain : nil)
        guard !Task.isCancelled else { return }
        if effort != snapshot.effortStored { snapshot.effortStored = effort }
        // This Today feeds the Momentum page and widget, as the shipped ones do.
        DashboardMomentum.publish(
            context: momentumContext,
            allDays: allDays,
            snoozedRaw: momentumSnoozedRaw, lastKind: momentumLastKind, lastAt: momentumLastAt,
            retrospective: false)
        // A due note (after a workout, in the evening) is written now, the same moment the brief uses.
        // When it lands, the transcript changes and `reloadKey` brings it into the timeline.
        if coachFeatureEnabled {
            Task { await coach.runForgeNotesIfDue(workouts: workouts, now: Self.notesClock(now)) }
        }
    }
}
/// A day from midnight to midnight on one thin strip: sleep and sessions as spans in their scores' colours,
/// notes and notices as dots. Tapping a span or a dot scrolls to its entry. One strip above the day, not an
/// axis beside the entries.
struct ForgeDayStrip: View {
    struct Span: Equatable { let start: Date; let end: Date; let tint: Color; let target: String }
    struct Mark: Equatable { let at: Date; let tint: Color; let target: String }

    let spans: [Span]
    let marks: [Mark]
    let dayStart: Date
    let onSelect: (String) -> Void

    private func x(_ date: Date, _ width: CGFloat) -> CGFloat {
        CGFloat(min(max(date.timeIntervalSince(dayStart) / 86_400, 0), 1)) * width
    }

    var body: some View {
        if spans.isEmpty && marks.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 3) {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(ForgeColor.card.opacity(0.55)).frame(height: 8)
                        ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                            let a = x(span.start, w), b = x(span.end, w)
                            if b > a {
                                Capsule().fill(span.tint)
                                    .frame(width: max(b - a, 4), height: 8)
                                    .offset(x: a)
                                    .onTapGesture { onSelect(span.target) }
                            }
                        }
                        ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                            Circle().fill(mark.tint)
                                .overlay(Circle().stroke(ForgeColor.card, lineWidth: 1.5))
                                .frame(width: 10, height: 10)
                                .offset(x: x(mark.at, w) - 5)
                                .onTapGesture { onSelect(mark.target) }
                        }
                    }
                    .frame(height: 12)
                }
                .frame(height: 12)
                HStack {
                    ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                        Text(verbatim: "\(hour)")
                        if hour < 24 { Spacer(minLength: 0) }
                    }
                }
                .font(.system(.caption2).monospacedDigit())
                .foregroundStyle(ForgeColor.secondaryOnPicture)
            }
            .padding(.horizontal, 4)
            .accessibilityHidden(true)
        }
    }
}

/// Log and Start on a solid surface, the page's two actions standing out from the see-through tiles under them.
private struct ForgeTodayActionSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(ForgeColor.card))
            .shadow(color: .black.opacity(colorScheme == .light ? 0.06 : 0), radius: 10, y: 3)
    }
}

private extension View {
    /// An event in its entry, which carries the surface.
    func forgeEventTile() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The recent nights and naps as the Sleep tab resolves them: every source, one night per wake day. The
/// on-device nights a strap produces live under the computed source, which the imported-only read misses.
enum ForgeRecentSleep {
    struct Night: Equatable {
        let start: Date
        let end: Date
        let asleepMinutes: Double
        let deep: Double
        let rem: Double
        let light: Double
        let awake: Double
    }

    /// Below this a block off the main night is a detector crumb, not a nap.
    private static let napMinutes = 10.0

    static func load(repo: Repository, days: Int) async -> (nights: [Night], naps: [ForgeTimeline.Nap]) {
        let sessions = await repo.allSleepSessions(days: days)
        let habitual = await repo.habitualMidsleepSec()
        var nights: [Night] = []
        var naps: [ForgeTimeline.Nap] = []
        for group in SleepModel.navDays(navSessions: sessions) {
            let main = SleepView.mainNightGroup(group, habitualMidsleepSec: habitual)
            let asleep = main.reduce(0) { $0 + SleepNight.asleepMinutes($1.stagesJSON, effectiveStartTs: $1.effectiveStartTs) }
            guard let end = main.map(\.endTs).max(), asleep > 0 else { continue }
            // A computed night stores timed segments, an imported one totals; both reach the strip.
            let stages = main.compactMap {
                SleepNight.segments($0.stagesJSON, sessionStart: $0.effectiveStartTs)?.minutes ?? SleepNight.minutes($0.stagesJSON)
            }
            nights.append(Night(start: Date(timeIntervalSince1970: TimeInterval(SleepNight.onsetTs(main))),
                                end: Date(timeIntervalSince1970: TimeInterval(end)),
                                asleepMinutes: asleep,
                                deep: stages.reduce(0) { $0 + $1.deep }, rem: stages.reduce(0) { $0 + $1.rem },
                                light: stages.reduce(0) { $0 + $1.light }, awake: stages.reduce(0) { $0 + $1.awake }))
            let mainStarts = Set(main.map(\.startTs))
            for block in group where !mainStarts.contains(block.startTs) {
                let minutes = SleepNight.asleepMinutes(block.stagesJSON, effectiveStartTs: block.effectiveStartTs)
                if minutes >= napMinutes {
                    naps.append(.init(start: Date(timeIntervalSince1970: TimeInterval(block.effectiveStartTs)),
                                      end: Date(timeIntervalSince1970: TimeInterval(block.endTs)), minutesAsleep: minutes))
                }
            }
        }
        return (nights, naps)
    }
}

/// Today's picture again, over the top and bottom edges of the page, opaque where cards are gone and clear where
/// they show fully. The top edge joins in once the rings have scrolled away.
private struct ForgeTodayEdges: View {
    let heroHidden: Bool

    var body: some View {
        Color.clear
            .overlay { ForgeBackground(tab: .today, showsMotif: true) }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(stops: heroHidden
                                   ? [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)]
                                   : [.init(color: .clear, location: 0), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 112)
                    Color.clear
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.6)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 120)
                }
            }
            // One flat image, so scrolling under it only blends it instead of masking it again on each frame.
            .drawingGroup()
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#endif
