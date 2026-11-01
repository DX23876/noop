#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandCore
import WhoopStore

/// The redesigned Today (2026-11, "New design (preview)"): the three organic rings at the top with today's
/// Effort target, what is still planned for later, then one timeline of what happened, newest first.
///
/// Every number is read through the same resolvers the shipped Today uses (`ChargeDisplay`,
/// `DashboardRestScore`/`freshRestScore`, `LiveEffort` floored by `effectiveEffort`), so the two designs can
/// never disagree about a score. The timeline is assembled by `ForgeTimeline` from stored rows and works
/// fully with the coach off; coach notes only join it when the coach is on.
struct ForgeTodayView: View {
    @ObservedObject var coach: AICoachEngine
    let onProfile: () -> Void
    let onLog: () -> Void
    let onWorkout: () -> Void
    let onCoach: () -> Void
    let onSleep: () -> Void
    /// Opens Coach settings (memory, usage, data access) on the Today stack.
    var onCoachSettings: () -> Void = {}

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

    @State private var snapshot = Snapshot()
    @State private var showPlan = false
    @State private var showCoachSheet = false
    @State private var rowWidth: CGFloat = 0
    @State private var whyEntry: ForgeTimeline.Entry?
    /// True once the rings have scrolled out of view; a compact glass bar then keeps the three scores.
    @State private var heroHidden = false

    struct Snapshot: Equatable {
        var loaded = false
        var charge: ChargeDisplay = .noData
        var rest: Double?
        var effortStored: Double?
        var effortDay = ""
        var timeline: [ForgeTimeline.Day] = []
        var workouts: [String: WorkoutRow] = [:]
        var sleeps: [Int: CachedSleepSession] = [:]
        var notes: [String: ChatMessage] = [:]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForgeLargeHeader(title: "Today", onProfile: onProfile) {
                        NavigationLink(value: ForgeRoute.weeklyReport) {
                            Image(systemName: "calendar")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(ForgeColor.text)
                                .frame(width: 36, height: 36)
                                .forgeGlassCapsule()
                        }
                        .accessibilityLabel(Text("Weekly report"))
                    }
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
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: ForgeHeroBottomKey.self,
                                                       value: geo.frame(in: .named("forge-today")).maxY)
                            })
                        laterToday
                        timeline
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 6)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(name: "forge-today")
            .onPreferenceChange(ForgeHeroBottomKey.self) { bottom in
                let hidden = bottom < 40
                if hidden != heroHidden { withAnimation(.easeOut(duration: 0.2)) { heroHidden = hidden } }
            }
            .overlay(alignment: .top) {
                if heroHidden { pinnedBar.transition(.move(edge: .top).combined(with: .opacity)) }
            }
            .onChange(of: scrollToTopSignal) { _, _ in
                withAnimation(.smooth) { proxy.scrollTo("forge-today-top", anchor: .top) }
            }
        }
        .background(ForgeBackground(tab: .today))
        .refreshable { await repo.refresh(); await load(force: true) }
        .task(id: reloadKey) { await load(force: false) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load(force: true) } }
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
        return "\(repo.days.count)|\(repo.today?.day ?? "")|\(repo.today?.strain ?? -1)|\(repo.today?.recovery ?? -1)|\(lastNote)|\(coachFeatureEnabled)"
    }

    // MARK: - Hero

    private var chargeScore: Double? { snapshot.loaded ? snapshot.charge.pct : nil }
    private var effortScore: Double? { snapshot.effortStored.map { UnitFormatter.effortValue($0, scale: effortScale) } }
    private var effortTarget: ClosedRange<Double>? { ForgeToday.effortTargetStored(charge: chargeScore) }

    private var hero: some View {
        let diameter = LiquidHeroRingLayout.diameter(rowWidth: rowWidth)
        let hit = LiquidHeroRingLayout.hitDiameter(rowWidth: rowWidth)
        return VStack(spacing: 12) {
            OrganicScoreHeroClock(dataReady: snapshot.loaded || effortScore != nil) { frame in
                HStack(alignment: .top, spacing: 0) {
                    ringCell(metric: .charge, label: DomainTheme.charge.productName, score: chargeScore,
                             tint: chargeScore.map { StrandPalette.chargeRingColor($0) } ?? StrandPalette.organicMissing,
                             caption: chargeCaption, frame: frame, diameter: diameter, hit: hit,
                             route: ForgeRoute.charge)
                    ringCell(metric: .effort, label: DomainTheme.effort.productName, score: effortScore,
                             tint: StrandPalette.organicEffort, caption: effortCaption,
                             frame: frame, diameter: diameter, hit: hit,
                             maxValue: effortScale == .whoop ? 21 : 100, decimals: effortScale == .whoop ? 1 : 0,
                             route: TabRoute.effort(DashboardEffortReadout(day: snapshot.effortDay, value: snapshot.effortStored)))
                    ringCell(metric: .rest, label: DomainTheme.rest.productName, score: snapshot.loaded ? snapshot.rest : nil,
                             tint: StrandPalette.organicRest, caption: nil,
                             frame: frame, diameter: diameter, hit: hit,
                             route: TabRoute.metric(HeroRingMetric.rest))
                }
            }
            .frame(maxWidth: .infinity)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { rowWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in rowWidth = w }
            })

            if let line = ForgeToday.summary(effortStored: snapshot.effortStored, charge: chargeScore, scale: effortScale) {
                Text(line)
                    .font(ForgeFont.body)
                    .foregroundStyle(ForgeColor.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                heroButton("Log", systemImage: "plus", action: onLog)
                heroButton("Workout", systemImage: "figure.run", action: onWorkout)
            }
        }
        .padding(.top, 6)
        .forgeCard(radius: 30, padding: 14)
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
        .liquidGlass(in: Capsule())
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    private func pinnedValue(_ label: String, _ value: String?, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(value ?? "–").font(ForgeFont.rounded(16, .bold)).foregroundStyle(ForgeColor.text)
            Text(label).font(.system(size: 12)).foregroundStyle(ForgeColor.secondary)
        }
    }

    private var chargeCaption: String? {
        switch snapshot.charge {
        case .carried, .calibrating: return snapshot.charge.stateLabel
        case .scored(let pct): return ChargeBand.of(score: pct).word.capitalized(with: AppLanguage.activeLocale)
        case .noData: return nil
        }
    }

    private var effortCaption: String? {
        guard let target = effortTarget else { return nil }
        let t = ForgeToday.targetText(target, scale: effortScale)
        return String(localized: "target \(t.low) to \(t.high)")
    }

    private func ringCell<Route: Hashable>(metric: OrganicScoreMetric, label: String, score: Double?, tint: Color,
                                           caption: String?, frame: OrganicScoreFrame, diameter: CGFloat, hit: CGFloat,
                                           maxValue: Double = 100, decimals: Int = 0, route: Route) -> some View {
        let model = OrganicScoreVisualModel.resolve(metric: metric, value: score, scaleMaximum: maxValue)
        return NavigationLink(value: route) {
            VStack(spacing: 2) {
                OrganicScoreRing(model: model, tint: tint, score: score, decimals: decimals, frame: frame,
                                 diameter: diameter, hitDiameter: hit)
                    .frame(width: hit, height: diameter)
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ForgeColor.text)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(caption ?? " ")
                    .font(.system(size: 12))
                    .foregroundStyle(ForgeColor.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(spoken(score: score, maxValue: maxValue, decimals: decimals, caption: caption)))
        .accessibilityHint(Text("Opens the trend and readings"))
        .accessibilityAddTraits(.isButton)
    }

    private func spoken(score: Double?, maxValue: Double, decimals: Int, caption: String?) -> String {
        guard let score else { return String(localized: "no data yet") }
        var parts: [String] = []
        if maxValue == 100 {
            parts.append(String(localized: "\(Int(score.rounded())) percent"))
        } else {
            let number = String(format: "%.\(decimals)f", locale: AppLanguage.activeLocale, score)
            parts.append(String(localized: "\(number) out of \(Int(maxValue))"))
        }
        if let caption { parts.append(caption) }
        return parts.joined(separator: ", ")
    }

    private func heroButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ForgeColor.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Capsule().fill(ForgeColor.fill))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Later today

    private struct LaterItem: Identifiable {
        let id: String
        let time: Date
        let title: String
        let systemImage: String
        let tint: Color
        let action: () -> Void
    }

    private var laterItems: [LaterItem] {
        let now = Date()
        var items: [LaterItem] = []
        if let bed = ForgeToday.plannedBedtime(now: now), bed > now,
           bed.timeIntervalSince(now) < 16 * 3600 {
            items.append(LaterItem(id: "bedtime", time: bed, title: String(localized: "Bedtime"),
                                   systemImage: "moon.fill", tint: ForgeColor.rest, action: onSleep))
        }
        return items.sorted { $0.time < $1.time }
    }

    /// Sunday evening: the week is complete enough to read back.
    private var showsWeeklyChip: Bool {
        let cal = Calendar.current
        return cal.component(.weekday, from: Date()) == 1 && cal.component(.hour, from: Date()) >= 17
    }

    @ViewBuilder private var laterToday: some View {
        let items = laterItems
        if !items.isEmpty || showsWeeklyChip {
            VStack(alignment: .leading, spacing: 8) {
                ForgeSectionTitle(title: "Later Today")
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        if showsWeeklyChip {
                            NavigationLink(value: ForgeRoute.weeklyReport) {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.text.fill").font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(ForgeColor.accent)
                                    Text("Weekly report").font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(ForgeColor.text)
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 44)
                                .forgeCard(radius: 22, padding: 0)
                                .fixedSize()
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(items) { item in
                            Button(action: item.action) {
                                HStack(spacing: 8) {
                                    Text(item.time, format: .dateTime.hour().minute().locale(AppLanguage.activeLocale))
                                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                                        .foregroundStyle(ForgeColor.secondary)
                                    Image(systemName: item.systemImage)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(item.tint)
                                    Text(item.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(ForgeColor.text)
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 44)
                                .forgeCard(radius: 22, padding: 0)
                                .fixedSize()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: - Timeline

    private static let timeWidth: CGFloat = 38

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            nowMarker
            if snapshot.loaded && snapshot.timeline.isEmpty {
                Text("Workouts, nights and notes from the coach appear here as the day goes on.")
                    .font(ForgeFont.body)
                    .foregroundStyle(ForgeColor.secondary)
                    .padding(.leading, Self.timeWidth + 25)
                    .padding(.vertical, 12)
            }
            ForEach(Array(snapshot.timeline.enumerated()), id: \.element.id) { index, day in
                if index > 0 || !Calendar.current.isDateInToday(day.date) {
                    dayDivider(day.date)
                }
                ForEach(day.entries) { entry in
                    railRow(time: entry.date) { entryCard(entry) }
                }
            }
        }
        .padding(.top, 10)
    }

    private var nowMarker: some View {
        HStack(spacing: 8) {
            Text(Date(), format: .dateTime.hour().minute().locale(AppLanguage.activeLocale))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(ForgeColor.accent)
                .fixedSize()
                .frame(width: Self.timeWidth, alignment: .trailing)
            Circle().fill(ForgeColor.accent).frame(width: 9, height: 9)
            Text("Now")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ForgeColor.onAccent)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(ForgeColor.accent))
            Spacer()
        }
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    private func dayDivider(_ date: Date) -> some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: Self.timeWidth, height: 1)
            Circle().fill(ForgeColor.text).frame(width: 9, height: 9)
            Text(dayTitle(date)).font(.system(size: 15, weight: .semibold)).foregroundStyle(ForgeColor.text)
            Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(AppLanguage.activeLocale))
                .font(.system(size: 15)).foregroundStyle(ForgeColor.secondary)
            Spacer()
        }
        .padding(.vertical, 10)
        .accessibilityAddTraits(.isHeader)
    }

    private func dayTitle(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return String(localized: "Today") }
        if cal.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return date.formatted(.dateTime.weekday(.wide).locale(AppLanguage.activeLocale))
    }

    private func railRow<Content: View>(time: Date, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(time, format: .dateTime.hour().minute().locale(AppLanguage.activeLocale))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(ForgeColor.tertiary)
                .fixedSize()
                .frame(width: Self.timeWidth, alignment: .trailing)
                .padding(.top, 15)
                .accessibilityHidden(true)
            // One continuous rail: the line runs the full row height, the dot sits on it at the card's
            // first line, so consecutive rows join into a single thread.
            ZStack(alignment: .top) {
                Rectangle().fill(ForgeColor.separator).frame(width: 1.5).frame(maxHeight: .infinity)
                Circle().fill(ForgeColor.tertiary).frame(width: 7, height: 7).padding(.top, 18)
            }
            .frame(width: 9)
            .accessibilityHidden(true)
            content()
                .padding(.bottom, 10)
        }
    }

    @ViewBuilder private func entryCard(_ entry: ForgeTimeline.Entry) -> some View {
        switch entry.kind {
        case .coach(let origin): coachCard(entry, origin: origin)
        case .workout: workoutCard(entry)
        case .wake: wakeCard(entry)
        case .weight: EmptyView()
        }
    }

    private func coachLabel(_ entry: ForgeTimeline.Entry, origin: ForgeTimeline.CoachNote.Origin) -> String {
        if let kicker = entry.kicker { return String(localized: "Coach · \(kicker)") }
        switch origin {
        case .brief: return String(localized: "Coach · morning")
        case .checkIn: return String(localized: "Coach · check-in")
        case .nudge: return String(localized: "Coach")
        case .weeklyReview: return String(localized: "Coach · weekly review")
        }
    }

    private func coachCard(_ entry: ForgeTimeline.Entry, origin: ForgeTimeline.CoachNote.Origin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(coachLabel(entry, origin: origin), systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ForgeColor.accent)
                Spacer()
                Button { whyEntry = entry } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(ForgeColor.tertiary)
                        .frame(width: 32, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Why am I seeing this?"))
            }
            Text(entry.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ForgeColor.text)
                .fixedSize(horizontal: false, vertical: true)
            if !entry.detail.isEmpty {
                Text(entry.detail)
                    .font(ForgeFont.body)
                    .foregroundStyle(ForgeColor.secondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                ForgeChip(title: String(localized: "Reply"), systemImage: "arrowshape.turn.up.left", prominent: true,
                          action: onCoach)
            }
            .padding(.top, 2)
        }
        .forgeCard(radius: 22, padding: 14)
        .contentShape(Rectangle())
        .onTapGesture(perform: onCoach)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func workoutCard(_ entry: ForgeTimeline.Entry) -> some View {
        if let row = entry.sourceId.flatMap({ snapshot.workouts[$0] }) {
            let tint = AppleInspiredColors.role(forSport: row.sport).color
            NavigationLink(value: TabRoute.workoutDetail(startTs: row.startTs, sport: row.sport)) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(tint.opacity(0.18))
                        WorkoutTypeIcon(workoutType: row.sport, size: 17, weight: .semibold, color: tint)
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WorkoutSource.localizedDisplaySport(row.sport))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(ForgeColor.text)
                            .lineLimit(1)
                        Text(workoutDetail(row))
                            .font(ForgeFont.caption)
                            .foregroundStyle(ForgeColor.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if let strain = row.strain {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(ForgeToday.effortText(strain, scale: effortScale))
                                .font(ForgeFont.rounded(22, .bold))
                                .foregroundStyle(ForgeColor.text)
                            Text(DomainTheme.effort.productName)
                                .font(.system(size: 11))
                                .foregroundStyle(ForgeColor.secondary)
                        }
                    }
                }
                .forgeCard(radius: 22, padding: 14)
            }
            .buttonStyle(LiquidPressStyle())
        }
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
        let session = snapshot.sleeps[Int(entry.date.timeIntervalSince1970)]
        let start = session.map { Date(timeIntervalSince1970: TimeInterval($0.effectiveStartTs)) }
        return Button(action: onSleep) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(ForgeColor.rest.opacity(0.18))
                    Image(systemName: "sun.horizon.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ForgeColor.rest)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Woke up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ForgeColor.text)
                    if let start {
                        Text("\(start.formatted(.dateTime.hour().minute().locale(AppLanguage.activeLocale))) to \(entry.date.formatted(.dateTime.hour().minute().locale(AppLanguage.activeLocale)))")
                            .font(ForgeFont.caption)
                            .foregroundStyle(ForgeColor.secondary)
                    }
                }
                Spacer(minLength: 6)
                if let minutes = entry.value, minutes > 0 {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(Self.hoursMinutes(minutes))
                            .font(ForgeFont.rounded(22, .bold))
                            .foregroundStyle(ForgeColor.text)
                        Text("h asleep")
                            .font(.system(size: 11))
                            .foregroundStyle(ForgeColor.secondary)
                    }
                }
            }
            .forgeCard(radius: 22, padding: 14)
        }
        .buttonStyle(LiquidPressStyle())
    }

    #if DEBUG
    private static func demoCoachNotes(now: Date) -> [ForgeTimeline.CoachNote] {
        let cal = Calendar.current
        func at(_ hour: Int, _ minute: Int, daysAgo: Int = 0) -> Date {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? now
        }
        return [
            .init(id: "demo-evening", date: at(20, 55), text: "Evening recap\n\nStrong day, inside your Effort target. Strength took most of it; bed by 23:00 keeps tomorrow's Charge up.", origin: .nudge),
            .init(id: "demo-workout", date: at(11, 5), text: "After your workout\n\nSteady walk, heart rate stayed easy. Good recovery work after yesterday's strength session.", origin: .nudge),
            .init(id: "demo-brief", date: at(7, 52), text: "Well recovered, push a bit today. HRV is above your usual range and resting heart rate is low. A harder session fits.", origin: .brief),
            .init(id: "demo-weekly", date: at(21, 30, daysAgo: 1), text: "Weekly review\n\nFive sessions this week, the plan is on track. Sleep held at about seven and a half hours.", origin: .weeklyReview),
        ].filter { $0.date <= now }
    }
    #endif

    static func hoursMinutes(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Load

    private func load(force: Bool) async {
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

        let workouts = await repo.workoutRows(days: 3, reconcileHrCap: 0)
        let nowTs = Int(now.timeIntervalSince1970)
        let sleeps = await repo.sleepSessions(from: nowTs - 3 * 86_400, to: nowTs)

        var input = ForgeTimeline.Input()
        for w in workouts {
            let id = "\(w.startTs)|\(w.sport)"
            next.workouts[id] = w
            input.workouts.append(.init(id: id, start: Date(timeIntervalSince1970: TimeInterval(w.startTs)),
                                        end: Date(timeIntervalSince1970: TimeInterval(w.endTs)), sport: w.sport,
                                        effort: w.strain, distanceM: w.distanceM, energyKcal: w.energyKcal))
        }
        for s in sleeps {
            let asleep = SleepNight.asleepMinutes(s.stagesJSON, effectiveStartTs: s.effectiveStartTs)
            // A main night, not a nap fragment: naps get their own entry later (Sleep tab).
            guard asleep >= 180 else { continue }
            next.sleeps[s.endTs] = s
            input.sleeps.append(.init(start: Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs)),
                                      end: Date(timeIntervalSince1970: TimeInterval(s.endTs)),
                                      minutesAsleep: asleep, rest: nil))
        }
        if coachFeatureEnabled {
            let cutoff = now.addingTimeInterval(-3 * 86_400)
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
                    input.coach.append(.init(id: m.id.uuidString, date: m.date, text: m.text, origin: origin))
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
        next.timeline = ForgeTimeline.build(input, now: now, days: 2, dayKey: { Repository.logicalDayKey($0) })
        next.loaded = true

        // The heaviest read last, as on the shipped Today: Effort floors at the stored row, so the live
        // refinement can only raise the ring, never pull it back.
        snapshot = next
        let live = await LiveEffort.today(repo: repo, profile: profile, restingHr: displayDay?.restingHr)
        let effort = StrainScorer.effectiveEffort(live: live, stored: displayDay?.day == todayKey ? displayDay?.strain : nil)
        guard !Task.isCancelled else { return }
        snapshot.effortStored = effort
        // A due note (after a workout, in the evening) is written now, the same moment the brief uses.
        // When it lands, the transcript changes and `reloadKey` brings it into the timeline.
        if coachFeatureEnabled {
            Task { await coach.runForgeNotesIfDue(workouts: workouts) }
        }
    }
}
/// Where the rings card ends in the Today scroll view, to pin the compact bar once it is gone.
private struct ForgeHeroBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}
#endif
