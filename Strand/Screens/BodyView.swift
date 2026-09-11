import SwiftUI
import StrandAnalytics
import StrandDesign
import StrandImport
import WhoopStore

// MARK: - Body — where a measurement finally has somewhere to go
//
// Before this screen there was no way to log a body measurement at all. Circumferences had no capture
// surface; a DEXA result or a caliper reading had nowhere to live; body fat could only arrive from
// Apple Health. Weight, meanwhile, had three homes and two of them disagreed.
//
// Built to the same grammar as the Strength and Cardio screens so the three read as one app: a history
// window, cards that answer one question each, and the wearer's own measurements as the only reference
// — no normal ranges, because a body-fat "normal range" is a medical claim and the Lab Book ships none
// for exactly that reason.
//
// THE ONE CHART DECISION WORTH STATING. Weight (~80 kg), waist (~85 cm) and body fat (~18 %) do not
// share an axis in any honest way; drawn together in absolute units the smallest number looks flat
// because of its scale rather than because it did not move. So the comparison chart plots CHANGE FROM
// THE FIRST READING for each series. That is the question people actually have — "am I losing fat or
// water?" — and it is the only form in which three units can sit on one axis without one of them lying.

struct BodyView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject private var profile: ProfileStore

    @StateObject private var model = BodyModel()

    @State private var capturing = false
    @State private var infoTopic: InfoTopic?
    @State private var weeklyReminder = BodyMeasurementReminder.weeklyEnabled
    @State private var dailyReminder = BodyMeasurementReminder.dailyEnabled
    /// Set when the OS refused. Surfaced rather than swallowed — a switch that silently flips back is
    /// the exact failure `WindDownNudge` documents.
    @State private var reminderDenied = false

    /// Which published Navy equation applies, read from the profile — the one place that fact lives.
    ///
    /// Hodgdon & Beckett fitted two equations, on a male and a female cohort, and they take different
    /// measurements. There is no published variant beyond those two, so a profile recorded as
    /// non-binary gets no estimate rather than a silently assumed one: picking an equation on someone's
    /// behalf is both a modelling error and a claim this app has no business making.
    ///
    /// Deliberately NOT a second control on this page. The profile already carries it, and a switch
    /// here would be a second place to set the same fact — which is exactly the duplication this whole
    /// feature was built to end.
    private var navyEquation: NavyEquation? {
        switch profile.sex.lowercased() {
        case "male": return .male
        case "female": return .female
        // A non-binary profile carries the answer in its own field, because the formula reads a body
        // composition pattern rather than an identity — and NOOP cannot infer one from the other.
        default: return NavyEquation(rawValue: profile.bodyFormulaSex)
        }
    }

    private enum InfoTopic: String, Identifiable {
        case navy, development, comparison
        var id: String { rawValue }
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                header
                if model.loaded && model.metrics.measuredKeys.isEmpty {
                    emptyState
                } else {
                    todayCard
                    developmentCard
                    comparisonCard
                    compositionCard
                    sitesCard
                    photosCard
                    remindersCard
                }
            }
            .padding(NoopMetrics.gap)
            DemoScrollBottomAnchor()
        }
        .task {
            await model.load(repo: repo)
            await scrollToDemoBottom(proxy)
        }
        .sheet(isPresented: $capturing) {
            BodyCaptureSheet(model: model) { await model.load(repo: repo) }
        }
        .sheet(item: $infoTopic) { topic in infoSheet(topic) }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("Body", overline: "Measurements")
                Spacer()
                Button {
                    capturing = true
                } label: {
                    Label("Measure", systemImage: "plus.circle.fill")
                        .font(StrandFont.subhead.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(StrandPalette.metricCyan.opacity(0.16))
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.metricCyan)
            }
        }
    }

    private var emptyState: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Nothing measured yet.")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text("Log a weigh-in, a tape measurement or a body-fat reading and it appears here with its own history. Every value keeps the date it was taken and where it came from, so a DEXA scan and a tape estimate never end up on the same line.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Today

    private var todayCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                          spacing: 10) {
                    tile(label: String(localized: "Weight"), icon: "scalemass.fill",
                         reading: model.current(WhoopStore.bodyWeightMetricKey),
                         unit: "kg", tint: DomainTheme.effort.color)
                    tile(label: String(localized: "Body fat"), icon: "drop.fill",
                         reading: model.current("body_fat"),
                         unit: "%", tint: StrandPalette.metricCyan)
                    tile(label: String(localized: "Waist"), icon: "ruler.fill",
                         reading: model.current("waist"),
                         unit: "cm", tint: StrandPalette.metricAmber)
                }
            }
        }
    }

    private func tile(label: String, icon: String, reading: BodyReading?, unit: String,
                      tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: icon)
                .font(StrandFont.caption)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(reading.map { "\($0.value.formatted(.number.precision(.fractionLength(1)))) \(unit)" }
                 ?? "—")
                .font(StrandFont.number(26))
                .foregroundStyle(StrandPalette.textPrimary)
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(label)
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Text(reading.map { dayText($0.day) } ?? " ")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .leading)
        .padding(NoopMetrics.space2)
        .background(TodayCardSurface(tint: tint, cornerRadius: NoopMetrics.groupedRadius))
    }

    // MARK: - Composition

    private var compositionCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    SectionHeader("Body fat", overline: "Composition")
                    Spacer()
                    Button { infoTopic = .navy } label: {
                        Image(systemName: "info.circle").foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                if let navyEquation, let estimate = model.navyEstimate(equation: navyEquation) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(estimate.formatted(.number.precision(.fractionLength(1))))
                            .font(StrandFont.number(30))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("% estimated").font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Text("Navy circumference estimate, ±\(Int(NavyBodyFat.errorBandPercentagePoints)) percentage points against DEXA. It is good at showing a trend and poor at an absolute level — watch how it moves, not what it says.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if navyEquation == nil {
                    Text("Hodgdon & Beckett fitted two equations, on a male and a female cohort, and they take different measurements — so there is nothing to average between them. Choose which applies under Body-composition formula in your profile, and the estimate appears here.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let missing = model.navyMissingSites(equation: navyEquation ?? .male)
                    if missing.isEmpty {
                        Text("Those measurements do not produce a plausible estimate. Check that neck and waist were not swapped.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        // The sentence and the list of sites are kept apart deliberately. Interpolating
                        // a Foundation-formatted list into a sentence renders the list in the device
                        // language and the sentence in whatever the catalog has, so an untranslated
                        // string came out as "Add neck und waist circumference…" — half in each.
                        Text("Measure these to estimate body fat:")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        Text(missing.map { model.label($0) }.joined(separator: " · "))
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !model.bodyFatBySource.isEmpty { measuredBodyFatRows }
            }
        }
    }

    private var measuredBodyFatRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().background(StrandPalette.hairline)
            ForEach(model.bodyFatBySource, id: \.source) { entry in
                if let newest = entry.points.last {
                    HStack {
                        Text(sourceLabel(entry.source))
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                        Text("\(newest.value.formatted(.number.precision(.fractionLength(1)))) %")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text(dayText(newest.day))
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    // MARK: - Development
    //
    // The card the tape is actually for. It counts sites by direction, then shows the start and latest
    // value for EACH site. Circumferences from different anatomy are never added into a fake physical
    // total: a waist centimetre and a thigh centimetre do not form a meaningful combined measurement.

    private var developmentCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    SectionHeader("What changed", overline: "Development")
                    Spacer()
                    Button { infoTopic = .development } label: {
                        Image(systemName: "info.circle").foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                Picker("Window", selection: $model.comparison) {
                    ForEach(BodyModel.ComparisonWindow.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                let total = model.circumferenceTotal
                if total.hasMovement { totalHeadline(total) } else { noMovementText(total) }

                let changes = model.circumferenceChanges
                if !changes.isEmpty {
                    Divider().background(StrandPalette.hairline)
                    let scale = max(changes.map { abs($0.deltaCm) }.max() ?? 1, 0.5)
                    ForEach(changes, id: \.key) { change in
                        changeRow(change, scale: scale)
                    }
                }
            }
        }
    }

    private func totalHeadline(_ total: CircumferenceTotal) -> some View {
        // Whichever direction includes MORE sites leads. The count is navigation for the rows below,
        // not a cross-body measurement.
        let gainLeads = total.growingSites >= total.shrinkingSites
        return VStack(alignment: .leading, spacing: 4) {
            if gainLeads {
                movementCount(total.growingSites, grew: true, lead: true)
                if total.shrinkingSites > 0 {
                    movementCount(total.shrinkingSites, grew: false, lead: false)
                }
            } else {
                movementCount(total.shrinkingSites, grew: false, lead: true)
                if total.growingSites > 0 {
                    movementCount(total.growingSites, grew: true, lead: false)
                }
            }
            // The line that makes the card worth having: the tape read against the scale.
            if let weight = model.weightChangeKg {
                Text(weightContextText(weight, total: total))
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Each row compares the same site then and now. Only changes larger than your own tape scatter count as movement.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func movementCount(_ sites: Int, grew: Bool, lead: Bool) -> some View {
        Text(grew ? String(localized: "\(sites) grew") : String(localized: "\(sites) decreased"))
            .font(StrandFont.number(lead ? 30 : 20))
            .foregroundStyle(lead ? StrandPalette.textPrimary : StrandPalette.textSecondary)
    }

    /// Reads the tape against the scale, in whichever direction the wearer is going.
    ///
    /// The stalled-scale case is said out loud in BOTH directions, because it is the week people give
    /// up in either way: someone cutting concludes the deficit is not working, and someone building
    /// concludes they are not growing — and in both cases the tape often disagrees with the scale, for
    /// the same reason. Water and glycogen mask real change on a scale for weeks at a time.
    private func weightContextText(_ weightKg: Double, total: CircumferenceTotal) -> String {
        let kg = abs(weightKg).formatted(.number.precision(.fractionLength(1)))
        let stalled = abs(weightKg) < 0.4

        if stalled {
            if total.lostCm > 0 && total.gainedCm > 0 {
                return String(localized: "Your weight barely moved — \(kg) kg — but the tape moved in both directions. Coming down in one place while going up in another is exactly what recomposition looks like, and it is invisible on a scale.")
            }
            if total.lostCm > 0 {
                return String(localized: "Your weight barely moved over this period — \(kg) kg — and the tape still came down. That is what a stalled scale looks like when something is in fact happening.")
            }
            return String(localized: "Your weight barely moved over this period — \(kg) kg — and the tape still went up. Size added without scale weight is easy to miss and easy to give up on.")
        }

        if weightKg > 0 {
            if total.gainedCm > 0 && total.lostCm == 0 {
                return String(localized: "Your weight is up \(kg) kg, and the tape agrees — the sites you are training are growing with it.")
            }
            if total.lostCm > 0 && total.gainedCm > 0 {
                return String(localized: "Your weight is up \(kg) kg, and the tape went both ways — some sites growing while others came down.")
            }
            return String(localized: "Your weight is up \(kg) kg while these sites came down.")
        }

        if total.lostCm > 0 && total.gainedCm == 0 {
            return String(localized: "Your weight is down \(kg) kg, and the tape agrees.")
        }
        if total.gainedCm > 0 {
            return String(localized: "Your weight is down \(kg) kg while these sites grew — losing while holding or adding size is the harder version, and this is what it looks like.")
        }
        return String(localized: "Your weight is down \(kg) kg over the same period.")
    }

    private func noMovementText(_ total: CircumferenceTotal) -> some View {
        Text(total.comparedSites == 0
             ? String(localized: "No site has two readings far enough apart yet. Measure again in a few weeks and this fills in.")
             : String(localized: "Nothing has moved further than your own tape scatter yet. That is not the same as nothing happening — it means these readings cannot yet tell a change apart from how the tape was held."))
            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One site, with a bar that diverges from a centre line. Direction is carried by the geometry, not
    /// by colour — whether growth is the good news depends entirely on the site and the goal.
    private func changeRow(_ change: CircumferenceChange, scale: Double) -> some View {
        let counts = change.exceedsTypicalStep
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(model.label(change.key)).font(StrandFont.subhead)
                    .foregroundStyle(counts ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                Spacer()
                Text("\(change.fromValue.formatted(.number.precision(.fractionLength(1)))) → \(change.toValue.formatted(.number.precision(.fractionLength(1)))) cm")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                Text("\(change.deltaCm > 0 ? "+" : "−")\(abs(change.deltaCm).formatted(.number.precision(.fractionLength(1))))")
                    .font(StrandFont.subhead)
                    .foregroundStyle(counts ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .frame(width: 46, alignment: .trailing)
            }
            DivergingBar(value: change.deltaCm, scale: scale, muted: !counts)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Comparison

    private var comparisonCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    SectionHeader("Change since the first reading", overline: "Weight · waist · body fat")
                    Spacer()
                    Button { infoTopic = .comparison } label: {
                        Image(systemName: "info.circle").foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                Picker("Range", selection: $model.range) {
                    ForEach(BodyModel.HistoryRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                // `onChangeCompat`, not a second `.task(id:)` — that also fires on first appearance and
                // would load twice on entry, the same trap the Strength and Cardio screens document.
                .onChangeCompat(of: model.range) { _ in Task { await model.load(repo: repo) } }
                let points = comparisonPoints
                if points.count >= 2 {
                    // A single-hue gradient on purpose. The default recovery ramp runs green to red,
                    // which would tell the wearer that one direction of change is good and the other
                    // bad — a judgement NOOP does not make about a body measurement, and one that
                    // reverses depending on whether someone is cutting or gaining.
                    TrendChart(points: points, gradient: neutralGradient,
                               valueRange: chartRange(points), showsArea: false,
                               height: 180,
                               valueFormat: { "\($0 > 0 ? "+" : "")\($0.formatted(.number.precision(.fractionLength(1)))) %" },
                               accessibilityLabel: String(localized: "Body measurement change"),
                               segmentColors: comparisonColors)
                    HStack(spacing: 12) {
                        ForEach(comparisonSeries, id: \.key) { entry in
                            legendDot(entry.color, model.label(entry.key))
                        }
                    }
                    Text("Each line is that measurement's change from its own first reading in this window, in percent. Absolute units cannot share an axis — a waist in centimetres would flatten a body-fat percentage next to it.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Two readings of the same measurement are needed before there is a change to draw.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    /// The three series this chart draws, and the colour each is drawn in. One list, so the lines and
    /// the legend can never disagree about which measurement is which.
    private var comparisonSeries: [(key: String, color: Color)] {
        // Three hues that stay apart from each other. Weight and waist were both in the orange family
        // at first and the legend read as two dots of the same colour — which defeats the point of
        // colouring the lines at all.
        [(WhoopStore.bodyWeightMetricKey, StrandPalette.metricAmber),
         ("waist", StrandPalette.metricPurple),
         ("body_fat", StrandPalette.metricCyan)]
            .filter { model.metrics.series($0.0).count >= 2 }
            .map { (key: $0.0, color: $0.1) }
    }

    /// Keyed by the segment name the points carry, which is the series' display label.
    private var comparisonColors: [String: Color] {
        Dictionary(uniqueKeysWithValues: comparisonSeries.map { (model.label($0.key), $0.color) })
    }

    /// Each series expressed as percent change from its own first reading in the window, which is the
    /// only form in which kilograms, centimetres and percentage points share an axis honestly.
    private var comparisonPoints: [TrendPoint] {
        var points: [TrendPoint] = []
        for key in [WhoopStore.bodyWeightMetricKey, "waist", "body_fat"] {
            let series = model.metrics.series(key)
            guard let base = series.first, base.value > 0, series.count >= 2 else { continue }
            for reading in series {
                guard let date = WeightSeries.date(forDay: reading.day) else { continue }
                points.append(TrendPoint(date: date,
                                         value: (reading.value - base.value) / base.value * 100,
                                         segment: model.label(key)))
            }
        }
        return points.sorted { $0.date < $1.date }
    }

    /// One hue, no good/bad ramp — see the chart above.
    private var neutralGradient: Gradient {
        Gradient(colors: [StrandPalette.metricCyan.opacity(0.35), StrandPalette.metricCyan])
    }

    private func chartRange(_ points: [TrendPoint]) -> ClosedRange<Double> {
        let values = points.map(\.value)
        let low = min(values.min() ?? -1, -1)
        let high = max(values.max() ?? 1, 1)
        return low...high
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: - Sites

    private var sitesCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                // The date is stated ONCE. The capture sheet records a whole session at one instant, so
                // in the ordinary case every row carries the same day — printing it fourteen times is
                // noise that crowds out the values. A site last measured on a DIFFERENT day is the
                // interesting case, and only those rows keep a date of their own.
                SectionHeader("Measurements", overline: lastMeasuredText)
                if model.measuredSites.isEmpty {
                    Text("No tape measurements yet. Tap Measure to record a session.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                } else {
                    ForEach(model.measuredSites, id: \.self) { key in
                        if let reading = model.current(key) {
                            NavigationLink {
                                BodySiteDetailView(siteKey: key, model: model)
                            } label: {
                            HStack(spacing: 8) {
                                Text(model.label(key)).font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                // One hue, no value ramp: a tape measurement going up is not good news
                                // or bad news, it depends entirely on the site and the goal.
                                Sparkline(values: model.metrics.series(key).map(\.value),
                                          gradient: neutralGradient, lineWidth: 1.5,
                                          showsArea: false, showsHead: false, showsHover: false)
                                    .frame(width: 46, height: 18)
                                Text("\(reading.value.formatted(.number.precision(.fractionLength(1)))) cm")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(reading.day == newestSiteDay ? "" : dayText(reading.day))
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.statusWarning)
                                    .frame(width: 52, alignment: .trailing)
                                Image(systemName: "chevron.right")
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .accessibilityHidden(true)
                            }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    /// The day the most recent tape session happened on.
    private var newestSiteDay: String? {
        model.measuredSites.compactMap { model.current($0)?.day }.max()
    }

    private var lastMeasuredText: LocalizedStringKey {
        guard let day = newestSiteDay else { return "All sites" }
        return LocalizedStringKey(String(localized: "Last measured \(dayText(day))"))
    }

    // MARK: - Photos

    private var photosCard: some View {
        NoopCard {
            NavigationLink {
                BodyPhotosView()
            } label: {
                HStack {
                    Image(systemName: "camera.fill")
                        .foregroundStyle(StrandPalette.metricPurple)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Progress photos").font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Front, side and back, taken in a fixed frame so two months apart are actually comparable. They stay on this device.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Reminders

    private var remindersCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                SectionHeader("Reminders", overline: "Optional")
                Toggle(isOn: Binding(
                    get: { weeklyReminder },
                    set: { on in
                        BodyMeasurementReminder.setEnabled(on, daily: false) { outcome in
                            weeklyReminder = outcome == .scheduled
                            reminderDenied = outcome == .denied
                        }
                    })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Weekly measurement")
                            Text("Circumferences move slowly and are measured with error. Weekly is the cadence at which a real change outgrows the tape's own spread.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                Toggle(isOn: Binding(
                    get: { dailyReminder },
                    set: { on in
                        BodyMeasurementReminder.setEnabled(on, daily: true) { outcome in
                            dailyReminder = outcome == .scheduled
                            reminderDenied = outcome == .denied
                        }
                    })) {
                        Text("Daily weigh-in")
                    }
                if reminderDenied {
                    Text("Notifications are turned off for NOOP in system settings, so a reminder would never arrive. Nothing was scheduled.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Info

    @ViewBuilder private func infoSheet(_ topic: InfoTopic) -> some View {
        let content: (String, String)
        switch topic {
        case .navy:
            content = (String(localized: "The Navy estimate"),
                       String(localized: "Hodgdon & Beckett's circumference method, published in 1984 and still the standard tape estimate. Against a DEXA scan it carries roughly ±4 percentage points — and the error is mostly a personal bias rather than random noise, so someone reading three points high tends to keep reading three points high.\n\nThat is why it is worth watching and not worth comparing. Your own number falling over two months is real. Your number next to someone else's, or next to a published category, is not.\n\nThe two equations were fitted on separate cohorts and take different measurements, so NOOP asks which one to apply rather than deciding for you."))
        case .development:
            content = (String(localized: "What counts as a change"),
                       String(localized: "A tape repeats to somewhere around half a centimetre, depending on how steadily you hold it and whether you find the same spot each time. So +0.2 cm is not growth — it is the tape.\n\nRather than asserting a fixed figure for that, NOOP reads it out of your own series: the typical step between your consecutive readings at that site. A change smaller than your own typical step is shown greyed out. That does not mean nothing happened — it means this series cannot tell what happened apart from how the tape was held, which is a more useful thing to know.\n\nThe summary counts only sites that beat their own scatter. Every row compares that same body site then and now; measurements from different sites are never added together."))
        case .comparison:
            content = (String(localized: "Why percent change"),
                       String(localized: "Weight, waist and body fat are measured in kilograms, centimetres and percentage points. Drawn together in their own units, the one with the smallest numbers looks flat regardless of what it did — that is the axis talking, not the body.\n\nPlotting each series as change from its own first reading puts them on one scale honestly, and answers the question people actually have: whether the waist is moving while the weight holds, which is what separates fat loss from water."))
        }
        return NavigationStack {
            ScrollView {
                Text(content.1)
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(NoopMetrics.gap)
            }
            .navigationTitle(content.0)
        }
    }

    // MARK: - Formatting

    private func dayText(_ day: String) -> String {
        guard let date = WeightSeries.date(forDay: day) else { return day }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private func signedText(_ value: Double) -> String {
        let text = abs(value).formatted(.number.precision(.fractionLength(1)))
        if abs(value) < 0.05 { return "—" }
        return "\(value > 0 ? "L+" : "R+")\(text)"
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "dexa": return String(localized: "DEXA")
        case "caliper": return String(localized: "Caliper")
        case "bia": return String(localized: "BIA scale")
        case "inbody": return String(localized: "InBody")
        case "navy": return String(localized: "Tape estimate")
        case Repository.appleHealthSource: return String(localized: "Apple Health")
        case "profile": return String(localized: "From your profile")
        default: return String(localized: "Entered")
        }
    }
}
