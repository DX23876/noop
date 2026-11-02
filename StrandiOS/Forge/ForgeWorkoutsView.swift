#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandCore
import StrandTraining
import WhoopStore

/// The redesign's Workouts page (prototype board "Workouts"): thirteen weeks of activity as a calendar,
/// this week in numbers, and the sessions grouped by week. Each session opens the shipped workout detail.
struct ForgeWorkoutsView: View {
    @EnvironmentObject private var repo: Repository
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    @AppStorage("training.weekStartsOn") private var weekStartRaw = TrainingWeekStart.monday.rawValue
    @State private var rows: [WorkoutRow] = []
    @State private var scrolledPast = false

    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    private var distanceSystem: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric, override: distanceSystemRaw)
    }
    private var calendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = (TrainingWeekStart(rawValue: weekStartRaw) ?? .monday) == .monday ? 2 : 1
        return cal
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForgeDetailHeader(overline: nil, title: String(localized: "Workouts"),
                                  scrolledPast: $scrolledPast)
                calendarCard
                weekNumbers
                ForEach(weeks, id: \.start) { week in
                    Text(Self.weekTitle(week.start, calendar: calendar))
                        .font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.secondary)
                        .padding(.horizontal, 4).padding(.top, 4)
                    ForgeGroup {
                        ForEach(Array(week.rows.enumerated()), id: \.offset) { index, row in
                            if index > 0 { ForgeRowDivider() }
                            NavigationLink(value: ForgeRoute.workout(startTs: row.startTs, sport: row.sport)) {
                                sessionRow(row)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if rows.isEmpty {
                    Text("Workouts you record or import appear here.")
                        .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary).padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .training))
        .forgeDetailBar(title: String(localized: "Workouts"), showsTitle: scrolledPast)
        .task(id: repo.refreshSeq) {
            rows = (await repo.workoutRows(days: 91, reconcileHrCap: 0)).sorted { $0.startTs > $1.startTs }
        }
    }

    // MARK: Calendar

    /// Active energy (or Effort when energy is missing) per day for the last 13 weeks, one column per week.
    private var calendarCard: some View {
        let cal = calendar
        let today = cal.startOfDay(for: Date())
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let first = cal.date(byAdding: .weekOfYear, value: -12, to: thisWeek) ?? thisWeek
        var load: [Date: Double] = [:]
        for r in rows {
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(r.startTs)))
            load[day, default: 0] += r.energyKcal ?? (r.strain ?? 0) * 8
        }
        let top = max(load.values.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 13 weeks").font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                Spacer()
                Text("active energy per day").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            }
            HStack(spacing: 3) {
                ForEach(0..<13, id: \.self) { w in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { d in
                            let day = cal.date(byAdding: .day, value: w * 7 + d, to: first) ?? first
                            let v = load[day] ?? 0
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(day > today ? Color.clear
                                      : v > 0 ? ForgeColor.effort.opacity(0.25 + 0.75 * min(1, v / top)) : ForgeColor.fill)
                                .aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Training days in the last 13 weeks"))
            .accessibilityValue(Text("\(Set(load.keys).count) days with a workout"))
        }
        .forgeCard(radius: 22, padding: 14)
    }

    // MARK: This week

    private var weekNumbers: some View {
        let start = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let week = rows.filter { Date(timeIntervalSince1970: TimeInterval($0.startTs)) >= start }
        let minutes = week.reduce(0.0) { $0 + ($1.durationS ?? Double(max($1.endTs - $1.startTs, 0))) / 60 }
        let effort = week.compactMap(\.strain).reduce(0, +)
        return HStack(spacing: 0) {
            stat("\(week.count)", String(localized: "this week"))
            stat(ForgeTrainingView.duration(minutes), String(localized: "time"))
            stat(ForgeToday.effortText(effort, scale: effortScale), String(localized: "Effort total"))
        }
        .forgeCard(radius: 22, padding: 14)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(ForgeFont.rounded(22, .bold)).foregroundStyle(ForgeColor.text).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Sessions by week

    private struct Week { let start: Date; let rows: [WorkoutRow] }

    private var weeks: [Week] {
        let cal = calendar
        let grouped = Dictionary(grouping: rows) { cal.dateInterval(of: .weekOfYear, for: Date(timeIntervalSince1970: TimeInterval($0.startTs)))?.start ?? .distantPast }
        return grouped.keys.sorted(by: >).map { Week(start: $0, rows: grouped[$0] ?? []) }
    }

    static func weekTitle(_ start: Date, calendar: Calendar) -> String {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: Date())?.start else { return "" }
        if calendar.isDate(start, inSameDayAs: thisWeek) { return String(localized: "This week") }
        if let last = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek), calendar.isDate(start, inSameDayAs: last) {
            return String(localized: "Last week")
        }
        return String(localized: "Week of \(start.formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale)))")
    }

    private func sessionRow(_ row: WorkoutRow) -> some View {
        let tint = AppleInspiredColors.role(forSport: row.sport).color
        let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
        let secs = row.durationS ?? Double(max(row.endTs - row.startTs, 0))
        var parts = [start.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(AppLanguage.activeLocale)),
                     String(localized: "\(Int(secs / 60)) min")]
        if let dm = row.distanceM, dm > 0 { parts.append(UnitFormatter.distanceFromMeters(dm, system: distanceSystem)) }
        return HStack(spacing: 12) {
            WorkoutTypeIcon(workoutType: row.sport, size: 16, weight: .semibold, color: tint)
                .frame(width: 38, height: 38)
                .background(Circle().fill(tint.opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                Text(WorkoutSource.localizedDisplaySport(row.sport))
                    .font(.system(.callout, weight: .semibold)).foregroundStyle(ForgeColor.text).lineLimit(1)
                Text(parts.joined(separator: " · ")).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let strain = row.strain {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(ForgeToday.effortText(strain, scale: effortScale)).font(ForgeFont.rounded(19, .bold))
                        .foregroundStyle(ForgeColor.effortInk)
                    Text(DomainTheme.effort.productName).font(.system(.caption2)).foregroundStyle(ForgeColor.secondary)
                }
            }
            Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold)).foregroundStyle(ForgeColor.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Opens one workout's shipped detail page directly: finds the row the list showed and hands it over.
struct ForgeWorkoutDetailHost: View {
    let startTs: Int
    let sport: String
    @EnvironmentObject private var repo: Repository
    @State private var row: WorkoutRow?
    @State private var looked = false

    var body: some View {
        Group {
            if let row {
                WorkoutDetailView(row: row)
            } else if looked {
                Text("This workout is no longer stored.")
                    .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ForgeBackground(tab: .training))
        .task {
            let age = max(1, Int(Date().timeIntervalSince1970) - startTs) / 86_400 + 2
            row = (await repo.workoutRows(days: age, reconcileHrCap: 0)).first { $0.startTs == startTs && $0.sport == sport }
            looked = true
        }
    }
}
#endif
