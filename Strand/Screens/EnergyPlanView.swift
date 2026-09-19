import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Energy — two pages, because they answer two different questions
//
// One page says what a published formula PREDICTS for a body like this. The other says what this
// wearer's own data MEASURED. They are not two opinions on one number; they are two different
// questions, and the spread between their answers is the honest output.
//
// Nobody can say how accurately a wearable measures. So this screen refuses to print a single
// maintenance figure and prints a corridor with named sources instead — and it refuses to call a
// mostly-modelled average "measured", because a thirty-day mean of which most days came from a step
// estimate is a formula calculation with extra steps.
//
// It computes no burn of its own. See `EnergyPlanModel`.

struct EnergyPlanView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject private var profile: ProfileStore

    @StateObject private var model = EnergyPlanModel()

    @State private var page: Page = .measured
    @State private var infoTopic: InfoTopic?
    @State private var switching: BasalFormula?
    @State private var enteringIntake = false
    @State private var onboarding = false

    private enum Page: String, CaseIterable, Identifiable {
        case calculated, measured
        var id: String { rawValue }
        var label: String {
            switch self {
            case .calculated: return String(localized: "Calculated")
            case .measured:   return String(localized: "From your data")
            }
        }
    }

    private enum InfoTopic: String, Identifiable {
        case corridor, pal, quality, balance, formula
        var id: String { rawValue }
    }

    private var analyticsProfile: UserProfile { Repository.analyticsProfile(profile) }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                HStack {
                    SectionHeader("Energy", overline: "Planning")
                    Spacer()
                    Button { onboarding = true } label: {
                        Label("How this works", systemImage: "questionmark.circle")
                            .font(StrandFont.subhead)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.metricCyan)
                }
                corridorCard
                Picker("Page", selection: $page) {
                    ForEach(Page.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                switch page {
                case .calculated: calculatedPage
                case .measured:   measuredPage
                }
                planCard
                DemoScrollBottomAnchor()
            }
            .padding(NoopMetrics.gap)
        }
        .task {
            await model.load(repo: repo, profile: analyticsProfile)
            // Shown once, unprompted. After that it stays reachable from the header — an explanation
            // people want again later is worse than useless if it can only be seen before they had
            // any reason to care.
            #if DEBUG
            let skipOnboarding = CommandLine.arguments.contains("--demo-skip-energy-onboarding")
            #else
            let skipOnboarding = false
            #endif
            if !EnergyOnboarding.hasSeen && !skipOnboarding { onboarding = true }
            await scrollToDemoBottom(proxy)
        }
        .sheet(isPresented: $onboarding) {
            EnergyOnboardingFlow(model: model, profile: analyticsProfile) {
                Task { await model.load(repo: repo, profile: analyticsProfile) }
            }
        }
        .sheet(item: $infoTopic) { infoSheet($0) }
        .sheet(item: $switching) { formula in
            FormulaSwitchSheet(model: model, target: formula, profile: analyticsProfile) {
                await model.load(repo: repo, profile: analyticsProfile)
            }
        }
        .sheet(isPresented: $enteringIntake) {
            IntakeEntrySheet { kcal, day in
                await repo.recordIntake(kcal: kcal, on: day)
                await model.load(repo: repo, profile: analyticsProfile)
            }
        }
        }
    }

    // MARK: - The corridor

    private var corridorCard: some View {
        let corridor = model.corridor(profile: analyticsProfile)
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    SectionHeader("What a day costs", overline: "Three answers")
                    Spacer()
                    Button { infoTopic = .corridor } label: {
                        Image(systemName: "info.circle").foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                CorridorBar(entries: corridorEntries(corridor))
                corridorRow(String(localized: "Formula"), corridor.formulaKcal,
                            note: String(localized: "predicted"),
                            icon: "function", tint: StrandPalette.metricAmber)
                corridorRow(String(localized: "Your wearable"), corridor.measuredKcal,
                            note: qualityNote,
                            icon: "sensor.tag.radiowaves.forward.fill",
                            tint: StrandPalette.metricCyan)
                corridorRow(String(localized: "Intake and weight"), corridor.balanceKcal,
                            note: balanceNote,
                            icon: "scalemass.fill", tint: StrandPalette.metricPurple)
                if let spread = corridor.spreadKcal {
                    Divider().background(StrandPalette.hairline)
                    Text("They disagree by \(Int(spread.rounded())) kcal a day. That gap is the honest answer — not any single number in it.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Only one figure is available so far, so there is nothing to compare it against yet.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Built stepwise rather than as one literal: the nested optional-map-into-array form timed the
    /// Swift 5 type checker out, the same trap `EnergySeries`' calibration grouping documents.
    private func corridorEntries(_ corridor: EnergyCorridor) -> [CorridorBar.Entry] {
        var entries: [CorridorBar.Entry] = []
        if let value = corridor.formulaKcal {
            entries.append(.init(id: "formula", value: value, color: StrandPalette.metricAmber))
        }
        if let value = corridor.measuredKcal {
            entries.append(.init(id: "measured", value: value, color: StrandPalette.metricCyan))
        }
        if let value = corridor.balanceKcal {
            entries.append(.init(id: "balance", value: value, color: StrandPalette.metricPurple))
        }
        return entries
    }

    private func corridorRow(_ label: String, _ value: Double?, note: String?,
                             icon: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            // The dot colour matches this route's marker on the bar above, so the two read as one
            // object rather than as a picture with a table under it.
            Image(systemName: icon)
                .font(StrandFont.caption)
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let note {
                    Text(note).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer()
            Text(value.map { "\(Int($0.rounded())) kcal" } ?? "—")
                .font(StrandFont.number(20))
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
        }
    }

    /// Names what the wearable figure actually rests on, rather than letting a modelled average pass
    /// as a measurement.
    private var qualityNote: String {
        switch model.burn.quality {
        case .measured:
            return String(localized: "measured on \(model.burn.measuredDays) of \(model.burn.totalDays) days")
        case .mixed:
            return String(localized: "part measured, part modelled — \(model.burn.measuredDays) of \(model.burn.totalDays) days")
        case .mostlyModelled:
            return String(localized: "mostly modelled — only \(model.burn.measuredDays) of \(model.burn.totalDays) days were measured")
        }
    }

    private var balanceNote: String? {
        guard let balance = model.balance else {
            return String(localized: "needs about two weeks of intake and regular weigh-ins")
        }
        return String(localized: "over \(balance.windowDays) days, \(balance.intakeDays) with intake logged")
    }

    // MARK: - Page A

    private var calculatedPage: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    SectionHeader("From a published formula", overline: "Calculated")
                    Spacer()
                    Button { infoTopic = .pal } label: {
                        Image(systemName: "info.circle").foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                if let basal = model.basalRate(model.currentFormula, profile: analyticsProfile) {
                    HStack {
                        Text("Basal rate").font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                        Text("\(Int(basal.rounded())) kcal/day").font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Text(formulaName(model.currentFormula))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text("Add your height and weight to calculate a basal rate.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }

                Divider().background(StrandPalette.hairline)
                Text("How active is an ordinary day?")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                // `.menu`, not `.segmented`: five labels do not fit a segmented control on a phone,
                // and they overflow outright at larger text sizes — the same failure `SettingsView`
                // documents for its own five-option row (#43). A menu is a compact button that fits
                // any label length in any language.
                Picker("Activity", selection: $model.activity) {
                    ForEach(ActivityLevel.allCases, id: \.self) { level in
                        Text("\(activityName(level))  ×\(level.factor.formatted())").tag(level)
                    }
                }
                .pickerStyle(.menu)
                Text("These steps are conventions, not measurements — nobody's life has a multiplier of exactly \(model.activity.factor.formatted()). They are what the literature and every calorie calculator use, which is why the number below is a prediction rather than a reading.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().background(StrandPalette.hairline)
                formulaPicker
            }
        }
    }

    private var formulaPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Basal formula").font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Button { infoTopic = .formula } label: {
                    Image(systemName: "info.circle").foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
            }
            ForEach(BasalFormula.allCases, id: \.self) { formula in
                Button {
                    if formula != model.currentFormula, model.isAvailable(formula) {
                        switching = formula
                    }
                } label: {
                    HStack {
                        Image(systemName: formula == model.currentFormula
                              ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(formula == model.currentFormula
                                             ? StrandPalette.metricCyan : StrandPalette.textTertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(formulaName(formula)).font(StrandFont.subhead)
                                .foregroundStyle(model.isAvailable(formula)
                                                 ? StrandPalette.textPrimary
                                                 : StrandPalette.textTertiary)
                            if formula.needsBodyFat, model.bodyFatToday == nil {
                                Text("Needs a body-fat reading")
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        Spacer()
                        if let value = model.basalRate(formula, profile: analyticsProfile) {
                            Text("\(Int(value.rounded()))")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!model.isAvailable(formula))
            }
            if let switched = EnergyPlanStore.formulaLog.lastSwitchDay {
                Text("Changed on \(switched). Days before that keep the formula that applied then — a switch never rewrites history.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Page B

    private var measuredPage: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    SectionHeader("From what was recorded", overline: "Your data")
                    Spacer()
                    Button { infoTopic = .quality } label: {
                        Image(systemName: "info.circle").foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                Text("Measured burn").font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(model.burn.measuredMeanKcal.map { kcalPerDay($0) }
                     ?? String(localized: "Not enough measured days"))
                    .font(StrandFont.number(26)).foregroundStyle(StrandPalette.textPrimary)
                Text(qualityNote).font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                if !model.burn.composition.isEmpty { compositionRows }

                Divider().background(StrandPalette.hairline)
                HStack {
                    Text("Energy balance").font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Button { infoTopic = .balance } label: {
                        Image(systemName: "info.circle").foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                if let balance = model.balance {
                    Text(kcalPerDay(balance.estimatedDailyKcal))
                        .font(StrandFont.number(26)).foregroundStyle(StrandPalette.textPrimary)
                    Text("Between \(Int(balance.lowerBoundKcal.rounded())) and \(Int(balance.upperBoundKcal.rounded())), from \(balance.intakeDays) days of intake and \(balance.weightReadings) weigh-ins.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Self-reported intake runs low — commonly by 10 to 30 percent. An under-reported diary makes this figure look low too, which then makes the wearable look like it is overestimating. The asymmetry is worth knowing before reading the gap above as a device error.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Needs about two weeks of intake and regular weigh-ins. \(model.intakeDays) days are available so far.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let thermic = model.thermicEffectKcal {
                    Divider().background(StrandPalette.hairline)
                    HStack {
                        Text("Digesting your food").font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                        Text("≈\(Int(thermic.rounded())) kcal/day").font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textPrimary).monospacedDigit()
                    }
                    Text("Processing what you eat costs energy too — about a tenth of the day, and more on a high-protein diet. It is not in the burn figures above: no wearable measures it, and mixing a calculation into a measurement would make both harder to trust. It belongs here, against your intake.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // NOOP ships no food diary on purpose — that is a separate app, and one that would need
                // a server this project does not have. The intended path is a nutrition app the wearer
                // already uses, synced through Apple Health, so nothing has to be retyped here. The
                // manual entry below stays as a fallback for a day Health did not receive, not as the
                // way this is meant to be used.
                Label("Calories and macros are read from Apple Health, so anything you log in another app counts here automatically.",
                      systemImage: "heart.text.square.fill")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    enteringIntake = true
                } label: {
                    Label("Enter a day by hand", systemImage: "square.and.pencil")
                        .font(StrandFont.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private var compositionRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.burn.composition.sorted { $0.value > $1.value }, id: \.key) { entry in
                HStack {
                    Text(sourceName(entry.key)).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Text("\(entry.value)").font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    // MARK: - The plan

    private var planCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                SectionHeader("A target", overline: "Plan")
                HStack {
                    Text("Aim for").font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Text(rateText).font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Slider(value: $model.targetKgPerWeek, in: -1...0.5, step: 0.05)
                HStack {
                    Text("−1,0 kg/week").font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                    Text("+0,5 kg/week").font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                if let delta = model.dailyDelta() {
                    Text(delta == 0
                         ? String(localized: "Eat what you burn.")
                         : (delta < 0
                            ? String(localized: "About \(Int(abs(delta).rounded())) kcal a day under what you burn.")
                            : String(localized: "About \(Int(delta.rounded())) kcal a day over what you burn.")))
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                }
                if let observed = model.observedKcalPerKg {
                    Text("Using your own observed cost of \(Int(observed.rounded())) kcal per kilogram, measured from what you ate, burned and weighed. The usual 7 700 figure is the Wishnofsky convention from 1958 and runs optimistic over months, because it ignores the adaptation that comes with sustained loss.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Using the Wishnofsky convention of 7 700 kcal per kilogram — a 1958 approximation that runs optimistic over months. Once enough intake and weight data exists, your own observed figure replaces it here.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// One formatter for every kcal figure on this screen. The corridor grouped its thousands while
    /// the tiers below printed a bare integer, so "2.188 kcal" and "2188 kcal/day" sat two cards apart
    /// naming the same number.
    private func kcalPerDay(_ value: Double) -> String {
        "\(value.rounded().formatted(.number.precision(.fractionLength(0)))) kcal/day"
    }

    private var rateText: String {
        let rate = model.targetKgPerWeek
        if abs(rate) < 0.025 { return String(localized: "Hold weight") }
        let value = abs(rate).formatted(.number.precision(.fractionLength(2)))
        return rate < 0 ? String(localized: "Lose \(value) kg/week")
                        : String(localized: "Gain \(value) kg/week")
    }

    // MARK: - Names

    /// The published name of each formula.
    ///
    /// Two of these carry a translatable word beside the surname — "Revised", "(lean mass)" — so they
    /// belong in the catalog. Mifflin-St Jeor is nothing but two researchers' names, and there is no
    /// language in which it reads differently. Putting a bare proper noun through `String(localized:)`
    /// files it as a string awaiting translation that can never receive one, and the i18n gate counts
    /// it forever as an untranslated echo — its own baseline file says to ratchet that number DOWN,
    /// never up. `verbatim` keeps it out of the catalog, which is where a surname belongs.
    private func formulaName(_ formula: BasalFormula) -> String {
        switch formula {
        case .revisedHarrisBenedict: return String(localized: "Revised Harris–Benedict")
        case .mifflinStJeor:         return "Mifflin-St Jeor"
        case .katchMcArdle:          return String(localized: "Katch-McArdle (lean mass)")
        }
    }

    private func activityName(_ level: ActivityLevel) -> String {
        switch level {
        case .sedentary: return String(localized: "Desk")
        case .light:     return String(localized: "Light")
        case .moderate:  return String(localized: "Moderate")
        case .high:      return String(localized: "High")
        case .veryHigh:  return String(localized: "Very high")
        }
    }

    private func sourceName(_ source: EnergySource) -> String {
        switch source {
        case .appleSplit:    return String(localized: "Apple measured")
        case .strapWornTime: return String(localized: "Strap worn")
        case .mixed:         return String(localized: "Part measured")
        case .stepsEstimate: return String(localized: "Estimated from steps")
        case .loggedActivity: return String(localized: "From logged sessions")
        case .profileOnly:   return String(localized: "Profile only")
        }
    }

    @ViewBuilder private func infoSheet(_ topic: InfoTopic) -> some View {
        let content: (String, String)
        switch topic {
        case .corridor:
            content = (String(localized: "Why three numbers"),
                       String(localized: "Nobody can say how accurately a wearable measures a person's energy. Printing one maintenance figure would hide that behind a decimal point.\n\nSo you get three, from three independent routes: what a published formula predicts for a body like yours, what your wearable recorded, and what your intake and weight change imply. The last one is the only one that does not inherit the strap's conversion error, which makes it the check value rather than a third opinion.\n\nThe gap between them is the real output. A narrow corridor means the routes agree and you can plan against the middle. A wide one means you are guessing, and it is better to know that."))
        case .pal:
            content = (String(localized: "Activity multipliers"),
                       String(localized: "The steps are conventions. They come from the literature and are what every calorie calculator uses, but nobody's actual life has a multiplier of exactly 1.55 — the ladder is a way of talking about activity, not a measurement of it.\n\nThat is the difference between this page and the other one. This page says what a formula predicts for a body like yours. The other says what your own days actually recorded."))
        case .quality:
            content = (String(localized: "What counts as measured"),
                       String(localized: "A thirty-day average of which most days came from a step estimate is a formula calculation with extra steps. Calling it measured would be a claim NOOP cannot support.\n\nSo a day counts as measured only when the burn came from a real energy source — Apple's own split or the strap's worn time — and enough of the day was covered. Days that do not meet that bar are still counted and shown, but they are not folded into the measured figure at a discount, because the weighting that would need would be invented.\n\nThe composition list says exactly which days came from where."))
        case .balance:
            content = (String(localized: "Intake and weight"),
                       String(localized: "Over a few weeks, what you ate minus what your weight did tells you what you actually burned — regardless of what any device thinks. That independence is the whole value: it is the one figure that does not inherit a wearable's conversion error.\n\nIt has its own weakness, and it runs one way. Self-reported intake is under-reported, commonly by 10 to 30 percent. Under-reported intake produces a low estimate here, and a low estimate makes your wearable look like it is overestimating. Before reading the gap as a device problem, it is worth asking whether the diary is complete.\n\nIt is never used to correct the daily figure. It sits beside it as a check."))
        case .formula:
            content = (String(localized: "Which basal formula"),
                       String(localized: "Harris–Benedict and Mifflin-St Jeor both estimate basal metabolism from height, weight, age and sex. Katch-McArdle works from lean mass instead, which makes it the better formula when — and only when — the body-fat figure behind it is good.\n\nFed a tape estimate carrying ±4 percentage points, its error can be as large as what it replaced. So it is offered rather than applied, and the switch sheet names what your number rests on.\n\nA change applies from the day you make it and never backwards. Days already scored keep the formula that applied then, so the step in the curve sits at the date you chose, with a reason beside it."))
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
}

extension BasalFormula: Identifiable {
    public var id: String { rawValue }
}
