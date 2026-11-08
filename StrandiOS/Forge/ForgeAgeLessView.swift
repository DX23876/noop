#if os(iOS)
import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

/// The redesign's AgeLess page (2026-11). One question, "am I ageing faster or slower than the calendar,
/// and what moves it?", answered by one age line: actual age, AgeLess age and where the last 30 days lead
/// in six months. Below it, where the years come from (sleep, activity and fitness as bars either side of
/// zero, each opening its measures), the strongest next steps, and the age over time, which also picks
/// the week the page shows.
///
/// Every number is the shipped engine's (`HealthspanSnapshot`, `HealthspanEngine`); the narrative, levers
/// and measure rows are the shipped views. The shipped `HealthspanDetailView` stays as it was, so this
/// page can be switched back by routing `ForgeRoute.ageless` to `AgeLessScreen` again.
struct ForgeAgeLessView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @State private var snapshot: HealthspanSnapshot?
    @State private var index: Int?
    @State private var open: Set<HealthspanDomain> = []
    @State private var scrolledPast = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForgeDetailHeader(overline: nil, title: "AgeLess", scrolledPast: $scrolledPast)
                if let snapshot, !snapshot.weeks.isEmpty {
                    let shown = min(max(index ?? snapshot.weeks.count - 1, 0), snapshot.weeks.count - 1)
                    let week = snapshot.weeks[shown]
                    hero(week, isLatest: shown == snapshot.weeks.count - 1)
                    narrative(week)
                    // The levers card carries its own "Biggest levers" heading.
                    if !week.levers.isEmpty { HealthspanLeversCard(week: week) }
                    ForgeSectionTitle(title: "Where the years come from")
                    domains(week, snapshot: snapshot)
                    if snapshot.weeks.count > 1 {
                        ForgeSectionTitle(title: "Over time")
                        overTime(snapshot, shown: shown)
                    }
                    more
                } else {
                    // No sex in the profile, too few nights, or still loading: the shipped section says which.
                    HealthspanSection().forgeCard(radius: ForgeRadius.card, padding: 14)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .health))
        .forgeDetailBar(title: "AgeLess", showsTitle: scrolledPast)
        .toolbar { ToolbarItem(placement: .primaryAction) { HealthspanInfoButton().labelStyle(.iconOnly) } }
        .task(id: repo.refreshSeq) {
            guard let sex = HealthspanEngine.Sex(profileValue: profile.sex) else { snapshot = nil; return }
            snapshot = await HealthspanSnapshot.load(repo: repo, age: profile.age, sex: sex)
        }
    }

    // MARK: Hero

    private func hero(_ week: HealthspanWeek, isLatest: Bool) -> some View {
        let age = week.result.healthspanAge, actual = week.result.chronologicalAge
        let projected = week.pace.map { HealthspanEngine.projectedAge(currentAge: age, pace: $0) }
        let gap = age - actual
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(HealthspanSection.years(age))
                    .font(ForgeFont.rounded(52, .bold))
                    .foregroundStyle(gap <= 0 ? ForgeColor.chargeInk : ForgeColor.effortInk)
                VStack(alignment: .leading, spacing: 0) {
                    Text("AgeLess age").font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Text("actual age \(HealthspanSection.years(actual))").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
            }
            ForgeAgeLine(actual: actual, age: age, projected: projected)
                .frame(height: 74)
            if let pace = week.pace {
                Text(Self.paceSentence(pace)).font(.system(.body, weight: .semibold)).foregroundStyle(ForgeColor.text)
                if let projected {
                    Text("In 6 months: \(HealthspanSection.years(projected)) if the last 30 days continue")
                        .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                }
            }
            Text(isLatest ? String(localized: "Based on \(week.coveredDays) of 182 days")
                          : String(localized: "Week of \(Self.weekLabel(week.day)) · based on \(week.coveredDays) of 182 days"))
                .font(ForgeFont.caption).foregroundStyle(ForgeColor.tertiary)
        }
        .forgeCard(radius: ForgeRadius.card, padding: 16)
        .accessibilityElement(children: .combine)
    }

    /// The pace in words: how many years of ageing one calendar year brings at the current habits.
    static func paceSentence(_ pace: Double) -> String {
        let n = abs(pace).formatted(.number.precision(.fractionLength(1)))
        switch HealthspanEngine.PaceClass(pace: pace) {
        case .reversing: return String(localized: "Your age is running backwards: \(n) years per calendar year")
        case .slowing: return String(localized: "You are ageing more slowly: \(n) years per calendar year")
        case .steady: return String(localized: "You are ageing with the calendar: \(n) years per year")
        case .accelerating: return String(localized: "You are ageing faster: \(n) years per calendar year")
        }
    }

    static func weekLabel(_ day: String) -> String {
        HealthspanSection.date(day)?.formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale)) ?? day
    }

    private func narrative(_ week: HealthspanWeek) -> some View {
        let n = HealthspanEngine.narrative(result: week.result, pace: week.pace, levers: week.levers)
        return VStack(alignment: .leading, spacing: 4) {
            Text(HealthspanDetailView.title(n.kind)).font(.system(.body, weight: .semibold)).foregroundStyle(ForgeColor.text)
            Text(HealthspanDetailView.body(n)).font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .forgeCard(radius: ForgeRadius.card, padding: 14)
    }

    // MARK: Where the years come from

    private func domains(_ week: HealthspanWeek, snapshot: HealthspanSnapshot) -> some View {
        let totals = HealthspanDomain.allCases.map { ($0, week.result.years(in: $0)) }
        let span = max(totals.map { abs($0.1) }.max() ?? 1, 1)
        return VStack(spacing: 0) {
            ForEach(Array(totals.enumerated()), id: \.element.0) { i, item in
                let (d, years) = item
                if i > 0 { Rectangle().fill(ForgeColor.separator).frame(height: 0.5) }
                Button {
                    withAnimation(.snappy) { if open.contains(d) { open.remove(d) } else { open.insert(d) } }
                } label: {
                    HStack(spacing: 10) {
                        Text(HealthspanSection.domainName(d)).font(.system(.callout, weight: .semibold)).foregroundStyle(ForgeColor.text)
                            .frame(width: 88, alignment: .leading)
                        ForgeYearsBar(years: years, span: span).frame(height: 14)
                        Text(HealthspanSection.signedYears(years)).font(ForgeFont.rounded(15, .semibold))
                            .foregroundStyle(years <= 0 ? ForgeColor.chargeInk : ForgeColor.effortInk)
                            .frame(width: 70, alignment: .trailing)
                        Image(systemName: open.contains(d) ? "chevron.up" : "chevron.down")
                            .font(.system(.caption, weight: .semibold)).foregroundStyle(ForgeColor.tertiary)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(HealthspanSection.domainName(d)))
                .accessibilityValue(Text(HealthspanSection.signedYears(years)))
                .accessibilityHint(Text("Shows the measures"))
                if open.contains(d) { measures(d, week: week, snapshot: snapshot).padding(.bottom, 10) }
            }
            HStack {
                Text("younger").foregroundStyle(ForgeColor.chargeInk)
                Spacer()
                Text("older").foregroundStyle(ForgeColor.effortInk)
            }
            .font(.system(.caption, weight: .medium))
            .padding(.leading, 98).padding(.trailing, 92).padding(.top, 2)
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .forgeCard(radius: ForgeRadius.card, padding: 0)
    }

    private func measures(_ d: HealthspanDomain, week: HealthspanWeek, snapshot: HealthspanSnapshot) -> some View {
        let recent = week.recentResult
        return VStack(alignment: .leading, spacing: 12) {
            Text("▼ 6-month average · ↑↓ last 30 days").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            ForEach(HealthspanEngine.Component.allCases.filter { $0.domain == d }, id: \.self) { c in
                let contribution = week.result.contributions.first { $0.component == c }
                let recentContribution = recent?.contributions.first { $0.component == c }
                let trend: HealthspanEngine.Trend? = {
                    guard let w = contribution, let wv = w.value, let r = recentContribution, let rv = r.value else { return nil }
                    return HealthspanEngine.trend(windowValue: wv, recentValue: rv, windowYears: w.years, recentYears: r.years)
                }()
                HealthspanMeasureRow(component: c, value: week.inputs.value(c),
                                     years: contribution?.value == nil ? nil : contribution?.years,
                                     scale: HealthspanEngine.barScale(c, age: week.inputs.age, sex: week.inputs.sex),
                                     trend: trend,
                                     note: HealthspanSection.note(c, week: week, today: snapshot.today),
                                     thin: HealthspanSection.isThin(c, week: week, today: snapshot.today))
            }
        }
    }

    // MARK: Over time

    private func overTime(_ snapshot: HealthspanSnapshot, shown: Int) -> some View {
        let weeks = Array(snapshot.weeks.enumerated())
        let actual = snapshot.weeks[shown].result.chronologicalAge
        let values = snapshot.weeks.map(\.result.healthspanAge) + [actual]
        let lo = (values.min() ?? 0).rounded(.down) - 1, hi = (values.max() ?? 0).rounded(.up) + 1
        // The line in the page's verdict colour: green reads as "good" and must not draw an age running ahead.
        let tint = snapshot.weeks[shown].result.healthspanAge <= actual ? ForgeColor.charge : ForgeColor.effort
        return VStack(alignment: .leading, spacing: 8) {
            Chart {
                RuleMark(y: .value("Actual age", actual))
                    .foregroundStyle(ForgeColor.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                ForEach(weeks, id: \.offset) { i, w in
                    LineMark(x: .value("Week", i), y: .value("AgeLess age", w.result.healthspanAge))
                        .foregroundStyle(tint)
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Week", i), y: .value("AgeLess age", w.result.healthspanAge))
                        .foregroundStyle(i == shown ? ForgeColor.text : tint)
                        .symbolSize(i == shown ? 80 : 24)
                }
            }
            .chartYScale(domain: lo...hi)
            .chartXAxis(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                            guard let plot = proxy.plotFrame else { return }
                            let x = g.location.x - geo[plot].origin.x
                            if let i: Int = proxy.value(atX: x) { index = min(max(i, 0), snapshot.weeks.count - 1) }
                        })
                }
            }
            .frame(height: 140)
            .accessibilityLabel(Text("AgeLess age over time"))
            Text("Dashed: your actual age. Tap or drag to show another week.")
                .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
        }
        .forgeCard(radius: ForgeRadius.card, padding: 14)
    }

    private var more: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForgeGroup {
                NavigationLink(value: MoreDestination.rhythmAge) {
                    ForgeRow(systemImage: "sun.and.horizon", tint: ForgeColor.charge, title: String(localized: "Daily rhythm"),
                             subtitle: String(localized: "Your rhythm age from movement over the day"))
                }
                .buttonStyle(.plain)
            }
            Text("Beta. Not a medical value.").font(ForgeFont.caption).foregroundStyle(ForgeColor.tertiary).padding(.horizontal, 4)
        }
    }
}

/// The age line: one axis with the actual age and the AgeLess age as dots, the gap between them shaded and
/// named, and a faint dot where six more months at the current pace lead.
struct ForgeAgeLine: View {
    let actual: Double
    let age: Double
    let projected: Double?

    var body: some View {
        let points = [actual, age] + (projected.map { [$0] } ?? [])
        let lo = (points.min() ?? 0) - 1.5, hi = (points.max() ?? 0) + 1.5
        let younger = age <= actual
        let tint = younger ? ForgeColor.charge : ForgeColor.effort
        GeometryReader { geo in
            let w = geo.size.width
            let x = { (v: Double) -> CGFloat in CGFloat((v - lo) / (hi - lo)) * w }
            let mid: CGFloat = 30
            ZStack(alignment: .topLeading) {
                Capsule().fill(ForgeColor.fill).frame(height: 6).offset(y: mid - 3)
                Capsule().fill(tint.opacity(0.35))
                    .frame(width: max(6, abs(x(actual) - x(age))), height: 14)
                    .offset(x: min(x(actual), x(age)), y: mid - 7)
                if let projected {
                    Circle().strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                        .frame(width: 16, height: 16).offset(x: x(projected) - 8, y: mid - 8)
                }
                Circle().fill(ForgeColor.card).overlay(Circle().strokeBorder(ForgeColor.secondary, lineWidth: 3))
                    .frame(width: 20, height: 20).offset(x: x(actual) - 10, y: mid - 10)
                Circle().fill(tint).overlay(Circle().strokeBorder(ForgeColor.card, lineWidth: 3))
                    .frame(width: 24, height: 24).offset(x: x(age) - 12, y: mid - 12)
                Text(younger ? String(localized: "\(HealthspanSection.years(actual - age)) years younger")
                             : String(localized: "\(HealthspanSection.years(age - actual)) years older"))
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(younger ? ForgeColor.chargeInk : ForgeColor.effortInk)
                    .fixedSize()
                    .position(x: min(max((x(actual) + x(age)) / 2, 60), w - 60), y: 6)
                Text("actual").font(.system(.caption2)).foregroundStyle(ForgeColor.secondary).fixedSize()
                    .position(x: x(actual), y: mid + 24)
                if let projected {
                    // On the same line as "actual" unless the two words would touch; then one row lower.
                    let crowded = abs(x(projected) - x(actual)) < 80
                    Text("in 6 months").font(.system(.caption2)).foregroundStyle(ForgeColor.secondary).fixedSize()
                        .position(x: min(max(x(projected), 36), w - 36), y: mid + (crowded ? 38 : 24))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A bar either side of a centre line: years off to the left (younger, charge colour), years on to the
/// right (older, effort colour), scaled to the largest domain.
struct ForgeYearsBar: View {
    let years: Double
    let span: Double

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let len = CGFloat(min(abs(years) / span, 1)) * half
            ZStack(alignment: .leading) {
                Capsule().fill(ForgeColor.fill).frame(height: 8).offset(y: (geo.size.height - 8) / 2)
                Rectangle().fill(ForgeColor.separator).frame(width: 1.5, height: geo.size.height).offset(x: half)
                Capsule().fill(years <= 0 ? ForgeColor.charge : ForgeColor.effort)
                    .frame(width: max(len, 3), height: 10)
                    .offset(x: years <= 0 ? half - max(len, 3) : half, y: (geo.size.height - 10) / 2)
            }
        }
        .accessibilityHidden(true)
    }
}
/// AgeLess as a card: the top of its page only (AgeLess age, actual age, pace, six months on) on the same
/// age line, opening the full page. Health and Today's wide AgeLess tile draw it. Without a week to show (no
/// sex in the profile, too few nights) it still opens the page, which says what is missing.
struct ForgeAgeLessSummary: View {
    let week: HealthspanWeek?

    var body: some View {
        NavigationLink(value: ForgeRoute.ageless) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("AgeLess", systemImage: "hourglass").font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold)).foregroundStyle(ForgeColor.tertiary)
                }
                if let week {
                    let age = week.result.healthspanAge, actual = week.result.chronologicalAge
                    let projected = week.pace.map { HealthspanEngine.projectedAge(currentAge: age, pace: $0) }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(HealthspanSection.years(age)).font(ForgeFont.rounded(34, .bold))
                            .foregroundStyle(age <= actual ? ForgeColor.chargeInk : ForgeColor.effortInk)
                        Text("AgeLess age · actual \(HealthspanSection.years(actual))").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    }
                    ForgeAgeLine(actual: actual, age: age, projected: projected).frame(height: 70)
                    if let pace = week.pace {
                        Text(ForgeAgeLessView.paceSentence(pace)).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    }
                } else {
                    Text("Your health age").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
            }
            .forgeCard(radius: ForgeRadius.card, padding: 14)
        }
        .buttonStyle(.plain)
    }
}
#endif
