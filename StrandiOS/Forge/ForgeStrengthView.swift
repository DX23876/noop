#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandTraining

/// The redesign's Strength page (prototype board "StrengthHub"): the next planned routine ready to start,
/// weekly volume, the latest sessions and the way into routines, muscles and the full strength analysis.
/// Every number comes from the same `StrengthModel` the shipped Strength screen reads; that screen stays
/// one row away, so nothing it shows is lost.
struct ForgeStrengthView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var session: ActiveSessionController
    @StateObject private var model = StrengthModel()
    @StateObject private var hub = TrainingHubModel()
    @AppStorage("training.weekStartsOn") private var weekStartRaw = TrainingWeekStart.monday.rawValue
    @State private var scrolledPast = false

    private var weekStart: TrainingWeekStart { TrainingWeekStart(rawValue: weekStartRaw) ?? .monday }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForgeDetailHeader(overline: nil, title: String(localized: "Strength"),
                                  scrolledPast: $scrolledPast, picture: PagePicture(symbol: "dumbbell.fill", accent: "flame.fill", tint: ForgeColor.trainingData))
                nextUp
                volume
                recent
                library
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .training))
        .forgeDetailBar(title: String(localized: "Strength"), showsTitle: scrolledPast)
        .task(id: repo.refreshSeq) {
            await hub.load(repo: repo, session: session, weekStartsOn: weekStart)
            await model.load(repo: repo)
        }
    }

    // MARK: Next up

    /// The first day of the coming week that has a routine planned, today included.
    private var nextPlanned: (day: Date, routine: TrainingRoutine)? {
        guard hub.loaded else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        for offset in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            if let routine = hub.routines(on: day).first { return (day, routine) }
        }
        return nil
    }

    @ViewBuilder private var nextUp: some View {
        if let next = nextPlanned {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Next up").font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Spacer()
                    Text(Self.dayText(next.day)).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
                Text(next.routine.title).font(.system(.title2, weight: .bold)).foregroundStyle(ForgeColor.text)
                Text("\(next.routine.exercises.count) exercises")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                Button { session.requestStrength(routines: [next.routine]) } label: {
                    Label("Start", systemImage: "play.fill")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(ForgeColor.onTrainingAccent)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Capsule().fill(ForgeColor.trainingAccent))
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
                .accessibilityLabel(Text("Start \(next.routine.title)"))
            }
            .forgeCard(radius: ForgeRadius.card, padding: 16)
        } else if hub.loaded {
            NavigationLink(value: MoreDestination.training) {
                ForgeRow(systemImage: "calendar.badge.plus", tint: ForgeColor.trainingAccent, title: String(localized: "Plan a strength day"),
                         subtitle: String(localized: "Pick routines for the days you train"))
                    .forgeCard(radius: ForgeRadius.card, padding: 0)
            }
            .buttonStyle(.plain)
        }
    }

    static func dayText(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return String(localized: "Today") }
        if Calendar.current.isDateInTomorrow(day) { return String(localized: "Tomorrow") }
        return day.formatted(.dateTime.weekday(.wide).locale(AppLanguage.activeLocale))
    }

    // MARK: Volume

    /// Tonnes lifted per training week, oldest first, for the last eight COMPLETED weeks (zero for a week
    /// without a session, so a gap reads as a gap). The running week is left out: a Monday would otherwise
    /// end the chart on an empty bar and read as a drop.
    private var weeklyTonnes: [Double] {
        var cal = Calendar.current
        cal.firstWeekday = weekStart == .monday ? 2 : 1
        guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: Date())?.start else { return [] }
        var totals = Array(repeating: 0.0, count: 8)
        for s in model.summaries {
            let start = Date(timeIntervalSince1970: TimeInterval(s.startTs))
            guard let week = cal.dateInterval(of: .weekOfYear, for: start)?.start,
                  let back = cal.dateComponents([.weekOfYear], from: week, to: thisWeek).weekOfYear,
                  (1...8).contains(back) else { continue }
            totals[8 - back] += s.volumeLoadKg / 1000
        }
        return totals
    }

    @ViewBuilder private var volume: some View {
        let tonnes = weeklyTonnes
        if tonnes.contains(where: { $0 > 0 }) {
            let top = max(tonnes.max() ?? 1, 0.1)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Volume").font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Spacer()
                    Text("tonnes lifted per week").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(tonnes.enumerated()), id: \.offset) { i, t in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(ForgeColor.trainingData.opacity(i == tonnes.count - 1 ? 1 : 0.55))
                            .frame(height: max(4, 90 * t / top))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 90, alignment: .bottom)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Volume per week"))
                .accessibilityValue(Text(tonnes.map { String(format: "%.1f", $0) }.joined(separator: ", ")))
                if let change = Self.fourWeekChange(tonnes) {
                    Text(change).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
            }
            .forgeCard(radius: ForgeRadius.card, padding: 16)
        }
    }

    /// The last four weeks against the four before them, in words. Nil without both halves.
    static func fourWeekChange(_ tonnes: [Double]) -> String? {
        guard tonnes.count == 8 else { return nil }
        let before = tonnes.prefix(4).reduce(0, +), after = tonnes.suffix(4).reduce(0, +)
        guard before > 0, after > 0 else { return nil }
        let pct = Int(((after / before) - 1) * 100)
        if abs(pct) < 3 { return String(localized: "About the same as the four weeks before.") }
        return pct > 0 ? String(localized: "Up \(pct) % on the four weeks before.")
                       : String(localized: "Down \(-pct) % on the four weeks before.")
    }

    // MARK: Recent

    @ViewBuilder private var recent: some View {
        let rows = Array(model.summaries.sorted { $0.startTs > $1.startTs }.prefix(3))
        if !rows.isEmpty {
            ForgeSectionTitle(title: "Recent")
            ForgeGroup {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, s in
                    if index > 0 { ForgeRowDivider() }
                    NavigationLink(value: TabRoute.strength) {
                        ForgeRow(systemImage: "dumbbell.fill", tint: ForgeColor.trainingData, title: s.title,
                                 subtitle: Self.sessionDetail(s), value: "\(s.workingSetCount)", unit: String(localized: "sets"))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    static func sessionDetail(_ s: StrengthSessionSummary) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(s.startTs))
        var parts = [start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(AppLanguage.activeLocale))]
        if let d = s.durationS, d > 0 { parts.append(String(localized: "\(Int(d / 60)) min")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Plan and library

    private var library: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForgeSectionTitle(title: "Plan and library")
            ForgeGroup {
                NavigationLink(value: MoreDestination.training) {
                    ForgeRow(systemImage: "calendar", tint: ForgeColor.trainingAccent, title: String(localized: "Routines and exercises"),
                             subtitle: hub.loaded ? String(localized: "\(hub.plan.routines.count) routines") : nil)
                }
                ForgeRowDivider()
                NavigationLink(value: ForgeRoute.muscles) {
                    ForgeRow(systemImage: "figure.strengthtraining.traditional", tint: ForgeColor.trainingAccent,
                             title: String(localized: "Muscles"), subtitle: String(localized: "Balance, fatigue and strength on a body map"))
                }
                ForgeRowDivider()
                NavigationLink(value: TabRoute.strength) {
                    ForgeRow(systemImage: "chart.bar.xaxis", tint: ForgeColor.trainingAccent, title: String(localized: "All strength details"),
                             subtitle: String(localized: "Sessions, records and load"))
                }
            }
            .buttonStyle(.plain)
        }
    }
}

/// The redesign's Muscles page (boards "MuscleBalance" and "MuscleFatigue"): the shipped body-map
/// analysis on a Forge page. The analysis, its modes and its wording are `MuscleAnalyticsSurface`'s own.
struct ForgeMusclesView: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = StrengthModel()
    @State private var scrolledPast = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForgeDetailHeader(overline: nil, title: String(localized: "Muscles"),
                                  scrolledPast: $scrolledPast,
                                  picture: PagePicture(symbol: "figure.strengthtraining.traditional", accent: "bolt.fill", tint: ForgeColor.trainingData))
                MuscleAnalyticsSurface(history: model.resolvedHistory, compact: false)
                    .forgeCard(radius: ForgeRadius.card, padding: 16)
                Link("Body geometry: MuscleMap · MIT License",
                     destination: URL(string: "https://github.com/melihcolpan/MuscleMap")!)
                    .font(ForgeFont.caption)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .training))
        .forgeDetailBar(title: String(localized: "Muscles"), showsTitle: scrolledPast)
        .task(id: repo.refreshSeq) { await model.load(repo: repo) }
    }
}
#endif
