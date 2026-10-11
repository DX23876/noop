import SwiftUI
import StrandDesign
import StrandAnalytics

// HealthspanSection.swift — fork feature (backlog plan HEALTHSPAN_AGE_PLAN, spec S6): the Healthspan card on
// Health. While HealthspanFeature is on it takes Body Age's place, so the screen never states two ages.
//
// One resolver (`HealthspanSnapshot.load`) reads the stored window inputs and runs each week through the
// engine; the headline, the domain totals, the levers and the trend all come from those results, so no two
// numbers on the card can disagree.

/// Everything the card shows for the latest week, resolved once.
struct HealthspanSnapshot {
    let week: String
    let result: HealthspanEngine.Result
    let pace: Double?
    let coveredDays: Int
    let levers: [HealthspanEngine.Lever]
    /// Weekly ages, oldest first; the last point is `result.healthspanAge`.
    let trend: [(day: String, age: Double)]

    var isProvisional: Bool { coveredDays < HealthspanWindow.ageWindowDays }

    /// Every week's age is recomputed from that week's stored inputs with today's profile, so the trend,
    /// the headline and the breakdown all come from the same engine call shape.
    @MainActor
    static func load(repo: Repository, age: Int, sex: HealthspanEngine.Sex) async -> HealthspanSnapshot? {
        let source = Repository.whoopSource
        func byDay(_ key: String) async -> [String: Double] {
            Dictionary(await repo.exploreSeries(key: key, source: source).map { ($0.day, $0.value) },
                       uniquingKeysWith: { _, b in b })
        }
        let weeks = await repo.exploreSeries(key: IntelligenceEngine.healthspanAgeKey, source: source).map(\.day)
        var inputSeries: [HealthspanEngine.Component: [String: Double]] = [:]
        for c in HealthspanEngine.Component.allCases {
            inputSeries[c] = await byDay(IntelligenceEngine.healthspanInputKey(c))
        }
        func inputs(_ week: String) -> HealthspanEngine.Inputs {
            var x = HealthspanEngine.Inputs(age: Double(age), sex: sex)
            for c in HealthspanEngine.Component.allCases { x.set(c, inputSeries[c]?[week]) }
            return x
        }
        let trend = weeks.compactMap { w in HealthspanEngine.compute(inputs(w)).map { (day: w, age: $0.healthspanAge) } }
        guard let week = trend.last?.day, let result = HealthspanEngine.compute(inputs(week)) else { return nil }
        let pace = await byDay(IntelligenceEngine.healthspanPaceKey)[week]
        let covered = Int(await byDay(IntelligenceEngine.healthspanCoveredDaysKey)[week] ?? 0)
        return HealthspanSnapshot(week: week, result: result, pace: pace, coveredDays: covered,
                                  levers: HealthspanEngine.levers(inputs(week)), trend: trend)
    }
}

struct HealthspanSection: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @State private var snapshot: HealthspanSnapshot?
    @State private var loaded = false
    @State private var gaugeDrawn = 0.0
    @State private var showsAllMeasures = false

    private var sex: HealthspanEngine.Sex? { HealthspanEngine.Sex(profileValue: profile.sex) }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Healthspan", overline: "Weekly",
                          trailing: snapshot?.isProvisional == true ? String(localized: "Provisional") : nil)
            if sex == nil {
                ComingSoon(what: "Set your sex in your profile to see your healthspan age.", symbol: "person")
            } else if let snapshot {
                card(snapshot)
            } else if loaded {
                ComingSoon(what: "Your healthspan age appears after 30 nights of sleep data.", symbol: "hourglass")
            } else {
                ComingSoon.loading("Reading your healthspan…", title: "Healthspan", symbol: "hourglass")
            }
        }
        .task(id: repo.refreshSeq) { await load() }
    }

    private func load() async {
        if let sex { snapshot = await HealthspanSnapshot.load(repo: repo, age: profile.age, sex: sex) }
        loaded = true
        withAnimation(.easeOut(duration: 0.8)) { gaugeDrawn = 1 }
    }

    // MARK: Card

    private func card(_ s: HealthspanSnapshot) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            hero(s)
            if s.trend.count >= 2 {
                Divider().overlay(StrandPalette.hairline)
                trend(s)
            }
            Divider().overlay(StrandPalette.hairline)
            domains(s.result)
            if !s.levers.isEmpty {
                Divider().overlay(StrandPalette.hairline)
                levers(s.levers)
            }
            Divider().overlay(StrandPalette.hairline)
            DisclosureGroup(isExpanded: $showsAllMeasures) {
                measures(s.result)
            } label: {
                Text("All nine measures").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
            }
            .tint(StrandPalette.textSecondary)
            HealthspanInfoButton()
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .padding(NoopMetrics.space5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { FrostedCardSurface(tint: StrandPalette.chargeColor, cornerRadius: NoopMetrics.cardRadius) }
        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
    }

    private func hero(_ s: HealthspanSnapshot) -> some View {
        let delta = s.result.deltaYears
        return HStack(alignment: .center, spacing: NoopMetrics.space5) {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text("Healthspan age").strandOverline()
                CountUpText(value: s.result.healthspanAge, format: { Self.years($0) },
                            font: StrandFont.number(40), color: StrandPalette.textPrimary)
                Text(Self.deltaLine(delta))
                    .font(StrandFont.footnote)
                    .foregroundStyle(delta <= 0 ? StrandPalette.statusPositive.legibleText
                                                : StrandPalette.statusWarningForeground)
                if let pace = s.pace {
                    Text("In 6 months: \(Self.years(HealthspanEngine.projectedAge(currentAge: s.result.healthspanAge, pace: pace))) if the last 30 days continue")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if let pace = s.pace { paceGauge(pace) }
        }
    }

    /// Pace of Aging on the paper's −1.0× to 3.0× scale: green while slower than the calendar, amber above it.
    private func paceGauge(_ pace: Double) -> some View {
        let fraction = (pace + 1) / 4
        let reversed = StrandPalette.recoveryStops.reversed().map { Gradient.Stop(color: $0.color, location: 1 - $0.location) }
        return VStack(spacing: NoopMetrics.space1) {
            BevelGauge(fraction: fraction, stops: reversed,
                       tipColor: pace <= 1 ? StrandPalette.statusPositive : StrandPalette.statusWarningForeground,
                       numberText: pace.formatted(.number.precision(.fractionLength(1))),
                       captionText: String(localized: "Pace of Aging"),
                       stateText: Self.paceState(pace),
                       diameter: 132, lineWidth: 11, animatedFraction: gaugeDrawn * fraction)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Pace of Aging \(pace.formatted(.number.precision(.fractionLength(1)))), \(Self.paceState(pace))"))
    }

    private func trend(_ s: HealthspanSnapshot) -> some View {
        let first = s.trend[0]
        let change = s.result.healthspanAge - first.age
        let points = s.trend.compactMap { p in Self.date(p.day).map { TrendPoint(date: $0, value: p.age) } }
        let values = s.trend.map(\.age) + [s.result.chronologicalAge]
        let lo = (values.min() ?? 0).rounded(.down) - 1, hi = (values.max() ?? 0).rounded(.up) + 1
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(Self.sinceLine(change, since: Self.date(first.day)))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            TrendChart(points: points, gradient: Gradient(colors: [StrandPalette.chargeColor, StrandPalette.chargeColor]),
                       valueRange: lo...hi, showsArea: false, baselineValue: s.result.chronologicalAge, height: 140,
                       valueFormat: { Self.years($0) },
                       accessibilityLabel: String(localized: "Healthspan age by week; dashed line is your actual age"),
                       yDomain: lo...hi)
            Text("Dashed line: your actual age")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func domains(_ r: HealthspanEngine.Result) -> some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            ForEach(HealthspanDomain.allCases, id: \.self) { d in
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text(Self.domainName(d)).strandOverline()
                    Text(Self.signedYears(r.years(in: d)))
                        .font(StrandFont.number(20).monospacedDigit())
                        .foregroundStyle(r.years(in: d) <= 0 ? StrandPalette.statusPositive.legibleText
                                                             : StrandPalette.statusWarningForeground)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func levers(_ levers: [HealthspanEngine.Lever]) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("Biggest levers").strandOverline()
            ForEach(levers, id: \.component) { l in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.componentName(l.component))
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text(verbatim: "\(Self.value(l.component, l.currentValue)) → \(Self.value(l.component, l.newValue))")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer(minLength: NoopMetrics.space2)
                    Text(Self.signedYears(l.years))
                        .font(StrandFont.subhead.monospacedDigit())
                        .foregroundStyle(StrandPalette.statusPositive.legibleText)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func measures(_ r: HealthspanEngine.Result) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            ForEach(r.contributions, id: \.component) { c in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.componentName(c.component))
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text(c.value.map { String(localized: "\(Self.value(c.component, $0)) · target \(Self.value(c.component, c.target))") }
                             ?? String(localized: "No data yet"))
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer(minLength: NoopMetrics.space2)
                    Text(c.value == nil ? "—" : Self.signedYears(c.years))
                        .font(StrandFont.subhead.monospacedDigit())
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, NoopMetrics.space2)
    }

    // MARK: Formatting

    static func years(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1))) }

    static func signedYears(_ v: Double) -> String {
        let n = abs(v).formatted(.number.precision(.fractionLength(1)))
        if abs(v) < 0.05 { return String(localized: "\(n) yrs") }
        return v < 0 ? String(localized: "−\(n) yrs") : String(localized: "+\(n) yrs")
    }

    static func deltaLine(_ delta: Double) -> String {
        let n = abs(delta).formatted(.number.precision(.fractionLength(1)))
        if abs(delta) < 0.05 { return String(localized: "about your age") }
        return delta < 0 ? String(localized: "\(n) yrs younger than your age") : String(localized: "\(n) yrs older than your age")
    }

    static func sinceLine(_ change: Double, since: Date?) -> String {
        let n = abs(change).formatted(.number.precision(.fractionLength(1)))
        let d = since?.formatted(.dateTime.day().month(.abbreviated)) ?? ""
        if abs(change) < 0.05 { return String(localized: "Unchanged since \(d)") }
        return change < 0 ? String(localized: "\(n) yrs younger since \(d)") : String(localized: "\(n) yrs older since \(d)")
    }

    static func paceState(_ pace: Double) -> String {
        if pace < 0 { return String(localized: "REVERSING") }
        if pace < 0.95 { return String(localized: "SLOWING") }
        if pace <= 1.05 { return String(localized: "STEADY") }
        return String(localized: "ACCELERATING")
    }

    static func domainName(_ d: HealthspanDomain) -> String {
        switch d {
        case .sleep: return String(localized: "Sleep")
        case .activity: return String(localized: "Activity")
        case .fitness: return String(localized: "Fitness")
        }
    }

    static func componentName(_ c: HealthspanEngine.Component) -> String {
        switch c {
        case .sleepDuration: return String(localized: "Hours of sleep")
        case .sleepConsistency: return String(localized: "Sleep consistency")
        case .dailySteps: return String(localized: "Daily steps")
        case .zone13: return String(localized: "Time in zones 1–3")
        case .zone45: return String(localized: "Time in zones 4–5")
        case .strength: return String(localized: "Strength activity")
        case .vo2max: return String(localized: "VO₂max")
        case .restingHR: return String(localized: "Resting heart rate")
        case .leanMass: return String(localized: "Lean body mass")
        }
    }

    static func value(_ c: HealthspanEngine.Component, _ v: Double) -> String {
        let whole = v.formatted(.number.precision(.fractionLength(0)))
        let one = v.formatted(.number.precision(.fractionLength(1)))
        switch c {
        case .sleepDuration: return String(localized: "\(one) h")
        case .sleepConsistency, .leanMass: return (v / 100).formatted(.percent.precision(.fractionLength(0)))
        case .dailySteps: return whole
        case .zone13, .zone45, .strength: return String(localized: "\(whole) min/wk")
        case .vo2max: return one + " ml/kg/min"
        case .restingHR: return String(localized: "\(whole) bpm")
        }
    }

    static func date(_ day: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)
    }
}

/// How the estimate is made and what it is not, one tap away instead of a footnote on the card.
struct HealthspanInfoButton: View {
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            Label("About this estimate", systemImage: "info.circle")
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $presented) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                        Text("Healthspan age").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                        Text("Nine measures of sleep, activity and fitness over the last six months, each compared with a recommendation for good long-term health. Large studies link every measure to all-cause mortality; the difference in risk is turned into years. Meeting every recommendation reads exactly at your age.")
                        Text("Pace of Aging assumes your last 30 days continue for six months: 1.0× ages with the calendar, below 1.0× slower, below 0 you get younger.")
                        Text("The method follows WHOOP's published Healthspan white paper (2025) and the studies it cites, computed on your device. It is an estimate to motivate healthy habits, not a medical or biological age and not a prediction of lifespan.")
                    }
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(NoopMetrics.space4)
                }
                .background(StrandPalette.surfaceBase)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { presented = false } }
                }
            }
            #if os(macOS)
            .frame(minWidth: NoopMetrics.detailSheetMinWidth, minHeight: NoopMetrics.detailSheetMinHeight)
            #endif
        }
    }
}
