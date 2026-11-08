#if os(iOS)
import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import StrandCore

/// The redesign's Energy page (2026-11). One question first, "how much have I burned, against a usual day?",
/// answered by one ring: resting and active energy as two arcs, a usual day as the full circle.
/// Under it what was eaten and the balance, the day's curve against other days, the last 30 days as bars a
/// tap selects, and where the figures come from.
///
/// Every figure is the shipped engine's (`energySummaries`, `energyDayRate`, `energyReferenceRate`,
/// `intakeByDay`), loaded the way `EnergyDetailView` loads them; the curve and the calculation page are the
/// shipped views. The shipped page stays for the Liquid design.
struct ForgeEnergyView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore

    @State private var summaries: [DailyEnergySummary] = []
    @State private var intake: [String: Double] = [:]
    @State private var loaded = false
    @State private var refreshingToday = false
    @State private var selectedDay = Self.startDay

    /// Today; a debug build takes `-forge.energyDay yyyy-MM-dd` for captures of a finished day.
    private static var startDay: String {
        #if DEBUG
        if let day = UserDefaults.standard.string(forKey: "forge.energyDay") { return day }
        #endif
        return Repository.localDayKey(Date())
    }
    @State private var dayRate: EnergyDayRate?
    @State private var comparison = EnergyRateComparison.sevenDay
    @State private var comparisonPoints: [EnergyBurnRate.Point] = []
    @State private var comparisonCaption: String?
    @State private var comparisonUnavailable: LocalizedStringKey?
    @State private var series: Series = .burned
    @State private var chartSelection: Date?
    @State private var scrolledPast = false
    @State private var showDayPicker = false
    @State private var pickerDate = Date()

    enum Series: Hashable { case burned, eaten, balance }

    /// The window the summaries load, and so how far back a day can be chosen.
    private static let historyDays = 30

    private var isToday: Bool { selectedDay == Repository.localDayKey(Date()) }
    private var summary: DailyEnergySummary? { summaries.last { $0.day == selectedDay } }
    private var eaten: Double? { intake[selectedDay] }
    private var earliestDate: Date {
        Calendar.current.startOfDay(for: Date().addingTimeInterval(-Double(Self.historyDays - 1) * 86_400))
    }

    /// The split of active energy into movement and training, only on a day with a five-minute grid
    /// (`EnergyDetailView.breakdown`).
    private var breakdown: EnergyActiveBreakdown? {
        guard let dayRate, dayRate.hasBuckets else { return nil }
        return EnergyActiveBreakdown(activeKcal: summary?.activeBurnedSoFar, trainingFraction: dayRate.trainingFraction)
    }

    private var usualTotal: Double? { Self.usualTotal(summaries, today: Repository.localDayKey(Date())) }

    /// A usual day: the median total of the finished days in the window, from five of them. The page and
    /// Today's Energy tile both read it here.
    static func usualTotal(_ summaries: [DailyEnergySummary], today: String) -> Double? {
        let totals = summaries.filter { $0.day != today }.compactMap(\.totalBurnedSoFar).filter { $0 > 0 }.sorted()
        guard totals.count >= 5 else { return nil }
        let mid = totals.count / 2
        return totals.count % 2 == 0 ? (totals[mid - 1] + totals[mid]) / 2 : totals[mid]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForgeDetailHeader(overline: String(localized: "Health"), title: String(localized: "Energy"), scrolledPast: $scrolledPast, picture: PagePicture(symbol: "flame.fill", accent: "bolt.fill", tint: StrandPalette.forgeEnergyActive))
                dayStepper
                if !loaded {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading energy…").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    }
                    .forgeCard(radius: ForgeRadius.card, padding: 14)
                } else if let summary {
                    hero(summary)
                    if refreshingToday && isToday {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Updating today's energy…").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        }
                    }
                    parts(summary)
                    curve(summary)
                } else {
                    emptyCard
                }
                if loaded && !summaries.isEmpty { history }
                if loaded, let summary { calculation(summary) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .health, wash: ForgeColor.energyWash))
        .forgeDetailBar(title: String(localized: "Energy"), showsTitle: scrolledPast)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ExplainerInfoButton(
                    title: String(localized: "Burned and eaten"),
                    text: String(localized: "Burned is what your body uses at rest plus what activity adds. Eaten is what you logged. The balance between them is best read over a week, not a single day.")) {
                        ExplainerEnergyBars()
                    }
            }
        }
        .task { await loadIfNeeded() }
        .task(id: selectedDay) { await loadDay() }
        .task(id: "\(selectedDay)|\(comparison.rawValue)") { await loadComparison() }
        .onChange(of: chartSelection) { _, date in
            guard let date else { return }
            let key = Repository.localDayKey(date)
            if summaries.contains(where: { $0.day == key }) { withAnimation(.snappy) { selectedDay = key } }
        }
        .sheet(isPresented: $showDayPicker) { dayPicker }
        .sensoryFeedback(.selection, trigger: selectedDay)
    }

    // MARK: - Day

    private var dayStepper: some View {
        HStack {
            dayStep(-1, symbol: "chevron.left", label: "Previous day")
            Spacer()
            Button {
                pickerDate = WeightSeries.date(forDay: selectedDay) ?? Date()
                showDayPicker = true
            } label: {
                HStack(spacing: 6) {
                    Text(dayTitle).font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Image(systemName: "calendar").font(.system(.footnote, weight: .semibold)).foregroundStyle(ForgeColor.accent)
                }
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(Capsule().fill(ForgeColor.card))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Choose date"))
            .accessibilityValue(Text(dayTitle))
            Spacer()
            dayStep(1, symbol: "chevron.right", label: "Next day")
        }
    }

    private var dayTitle: String {
        guard let date = WeightSeries.date(forDay: selectedDay) else { return selectedDay }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return String(localized: "Today") }
        if cal.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).locale(AppLanguage.activeLocale))
    }

    private func dayStep(_ days: Int, symbol: String, label: LocalizedStringKey) -> some View {
        let target = WeightSeries.date(forDay: selectedDay).map { $0.addingTimeInterval(Double(days) * 86_400) }
        let allowed = target.map { $0 <= Date() && $0 >= earliestDate } ?? false
        return Button {
            if let target { withAnimation(.snappy) { selectedDay = Repository.localDayKey(target) } }
        } label: {
            Image(systemName: symbol)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(allowed ? ForgeColor.text : ForgeColor.tertiary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!allowed)
        .accessibilityLabel(Text(label))
    }

    private var dayPicker: some View {
        NavigationStack {
            DatePicker("Choose date", selection: $pickerDate, in: earliestDate...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(ForgeColor.accent)
                .padding(.horizontal, 16)
                .navigationTitle(Text("Choose date"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            selectedDay = Repository.localDayKey(pickerDate)
                            showDayPicker = false
                        }
                    }
                }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Hero

    private func kcal(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.locale(AppLanguage.activeLocale))
    }

    /// As the score pages open: the ring alone and centred, one sentence under it, then the day's three
    /// figures in a row (the prototype's "Energy today").
    private func hero(_ s: DailyEnergySummary) -> some View {
        let card = EnergyHeroCard(summary: s, breakdown: breakdown, eatenKcal: eaten)
        return VStack(spacing: 16) {
            ForgeEnergyRing(resting: s.basalBurnedSoFar, active: s.activeBurnedSoFar, total: s.totalBurnedSoFar,
                            usual: usualTotal, totalText: Self.plainTotal(s), selectedDay: selectedDay)
                .frame(width: 200, height: 200)
                .padding(.top, 4)
            VStack(spacing: 4) {
                if s.totalBurnedSoFar != nil {
                    Text(isToday ? "Burned so far" : "Burned")
                        .font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                }
                if let line = usualLine(s) {
                    Text(verbatim: line).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            // A row of dashes says nothing the ring's "No data yet" did not.
            if s.totalBurnedSoFar != nil || eaten != nil { figures(s) }
            if let eaten, let total = s.totalBurnedSoFar {
                ForgeEnergyBalance(eaten: eaten, burned: total, isToday: isToday)
            }
            if let range = s.projectedRangeKcal, isToday {
                Label {
                    Text("By tonight about \(kcal(range.lowerBound)) to \(kcal(range.upperBound)) kcal")
                } icon: { Image(systemName: "moon.stars") }
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let note = card.qualityNote {
                Label(note, systemImage: "info.circle")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
        .forgeCard(radius: ForgeRadius.card, padding: 16)
    }

    /// The day against a usual one, in words: how far short of it or past it.
    /// The day's total without the "~" the shipped card adds: every calorie figure is an estimate, so the
    /// mark says nothing here.
    static func plainTotal(_ s: DailyEnergySummary) -> String {
        guard let total = s.totalBurnedSoFar, total.isFinite, total >= 0 else { return "–" }
        return Int(total.rounded()).formatted(.number.locale(AppLanguage.activeLocale))
    }

    private func usualLine(_ s: DailyEnergySummary) -> String? {
        guard let usualTotal, let total = s.totalBurnedSoFar, total > 0 else { return nil }
        let gap = total - usualTotal
        if abs(gap) < 50 { return String(localized: "About a usual day") }
        return gap < 0
            ? String(localized: "\(kcal(-gap)) kcal short of a usual day")
            : String(localized: "\(kcal(gap)) kcal past a usual day")
    }

    /// Resting, active and (when logged) eaten side by side, each in its colour, as the prototype's three figures.
    private func figures(_ s: DailyEnergySummary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            figure(StrandPalette.forgeEnergyResting, String(localized: "Resting"), s.basalBurnedSoFar)
            figure(StrandPalette.forgeEnergyActive, String(localized: "Active"), s.activeBurnedSoFar)
            // Eaten only on a day with logged meals: a dash every day reads as a missing figure.
            if let eaten { figure(ForgeColor.charge, String(localized: "Eaten"), eaten) }
        }
    }

    private func figure(_ color: Color, _ title: String, _ value: Double?) -> some View {
        VStack(spacing: 4) {
            Text(value.map(kcal) ?? "–").font(ForgeFont.rounded(22, .bold)).foregroundStyle(ForgeColor.text)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                .contentTransition(.numericText())
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: ForgeRadius.inner, style: .continuous).fill(ForgeColor.canvas))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Parts

    /// Where the day's energy went, as the score pages' "Why" card: one row per part with its share as a bar.
    @ViewBuilder private func parts(_ s: DailyEnergySummary) -> some View {
        if let breakdown, let total = s.totalBurnedSoFar, total > 0 {
            ForgeSectionTitle(title: "Where it comes from")
            VStack(spacing: 0) {
                partRow(symbol: "bed.double.fill", tint: StrandPalette.forgeEnergyResting, title: String(localized: "Basal burn"),
                        value: s.basalBurnedSoFar ?? s.estimatedBMR24h, share: s.basalBurnedSoFar.map { $0 / total })
                ForgeRowDivider()
                partRow(symbol: "figure.walk", tint: StrandPalette.forgeEnergyMovement, title: String(localized: "Daily movement"),
                        value: breakdown.movementKcal, share: breakdown.movementKcal / total)
                ForgeRowDivider()
                partRow(symbol: "dumbbell.fill", tint: StrandPalette.forgeEnergyTraining, title: String(localized: "Training"),
                        value: breakdown.trainingKcal, share: breakdown.trainingKcal / total)
            }
            .forgeCard(radius: ForgeRadius.card, padding: 0)
        }
    }

    private func partRow(symbol: String, tint: Color, title: String, value: Double?, share: Double?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(.footnote, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 32, height: 32).background(Circle().fill(tint.opacity(ForgeOpacity.wash)))
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Spacer(minLength: 8)
                    Text(value.map(kcal) ?? "–").font(ForgeFont.rounded(17, .bold)).foregroundStyle(ForgeColor.text)
                        .monospacedDigit()
                    Text(verbatim: "kcal").font(.system(.caption2, weight: .medium)).foregroundStyle(ForgeColor.secondary)
                }
                if let share {
                    HStack(spacing: 8) {
                        ForgeShareBar(fraction: min(max(share, 0), 1), typical: nil, tint: tint)
                        Text(verbatim: share.formatted(.percent.precision(.fractionLength(0)).locale(AppLanguage.activeLocale)))
                            .font(.system(.caption2, weight: .semibold)).foregroundStyle(ForgeColor.secondary)
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Curve

    @ViewBuilder private func curve(_ s: DailyEnergySummary) -> some View {
        if let dayRate, dayRate.hasBuckets, let start = WeightSeries.date(forDay: selectedDay).map({ Calendar.current.startOfDay(for: $0) }) {
            // The card carries its own "Burn rate" title, so no section title above it.
            EnergyBurnRateCard(dayStart: start, isToday: isToday, points: dayRate.points, bands: dayRate.bands,
                               comparison: $comparison, comparisonPoints: comparisonPoints,
                               comparisonCaption: comparisonCaption, comparisonUnavailable: comparisonUnavailable)
        } else if dayRate != nil, s.totalBurnedSoFar != nil {
            // A daily figure without a minute-by-minute record must not read as a day without activity.
            // With no figure at all the ring already says so.
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "chart.xyaxis.line").font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(ForgeColor.tertiary)
                    .frame(width: 34, height: 34).background(Circle().fill(ForgeColor.canvas))
                VStack(alignment: .leading, spacing: 2) {
                    Text("No minute-by-minute record for this day")
                        .font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Text("\(EnergyProvenance.sourceLabel(s.source)) gives a daily figure, not a curve.")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .forgeCard(radius: ForgeRadius.card, padding: 14)
        }
    }

    // MARK: - History

    private struct Bar: Identifiable {
        let id: String
        let date: Date
        let part: String
        let value: Double
        let color: Color
    }

    /// The bars of the chosen series. Today stays out: its "so far" would read as a drop every morning.
    private var bars: [Bar] {
        let today = Repository.localDayKey(Date())
        var out: [Bar] = []
        for s in summaries where s.day != today {
            guard let date = WeightSeries.date(forDay: s.day) else { continue }
            switch series {
            case .burned:
                guard let total = s.totalBurnedSoFar, total > 0 else { continue }
                if let rest = s.basalBurnedSoFar, let active = s.activeBurnedSoFar, rest + active > 0 {
                    out.append(.init(id: s.day + "r", date: date, part: "resting", value: rest, color: StrandPalette.forgeEnergyResting))
                    out.append(.init(id: s.day + "a", date: date, part: "active", value: active, color: StrandPalette.forgeEnergyActive))
                } else {
                    // A summary without the split is one block rather than an invented share.
                    out.append(.init(id: s.day, date: date, part: "resting", value: total, color: StrandPalette.forgeEnergyResting))
                }
            case .eaten:
                if let e = intake[s.day] {
                    out.append(.init(id: s.day, date: date, part: "eaten", value: e, color: ForgeColor.charge))
                }
            case .balance:
                if let e = intake[s.day], let total = s.totalBurnedSoFar {
                    let b = e - total
                    out.append(.init(id: s.day, date: date, part: "balance", value: b,
                                     color: b > 0 ? ForgeColor.effort : ForgeColor.charge))
                }
            }
        }
        return out
    }

    /// From zero to a little above the tallest bar; a balance spans both sides of zero.
    private func yDomain(_ shown: [Bar]) -> ClosedRange<Double> {
        var byDay: [Date: Double] = [:]
        for bar in shown { byDay[bar.date, default: 0] += bar.value }
        let top = max(byDay.values.max() ?? 0, series == .burned ? usualTotal ?? 0 : 0)
        if series == .balance {
            let low = min(shown.map(\.value).min() ?? 0, 0), high = max(shown.map(\.value).max() ?? 0, 0)
            let pad = max(100, (high - low) * 0.12)
            return (low - pad)...(high + pad)
        }
        return 0...max(top * 1.12, 100)
    }

    private var history: some View {
        let shown = bars
        let selected = WeightSeries.date(forDay: selectedDay).map { Calendar.current.startOfDay(for: $0) }
        return VStack(alignment: .leading, spacing: 10) {
            ForgeSectionTitle(title: "Last 30 days")
            if !intake.isEmpty {
                Picker("Show", selection: $series.animation(.snappy)) {
                    Text("Burned").tag(Series.burned)
                    Text("Eaten").tag(Series.eaten)
                    Text("Balance").tag(Series.balance)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 8) {
                if shown.isEmpty {
                    Text("Nothing logged in these days.").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    Chart {
                        ForEach(shown) { bar in
                            let isSelected = selected.map { Calendar.current.isDate($0, inSameDayAs: bar.date) } ?? false
                            BarMark(x: .value("Day", bar.date, unit: .day), y: .value("kcal", bar.value), width: .ratio(0.7))
                                .foregroundStyle(bar.color.opacity(selected == nil || isSelected ? 1 : 0.42))
                                .cornerRadius(3)
                        }
                        if series == .burned, let usualTotal {
                            RuleMark(y: .value("Usual", usualTotal))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .foregroundStyle(ForgeColor.secondary)
                        }
                        if series == .balance {
                            RuleMark(y: .value("Zero", 0)).foregroundStyle(ForgeColor.tertiary)
                        }
                    }
                    .chartYScale(domain: yDomain(shown))
                    // A tap on a bar opens that day; the default selection only answers a held drag.
                    .chartXSelection(value: $chartSelection)
                    .chartGesture { proxy in
                        SpatialTapGesture().onEnded { proxy.selectXValue(at: $0.location.x) }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                            AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine().foregroundStyle(ForgeColor.tertiary.opacity(0.4))
                            AxisValueLabel {
                                if let v = value.as(Double.self) { Text(verbatim: kcal(v)) }
                            }
                        }
                    }
                    .frame(height: 190)
                    .accessibilityLabel(Text("Daily energy burn"))
                    // The dashed line's key sits under the chart: a word inside the plot lands on a bar.
                    if series == .burned, let usualTotal {
                        HStack(spacing: 6) {
                            HStack(spacing: 2) {
                                ForEach(0..<3, id: \.self) { _ in
                                    Capsule().fill(ForgeColor.secondary).frame(width: 4, height: 1.5)
                                }
                            }
                            Text("Usual day \(kcal(usualTotal)) kcal")
                                .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text("Tap a day to open it.").font(ForgeFont.caption).foregroundStyle(ForgeColor.tertiary)
                }
            }
            .forgeCard(radius: ForgeRadius.card, padding: 14)
        }
    }

    // MARK: - Calculation

    private func calculation(_ s: DailyEnergySummary) -> some View {
        NavigationLink {
            EnergyCalculationView(summary: s)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill").font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(EnergyProvenance.confidenceColor(s.confidence))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(EnergyProvenance.confidenceColor(s.confidence).opacity(ForgeOpacity.wash)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Data quality & calculation").font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Text(EnergyProvenance.compactLine(s) ?? EnergyProvenance.sourceLabel(s.source))
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold)).foregroundStyle(ForgeColor.tertiary)
            }
            .forgeCard(radius: ForgeRadius.card, padding: 14)
        }
        .buttonStyle(.plain)
    }

    private var emptyCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "flame.fill").font(.title2).foregroundStyle(StrandPalette.forgeEnergyActive)
                .frame(width: 48, height: 48).background(Circle().fill(StrandPalette.forgeEnergyActive.opacity(ForgeOpacity.wash)))
            VStack(alignment: .leading, spacing: 3) {
                Text(isToday ? "Nothing recorded yet today." : "Nothing was recorded on this day.")
                    .font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                Text("Energy appears as soon as a connected source records activity.")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .forgeCard(radius: ForgeRadius.card, padding: 14)
    }

    // MARK: - Loading (as `EnergyDetailView`)

    private func loadIfNeeded() async {
        guard !loaded else { return }
        let analyticsProfile = Repository.analyticsProfile(profile)
        // Paint from the store first; only the live day is rebuilt on entry.
        summaries = await repo.energySummaries(days: Self.historyDays, profile: analyticsProfile)
        if let oldest = summaries.map(\.day).min() {
            intake = await repo.intakeByDay(from: oldest, to: Repository.localDayKey(Date()))
        }
        loaded = true
        refreshingToday = true
        await repo.refreshWhoopEnergyModel(days: 1, profile: analyticsProfile)
        summaries = await repo.energySummaries(days: Self.historyDays, profile: analyticsProfile)
        refreshingToday = false
        if isToday { await loadDay() }
    }

    private func loadDay() async {
        let day = selectedDay
        let rate = await repo.energyDayRate(day: day, profile: Repository.analyticsProfile(profile))
        guard !Task.isCancelled, day == selectedDay else { return }
        dayRate = rate
    }

    private func loadComparison() async {
        let day = selectedDay
        let mode = comparison
        let analyticsProfile = Repository.analyticsProfile(profile)
        var points: [EnergyBurnRate.Point] = []
        var caption: String?
        var unavailable: LocalizedStringKey?
        if let window = mode.windowDays {
            if let reference = await repo.energyReferenceRate(before: day, windowDays: window, profile: analyticsProfile) {
                points = reference.points
                caption = String(localized: "Median of \(reference.sampleDays) of the last \(reference.windowDays) days")
            } else {
                unavailable = "Not enough fully measured days yet to show a \(window)-day average."
            }
        } else if let date = WeightSeries.date(forDay: day),
                  let previous = Calendar.current.date(byAdding: .day, value: -1, to: date) {
            let rate = await repo.energyDayRate(day: Repository.localDayKey(previous), profile: analyticsProfile)
            points = rate.points
            if points.isEmpty { unavailable = "The day before has no minute-by-minute record." }
        }
        guard !Task.isCancelled, day == selectedDay, mode == comparison else { return }
        comparisonPoints = points
        comparisonCaption = caption
        comparisonUnavailable = unavailable
    }
}

/// The day's burn as one ring: resting, then active, on a circle that a usual day fills. A day past its
/// usual fills the ring; the page says the gap in words under it. Draws in when it comes into view and again per day.
struct ForgeEnergyRing: View {
    let resting: Double?
    let active: Double?
    let total: Double?
    let usual: Double?
    let totalText: String
    let selectedDay: String
    /// Today's tile: a thinner ring and a smaller figure, without the share of a usual day.
    var compact = false
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var line: CGFloat { compact ? 11 : 16 }

    private var scale: Double { max(usual ?? 0, total ?? 0, 1) }
    /// Without the split the day is one arc rather than an invented share.
    private var restFraction: Double {
        guard let total, total > 0 else { return 0 }
        if let resting, let active, resting + active > 0 { return resting / scale }
        return total / scale
    }
    private var activeFraction: Double {
        guard let resting, let active, resting + active > 0 else { return 0 }
        return active / scale
    }

    var body: some View {
        ZStack {
            Circle().stroke(StrandPalette.forgeEnergyTrack, lineWidth: line)
            // A soft glow under the arcs, as the score rings carry one.
            Group {
                arc(from: 0, to: restFraction, color: StrandPalette.forgeEnergyResting)
                arc(from: restFraction, to: restFraction + activeFraction, color: StrandPalette.forgeEnergyActive)
            }
            .blur(radius: compact ? 5 : 9)
            .opacity(colorScheme == .dark ? 0.6 : 0.35)
            .accessibilityHidden(true)
            arc(from: 0, to: restFraction, color: StrandPalette.forgeEnergyResting)
            arc(from: restFraction, to: restFraction + activeFraction, color: StrandPalette.forgeEnergyActive)
            if total == nil, compact {
                // The tile says it in a sentence beside the ring; the ring holds only the flame.
                Image(systemName: "flame.fill").font(.system(size: 26))
                    .foregroundStyle(StrandPalette.forgeEnergyActive.opacity(0.45))
            } else if total == nil {
                // Nothing measured yet: words in the ring rather than a dash over "kcal".
                Text("No data yet")
                    .font(compact ? ForgeFont.caption : .system(.subheadline, weight: .semibold))
                    .foregroundStyle(ForgeColor.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, line + 6)
            } else {
                VStack(spacing: 0) {
                    Text(verbatim: totalText)
                        .font(ForgeFont.rounded(compact ? 21 : 36, .bold)).foregroundStyle(ForgeColor.text)
                        .lineLimit(1).minimumScaleFactor(0.6).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(verbatim: "kcal").font(.system(.footnote, weight: .semibold)).foregroundStyle(ForgeColor.secondary)
                }
                .padding(.horizontal, line + 6)
            }
        }
        .padding(line / 2)
        .revealWhenVisible {
            guard !drawn else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.9, dampingFraction: 0.85)) { drawn = true }
        }
        .onChange(of: selectedDay) { _, _ in
            guard !reduceMotion else { return }
            drawn = false
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { drawn = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Energy"))
        .accessibilityValue(Text("\(totalText) kcal"))
    }

    private func arc(from: Double, to: Double, color: Color) -> some View {
        Circle()
            .trim(from: drawn ? min(from, 1) : 0, to: drawn ? min(to, 1) : 0)
            .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }
}

/// Eaten against burned as one bar either side of zero: a deficit to the left, a surplus to the right,
/// with the figure over it. Read over a week rather than a day, as the explainer says.
struct ForgeEnergyBalance: View {
    let eaten: Double
    let burned: Double
    let isToday: Bool

    private var balance: Double { eaten - burned }

    var body: some View {
        let magnitude = min(abs(balance) / max(burned, 1), 1)
        let tint = balance > 0 ? ForgeColor.effort : ForgeColor.charge
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(isToday ? "Balance so far" : "Balance").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                Spacer()
                Text("\((balance > 0 ? "+" : balance < 0 ? "−" : "") + Int(abs(balance).rounded()).formatted(.number.locale(AppLanguage.activeLocale))) kcal")
                    .font(ForgeFont.rounded(17, .bold)).foregroundStyle(ForgeColor.text).monospacedDigit()
            }
            GeometryReader { geo in
                let half = geo.size.width / 2
                ZStack(alignment: .leading) {
                    Capsule().fill(ForgeColor.canvas)
                    Rectangle().fill(tint)
                        .frame(width: half * magnitude)
                        .offset(x: balance > 0 ? half : half - half * magnitude)
                    Rectangle().fill(ForgeColor.text.opacity(0.6)).frame(width: 2).offset(x: half - 1)
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            HStack {
                Text("Deficit").font(.system(.caption2)).foregroundStyle(ForgeColor.tertiary)
                Spacer()
                Text("Surplus").font(.system(.caption2)).foregroundStyle(ForgeColor.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
