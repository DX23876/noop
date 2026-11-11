#if os(iOS)
import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import StrandCore
import WhoopStore

/// The cycle as one place (prototype board "CycleWheel", 2026-11): the cycle day on a dial of real days, the
/// three ways to log, what this phase tends to mean, the nightly temperature of this cycle and a calendar.
/// The phase, the shift and the next-period window are `CyclePhaseEngine`'s, read from the analysis pass;
/// the cycle day counts from the start the wearer logged. Awareness only, opt-in, on this iPhone.
struct ForgeCycleView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var appModel: AppModel
    @AppStorage(AppModel.cycleAwarenessKey) private var cycleEnabled = false
    @State private var starts: [String] = []
    @State private var log: [String: CycleLog.Day] = [:]
    /// Worked out once per load, not in `body`: it walks the logged days and the nights of this cycle.
    @State private var snap: ForgeCycleSnapshot?
    @State private var logging = false
    @State private var showingHistory = false
    @State private var scrolledPast = false
    @State private var pattern: CycleTrainingPattern.Result?
    @AppStorage(ForgeCyclePush.learningKey) private var learning = true
    @AppStorage(ForgeCycleSnapshot.fertileKey) private var showFertile = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForgeDetailHeader(overline: nil, title: String(localized: "Cycle"), scrolledPast: $scrolledPast, picture: PagePicture(symbol: "drop.fill", accent: "moon.fill", tint: .pink))
                if !cycleEnabled {
                    optIn
                } else if let snap {
                    content(snap)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .health))
        .forgeDetailBar(title: String(localized: "Cycle"), showsTitle: scrolledPast)
        .task(id: "\(repo.cycleTrackingSeq)-\(repo.refreshSeq)") { await load() }
        .sheet(isPresented: $logging) {
            ForgeCycleLogSheet(day: Repository.localDayKey(Date()), existing: log[Repository.localDayKey(Date())] ?? CycleLog.Day(),
                               starts: starts) {
                await appModel.refreshV5Signals()
            }
        }
        .sheet(isPresented: $showingHistory) {
            if let result = appModel.cyclePhase {
                CycleTrackerView(result: result, curve: appModel.cycleCurve)
            }
        }
    }

    private func load() async {
        guard cycleEnabled else { snap = nil; return }
        let today = Date()
        let from = Repository.localDayKey(today.addingTimeInterval(-180 * 86_400))
        starts = await repo.periodStarts()
        log = await repo.cycleLog(from: from, to: Repository.localDayKey(today))
        // Always re-read: a phase computed before the nights arrived would otherwise stay "learning".
        await appModel.refreshV5Signals()
        rebuild()
        FertileReminder.reschedule(windowStart: snap?.fertileStartAhead)
        if learning { pattern = await learnPattern() }
    }

    private func rebuild() {
        snap = ForgeCycleSnapshot.make(result: appModel.cyclePhase, starts: starts, log: log, days: repo.days,
                                       today: Date(), showFertile: showFertile)
    }

    /// The wearer's own sessions by phase, through the reading the Android core shares (`CyclePatternReading`).
    private func learnPattern() async -> CycleTrainingPattern.Result? {
        guard let store = await repo.storeHandle() else { return nil }
        return await CyclePatternReading.learn(reader: repo.storeReader(store),
            cycles: CycleSnapshot.cycles(starts: starts, log: log, result: appModel.cyclePhase),
            dismissedWorkouts: UserDefaults.standard.stringArray(forKey: WorkoutSource.dismissedDefaultsKey) ?? [])
    }

    // MARK: Opt-in

    private var optIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Track your cycle privately")
                .font(.system(.title3, weight: .semibold)).foregroundStyle(ForgeColor.text)
            Text("Log your period and NOOP reads the rest from your nights: the phase you are in, the rise in temperature after the middle of the cycle and when the next period is likely. Nothing leaves this iPhone.")
                .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                cycleEnabled = true
                appModel.cycleAwarenessEnabled = true
                Task { await appModel.refreshV5Signals(); await load() }
            } label: {
                Text("Turn on cycle tracking")
                    .font(.system(.body, weight: .semibold)).foregroundStyle(ForgeColor.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Capsule().fill(ForgeColor.accent))
            }
            .buttonStyle(.plain)
            footer
        }
        .forgeCard(radius: ForgeRadius.card, padding: 16)
    }

    private var footer: some View {
        Text(showFertile && cycleEnabled
             ? String(localized: "Awareness only. Fertile days are a rough estimate, not contraception and not a diagnosis.")
             : String(localized: "Awareness only. Not contraception, not a fertility predictor and not a diagnosis."))
            .font(ForgeFont.caption).foregroundStyle(ForgeColor.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Content

    @ViewBuilder private func content(_ snap: ForgeCycleSnapshot) -> some View {
        VStack(spacing: 14) {
            ForgeCycleDial(snap: snap)
            if let line = snap.fertileLine {
                NavigationLink {
                    ForgeCycleFertileInfo(snap: snap) { logging = true }
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(ForgeColor.cycleFertile).frame(width: 9, height: 9)
                        // One text so a long language wraps instead of cutting the status off.
                        (Text(line.title).font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                         + Text(line.detail.map { " · " + $0 } ?? "").font(.system(.subheadline)).foregroundStyle(ForgeColor.secondary))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "info.circle").font(.system(.subheadline)).foregroundStyle(ForgeColor.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(ForgeColor.cycleFertile.opacity(ForgeOpacity.wash)))
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("How the fertile days are estimated"))
            }
        }
        .forgeCard(radius: ForgeRadius.card, padding: 16)
        logRow
        if let phase = snap.phase {
            ForgeSectionTitle(title: "This phase for you")
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(ForgeCycleTopic.allCases) { topic in
                        let push = ForgeCyclePush.make(topic: topic, phase: phase, charge: todayCharge,
                                                       pattern: learning ? pattern : nil)
                        NavigationLink {
                            ForgeCycleTopicView(topic: topic, phase: phase, snap: snap, cycleDay: snap.cycleDayText,
                                                push: push, pattern: learning ? pattern : nil)
                        } label: {
                            ForgeCycleTopicCard(topic: topic, phase: phase, snap: snap, push: push)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -16)
        }
        if snap.temps.count > 2 {
            temperatureCard(snap)
        }
        ForgeCycleCalendar(snap: snap)
            .forgeCard(radius: ForgeRadius.card, padding: 16)
        if appModel.cyclePhase != nil {
            Button { showingHistory = true } label: {
                ForgeRow(systemImage: "calendar", tint: ForgeColor.secondary, title: String(localized: "Cycle history"),
                         subtitle: snap.historyLine)
                    .forgeCard(radius: ForgeRadius.card, padding: 0)
            }
            .buttonStyle(.plain)
        }
        ForgeSectionTitle(title: "Settings")
        VStack(spacing: 0) {
            Toggle(isOn: $learning) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Learn from my training").font(.system(.callout, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Text("Compares how hard your sessions felt and how much you lifted in each phase, to tell you when to push.")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(ForgeColor.accent)
            .padding(14)
            Rectangle().fill(ForgeColor.separator).frame(height: 0.5).padding(.leading, 14)
            Toggle(isOn: $showFertile) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show likely fertile days").font(.system(.callout, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Text("A rough estimate from your past cycles. Not birth control.")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(ForgeColor.accent)
            .padding(14)
            if showFertile {
                Rectangle().fill(ForgeColor.separator).frame(height: 0.5).padding(.leading, 14)
                ForgeFertileReminderToggles()
                    .padding(14)
            }
            Rectangle().fill(ForgeColor.separator).frame(height: 0.5).padding(.leading, 14)
            Button(role: .destructive) {
                cycleEnabled = false
                appModel.cycleAwarenessEnabled = false
                Task { await appModel.refreshV5Signals() }
            } label: {
                Text("Turn off cycle tracking").font(.system(.callout)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
        .forgeCard(radius: ForgeRadius.card, padding: 0)
        .onChange(of: learning) { _, on in
            if on { Task { pattern = await learnPattern() } }
        }
        .onChange(of: showFertile) { _, _ in
            rebuild()
            FertileReminder.reschedule(windowStart: self.snap?.fertileStartAhead)
        }
        footer.padding(.horizontal, 4)
    }

    private var todayCharge: Double? {
        (repo.today ?? repo.days.last(where: { $0.day == Repository.logicalDayKey(Date()) }))?.recovery
    }

    private var logRow: some View {
        HStack(spacing: 8) {
            logButton(String(localized: "cycle.period", defaultValue: "Period"), symbol: "drop.fill", tint: ForgeColor.cyclePeriod)
            logButton(String(localized: "Symptoms"), symbol: "cross.case.fill", tint: ForgeColor.effort)
            logButton(String(localized: "Mood"), symbol: "face.smiling", tint: ForgeColor.rest)
        }
    }

    private func logButton(_ title: String, symbol: String, tint: Color) -> some View {
        Button { logging = true } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(.body, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 40, height: 40).background(Circle().fill(tint.opacity(ForgeOpacity.wash)))
                Text(title).font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, minHeight: 88)
            .forgeCard(radius: ForgeRadius.card, padding: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Log \(title)"))
    }

    private func temperatureCard(_ snap: ForgeCycleSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your nights this cycle").font(.system(.headline)).foregroundStyle(ForgeColor.text)
                Spacer(minLength: 8)
                Text("skin temperature against your usual").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Chart {
                ForEach(snap.temps, id: \.day) { t in
                    AreaMark(x: .value("Day", t.day), yStart: .value("Base", snap.tempFloor), yEnd: .value("°C", t.value))
                        .foregroundStyle(ForgeColor.rest.opacity(0.14))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Day", t.day), y: .value("°C", t.value))
                        .foregroundStyle(ForgeColor.rest)
                        .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if let shift = snap.shiftDay {
                    RuleMark(x: .value("Shift", shift))
                        .foregroundStyle(ForgeColor.cycleShift.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .chartYScale(domain: snap.tempFloor...snap.tempCeiling)
            .chartXScale(domain: 1...max(snap.wheelDays, snap.temps.last?.day ?? 1))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(ForgeColor.separator)
                    AxisValueLabel {
                        if let d = v.as(Double.self) { Text(d.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)))) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { v in
                    AxisValueLabel { if let d = v.as(Int.self) { Text("Day \(d)") } }
                }
            }
            .frame(height: 120)
            .accessibilityLabel(Text("Skin temperature over this cycle"))
            Text(snap.shiftDay.map { String(localized: "The rise around day \($0) is the shift NOOP reads from your nights.") }
                 ?? String(localized: "No rise in temperature yet this cycle."))
                .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .forgeCard(radius: ForgeRadius.card, padding: 16)
    }
}

// MARK: - Snapshot

/// The page's snapshot is the shared `CycleSnapshot` (`CycleReading.swift`, also the Android core's); the iPhone
/// adds the wording and the dates it shows.
typealias ForgeCycleSnapshot = CycleSnapshot

extension CycleSnapshot {
    static let fertileKey = "noopCycleShowFertile"

    static func make(result: CyclePhaseEngine.Result?, starts: [String], log: [String: CycleLog.Day],
                     days: [DailyMetric], today: Date, showFertile: Bool = false) -> CycleSnapshot {
        make(result: result, starts: starts, log: log, days: days, today: Repository.localDayKey(today), showFertile: showFertile)
    }

    /// The first day of this cycle as a local date.
    var startDate: Date? { startDay.flatMap { Self.dayFormatter.date(from: $0) }.map { Calendar.current.startOfDay(for: $0) } }

    /// The first likely fertile day as a date, while it still lies ahead; what the reminder arms.
    var fertileStartAhead: Date? { fertileStartDayAhead.flatMap { Self.dayFormatter.date(from: $0) } }

    /// The status line under the dial and on the cards.
    var fertileLine: (title: String, detail: String?)? {
        switch fertileStatus {
        case .before(let n)?:
            return (n == 1 ? String(localized: "Likely fertile from tomorrow") : String(localized: "\(n) days until your likely fertile days"), nil)
        case .during(let day, let of)?:
            return (String(localized: "Likely fertile today"), String(localized: "day \(day) of \(of)"))
        case .over?:
            return (String(localized: "Fertile days are over"), shiftDay.map { String(localized: "rise on day \($0)") })
        case nil:
            return nil
        }
    }

    var cycleDayText: String {
        if let cycleDay { return String(localized: "Day \(cycleDay)") }
        if let r = dayRange { return String(localized: "Day \(r.lowerBound) to \(r.upperBound)") }
        return String(localized: "Day unknown")
    }

    var nextLine: String? {
        guard let w = nextWindow else { return nil }
        if w.upperBound <= 0 { return String(localized: "Period likely any day now") }
        if w.lowerBound <= 0 { return String(localized: "Period likely within \(w.upperBound) days") }
        return String(localized: "Period likely in \(w.lowerBound) to \(w.upperBound) days")
    }

    var historyLine: String {
        cyclesSeen > 1 ? String(localized: "\(cyclesSeen) cycles logged") : String(localized: "Every period start you logged")
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Dial

/// Every day of this cycle as a dot on a dial: past days in their phase colour, coming days faint, the likely
/// next-period window dashed, today large. The cycle day sits in the middle as the page's one big number.
struct ForgeCycleDial: View {
    let snap: ForgeCycleSnapshot

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Canvas { ctx, size in draw(ctx, size) }
                    .accessibilityHidden(true)
                VStack(spacing: 2) {
                    Text("Cycle day").font(.system(.footnote, weight: .semibold)).foregroundStyle(ForgeColor.secondary)
                    Text(centreNumber).font(ForgeFont.rounded(54, .bold)).foregroundStyle(ForgeColor.text)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if let phase = snap.phase {
                        Text(phase.title).font(.system(.subheadline, weight: .semibold)).foregroundStyle(phase.color)
                    } else {
                        Text(snap.engineConfidence == .learning ? String(localized: "Learning your pattern") : String(localized: "No clear pattern yet"))
                            .font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if let next = snap.nextLine {
                        Text(next).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 160)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 60)
            }
            .frame(width: 280, height: 280)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilitySummary))
            legend
        }
    }

    private var centreNumber: String {
        if let d = snap.cycleDay { return "\(d)" }
        if let r = snap.dayRange { return r.lowerBound == r.upperBound ? "\(r.lowerBound)" : "\(r.lowerBound)–\(r.upperBound)" }
        return "–"
    }

    private var accessibilitySummary: String {
        [snap.cycleDayText, snap.phase?.title, snap.nextLine].compactMap { $0 }.joined(separator: ", ")
    }

    private var legend: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                ForEach(ForgeCyclePhase.allCases, id: \.self) { p in
                    HStack(spacing: 4) {
                        Circle().fill(p.color).frame(width: 8, height: 8)
                        Text(p.shortTitle).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    }
                }
            }
            if snap.fertile != nil || snap.nextWindow != nil {
                HStack(spacing: 12) { extraLegend }
            }
        }
        .lineLimit(1).minimumScaleFactor(0.8)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var extraLegend: some View {
        Group {
            if snap.fertile != nil {
                HStack(spacing: 4) {
                    Circle().fill(ForgeColor.cycleFertile).frame(width: 8, height: 8)
                    Text("Likely fertile").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
            }
            if snap.nextWindow != nil {
                HStack(spacing: 4) {
                    Circle().strokeBorder(ForgeColor.cyclePeriod, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                        .frame(width: 9, height: 9)
                    Text("Likely next").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
            }
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let n = snap.wheelDays
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = min(size.width, size.height) / 2 - 18
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                   with: .color(ForgeColor.fill), lineWidth: 22)
        let today = snap.todayOnWheel
        let next = snap.nextWindow.flatMap { w in today.map { ($0 + w.lowerBound)...($0 + w.upperBound) } }
        func angle(_ d: Double) -> Angle { .radians(-Double.pi / 2 + (d - 1) / Double(n) * 2 * .pi) }
        if let f = snap.fertile {
            // The likely fertile days as a soft arc behind their dots.
            var arc = Path()
            arc.addArc(center: c, radius: r, startAngle: angle(Double(f.firstDay) - 0.35), endAngle: angle(Double(f.lastDay) + 0.35), clockwise: false)
            ctx.stroke(arc, with: .color(ForgeColor.cycleFertile.opacity(0.28)), style: StrokeStyle(lineWidth: 22, lineCap: .round))
        }
        for d in 1...max(n, 1) {
            let a = -Double.pi / 2 + Double(d - 1) / Double(n) * 2 * .pi
            let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            let fertileDay = snap.isFertile(day: d)
            let colour = fertileDay && (today.map { d >= $0 } ?? false) ? ForgeColor.cycleFertile : (snap.phase(onDay: d)?.color ?? ForgeColor.tertiary)
            func dot(_ radius: CGFloat) -> Path { Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius)) }
            if d == today {
                ctx.fill(dot(13), with: .color(colour))
                ctx.stroke(dot(13), with: .color(ForgeColor.card), lineWidth: 3)
            } else if let today, d < today {
                ctx.fill(dot(6.5), with: .color(colour))
            } else if let next, next.contains(d) {
                ctx.stroke(dot(6), with: .color(ForgeColor.cyclePeriod), style: StrokeStyle(lineWidth: 2, dash: [3, 2.4]))
            } else if fertileDay {
                ctx.fill(dot(6), with: .color(ForgeColor.cycleFertile.opacity(0.85)))
            } else {
                ctx.fill(dot(5), with: .color(colour.opacity(0.3)))
            }
        }
    }
}

// MARK: - Cards

struct ForgeCycleTopicCard: View {
    let topic: ForgeCycleTopic
    let phase: ForgeCyclePhase
    let snap: ForgeCycleSnapshot
    let push: ForgeCyclePush?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: topic.symbol).font(.system(.body, weight: .semibold)).foregroundStyle(phase.color)
                    .frame(width: 40, height: 40).background(Circle().fill(phase.color.opacity(ForgeOpacity.wash)))
                Text(topic.title).font(.system(.headline)).foregroundStyle(ForgeColor.text)
            }
            if let push {
                Text(push.headline).font(.system(.callout, weight: .semibold)).foregroundStyle(push.tone)
                    .fixedSize(horizontal: false, vertical: true)
                Text(push.reason).font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(cardText).font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                Text("More")
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.accent)
        }
        .frame(width: 250, alignment: .topLeading)
        .frame(minHeight: 190, alignment: .topLeading)
        .forgeCard(radius: ForgeRadius.card, padding: 16)
        .accessibilityElement(children: .combine)
    }

    /// The Body card leads with the wearer's own shift when this cycle has one to show.
    private var cardText: String {
        if topic == .body, let line = ForgeCycleTopicView.bodyLine(snap) { return line }
        return topic.summary(phase)
    }
}

/// One card's page: the phase, the short and the longer read, what the wearer's own nights show, and the
/// studies behind it.
struct ForgeCycleTopicView: View {
    let topic: ForgeCycleTopic
    let phase: ForgeCyclePhase
    let snap: ForgeCycleSnapshot
    let cycleDay: String
    var push: ForgeCyclePush? = nil
    var pattern: CycleTrainingPattern.Result? = nil
    @State private var scrolledPast = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 10) {
                    Text("\(phase.title) · \(cycleDay)")
                        .font(.system(.footnote, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(phase.color))
                    Image(systemName: topic.symbol).font(.system(size: 36, weight: .semibold)).foregroundStyle(phase.color)
                        .frame(width: 84, height: 84).background(Circle().fill(phase.color.opacity(ForgeOpacity.wash)))
                        .accessibilityHidden(true)
                    Text(topic.title).font(ForgeFont.largeTitle).foregroundStyle(ForgeColor.text)
                        .accessibilityAddTraits(.isHeader)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                VStack(alignment: .leading, spacing: 12) {
                    if let push {
                        Text(push.headline).font(.system(.title3, weight: .semibold)).foregroundStyle(push.tone)
                        Text(push.reason).foregroundStyle(ForgeColor.secondary)
                    }
                    Text(topic.summary(phase))
                    Text(topic.more(phase))
                }
                .font(.body).foregroundStyle(ForgeColor.text)
                .fixedSize(horizontal: false, vertical: true)
                .forgeCard(radius: ForgeRadius.card, padding: 16)
                let lines = dataLines
                if !lines.isEmpty {
                    ForgeSectionTitle(title: "In your data")
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(lines, id: \.self) { Text($0) }
                    }
                    .font(ForgeFont.body).foregroundStyle(ForgeColor.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .forgeCard(radius: ForgeRadius.card, padding: 16)
                }
                ForgeSectionTitle(title: "What this is based on")
                Text(topic.sources(phase))
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .forgeCard(radius: ForgeRadius.card, padding: 16)
                Text("Awareness only. Not contraception, not a fertility predictor and not a diagnosis.")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.tertiary)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .health))
        .forgeDetailBar(title: topic.title, showsTitle: false)
    }

    /// "Nights +0.3 °C, resting heart rate +3 bpm, HRV −6 ms against the first half of this cycle."
    static func bodyLine(_ snap: ForgeCycleSnapshot) -> String? {
        guard let c = snap.compare else { return nil }
        var parts: [String] = []
        if let t = c.tempDelta { parts.append(String(localized: "nights \(signed(t, 1)) °C")) }
        if let r = c.rhrDelta { parts.append(String(localized: "resting heart rate \(signed(r, 0)) bpm")) }
        if let h = c.hrvDelta { parts.append(String(localized: "HRV \(signed(h, 0)) ms")) }
        guard !parts.isEmpty else { return nil }
        return String(localized: "Against the first half of this cycle: \(parts.joined(separator: ", ")). The usual shift of this phase, not a sign of illness.")
    }

    static func signed(_ v: Double, _ digits: Int) -> String {
        let s = abs(v).formatted(.number.precision(.fractionLength(digits)).locale(AppLanguage.activeLocale))
        return (v < 0 ? "−" : "+") + s
    }

    private var dataLines: [String] {
        var out: [String] = []
        if topic == .exercise, let line = ForgeCyclePush.patternLine(pattern, phase: phase) { out.append(line) }
        guard let c = snap.compare else { return out }
        switch topic {
        case .body:
            if let line = Self.bodyLine(snap) { out.append(line) }
        case .exercise:
            if let now = c.chargeNow, let before = c.chargeBefore {
                out.append(String(localized: "Charge in this phase: \(Int(now.rounded())) on average, \(Int(before.rounded())) in the first half."))
            }
        case .mind:
            if let now = c.wakeNow, let before = c.wakeBefore {
                out.append(String(localized: "Wake-ups a night: \(Int(now.rounded())) in this phase, \(Int(before.rounded())) in the first half."))
            }
            for (id, count) in snap.moodsThisPhase.sorted(by: { $0.value > $1.value }).prefix(2) {
                if let title = CycleLog.moods.first(where: { $0.id == id })?.title {
                    out.append(String(localized: "You logged \(title) on \(count) days of this phase."))
                }
            }
        }
        return out
    }
}

// MARK: - Calendar

/// Five weeks around this cycle: logged period days filled, the likely next window dashed, today marked.
struct ForgeCycleCalendar: View {
    let snap: ForgeCycleSnapshot

    private var weeks: [Date] {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let anchor = snap.startDate ?? cal.date(byAdding: .day, value: -20, to: Date())!
        let first = cal.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
        return (0..<35).compactMap { cal.date(byAdding: .day, value: $0, to: first) }
    }

    var body: some View {
        let days = weeks
        let todayKey = Repository.localDayKey(Date())
        let next: Set<String> = Set(snap.nextWindow.map { w in
            (w.lowerBound...w.upperBound).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: Date()) }.map(Repository.localDayKey)
        } ?? [])
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Calendar").font(.system(.headline)).foregroundStyle(ForgeColor.text)
                Spacer()
                if let a = days.first, let b = days.last {
                    Text("\(a.formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale))) – \(b.formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale)))")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 6) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.system(.caption2, weight: .semibold)).foregroundStyle(ForgeColor.secondary)
                }
                ForEach(days, id: \.self) { d in
                    let key = Repository.localDayKey(d)
                    cell(d, isToday: key == todayKey, period: snap.periodDays.contains(key), likely: next.contains(key),
                         fertile: snap.fertileDays.contains(key))
                }
            }
            Text(snap.fertileDays.isEmpty
                 ? String(localized: "Filled: periods you logged. Dashed: the likely window for the next one, from your nights.")
                 : String(localized: "Red: periods you logged. Green: the likely fertile days. Dashed: the likely next period."))
                .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    private var weekdaySymbols: [String] {
        var cal = Calendar.current
        cal.locale = AppLanguage.activeLocale
        let s = cal.veryShortStandaloneWeekdaySymbols
        return Array(s[1...] + s[..<1])
    }

    private func cell(_ d: Date, isToday: Bool, period: Bool, likely: Bool, fertile: Bool) -> some View {
        Text("\(Calendar.current.component(.day, from: d))")
            .font(.system(.subheadline, weight: isToday ? .bold : .regular))
            .foregroundStyle(isToday ? ForgeColor.card : (period ? .white : ForgeColor.text))
            .frame(width: 32, height: 32)
            .background {
                if isToday {
                    Circle().fill(ForgeColor.text)
                } else if period {
                    Circle().fill(ForgeColor.cyclePeriod)
                } else if fertile {
                    Circle().fill(ForgeColor.cycleFertile.opacity(ForgeOpacity.band))
                } else if likely {
                    Circle().strokeBorder(ForgeColor.cyclePeriod, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5]))
                }
            }
            .accessibilityLabel(Text(d.formatted(.dateTime.day().month(.wide).locale(AppLanguage.activeLocale))))
            .accessibilityValue(Text(period ? String(localized: "cycle.period", defaultValue: "Period")
                                     : (fertile ? String(localized: "Likely fertile") : (likely ? String(localized: "Likely next period") : ""))))
    }
}

// MARK: - Log sheet

/// Today's flow, symptoms and mood. Logging flow with no period start in the last ten days also logs today as
/// cycle day 1, since that is what a new period means.
struct ForgeCycleLogSheet: View {
    let day: String
    let existing: CycleLog.Day
    let starts: [String]
    var onSaved: () async -> Void
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CycleLog.Day()
    @State private var saving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(String(localized: "cycle.period", defaultValue: "Period")) {
                        chip(String(localized: "None"), on: draft.flow == nil, tint: ForgeColor.cyclePeriod) { draft.flow = nil }
                        ForEach(CycleLog.Flow.allCases) { f in
                            chip(f.title, on: draft.flow == f, tint: ForgeColor.cyclePeriod) { draft.flow = f }
                        }
                    }
                    section(String(localized: "Symptoms")) {
                        ForEach(CycleLog.symptoms, id: \.id) { s in
                            chip(s.title, on: draft.symptoms.contains(s.id), tint: ForgeColor.effort) { toggle(&draft.symptoms, s.id) }
                        }
                    }
                    section(String(localized: "Mood")) {
                        ForEach(CycleLog.moods, id: \.id) { m in
                            chip(m.title, on: draft.moods.contains(m.id), tint: ForgeColor.rest) { toggle(&draft.moods, m.id) }
                        }
                    }
                    section(String(localized: "Ovulation test")) {
                        chip(String(localized: "Positive test today"), on: draft.ovulationTest, tint: ForgeColor.cycleFertile) {
                            draft.ovulationTest.toggle()
                        }
                    }
                    Text("Stays on this iPhone. Symptoms and mood feed the Mind card, never the cycle estimate. Logging a period with no start in the last ten days makes today cycle day 1.")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .background(ForgeColor.canvas.ignoresSafeArea())
            .navigationTitle(Text("Log today"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving)
                }
            }
        }
        .presentationDetents([.large])
        .onAppear { draft = existing }
    }

    private func toggle(_ set: inout Set<String>, _ id: String) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ chips: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(.headline)).foregroundStyle(ForgeColor.text)
            ForgeFlowLayout(spacing: 8) { chips() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .forgeCard(radius: ForgeRadius.card, padding: 16)
    }

    private func chip(_ title: String, on: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(.subheadline, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.white : ForgeColor.text)
                .padding(.horizontal, 14).frame(minHeight: 40)
                .background(Capsule().fill(on ? tint : ForgeColor.fill))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func save() async {
        saving = true
        await repo.saveCycleLogLoggingStart(day: day, draft, previous: existing, starts: starts)
        await onSaved()
        dismiss()
    }
}

#endif
