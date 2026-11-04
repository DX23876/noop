import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign
import StrandCore

// EnergyDetailView.swift — the figures behind the card, and where they came from.
//
// Progressive disclosure, three levels deep now rather than two: the Today card answers "how
// much?", this screen answers "when, and compared with what?", and the calculation page behind it
// answers "how do you know?". Each level is a question someone actually asks, in the order they
// ask them — which is why the provenance rows moved off this screen instead of staying folded into
// the bottom of it.
//
// The day picker is what makes the rest of it worth having. A burn-rate curve is only interesting
// beside another day's, and until a day could be chosen there was nothing to choose between.

struct EnergyDetailView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    @State private var summaries: [DailyEnergySummary] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var refreshingToday = false

    @State private var selectedDay = Repository.localDayKey(Date())
    @State private var dayRate: EnergyDayRate?
    @State private var comparison = EnergyRateComparison.sevenDay
    @State private var comparisonPoints: [EnergyBurnRate.Point] = []
    @State private var comparisonCaption: String?
    @State private var comparisonUnavailable: LocalizedStringKey?
    @State private var showDayPicker = false
    @State private var pickerDate = Date()
    /// New design: logged meals per day, and which series the 30-day chart shows.
    @State private var intake: [String: Double] = [:]
    private enum ForgeSeries: Hashable { case burned, eaten, balance }
    @State private var forgeSeries: ForgeSeries = .burned

    /// How far back the picker and the swipe may go. Tied to the window `energySummaries` loads:
    /// offering a day the screen has no summary for would open an empty screen and call it a date.
    private static let historyDays = 30

    private var isToday: Bool { selectedDay == Repository.localDayKey(Date()) }

    private var selectedSummary: DailyEnergySummary? {
        summaries.last { $0.day == selectedDay }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                if NoopVisualStyle.skin == .forge {
                    forgeHead
                }
                if !loaded {
                    loadingRow
                } else if let selectedSummary {
                    EnergyHeroCard(summary: selectedSummary, breakdown: breakdown, eatenKcal: intake[selectedDay])
                    if refreshingToday && isToday {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Updating today's energy…")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    burnRateSection
                } else {
                    emptyState
                }
                if NoopVisualStyle.skin == .forge {
                    if !history.isEmpty { forgeHistory }
                    if loaded, let selectedSummary { forgeOrigins(selectedSummary) }
                } else {
                    if !history.isEmpty { chart }
                    if loaded, let selectedSummary { calculationLink(selectedSummary) }
                }
            }
            .padding(NoopMetrics.screenPadding)
            // Restrained surfaces (Liquid Today redesign): the cards rest on their fill, without the
            // slate hairline. Presentation only; every value and source below is unchanged.
            .environment(\.noopQuietCardRims, true)
        }
        #if os(iOS)
        .modifier(StatusBarContentFade())
        #endif
        .background {
            #if os(iOS)
            ForgeSharedScreenBackground()
            #else
            StrandPalette.surfaceBase.ignoresSafeArea()
            #endif
        }
        .navigationTitle(NoopVisualStyle.skin == .forge ? Text(verbatim: "") : Text("Energy"))
        // The day control belongs in the bar, beside the title it qualifies — a second large
        // "Energy" heading inside the scroll view just to host it printed the screen's name twice.
        .toolbar {
            if NoopVisualStyle.skin != .forge { ToolbarItem(placement: .primaryAction) { dayMenu } }
        }
        .simultaneousGesture(daySwipeGesture)
        .task { await loadIfNeeded() }
        .task(id: selectedDay) { await loadDay() }
        .task(id: "\(selectedDay)|\(comparison.rawValue)") { await loadComparison() }
        .sheet(isPresented: $showDayPicker) { dayPickerSheet }
    }

    // MARK: - New design

    /// The page title, then the day it is about with a step either way.
    private var forgeHead: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(spacing: 0) {
                Text("Energy")
                    .font(StrandFont.title1)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                ExplainerInfoButton(
                    title: String(localized: "Burned and eaten"),
                    text: String(localized: "Burned is what your body uses at rest plus what activity adds. Eaten is what you logged. The balance between them is best read over a week, not a single day.")) {
                        ExplainerEnergyBars()
                    }
                    .padding(.vertical, -12)
            }
            HStack {
                forgeDayStep(-1, symbol: "chevron.left", label: "Previous day")
                Spacer()
                dayMenu
                Spacer()
                forgeDayStep(1, symbol: "chevron.right", label: "Next day")
            }
        }
    }

    private func forgeDayStep(_ days: Int, symbol: String, label: LocalizedStringKey) -> some View {
        let target = WeightSeries.date(forDay: selectedDay).map { $0.addingTimeInterval(Double(days) * 86_400) }
        let allowed = target.map { $0 <= Date() && $0 >= earliestDate } ?? false
        return Button {
            if let target { withAnimation(StrandMotion.interactive) { select(Repository.localDayKey(target)) } }
        } label: {
            Image(systemName: symbol)
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(allowed ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!allowed)
        .accessibilityLabel(Text(label))
    }

    private var forgeHistoryPoints: [TrendPoint] {
        guard forgeSeries != .burned else { return history }
        let today = Repository.localDayKey(Date())
        return summaries.compactMap { s in
            guard s.day != today, let eaten = intake[s.day], let date = WeightSeries.date(forDay: s.day) else { return nil }
            if forgeSeries == .eaten { return TrendPoint(date: date, value: eaten) }
            guard let total = s.totalBurnedSoFar else { return nil }
            return TrendPoint(date: date, value: eaten - total)
        }
    }

    @ViewBuilder private var forgeHistory: some View {
        ForgeSectionHeading("Last 30 days")
        if !intake.isEmpty {
            SegmentedPillControl([ForgeSeries.burned, .eaten, .balance], selection: $forgeSeries, fillsAvailableWidth: true) { series in
                switch series {
                case .burned: return String(localized: "Burned")
                case .eaten: return String(localized: "Eaten")
                case .balance: return String(localized: "Balance")
                }
            }
        }
        NoopCard {
            let points = forgeHistoryPoints
            let values = points.map(\.value)
            let pad = max(100.0, ((values.max() ?? 0) - (values.min() ?? 0)) * 0.2)
            TrendChart(points: points,
                       gradient: StrandPalette.energyGradient,
                       valueRange: ((values.min() ?? 0) - pad)...((values.max() ?? 3_000) + pad),
                       height: 180,
                       valueFormat: { "\(Int($0.rounded())) kcal" },
                       dateFormat: { $0.formatted(date: .abbreviated, time: .omitted) },
                       accessibilityLabel: String(localized: "Daily energy burn"))
        }
    }

    private func kcalFigure(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.locale(AppLanguage.activeLocale))
    }

    @ViewBuilder private func forgeOrigins(_ s: DailyEnergySummary) -> some View {
        ForgeSectionHeading("Where it comes from")
        NoopCard {
            VStack(spacing: NoopMetrics.space2) {
                if let resting = s.basalBurnedSoFar ?? s.estimatedBMR24h {
                    ForgeTileRow(symbol: "bed.double.fill", tint: StrandPalette.energyResting,
                                 title: String(localized: "Basal burn"),
                                 subtitle: s.basalBurnedSoFar == nil ? String(localized: "Basal / day") : nil) {
                        ForgeRowFigure(value: kcalFigure(resting), unit: "kcal")
                    }
                }
                if let active = s.activeBurnedSoFar {
                    Divider().overlay(StrandPalette.hairline)
                    ForgeTileRow(symbol: "figure.run", tint: StrandPalette.energyActive,
                                 title: String(localized: "Active"),
                                 subtitle: breakdown.map { String(localized: "Daily movement \(kcalFigure($0.movementKcal)) · Training \(kcalFigure($0.trainingKcal))") }) {
                        ForgeRowFigure(value: kcalFigure(active), unit: "kcal")
                    }
                }
                if let eaten = intake[selectedDay] {
                    Divider().overlay(StrandPalette.hairline)
                    ForgeTileRow(symbol: "fork.knife", tint: StrandPalette.chargeColor,
                                 title: String(localized: "Eaten")) {
                        ForgeRowFigure(value: kcalFigure(eaten), unit: "kcal")
                    }
                }
            }
        }
        NoopCard {
            NavigationLink {
                EnergyCalculationView(summary: s)
            } label: {
                ForgeTileRow(symbol: "checkmark.shield.fill", tint: EnergyProvenance.confidenceColor(s.confidence),
                             title: String(localized: "Data quality & calculation"),
                             subtitle: EnergyProvenance.compactLine(s) ?? EnergyProvenance.sourceLabel(s.source),
                             showsChevron: true) { EmptyView() }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - The day picker

    private var dayMenu: some View {
        Menu {
            Button("Today") { select(Repository.localDayKey(Date())) }
            Button("Yesterday") { select(Repository.localDayKey(Date().addingTimeInterval(-86_400))) }
            Divider()
            Button("Choose date…") {
                pickerDate = WeightSeries.date(forDay: selectedDay) ?? Date()
                showDayPicker = true
            }
        } label: {
            HStack(spacing: 4) {
                Text(dayMenuLabel).font(StrandFont.footnote)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(StrandPalette.surfaceInset, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var dayMenuLabel: String {
        if isToday { return String(localized: "Today") }
        guard let date = WeightSeries.date(forDay: selectedDay) else { return selectedDay }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var dayPickerSheet: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text("Choose date").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            DatePicker("Day", selection: $pickerDate, in: earliestDate...Date(),
                       displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Spacer()
                Button("Done") {
                    select(Repository.localDayKey(pickerDate))
                    showDayPicker = false
                }
            }
        }
        .padding(NoopMetrics.screenPadding)
        .frame(minWidth: 320)
    }

    private var earliestDate: Date {
        let floor = Date().addingTimeInterval(-Double(Self.historyDays - 1) * 86_400)
        guard let oldest = summaries.map(\.day).min(),
              let date = WeightSeries.date(forDay: oldest) else { return floor }
        return max(floor, date)
    }

    /// Left/right paging, the same gesture and the same bounds Trends uses for its day selection —
    /// a second dashboard that scrolled days a different way would be a second thing to learn.
    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) * 1.5,
                  abs(value.translation.width) > 50,
                  let current = WeightSeries.date(forDay: selectedDay) else { return }
            let step: TimeInterval = value.translation.width < 0 ? -86_400 : 86_400
            let candidate = current.addingTimeInterval(step)
            guard candidate <= Date(), candidate >= earliestDate else { return }
            withAnimation(StrandMotion.interactive) { select(Repository.localDayKey(candidate)) }
        }
    }

    private func select(_ day: String) {
        guard day != selectedDay else { return }
        selectedDay = day
    }

    // MARK: - Sections

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Loading energy…").font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Nil on a day with no five-minute grid, which is what keeps the card at two figures instead of
    /// printing two dashes. See `EnergyDayRate.hasBuckets`.
    ///
    /// The split is applied to the SUMMARY's active energy, never reported as the bucket sums it was
    /// derived from — see `EnergyDayRate.trainingFraction` for what that cost the first time.
    private var breakdown: EnergyActiveBreakdown? {
        guard let dayRate, dayRate.hasBuckets else { return nil }
        return EnergyActiveBreakdown(activeKcal: selectedSummary?.activeBurnedSoFar,
                                     trainingFraction: dayRate.trainingFraction)
    }

    @ViewBuilder private var burnRateSection: some View {
        if let dayRate, dayRate.hasBuckets, let start = dayStartDate {
            EnergyBurnRateCard(dayStart: start, isToday: isToday, points: dayRate.points,
                               bands: dayRate.bands, comparison: $comparison,
                               comparisonPoints: comparisonPoints,
                               comparisonCaption: comparisonCaption,
                               comparisonUnavailable: comparisonUnavailable)
        } else if dayRate != nil, let selectedSummary {
            // An Apple, steps-only or profile-only day HAS a total but no minute-by-minute record
            // under it. An empty chart here would read as a day of no activity, which is a different
            // claim entirely — so the card says which of the two this is.
            //
            // The source is named on its own line rather than folded into the sentence: it is a
            // translated label, and lowercasing one mid-sentence for English grammar turned "Nur
            // Profil" into "nur profil" on a German phone.
            NoopCard {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(width: 34, height: 34)
                        .background(StrandPalette.surfaceInset,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No minute-by-minute record for this day")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("\(EnergyProvenance.sourceLabel(selectedSummary.source)) gives a daily figure, not a curve.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var emptyState: some View {
        NoopCard(tint: StrandPalette.energyHighlight) {
            HStack(spacing: 14) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(StrandPalette.energyHighlight)
                    .frame(width: 48, height: 48)
                    .background(StrandPalette.energyHighlight.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(isToday ? "Nothing recorded yet today." : "Nothing was recorded on this day.")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Energy appears as soon as a connected source records activity.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private func calculationLink(_ s: DailyEnergySummary) -> some View {
        NoopCard(tint: StrandPalette.energyHighlight) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Data quality & calculation")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    confidenceBadge(s.confidence)
                }
                NavigationLink {
                    EnergyCalculationView(summary: s)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(EnergyProvenance.confidenceColor(s.confidence))
                            .frame(width: 40, height: 40)
                            .background(EnergyProvenance.confidenceColor(s.confidence).opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isToday ? "How today's number was calculated"
                                         : "How this number was calculated")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .multilineTextAlignment(.leading)
                            Text(EnergyProvenance.compactLine(s) ?? EnergyProvenance.sourceLabel(s.source))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(StrandPalette.surfaceInset,
                                in: RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius,
                                                     style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The confidence word as a tinted pill, the way the reference layout carries it — a plain grey
    /// trailing word next to a heading reads as a subtitle, not as a verdict on the day.
    private func confidenceBadge(_ confidence: ScoreConfidence) -> some View {
        let color = EnergyProvenance.confidenceColor(confidence)
        return Text(EnergyProvenance.confidenceLabel(confidence))
            .font(StrandFont.footnote)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }

    /// A card's own heading. Cards on this screen carry their titles INSIDE them rather than under a
    /// `SectionHeader`: each one is a self-contained panel with its own control or range, and a
    /// heading floating above the surface it belongs to separates the two.
    private func cardTitle(_ title: LocalizedStringKey, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    // MARK: - Daily burn

    private var history: [TrendPoint] {
        summaries.compactMap { s in
            // Today's number is intentionally "so far". Plotting it beside complete past days would
            // manufacture a dramatic drop every morning; the live card above already owns that value.
            guard s.day != Repository.localDayKey(Date()) else { return nil }
            guard let total = s.totalBurnedSoFar, let date = WeightSeries.date(forDay: s.day) else { return nil }
            return TrendPoint(date: date, value: total)
        }
    }

    private var chart: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("Daily burn", trailing: String(localized: "Last 30 days"))
                TrendChart(points: history,
                           gradient: StrandPalette.energyGradient,
                           valueRange: chartRange,
                           height: 180,
                           valueFormat: { "\(Int($0.rounded())) kcal" },
                           dateFormat: { $0.formatted(date: .abbreviated, time: .omitted) },
                           accessibilityLabel: String(localized: "Daily energy burn"))
            }
        }
    }

    /// Fitted to the data, not anchored at zero: a day's burn varies by a few hundred kcal around a
    /// couple of thousand, and a zero-based axis would flatten every real difference.
    private var chartRange: ClosedRange<Double> {
        let values = history.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return 0...3_000 }
        let pad = max(100.0, (hi - lo) * 0.2)
        return max(0, lo - pad)...(hi + pad)
    }

    private var dayStartDate: Date? {
        WeightSeries.date(forDay: selectedDay).map { Calendar.current.startOfDay(for: $0) }
    }

    // MARK: - Loading

    private func loadIfNeeded() async {
        guard !loaded, !loading else { return }
        loading = true
        let analyticsProfile = Repository.analyticsProfile(profile)

        // Paint from the store first. A model-version migration must never hold the entire detail
        // screen hostage while it walks months of raw one-second movement rows.
        summaries = await repo.energySummaries(days: Self.historyDays, profile: analyticsProfile)
        if let oldest = summaries.map(\.day).min() {
            intake = await repo.intakeByDay(from: oldest, to: Repository.localDayKey(Date()))
        }
        loaded = true
        loading = false

        // Rebuild only the live day on entry, then repaint. The normal completed-offload path owns
        // the 120-day backfill; doing that synchronously here made a 2.4 GB library look like an empty
        // card for minutes. A past day is read as stored — it is finished being measured.
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
            if let reference = await repo.energyReferenceRate(before: day, windowDays: window,
                                                              profile: analyticsProfile) {
                points = reference.points
                // The sample count is the honest half of the label: a "7d avg" drawn from four days
                // is drawn from four days, and the reader is the one who gets to decide whether that
                // is enough.
                caption = String(localized: "Median of \(reference.sampleDays) of the last \(reference.windowDays) days")
            } else {
                unavailable = "Not enough fully measured days yet to show a \(window)-day average."
            }
        } else if let previous = previousDayKey(before: day) {
            let rate = await repo.energyDayRate(day: previous, profile: analyticsProfile)
            points = rate.points
            if points.isEmpty { unavailable = "The day before has no minute-by-minute record." }
        }

        guard !Task.isCancelled, day == selectedDay, mode == comparison else { return }
        comparisonPoints = points
        comparisonCaption = caption
        comparisonUnavailable = unavailable
    }

    private func previousDayKey(before day: String) -> String? {
        guard let date = WeightSeries.date(forDay: day),
              let previous = Calendar.current.date(byAdding: .day, value: -1, to: date) else { return nil }
        return Repository.localDayKey(previous)
    }
}
