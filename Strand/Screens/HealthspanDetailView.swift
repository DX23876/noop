import SwiftUI
import StrandDesign
import StrandAnalytics

// HealthspanDetailView.swift — fork feature "AgeLess" (backlog plan HEALTHSPAN_AGE_PLAN, spec S6): the full
// AgeLess screen behind the Health card. Week by week: the age in its orb, Pace of Aging on its slider, a
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

    private var week: HealthspanWeek { snapshot.weeks[index] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.space6) {
                weekSwitcher
                HealthspanTopRow(week: week, showsPace: false)
                if let pace = week.pace {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text("Pace of Aging").strandOverline()
                        HealthspanPaceSlider(pace: pace)
                        Text("In 6 months: \(HealthspanSection.years(HealthspanEngine.projectedAge(currentAge: week.result.healthspanAge, pace: pace))) if the last 30 days continue")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                narrative
                if !week.levers.isEmpty { levers }
                ForEach(HealthspanDomain.allCases, id: \.self) { domain($0) }
                if index > 0 { trend }
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
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    // MARK: Week

    private var weekSwitcher: some View {
        HStack {
            Button { index -= 1 } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .disabled(index == 0)
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
            Button { index += 1 } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .disabled(index == snapshot.weeks.count - 1)
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
        .padding(NoopMetrics.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { FrostedCardSurface(tint: StrandPalette.agelessYoungDeep, cornerRadius: NoopMetrics.cardRadius) }
        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
    }

    static func title(_ k: HealthspanEngine.Narrative.Kind) -> String {
        switch k {
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

    private var levers: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("Biggest levers").strandOverline()
            ForEach(week.levers, id: \.component) { l in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(HealthspanSection.componentName(l.component))
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text(verbatim: "\(HealthspanSection.value(l.component, l.currentValue)) → \(HealthspanSection.value(l.component, l.newValue))")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer(minLength: NoopMetrics.space2)
                    Text(HealthspanSection.signedYears(l.years))
                        .font(StrandFont.subhead.monospacedDigit())
                        .foregroundStyle(StrandPalette.agelessYoungDeep.legibleText)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Measures

    private func domain(_ d: HealthspanDomain) -> some View {
        let total = week.result.years(in: d)
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
            HStack(spacing: NoopMetrics.space3) {
                Text("▼ 6-month avg")
                Text("▲ 30-day avg")
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            ForEach(HealthspanEngine.Component.allCases.filter { $0.domain == d }, id: \.self) { c in
                let contribution = week.result.contributions.first { $0.component == c }
                HealthspanMeasureRow(component: c, value: week.inputs.value(c), recentValue: week.recentInputs?.value(c),
                                     years: contribution?.value == nil ? nil : contribution?.years,
                                     scale: HealthspanEngine.barScale(c, age: week.inputs.age, sex: week.inputs.sex))
            }
        }
        .padding(NoopMetrics.space4)
        .background { FrostedCardSurface(tint: StrandPalette.agelessYoungDeep, cornerRadius: NoopMetrics.cardRadius) }
        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
    }

    // MARK: Trend

    private var trend: some View {
        let weeks = Array(snapshot.weeks.prefix(index + 1))
        let points = weeks.compactMap { w in HealthspanSection.date(w.day).map { TrendPoint(date: $0, value: w.result.healthspanAge) } }
        let values = weeks.map(\.result.healthspanAge) + [week.result.chronologicalAge]
        let lo = (values.min() ?? 0).rounded(.down) - 1, hi = (values.max() ?? 0).rounded(.up) + 1
        let change = week.result.healthspanAge - weeks[0].result.healthspanAge
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("Over time").strandOverline()
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
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }
}

/// How the estimate is made and what it is not, one tap away instead of a footnote on every screen.
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
                        Text("AgeLess age").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
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
