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
    @AppStorage(ForgeTodayWidgetStore.belowTimelineKey) private var tilesBelowTimeline = false
    /// Bumped by a tap on the pinned bar: back to the rings.
    @State private var backToTop = 0
    /// Long notes opened in place: figures and a few lines first, the rest on request.
    @State private var openedNotes: Set<String> = []

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
                            ActivitySuggestionPrompt()
                            MorningSuggestionCard(showPlan: $showPlan)
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
            if phase == .active { Task { await load() } }
        }
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

    /// The three scores in one glass bar while the rings are scrolled away. Tapping returns to the top.
    private var pinnedBar: some View {
        HStack(spacing: 18) {
            pinnedValue(DomainTheme.charge.productName, chargeScore.map { "\(Int($0.rounded()))" }, ForgeColor.charge)
            pinnedValue(DomainTheme.effort.productName,
                        snapshot.effortStored.map { ForgeToday.effortText($0, scale: effortScale) }, ForgeColor.effort)
            pinnedValue(DomainTheme.rest.productName,
                        (snapshot.loaded ? snapshot.rest : nil).map { "\(Int($0.rounded()))" }, ForgeColor.rest)
        }
        .padding(.horizontal, 18)
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
        HStack(spacing: 5) {
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
                OrganicScoreRing(model: face.model, tint: face.tint, score: face.score, decimals: face.decimals, frame: frame,
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
                    // On the picture a name is white, for it crosses snow and rock; the ring carries the colour.
                    .foregroundStyle(onPicture ? AnyShapeStyle(.white) : AnyShapeStyle(Self.labelTint(face.metric)))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .shadow(color: .black.opacity(onPicture ? 0.45 : 0), radius: 3, y: 1)
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
                    .forgeCard(radius: 20, padding: 14)
            }
            ForEach(Array(snapshot.timeline.enumerated()), id: \.element.id) { index, day in
                if index > 0 || !Calendar.current.isDateInToday(day.date) {
                    dayDivider(day.date)
                }
                ForEach(day.entries) { entry in
                    timelineEntry(entry)
                }
            }
        }
    }

    private func dayDivider(_ date: Date) -> some View {
        (Text(dayTitle(date)).font(.system(.subheadline, weight: .semibold)).foregroundColor(ForgeColor.text)
         + Text(verbatim: "  ") + Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(AppLanguage.activeLocale))
            .font(.system(.subheadline)).foregroundColor(ForgeColor.secondaryOnPicture))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
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

    /// One entry: its time, then what happened. A figure that only knows its day shows none; a coach note
    /// carries its time in its own label.
    private func timelineEntry(_ entry: ForgeTimeline.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .coach = entry.kind {
                EmptyView()
            } else if entry.timed {
                Text(Self.timeText(entry.date))
                    .font(.system(.footnote, weight: .medium).monospacedDigit())
                    .foregroundStyle(ForgeColor.secondaryOnPicture)
            }
            entryCard(entry)
        }
        .forgeCard(radius: 20, padding: 14)
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
        }
    }

    /// Up to here a note shows whole: about four lines of body text.
    private static let shortNoteLength = 180

    private func coachLabel(_ entry: ForgeTimeline.Entry, origin: ForgeTimeline.CoachNote.Origin) -> String {
        let label: String
        if let kicker = entry.kicker {
            label = String(localized: "Coach · \(kicker)")
        } else {
            switch origin {
            case .brief: label = String(localized: "Coach · morning")
            case .checkIn: label = String(localized: "Coach · check-in")
            case .nudge: label = String(localized: "Coach")
            case .weeklyReview: label = String(localized: "Coach · weekly review")
            }
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
            // The figures first, then the words about them.
            noteFigures(entry, origin: origin)
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
            FlowRows(spacing: 8) {
                if coachFeatureEnabled {
                    // Only what the coach offered with this note: a note that asks nothing offers nothing.
                    ForEach(entry.replies, id: \.self) { reply in
                        ForgeChip(title: reply) { onAsk(reply) }
                    }
                }
                ForgeChip(title: String(localized: "Reply"), systemImage: "square.and.pencil", prominent: true,
                          action: onCoach)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onCoach)
        .accessibilityElement(children: .contain)
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
            VStack(spacing: 6) {
                ForEach(Array(snapshot.drivers.prefix(3).enumerated()), id: \.offset) { _, driver in
                    HStack(spacing: 8) {
                        Text(driver.label).font(.system(.subheadline)).foregroundStyle(ForgeColor.secondaryOnPicture)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer()
                        Text(ForgeToday.driverValue(driver.valueText)).font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                        ForgeDirection(delta: driver.deltaPoints)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(ChargeBreakdownFormat.driverAccessibilityLabel(driver)))
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ForgeColor.fill))
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
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ForgeColor.fill))
            }
            .buttonStyle(.plain)
            if let zones = WorkoutZones.percents(row.zonesJSON) {
                ForgeZoneBar(percents: zones,
                             minutes: (row.durationS ?? Double(max(row.endTs - row.startTs, 0))) / 60)
            }
        } else if entry.kicker == String(localized: "Evening recap"), let effort = snapshot.effortStored,
                  let target = effortTarget, Calendar.current.isDateInToday(entry.date) {
            ForgeEffortTargetBar(effort: effort, target: target, scale: effortScale)
        }
        // The night a morning note reads, inside the note instead of beside it.
        if let night = entry.wake.flatMap({ snapshot.nights[Int($0.timeIntervalSince1970)] }) {
            Button(action: onSleep) { nightSummary(night) }
                .buttonStyle(.plain)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ForgeColor.fill))
        }
    }

    @ViewBuilder private func workoutCard(_ entry: ForgeTimeline.Entry) -> some View {
        if let row = entry.sourceId.flatMap({ snapshot.workouts[$0] }) {
            let tint = AppleInspiredColors.role(forSport: row.sport).color
            NavigationLink(value: ForgeRoute.workout(startTs: row.startTs, sport: row.sport)) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(tint.opacity(0.18))
                        WorkoutTypeIcon(workoutType: row.sport, size: 17, weight: .semibold, color: tint)
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WorkoutSource.localizedDisplaySport(row.sport))
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(ForgeColor.text)
                            .lineLimit(1)
                        Text(workoutDetail(row))
                            .font(ForgeFont.caption)
                            .foregroundStyle(ForgeColor.secondaryOnPicture)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if let strain = row.strain {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(ForgeToday.effortText(strain, scale: effortScale))
                                .font(ForgeFont.rounded(22, .bold))
                                .foregroundStyle(ForgeColor.text)
                            Text(DomainTheme.effort.productName)
                                .font(.system(.caption2))
                                .foregroundStyle(ForgeColor.secondaryOnPicture)
                        }
                    }
                }
                .forgeEventTile()
            }
            .buttonStyle(LiquidPressStyle())
        }
    }

    /// A weigh-in with its time (only entries that record one reach the timeline).
    private func weightCard(_ entry: ForgeTimeline.Entry) -> some View {
        NavigationLink(value: TabRoute.weight) {
            HStack(spacing: 12) {
                Image(systemName: "figure.stand")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(ForgeColor.rest)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(ForgeColor.rest.opacity(0.18)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Weight logged").font(.system(.body, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    if let change = snapshot.weightChange30d {
                        Text("\(UnitFormatter.massFromKilograms(change, system: UnitSystem(rawValue: unitSystemRaw) ?? .metric).replacingOccurrences(of: "-", with: "−")) in 30 days")
                            .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondaryOnPicture)
                    }
                }
                Spacer(minLength: 6)
                if let kg = entry.value {
                    Text(UnitFormatter.massFromKilograms(kg, system: UnitSystem(rawValue: unitSystemRaw) ?? .metric))
                        .font(ForgeFont.rounded(20, .bold)).foregroundStyle(ForgeColor.text)
                }
            }
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
                    value: entry.value.map(Self.hoursMinutes), unit: String(localized: "h asleep"))
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
                        value: UnitFormatter.localizedMark(String(format: "%.1f", HydrationGoal.litres(fromML: value))), unit: "L")
                    .forgeEventTile()
            }
            .buttonStyle(LiquidPressStyle())
        case .food:
            NavigationLink(value: TabRoute.energy) {
                factRow(symbol: "fork.knife", tint: ForgeColor.effort, title: String(localized: "Food"), detail: nil,
                        value: "\(Int(value.rounded()))", unit: "kcal")
                    .forgeEventTile()
            }
            .buttonStyle(LiquidPressStyle())
        case .journal:
            NavigationLink(value: MoreDestination.insights) {
                factRow(symbol: "book.closed.fill", tint: ForgeColor.accent, title: String(localized: "Journal"), detail: nil,
                        value: "\(Int(value))", unit: String(localized: "entries"))
                    .forgeEventTile()
            }
            .buttonStyle(LiquidPressStyle())
        }
    }

    private func ecgCard(_ entry: ForgeTimeline.Entry) -> some View {
        NavigationLink(value: MoreDestination.ecg) {
            factRow(symbol: "waveform.path.ecg.rectangle", tint: ForgeColor.accent, title: String(localized: "ECG"), detail: nil,
                    value: entry.value.map { "\(Int($0))" }, unit: "bpm")
                .forgeEventTile()
        }
        .buttonStyle(LiquidPressStyle())
    }

    /// The timeline's plain event: a round icon, what happened, its figure.
    private func factRow(symbol: String, tint: Color, title: String, detail: String?, value: String?, unit: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(Circle().fill(tint.opacity(0.18)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.body, weight: .semibold)).foregroundStyle(ForgeColor.text).lineLimit(1)
                if let detail {
                    Text(detail).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondaryOnPicture).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            if let value {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(value).font(ForgeFont.rounded(22, .bold)).foregroundStyle(ForgeColor.text)
                    Text(unit).font(.system(.caption2)).foregroundStyle(ForgeColor.secondaryOnPicture)
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
            .init(id: "demo-evening", date: at(20, 55), text: String(localized: "Evening recap") + "\n\nStrong day, inside your Effort target. Strength took most of it; bed by 23:00 keeps tomorrow's Charge up.", origin: .nudge),
            .init(id: "demo-workout", date: at(11, 5), text: String(localized: "After your workout") + "\n\nSteady walk, heart rate stayed easy. Good recovery work after yesterday's strength session.", origin: .nudge),
            .init(id: "demo-brief", date: at(7, 52), text: "Well recovered, push a bit today. HRV is above your usual range and resting heart rate is low. A harder session fits.", origin: .brief),
            .init(id: "demo-weekly", date: at(21, 30, daysAgo: 1), text: String(localized: "Weekly review") + "\n\nFive sessions this week, the plan is on track. Sleep held at about seven and a half hours.", origin: .weeklyReview),
        ].filter { $0.date <= now }
    }
    #endif

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

        next.restByDay = restByDay
        let workouts = await repo.workoutRows(days: Self.timelineDays + 1, reconcileHrCap: 0)
        var input = ForgeTimeline.Input()
        // Weigh-ins that carry their own time (NOOP's own entries; Apple's daily cells have none).
        for w in await repo.weightEntries(days: Self.timelineDays + 1) {
            if let at = w.takenAt {
                input.weights.append(.init(date: at, kg: w.value))
            } else if let at = Self.endOfTimelineDay(w.day) {
                input.weights.append(.init(date: at, kg: w.value, timed: false))
            }
        }
        next.weightChange30d = await repo.weightTrendSummary(days: 91)?.change30dKg
        for w in workouts {
            let id = "\(w.startTs)|\(w.sport)"
            next.workouts[id] = w
            input.workouts.append(.init(id: id, start: Date(timeIntervalSince1970: TimeInterval(w.startTs)),
                                        end: Date(timeIntervalSince1970: TimeInterval(w.endTs)), sport: w.sport,
                                        effort: w.strain, distanceM: w.distanceM, energyKcal: w.energyKcal))
        }
        // The same nights the Sleep tab shows, a short one included: a bad night is the one that matters.
        let recent = await ForgeRecentSleep.load(repo: repo, days: Self.timelineDays + 1)
        for night in recent.nights {
            next.nights[Int(night.end.timeIntervalSince1970)] = night
            input.sleeps.append(.init(start: night.start, end: night.end, minutesAsleep: night.asleepMinutes, rest: nil))
        }
        input.naps = recent.naps
        input.dayLogs = await Self.dayLogs(repo: repo, now: now)
        if let store = await repo.storeHandle(), let readings = try? await store.ecgReadings() {
            let cutoff = now.addingTimeInterval(-Double(Self.timelineDays + 1) * 86_400)
            input.ecgs = readings.map { .init(id: $0.id, date: Date(timeIntervalSince1970: TimeInterval($0.endTs)), averageHr: $0.averageHr) }
                .filter { $0.date >= cutoff }
        }
        if coachFeatureEnabled {
            let cutoff = now.addingTimeInterval(-Double(Self.timelineDays + 1) * 86_400)
            for conversation in coach.conversations {
                for m in conversation.messages where m.role == .assistant && m.date >= cutoff {
                    let origin: ForgeTimeline.CoachNote.Origin
                    switch m.origin {
                    case .brief: origin = .brief
                    case .checkIn: origin = .checkIn
                    case .nudge: origin = .nudge
                    case .weeklyReview: origin = .weeklyReview
                    case .reply: continue
                    }
                    input.coach.append(.init(id: m.id.uuidString, date: m.date, text: m.text, origin: origin,
                                             workoutId: m.workoutId, replies: m.replies))
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
        next.timeline = ForgeTimeline.build(input, now: now, days: Self.timelineDays, dayKey: { Repository.logicalDayKey($0) })
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
            context: DashboardMomentum.context(
                displayDay: displayDay, allDays: allDays, hrvBaseline: repo.chargeBaselines?.hrv,
                dayKey: todayKey, isToday: true,
                steps: DailyStepsReading.resolve(strapSteps: displayDay?.steps, appleSteps: nil, estimatedSteps: nil),
                stepGoal: momentumStepGoal, live: DashboardMomentum.LiveInput(model: model)),
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
