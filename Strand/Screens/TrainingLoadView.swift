import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Three loads, three units
//
// A single combined score would need an invented exchange rate between a hard set, a heart-rate load
// and the athlete's own perception. This screen keeps all three visible in their real units and gives
// each the same useful comparison: the rolling seven days against the person's recent level. That
// level grows with the history available and tops out at 28 days.

@MainActor
final class TrainingLoadModel: ObservableObject {
    struct Lane: Sendable {
        let sevenDayTotal: Double
        let trend: LoadTrend?
        /// What the lane's figure rests on over the last 28 days, in the lane's own unit: RPE-rated
        /// working sets for Strength, sessions carrying Effort for Cardio, rated sessions for Session.
        let measuredCount: Int
        let possibleCount: Int
    }

    @Published private(set) var strength: Lane?
    @Published private(set) var cardio: Lane?
    @Published private(set) var session: Lane?
    @Published private(set) var loaded = false

    func load(repo: Repository) async {
        let now = Int(Date().timeIntervalSince1970)
        let from = now - 120 * 86_400
        let offset = TimeZone.current.secondsFromGMT()

        async let workoutRows = repo.workoutRows(days: 120, reconcileHrCap: 0)
        async let ratings = repo.sessionRPEEntries(from: from, to: now + 86_400)
        let strengthWorkouts: [HevyWorkout]
        if let store = await repo.storeHandle() {
            strengthWorkouts = (try? await store.strengthWorkouts(from: from, to: now + 86_400)) ?? []
        } else {
            strengthWorkouts = []
        }
        let rows = await workoutRows
        let rpeEntries = await ratings

        let today = Repository.localDayKey(Date())
        let prepared = await Task.detached(priority: .userInitiated) {
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

            return (
                Lane(sevenDayTotal: Self.lastSeven(strengthByDay, through: today),
                     trend: TrainingLoad.trend(dailyByDay: strengthByDay, through: today),
                     measuredCount: pooledStrength.ratedSets,
                     possibleCount: pooledStrength.workingSets),
                Lane(sevenDayTotal: Self.lastSeven(cardioByDay, through: today),
                     trend: TrainingLoad.trend(dailyByDay: cardioByDay, through: today),
                     measuredCount: recentCardio.filter { $0.strain != nil }.count,
                     possibleCount: recentCardio.count),
                Lane(sevenDayTotal: Self.lastSeven(sessionByDay, through: today),
                     trend: TrainingLoad.trend(dailyByDay: sessionByDay, through: today),
                     measuredCount: measured, possibleCount: possible)
            )
        }.value

        guard !Task.isCancelled else { return }
        strength = prepared.0
        cardio = prepared.1
        session = prepared.2
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
}

struct TrainingLoadView: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = TrainingLoadModel()

    var body: some View {
        ScreenScaffold(title: "Training Load",
                       subtitle: "Three views of training, each in the unit that fits it.",
                       onRefresh: { await model.load(repo: repo) },
                       lazy: true) {
            if !model.loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                overview
                interactionCard
                methodCard
            }
        }
        .task(id: repo.refreshSeq) { await model.load(repo: repo) }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Last 7 days", overline: "Against your own recent level")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: NoopMetrics.gap)],
                      spacing: NoopMetrics.gap) {
                laneCard(icon: "dumbbell.fill", title: "Strength load", lane: model.strength,
                         value: weightedSetText, tint: StrandPalette.metricAmber,
                         coverage: strengthCoverage)
                laneCard(icon: "heart.fill", title: "Cardio load", lane: model.cardio,
                         value: effortText, tint: StrandPalette.effortColor,
                         coverage: cardioCoverage)
                laneCard(icon: "person.fill.checkmark", title: "Session load", lane: model.session,
                         value: sessionText, tint: StrandPalette.metricCyan,
                         coverage: sessionCoverage)
            }
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

    private var interactionCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Where they meet", overline: "Recovery context")
            NoopCard(tint: DomainTheme.charge.color) {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Label("Charge adds the context", systemImage: "gauge.with.dots.needle.50percent")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Strength, cardio and perceived load stay separate because there is no measured exchange rate between a hard set, heart-rate work and how a whole session felt. They still interact through recovery: sleep, HRV and resting heart rate show how your body handled their combined demand.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var methodCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("What each number means", overline: "Transparent by design")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    methodRow("Strength", "Working sets weighted by proximity to failure. Tonnage remains a training statistic, not the load.")
                    Divider().overlay(StrandPalette.hairline)
                    methodRow("Cardio", "Session Effort from heart rate and intensity over time, derived from TRIMP.")
                    Divider().overlay(StrandPalette.hairline)
                    methodRow("Session", "Your whole-session RPE × duration. Add it from any workout detail; missing ratings are never guessed.")
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

    private func signedPercent(_ value: Double) -> String {
        "\(value >= 0 ? "+" : "−")\(Int(abs(value).rounded())) %"
    }

    private func comparisonText(_ value: Double) -> String {
        if value >= 15 { return String(localized: "Above your usual") }
        if value <= -15 { return String(localized: "Below your usual") }
        return String(localized: "About your usual")
    }

    private func weightedSetText(_ lane: TrainingLoadModel.Lane?) -> String {
        guard let lane else { return "—" }
        let number = lane.sevenDayTotal.formatted(.number.precision(.fractionLength(1)))
        return String(localized: "\(number) weighted sets")
    }

    private func effortText(_ lane: TrainingLoadModel.Lane?) -> String {
        guard let lane else { return "—" }
        return String(localized: "\(Int(lane.sevenDayTotal.rounded())) Effort")
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
