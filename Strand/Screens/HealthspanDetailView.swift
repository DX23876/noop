import SwiftUI
import StrandDesign
import StrandAnalytics

// HealthspanDetailView.swift — fork feature "AgeLess" (backlog plan HEALTHSPAN_AGE_PLAN, spec S6): the full
// AgeLess screen behind the Health card. Week by week: the age on its gauge, Aging speed on its slider, a
// status line naming the strongest helper and lever, the next steps, every measure on its bar grouped as
// sleep, activity and fitness, and the age over time against the actual age.

struct HealthspanDetailView: View {
    let snapshot: HealthspanSnapshot
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(snapshot: HealthspanSnapshot) {
        self.snapshot = snapshot
        _index = State(initialValue: snapshot.weeks.count - 1)
    }

    /// A reload while the sheet is open can bring fewer weeks; the index never reads past them.
    private var shown: Int { min(max(index, 0), snapshot.weeks.count - 1) }
    private var week: HealthspanWeek { snapshot.weeks[shown] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.space6) {
                weekSwitcher
                HealthspanTopRow(week: week, showsPace: false)
                if let pace = week.pace {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        Text("Aging speed").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                        HealthspanPaceSlider(pace: pace)
                        Text("In 6 months: \(HealthspanSection.years(HealthspanEngine.projectedAge(currentAge: week.result.healthspanAge, pace: pace))) if the last 30 days continue")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .agelessCard()
                }
                narrative
                if !week.levers.isEmpty { HealthspanLeversCard(week: week) }
                ForEach(HealthspanDomain.allCases, id: \.self) { domain($0) }
                if shown > 0 { trend }
                HealthspanInfoButton()
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(minHeight: 44, alignment: .leading)
            }
            .padding(NoopMetrics.space4)
        }
        .background(StrandPalette.surfaceBase)
        .navigationTitle(Text("AgeLess"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                HealthspanInfoButton().labelStyle(.iconOnly)
            }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    // MARK: Week

    private var weekSwitcher: some View {
        HStack {
            Button { index = shown - 1 } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .disabled(shown == 0)
                .accessibilityLabel(Text("Previous week"))
            Spacer()
            VStack(spacing: 2) {
                Text(verbatim: weekRange(week.day))
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                if week.isProvisional {
                    Text("Based on \(week.coveredDays) of 182 days so far")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer()
            Button { index = shown + 1 } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .disabled(shown >= snapshot.weeks.count - 1)
                .accessibilityLabel(Text("Next week"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(StrandPalette.textSecondary)
    }

    private func weekRange(_ saturday: String) -> String {
        guard let start = HealthspanSection.date(saturday) else { return saturday }
        let end = start.addingTimeInterval(6 * 86_400)
        let f = Date.FormatStyle.dateTime.day().month(.abbreviated)
        return "\(start.formatted(f)) – \(end.formatted(f))"
    }

    // MARK: Status

    private var narrative: some View {
        let n = HealthspanEngine.narrative(result: week.result, pace: week.pace, levers: week.levers)
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(Self.title(n.kind))
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(Self.body(n))
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .agelessCard()
    }

    static func title(_ k: HealthspanEngine.Narrative.Kind) -> String {
        switch k {
        case .reversing: return String(localized: "Getting younger")
        case .youngerSteady: return String(localized: "Steady and healthy")
        case .youngerAccelerating: return String(localized: "Younger, but speeding up")
        case .olderImproving: return String(localized: "Heading the right way")
        case .olderAccelerating: return String(localized: "Small steps, big impact")
        }
    }

    static func body(_ n: HealthspanEngine.Narrative) -> String {
        let helper = n.helper.map(HealthspanSection.componentName)
        let lever = n.lever.map(HealthspanSection.componentName)
        switch n.kind {
        case .reversing:
            if let helper { return String(localized: "Your last 30 days beat your six-month average so clearly that your AgeLess age is falling. \(helper) helps you most; keep it up.") }
        case .youngerSteady:
            if let helper { return String(localized: "Your AgeLess age is below your actual age and your pace is steady or slowing. \(helper) helps you most; keep it up.") }
        case .youngerAccelerating:
            if let lever { return String(localized: "Your last 30 days are less healthy than your six-month average, so your AgeLess age is starting to rise. \(lever) would help most right now.") }
        case .olderImproving:
            if let lever { return String(localized: "Your recent habits beat your six-month average, so your AgeLess age is coming down. Your strongest next step: \(lever).") }
        case .olderAccelerating:
            if let lever { return String(localized: "Your AgeLess age is rising faster than the calendar. Start with \(lever); it is your strongest lever.") }
        }
        return String(localized: "Keep wearing your strap; the picture sharpens as your six-month window fills.")
    }

    // MARK: Measures

    /// What the two markers on every bar mean, said once in the first of the three cards.
    private var legend: some View {
        HStack(spacing: NoopMetrics.space3) {
            Text("▼ 6-month average · ↑↓ last 30 days")
        }
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textSecondary)
    }

    private func domain(_ d: HealthspanDomain) -> some View {
        let total = week.result.years(in: d)
        let recent = week.recentResult
        return VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            HStack(alignment: .firstTextBaseline) {
                Text(HealthspanSection.domainName(d))
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(HealthspanSection.signedYears(total))
                    .font(StrandFont.subhead.weight(.semibold).monospacedDigit())
                    .foregroundStyle(HealthspanMeasureRow.textColour(total))
            }
            if d == HealthspanDomain.allCases.first { legend }
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
        .agelessCard()
    }

    // MARK: Trend

    private var trend: some View {
        let weeks = Array(snapshot.weeks.prefix(shown + 1))
        let points = weeks.compactMap { w in HealthspanSection.date(w.day).map { TrendPoint(date: $0, value: w.result.healthspanAge) } }
        let values = weeks.map(\.result.healthspanAge) + [week.result.chronologicalAge]
        let lo = (values.min() ?? 0).rounded(.down) - 1, hi = (values.max() ?? 0).rounded(.up) + 1
        let change = week.result.healthspanAge - weeks[0].result.healthspanAge
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("Over time").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text(HealthspanSection.sinceLine(change, since: HealthspanSection.date(weeks[0].day)))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            TrendChart(points: points, gradient: Gradient(colors: [StrandPalette.agelessYoung, StrandPalette.agelessYoungDeep]),
                       valueRange: lo...hi, showsArea: false, baselineValue: week.result.chronologicalAge, height: 160,
                       valueFormat: { HealthspanSection.years($0) },
                       accessibilityLabel: String(localized: "AgeLess age by week; dashed line is your actual age"),
                       yDomain: lo...hi)
            Text("Dashed line: your actual age")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .agelessCard()
    }
}

/// What AgeLess is and what it rests on, one tap away instead of a footnote on every screen.
struct HealthspanInfoButton: View {
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            Label("About AgeLess", systemImage: "info.circle")
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $presented) { AgeLessAboutSheet() }
    }
}
