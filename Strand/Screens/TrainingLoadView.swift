import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Three loads, three units — and whether the training is doing anything
//
// A single combined score would need an invented exchange rate between a hard set, a heart-rate load
// and the athlete's own perception. This screen keeps all three visible in their real units and gives
// each the same useful comparison: the rolling seven days against the person's recent level. That
// level grows with the history available and tops out at 28 days.
//
// On top of that comparison, strength and cardio each get a STATUS — detraining, recovering,
// maintaining, productive, unproductive, overreaching — decided in `TrainingStatusModel`: Polar's scale
// for cardio, and for strength the same scale read together with the lifts' own e1RM lines and recent
// recovery. The session lane keeps its comparison and gets no status (Polar gives Perceived Load none).

@MainActor
final class TrainingLoadModel: ObservableObject {
    struct Lane: Sendable {
        let sevenDayTotal: Double
        let trend: LoadTrend?
        /// What the lane's figure rests on over the last 28 days, in the lane's own unit: RPE-rated
        /// working sets for Strength, sessions carrying Effort for Cardio, rated sessions for Session.
        let measuredCount: Int
        let possibleCount: Int
        /// Polar-style status (`TrainingStatusModel`). Nil for the session lane, which has none, and
        /// while the comparison itself is withheld.
        let status: LaneStatus?
    }

    /// One day's ratio per lane, for the eight-week chart. Nil while that day had no comparison.
    struct RatioPoint: Sendable, Identifiable {
        let day: String
        let strength: Double?
        let cardio: Double?
        var id: String { day }
    }

    private struct Prepared: Sendable {
        let strength: Lane
        let cardio: Lane
        let session: Lane
        let response: StrengthResponseReading
        let vo2max: VO2maxResponse
        let recovery: RecoveryReading
        let history: [TrainingStatusModel.WeeklyStatus]
        let ratios: [RatioPoint]
        let sustained: SustainedOverreaching?
    }

    /// Days of history read. The oldest week of the eight-week strip is judged as of 56 days ago, and
    /// that verdict looks back a further 28 days for its baseline and up to 60 for a below-usual run.
    private static let historyDays = 150

    @Published private(set) var strength: Lane?
    @Published private(set) var cardio: Lane?
    @Published private(set) var session: Lane?
    /// Which way the lifts of the last six weeks are moving — one input to the strength status.
    @Published private(set) var strengthResponse: StrengthResponseReading?
    /// VO₂max over the last eight weeks — cardio's "is it working". Shown, and one input to the
    /// sustained-overreaching warning; the cardio status itself stays Polar's load-only scale.
    @Published private(set) var vo2max: VO2maxResponse?
    /// Overreaching that has lasted with performance falling and recovery strained, if present.
    @Published private(set) var sustainedOverreaching: SustainedOverreaching?
    /// How recovery has held over the last three nights — the other input above 1.3.
    @Published private(set) var recovery: RecoveryReading?
    /// The status at the end of each of the last eight weeks, oldest first.
    @Published private(set) var history: [TrainingStatusModel.WeeklyStatus] = []
    /// Each of the last 56 days' ratio per lane — the same comparison the dials show, day by day.
    @Published private(set) var ratios: [RatioPoint] = []
    @Published private(set) var loaded = false

    func load(repo: Repository) async {
        let now = Int(Date().timeIntervalSince1970)
        let from = now - Self.historyDays * 86_400
        let offset = TimeZone.current.secondsFromGMT()

        async let workoutRows = repo.workoutRows(days: Self.historyDays, reconcileHrCap: 0)
        async let ratings = repo.sessionRPEEntries(from: from, to: now + 86_400)
        let strengthWorkouts: [HevyWorkout]
        let templates: [String: HevyExerciseTemplate]
        if let store = await repo.storeHandle() {
            strengthWorkouts = (try? await store.strengthWorkouts(from: from, to: now + 86_400)) ?? []
            templates = (try? await store.strengthExerciseTemplates()) ?? [:]
        } else {
            strengthWorkouts = []
            templates = [:]
        }
        let rows = await workoutRows
        let rpeEntries = await ratings
        let dailyRows = repo.days
        let vo2 = await Self.vo2maxReadings(repo: repo)

        let today = Repository.localDayKey(Date())
        let prepared = await Task.detached(priority: .userInitiated) { () -> Prepared in
            let strengthByDay = StrengthSession.weightedSetsByDay(strengthWorkouts,
                                                                  tzOffsetSeconds: offset)
            let cardioSessions = CardioSession.sessions(rows, tzOffsetSeconds: offset)
            var cardioByDay: [String: Double] = [:]
            for workout in cardioSessions {
                guard let effort = workout.strain, effort.isFinite, effort >= 0 else { continue }
                cardioByDay[workout.day, default: 0] += effort
            }

            var durationByStart: [Int: Double] = [:]
            for row in rows {
                let seconds = row.durationS ?? Double(row.endTs - row.startTs)
                if seconds > 0 { durationByStart[row.startTs] = seconds }
            }
            for workout in strengthWorkouts where durationByStart[workout.startTs] == nil {
                if let seconds = workout.durationS { durationByStart[workout.startTs] = seconds }
            }

            var sessionByDay: [String: Double] = [:]
            for entry in rpeEntries {
                guard let seconds = durationByStart[entry.startTs], seconds > 0 else { continue }
                let day = AnalyticsEngine.dayString(entry.startTs, offsetSec: offset)
                sessionByDay[day, default: 0] += entry.rpe * seconds / 60
            }

            let cutoff = WeeklyDigestEngine.addDays(today, -27)
            let recentStrength = strengthWorkouts.filter {
                let day = AnalyticsEngine.dayString($0.startTs, offsetSec: offset)
                return day >= cutoff && day <= today
            }
            let pooledStrength = StrengthSession.strengthLoad(recentStrength)
            let recentCardio = cardioSessions.filter { $0.day >= cutoff && $0.day <= today }
            let uniqueSessions = Set(rows.map(\.startTs) + strengthWorkouts.map(\.startTs))
            let possible = uniqueSessions.filter {
                let day = AnalyticsEngine.dayString($0, offsetSec: offset)
                return day >= cutoff && day <= today
            }.count
            let measured = rpeEntries.filter {
                let day = AnalyticsEngine.dayString($0.startTs, offsetSec: offset)
                return day >= cutoff && day <= today && durationByStart[$0.startTs] != nil
            }.count

            // The status inputs. Strength asks the lifts and, above 1.3, recovery; cardio is Polar's
            // ratio scale alone. See `TrainingStatusModel` for the tables.
            let response = TrainingStatusModel.strengthResponse(workouts: strengthWorkouts,
                                                                templates: templates, through: today,
                                                                tzOffsetSeconds: offset)
            let recovery = TrainingStatusModel.recovery(days: dailyRows, through: today)
            let history = TrainingStatusModel.weeklyHistory(weeks: 8, through: today,
                                                            strengthDaily: strengthByDay,
                                                            cardioDaily: cardioByDay,
                                                            workouts: strengthWorkouts, templates: templates,
                                                            days: dailyRows, tzOffsetSeconds: offset)
            var ratios: [RatioPoint] = []
            var ratioDay = WeeklyDigestEngine.addDays(today, -55)
            for _ in 0..<56 {
                ratios.append(RatioPoint(day: ratioDay,
                                         strength: TrainingLoad.trend(dailyByDay: strengthByDay, through: ratioDay)?.ratio,
                                         cardio: TrainingLoad.trend(dailyByDay: cardioByDay, through: ratioDay)?.ratio))
                ratioDay = WeeklyDigestEngine.addDays(ratioDay, 1)
            }
            let vo2max = TrainingStatusModel.vo2maxResponse(readings: vo2, through: today)
            let sustained = TrainingStatusModel.sustainedOverreaching(history: history, strengthResponse: response,
                                                                      cardioDirection: vo2max.direction,
                                                                      recovery: recovery)

            return Prepared(
                strength: Lane(sevenDayTotal: Self.lastSeven(strengthByDay, through: today),
                               trend: TrainingLoad.trend(dailyByDay: strengthByDay, through: today),
                               measuredCount: pooledStrength.ratedSets,
                               possibleCount: pooledStrength.workingSets,
                               status: TrainingStatusModel.strength(dailyByDay: strengthByDay, through: today,
                                                                    response: response, recovery: recovery)),
                cardio: Lane(sevenDayTotal: Self.lastSeven(cardioByDay, through: today),
                             trend: TrainingLoad.trend(dailyByDay: cardioByDay, through: today),
                             measuredCount: recentCardio.filter { $0.strain != nil }.count,
                             possibleCount: recentCardio.count,
                             status: TrainingStatusModel.cardio(dailyByDay: cardioByDay, through: today)),
                session: Lane(sevenDayTotal: Self.lastSeven(sessionByDay, through: today),
                              trend: TrainingLoad.trend(dailyByDay: sessionByDay, through: today),
                              measuredCount: measured, possibleCount: possible, status: nil),
                response: response,
                vo2max: vo2max,
                recovery: recovery,
                history: history,
                ratios: ratios,
                sustained: sustained)
        }.value

        guard !Task.isCancelled else { return }
        strength = prepared.strength
        cardio = prepared.cardio
        session = prepared.session
        strengthResponse = prepared.response
        vo2max = prepared.vo2max
        sustainedOverreaching = prepared.sustained
        recovery = prepared.recovery
        history = prepared.history
        ratios = prepared.ratios
        loaded = true
    }

    nonisolated private static func lastSeven(_ values: [String: Double], through day: String) -> Double {
        var total = 0.0
        var cursor = day
        for _ in 0..<7 {
            total += values[cursor] ?? 0
            cursor = WeeklyDigestEngine.addDays(cursor, -1)
        }
        return total
    }

    /// The VO₂max readings the cardio lane reads.
    ///
    /// Apple Watch's measured Cardio Fitness when it has at least four readings in the window — it comes
    /// from real outdoor effort. Otherwise NOOP's weekly estimate, each reading tagged with the estimator
    /// that produced it (Nes 2011 or Uth 2004), so `TrainingStatusModel.vo2maxResponse` never draws a
    /// line across a change of method. The same series and provenance the Metric Explorer shows.
    private static func vo2maxReadings(repo: Repository) async -> [VO2maxReading] {
        let cutoff = WeeklyDigestEngine.addDays(Repository.localDayKey(Date()),
                                                -(TrainingStatusModel.vo2maxWindowDays - 1))
        let apple = await repo.exploreSeries(key: "vo2max", source: Repository.appleHealthSource, days: 90)
        if apple.filter({ $0.day >= cutoff }).count >= StrengthProgress.minimumTrendPoints {
            return apple.map { VO2maxReading(day: $0.day, value: $0.value, segment: Repository.appleHealthSource) }
        }
        let resolution = await repo.resolvedSeries(key: "vo2max_est", source: Repository.whoopSource, days: 90)
        var readings: [VO2maxReading] = []
        for point in resolution.points {
            let tag = await repo.scoreProvenanceTag(resolvedSource: point.source, day: point.day,
                                                    metricKey: "vo2max_est")
            readings.append(VO2maxReading(day: point.day, value: point.value, segment: tag ?? point.source))
        }
        return readings
    }
}

struct TrainingLoadView: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = TrainingLoadModel()
    @State private var shownVO2: Double = 0
    @State private var adviceBounce = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScreenScaffold(title: "Training Load",
                       subtitle: "Three views of training, each in the unit that fits it.",
                       onRefresh: { await model.load(repo: repo) }) {
            if !model.loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                hero
                sustainedCard
                adviceCard.trainingCardEntrance()
                recoveryCard.trainingCardEntrance()
                // Named sections for `--demo-scroll-to` screenshot QA (DEBUG only; ids are inert otherwise).
                historyCard.trainingCardEntrance().id("history")
                strengthSummaryCard.trainingCardEntrance().id("lifts")
                vo2maxCard.trainingCardEntrance().id("cardio")
                sessionCard.trainingCardEntrance()
                basisCard.trainingCardEntrance()
                legendCard.trainingCardEntrance()
                methodCard.trainingCardEntrance()
            }
        }
        .task(id: repo.refreshSeq) { await model.load(repo: repo) }
    }

    // MARK: - The two dials

    /// The two dials on a surface lit by their own status colours.
    private var hero: some View {
        VStack(spacing: NoopMetrics.space4) {
            HStack(alignment: .top, spacing: NoopMetrics.space2) {
                LoadStatusRing(title: "Strength", symbol: "figure.strengthtraining.traditional",
                               lane: model.strength?.status, figure: strengthFigure,
                               evidence: strengthEvidence)
                LoadStatusRing(title: "Cardio", symbol: "heart.fill",
                               lane: model.cardio?.status, figure: cardioFigure,
                               evidence: cardioEvidence)
            }
            LoadZoneLegend()
        }
        .padding(NoopMetrics.cardPadding)
        .frame(maxWidth: .infinity)
        .background(TrainingHeroSurface(leading: model.strength?.status?.status.color ?? StrandPalette.textTertiary,
                                        trailing: model.cardio?.status?.status.color ?? StrandPalette.textTertiary))
    }

    private var strengthFigure: String? {
        guard let lane = model.strength else { return nil }
        guard let trend = lane.trend else { return weightedSetText(lane) }
        return "\(weightedSetText(lane)) · \(signedPercent(trend.percentChange))"
    }

    private var cardioFigure: String? {
        guard let lane = model.cardio else { return nil }
        guard let trend = lane.trend else { return effortText(lane) }
        return "\(effortText(lane)) · \(signedPercent(trend.percentChange))"
    }

    /// What the strength verdict rests on — a below-usual run, the lifts, or an honest "load only".
    private var strengthEvidence: String? {
        guard let status = model.strength?.status else { return nil }
        if status.band == .below, status.daysBelowUsual > 0 { return belowSinceText(status.daysBelowUsual) }
        guard let response = model.strengthResponse, response.direction != .unknown else {
            return String(localized: "Too few lifts to judge, so rated on load alone")
        }
        switch response.direction {
        case .rising:  return String(localized: "\(response.rising) of \(response.evaluated) lifts rising")
        case .falling: return String(localized: "\(response.falling) of \(response.evaluated) lifts falling")
        default:       return String(localized: "No clear direction across \(response.evaluated) lifts")
        }
    }

    private var cardioEvidence: String? {
        guard let status = model.cardio?.status else { return nil }
        if status.band == .below, status.daysBelowUsual > 0 { return belowSinceText(status.daysBelowUsual) }
        return String(localized: "From heart rate, on Polar's scale")
    }

    /// "Below your usual since 3 Sep" — a date rather than "N days", which needs no plural forms and
    /// says when the dip started, the thing the 21-day strength rule counts from.
    private func belowSinceText(_ days: Int) -> String {
        let since = WeeklyDigestEngine.addDays(Repository.localDayKey(Date()), -(days - 1))
        return String(localized: "Below your usual since \(StatusHistoryStrip.shortDate(since))")
    }

    // MARK: - What to do

    private struct Advice {
        let symbol: String
        let color: Color
        let text: String
    }

    /// One sentence for the whole screen, in order of what matters most: too much first, then work
    /// without return, then recovery, then the good news, then the quiet states.
    private var advice: Advice {
        let strength = model.strength?.status?.status
        let cardio = model.cardio?.status?.status
        let recovery = model.recovery?.state
        if strength == .overreaching {
            return Advice(symbol: TrainingStatus.overreaching.symbol, color: TrainingStatus.overreaching.color,
                          text: recovery == .strained
                            ? String(localized: "Much more strength work than usual, and your recovery is dropping. Take a few easier days before adding more.")
                            : String(localized: "Much more strength work than usual. Hold here until your usual level catches up."))
        }
        if cardio == .overreaching {
            return Advice(symbol: TrainingStatus.overreaching.symbol, color: TrainingStatus.overreaching.color,
                          text: String(localized: "Much more cardio than usual. Hold here until your usual level catches up."))
        }
        if strength == .unproductive {
            return Advice(symbol: TrainingStatus.unproductive.symbol, color: TrainingStatus.unproductive.color,
                          text: String(localized: "Plenty of strength work, but your lifts are not improving. More volume will not fix that: look at sleep, recovery or the programme."))
        }
        if recovery == .strained {
            return Advice(symbol: "moon.zzz.fill", color: TrainingStatus.unproductive.color,
                          text: String(localized: "Your recovery signals flagged on several recent nights. Hold your load rather than raising it."))
        }
        if strength == .productive || cardio == .productive {
            return Advice(symbol: TrainingStatus.productive.symbol, color: TrainingStatus.productive.color,
                          text: recovery == .holding
                            ? String(localized: "Your build is working: load at or above your usual, and your recovery is keeping up.")
                            : String(localized: "Your build is working: load at or above your usual, and it is paying off."))
        }
        if strength == .recovering || cardio == .recovering {
            return Advice(symbol: TrainingStatus.recovering.symbol, color: TrainingStatus.recovering.color,
                          text: String(localized: "A lighter stretch after a hard phase. Good timing to let strength and fitness settle."))
        }
        if strength == .detraining || cardio == .detraining {
            return Advice(symbol: TrainingStatus.detraining.symbol, color: TrainingStatus.detraining.color,
                          text: String(localized: "You have been training well below your usual level. If this is not a planned break, restart with a few easy sessions."))
        }
        if strength != nil || cardio != nil {
            return Advice(symbol: TrainingStatus.maintaining.symbol, color: TrainingStatus.maintaining.color,
                          text: String(localized: "You are holding your level. To build, raise the load in small steps."))
        }
        return Advice(symbol: "hourglass", color: StrandPalette.textTertiary,
                      text: String(localized: "After two weeks of training this shows whether it is building, holding or too much."))
    }

    private var adviceCard: some View {
        let advice = advice
        return TrainingWashCard(color: advice.color, watermark: advice.symbol) {
            HStack(alignment: .center, spacing: NoopMetrics.space3) {
                StatusBadge(symbol: advice.symbol, color: advice.color, size: 44, bounceTrigger: adviceBounce)
                Text(advice.text)
                    .font(StrandFont.subhead.weight(.medium))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .task(id: advice.text) {
            guard !reduceMotion else { return }
            try? await Task.sleep(nanoseconds: 900_000_000)
            adviceBounce += 1
        }
    }

    // MARK: - Lasting overreaching

    /// Shown only when overreaching has lasted three week-ends with that lane's performance falling and
    /// recovery strained — the pattern of non-functional overreaching (Meeusen et al. 2013). It says in
    /// so many words that it is not a diagnosis of overtraining.
    @ViewBuilder private var sustainedCard: some View {
        if let warning = model.sustainedOverreaching {
            TrainingWashCard(color: TrainingStatus.overreaching.color, watermark: "exclamationmark.octagon.fill") {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    HStack(spacing: NoopMetrics.space2) {
                        StatusBadge(symbol: "exclamationmark.octagon.fill", color: TrainingStatus.overreaching.color,
                                    size: 34, pulses: !reduceMotion)
                        Text("Signs of lasting overreaching")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Text(sustainedText(warning))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("This is not a diagnosis of overtraining. That can only be made by a doctor, over months and after ruling out other causes. If your performance and how you feel stay down for weeks, get checked.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func sustainedText(_ warning: SustainedOverreaching) -> String {
        let lanes: String
        switch (warning.lanes.contains(.strength), warning.lanes.contains(.cardio)) {
        case (true, true): lanes = String(localized: "Strength and cardio")
        case (true, false): lanes = String(localized: "Strength")
        default: lanes = String(localized: "Cardio")
        }
        return String(localized: "Overreaching for \(warning.weeks) weeks in a row (\(lanes)), with falling performance and strained recovery. Plan several easy or rest days now.")
    }

    // MARK: - Recovery

    private var recoveryCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Recovery", overline: "Last three nights")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack(spacing: NoopMetrics.space2) {
                        recoveryTile("HRV", symbol: "waveform.path.ecg", key: "hrv")
                        recoveryTile("Resting HR", symbol: "heart.fill", key: "rhr")
                        recoveryTile("Breathing", symbol: "lungs.fill", key: "respRate")
                    }
                    if let reading = model.recovery, reading.nightsRead > 0 {
                        NightsMeter(strained: reading.strainedNights, read: reading.nightsRead,
                                    total: TrainingStatusModel.recoveryNights)
                    }
                    Text(recoverySummary)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func recoveryTile(_ title: LocalizedStringKey, symbol: String, key: String) -> some View {
        let read = model.recovery?.readOnLatestNight.contains(key) ?? false
        let flagging = model.recovery?.flaggingOnLatestNight.contains(key) ?? false
        let color = !read ? StrandPalette.textTertiary
            : (flagging ? StrandPalette.statusWarning : StrandPalette.statusPositive)
        let state = !read ? String(localized: "No data")
            : (flagging ? String(localized: "Flagging") : String(localized: "Normal"))
        return VStack(spacing: 6) {
            // A filled badge when there is a reading — pulsing while it flags; a missing reading stays
            // neutral so it never looks like a verdict.
            if read {
                StatusBadge(symbol: symbol, color: color, size: 44, pulses: flagging && !reduceMotion)
            } else {
                ZStack {
                    Circle().fill(StrandPalette.surfaceInset)
                    Image(systemName: symbol)
                        .font(StrandFont.rounded(18, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(width: 44, height: 44)
            }
            Text(title)
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(state)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(.vertical, NoopMetrics.space3)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(color.opacity(read ? 0.13 : 0.05)))
        .accessibilityElement(children: .combine)
    }

    private var recoverySummary: String {
        guard let reading = model.recovery, reading.state != .unknown else {
            return String(localized: "Too few nights with recovery data to judge yet.")
        }
        return reading.state == .strained
            ? String(localized: "Strained: a signal flagged on \(reading.strainedNights) of \(reading.nightsRead) nights. Above 1.3 × usual this turns strength into overreaching.")
            : String(localized: "Holding: a signal flagged on \(reading.strainedNights) of \(reading.nightsRead) nights.")
    }

    // MARK: - History

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Last 8 weeks", overline: "Status history")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    LoadRatioChart(points: model.ratios)
                    Divider().overlay(StrandPalette.hairline)
                    StatusHistoryStrip(history: model.history)
                    Text("Each week is judged with that week's own data, as the screen would have shown it then.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Strength and cardio development

    /// The lifts' verdict in one bar: how many of the evaluated lifts rise, stay unclear or fall. This is
    /// the evidence behind the strength status; each lift's own line lives on the Strength screen.
    private var strengthSummaryCard: some View {
        let response = model.strengthResponse
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Strength development", overline: "Last six weeks")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    if let response, response.evaluated > 0 {
                        liftDirections(response)
                        Text("Each lift's estimated one-rep max over the last six weeks. A direction counts only when the sessions agree on it; the line for every lift is on the Strength screen.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Log a lift at least four times within six weeks to see which way it is moving.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// A donut with the counts beside it; a bar with the counts under it before macOS 14.
    @ViewBuilder private func liftDirections(_ response: StrengthResponseReading) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            HStack(spacing: NoopMetrics.space4) {
                LiftDirectionDonut(rising: response.rising, unclear: response.unclear, falling: response.falling)
                    .frame(width: 116, height: 116)
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    directionCounts(response)
                }
                Spacer(minLength: 0)
            }
        } else {
            DirectionBar(rising: response.rising, unclear: response.unclear, falling: response.falling)
            HStack(spacing: NoopMetrics.space4) {
                directionCounts(response)
            }
        }
    }

    @ViewBuilder private func directionCounts(_ response: StrengthResponseReading) -> some View {
        countLabel(response.rising, symbol: "arrow.up.right", color: StrandPalette.statusPositive, title: "Rising")
        countLabel(response.unclear, symbol: "minus", color: StrandPalette.textTertiary, title: "Unclear")
        countLabel(response.falling, symbol: "arrow.down.right", color: StrandPalette.statusCritical, title: "Falling")
    }

    private func countLabel(_ count: Int, symbol: String, color: Color, title: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            StatusBadge(symbol: symbol, color: color, size: 26)
            Text(verbatim: "\(count)")
                .font(StrandFont.number(20))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(title)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Cardio's "is it working": VO₂max over eight weeks — the marker Garmin requires for a productive
    /// load. Shown beside Polar's load status, never changing it.
    private var vo2maxCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Cardio development", overline: "VO₂max, last eight weeks")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    if let vo2 = model.vo2max, let latest = vo2.latest {
                        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                            TrainingCountUp(value: shownVO2, decimals: 1)
                                .font(StrandFont.number(40, weight: .bold))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .accessibilityLabel(Text(latest.value, format: .number.precision(.fractionLength(1))))
                                .task(id: latest.value) {
                                    if reduceMotion {
                                        shownVO2 = latest.value
                                    } else {
                                        withAnimation(StrandMotion.drawIn) { shownVO2 = latest.value }
                                    }
                                }
                            Text(verbatim: "ml/kg/min")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                            Spacer(minLength: NoopMetrics.space2)
                            vo2Chip(vo2)
                        }
                        VO2maxSparkline(readings: vo2.readings, color: vo2Color(vo2.direction))
                        Text(vo2SourceText(latest))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if vo2.segmentBreak {
                            Text("Earlier readings in this window came from a different estimate and are left out, so a change of method is not shown as fitness.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("No VO₂max readings in the last eight weeks yet. They come from Apple Health, or from NOOP's weekly estimate once your profile and resting heart rate allow it.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func vo2Color(_ direction: FitnessDirection) -> Color {
        switch direction {
        case .improving: return StrandPalette.statusPositive
        case .worsening: return StrandPalette.statusCritical
        default:         return StrandPalette.effortColor
        }
    }

    /// The direction and the change the line implies, e.g. "↗ +1.2 in 7 weeks".
    private func vo2Chip(_ vo2: VO2maxResponse) -> some View {
        let color = vo2Color(vo2.direction)
        let symbol: String
        let text: String
        switch vo2.direction {
        case .improving, .worsening:
            symbol = vo2.direction == .improving ? "arrow.up.right" : "arrow.down.right"
            let change = (vo2.changeOverSpan ?? 0).formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))
            let weeks = max(1, Int((Double(vo2.spanDays) / 7).rounded()))
            text = String(localized: "\(change) in \(weeks) weeks")
        case .unclear:
            symbol = "minus"
            text = String(localized: "No clear direction")
        case .unknown:
            symbol = "hourglass"
            text = String(localized: "Needs four readings")
        }
        let muted = vo2.direction == .unknown || vo2.direction == .unclear
        return HStack(spacing: 5) {
            Image(systemName: symbol).font(StrandFont.rounded(11, weight: .bold))
            Text(text).font(StrandFont.captionNumber)
        }
        .foregroundStyle(muted ? StrandPalette.textSecondary : StrandPalette.onDarkPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            if muted {
                Capsule().fill(StrandPalette.surfaceInset)
            } else {
                Capsule().fill(color.gradient).shadow(color: color.opacity(0.4), radius: 4, y: 2)
            }
        }
    }

    private func vo2SourceText(_ latest: VO2maxReading) -> String {
        if latest.segment == Repository.appleHealthSource {
            return String(localized: "Measured by Apple Watch during outdoor walks and runs.")
        }
        // Name the estimator when the reading carries its provenance; never print "Unknown" in its place.
        guard let estimator = Vo2MaxEstimator(rawValue: latest.segment) else {
            return String(localized: "Estimated by NOOP from your resting heart rate and activity. An estimate, not a lab test.")
        }
        let name = vo2MaxEstimatorDisplayName(estimator)
        return String(localized: "Estimated by NOOP (\(name)) from your resting heart rate and activity. An estimate, not a lab test.")
    }

    // MARK: - Session lane and coverage

    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Session load", overline: "Your own rating")
            laneCard(icon: "person.fill.checkmark", title: "Session load", lane: model.session,
                     value: sessionText, tint: StrandPalette.metricCyan, coverage: sessionCoverage)
        }
    }

    private var basisCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("What it rests on", overline: "Data coverage")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    basisRow(symbol: "figure.strengthtraining.traditional", share: coverageShare(model.strength),
                             text: strengthCoverage(model.strength))
                    Divider().overlay(StrandPalette.hairline)
                    basisRow(symbol: "heart.fill", share: coverageShare(model.cardio),
                             text: cardioCoverage(model.cardio))
                }
            }
        }
    }

    /// The measured share of a lane's figure, nil when there is nothing to measure.
    private func coverageShare(_ lane: TrainingLoadModel.Lane?) -> Double? {
        guard let lane, lane.possibleCount > 0 else { return nil }
        return Double(lane.measuredCount) / Double(lane.possibleCount)
    }

    private func basisRow(symbol: String, share: Double?, text: String) -> some View {
        let color = share.map { $0 >= TrainingLoad.trustedRatedShare ? StrandPalette.statusPositive
                                                                      : StrandPalette.statusWarning }
            ?? StrandPalette.textTertiary
        return HStack(alignment: .center, spacing: NoopMetrics.space3) {
            CoverageRing(fraction: share ?? 0, color: color, symbol: symbol)
            Text(text)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func laneCard(icon: String, title: LocalizedStringKey, lane: TrainingLoadModel.Lane?,
                          value: @escaping (TrainingLoadModel.Lane?) -> String, tint: Color,
                          coverage: @escaping (TrainingLoadModel.Lane?) -> String) -> some View {
        NoopCard(tint: tint) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)
                    Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    if let trend = lane?.trend {
                        Text(signedPercent(trend.percentChange))
                            .font(StrandFont.number(18))
                            .foregroundStyle(abs(trend.percentChange) < 15
                                             ? StrandPalette.textSecondary : StrandPalette.metricCyan)
                    }
                }
                Text(value(lane))
                    .font(StrandFont.number(28))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(lane?.trend.map { comparisonText($0.percentChange) }
                     ?? String(localized: "Needs two weeks of measured history"))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(coverage(lane))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Legend and method

    private var legendCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("The six states", overline: "Legend")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    ForEach(TrainingStatus.allCases, id: \.self) { status in
                        HStack(alignment: .top, spacing: NoopMetrics.space3) {
                            StatusBadge(symbol: status.symbol, color: status.color, size: 34, cornerRadius: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(status.label)
                                    .font(StrandFont.subhead.weight(.semibold))
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(status.meaning)
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var methodCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("What each number means", overline: "Transparent by design")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    // The lane titles, not bare "Strength/Cardio/Session": the method rows explain the three
                    // cards above and have to name them the same way in every language.
                    methodRow("Strength load", "Working sets weighted by proximity to failure. Tonnage remains a training statistic, not the load.")
                    Divider().overlay(StrandPalette.hairline)
                    methodRow("Cardio load", "Session Effort from heart rate and intensity over time, derived from TRIMP.")
                    Divider().overlay(StrandPalette.hairline)
                    methodRow("Session load", "Your whole-session RPE × duration. Add it from any workout detail; missing ratings are never guessed.")
                    Divider().overlay(StrandPalette.hairline)
                    methodRow("How the status is set", "Cardio uses Polar's cardio load status: the last 7 days against your level over up to 28 days, with Polar's thresholds 0.8, 1.0 and 1.3. Strength also asks whether your lifts are improving, and above 1.3 whether your recovery holds. It counts as detraining only after three weeks below your usual or with falling lifts, because maximal strength drops measurably only from the third week without training. The thresholds are a convention, not a measurement.")
                    Divider().overlay(StrandPalette.hairline)
                    methodRow("Sources", "Polar Training Load Pro · Garmin Training Status · Bosquet et al. 2013 · Pelland et al. 2024 · Robinson et al. 2024 · Foster 2001")
                }
            }
        }
    }

    private func methodRow(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text(detail).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Formatting

    private func signedPercent(_ value: Double) -> String {
        let magnitude = Int(abs(value).rounded())
        // A change that rounds to zero has no direction; "+0 %" or "−0 %" would imply one.
        guard magnitude > 0 else { return "0 %" }
        return "\(value > 0 ? "+" : "−")\(magnitude) %"
    }

    private func comparisonText(_ value: Double) -> String {
        if value >= 15 { return String(localized: "Above your usual") }
        if value <= -15 { return String(localized: "Below your usual") }
        return String(localized: "About your usual")
    }

    private func weightedSetText(_ lane: TrainingLoadModel.Lane) -> String {
        let number = lane.sevenDayTotal.formatted(.number.precision(.fractionLength(1)))
        return String(localized: "\(number) weighted sets")
    }

    private func effortText(_ lane: TrainingLoadModel.Lane) -> String {
        String(localized: "\(Int(lane.sevenDayTotal.rounded())) Effort")
    }

    private func sessionText(_ lane: TrainingLoadModel.Lane?) -> String {
        guard let lane, lane.measuredCount > 0 else { return "—" }
        return String(localized: "\(Int(lane.sevenDayTotal.rounded())) AU")
    }

    /// How much of the effort weighting is measured rather than the unrated default. Counted, not a
    /// percentage, so a share that rests on a handful of sets reads as a handful of sets.
    private func strengthCoverage(_ lane: TrainingLoadModel.Lane?) -> String {
        guard let lane, lane.possibleCount > 0 else {
            return String(localized: "No working sets in the last 28 days")
        }
        let rated = lane.measuredCount
        let total = lane.possibleCount
        if rated == total {
            return String(localized: "All \(total) working sets in the last 28 days carry an RPE")
        }
        if Double(rated) / Double(total) < TrainingLoad.trustedRatedShare {
            return String(localized: "Only \(rated) of \(total) working sets in the last 28 days carry an RPE, so most of the weighting is the neutral default for unrated sets")
        }
        return String(localized: "\(rated) of \(total) working sets in the last 28 days carry an RPE; the rest use the neutral default")
    }

    private func cardioCoverage(_ lane: TrainingLoadModel.Lane?) -> String {
        guard let lane, lane.possibleCount > 0 else { return String(localized: "No cardio sessions yet") }
        return String(localized: "\(lane.measuredCount) of \(lane.possibleCount) cardio sessions carry Effort")
    }

    private func sessionCoverage(_ lane: TrainingLoadModel.Lane?) -> String {
        guard let lane, lane.possibleCount > 0 else { return String(localized: "Open a workout to add your first session rating") }
        return String(localized: "\(lane.measuredCount) of \(lane.possibleCount) sessions rated in the last 28 days")
    }
}
