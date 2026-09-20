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
    /// What is being typed into today's intake field, as text: an empty field is not zero calories,
    /// and a `Double` binding cannot tell the two apart.
    @State private var todayIntakeDraft = ""
    @FocusState private var intakeFieldFocused: Bool
    @State private var onboarding = false

    /// Which route's workings are shown below the corridor. Chosen by tapping that route's row —
    /// the labels and `CaseIterable` went with the segmented control that used to offer it.
    private enum Page {
        case calculated, measured
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
                // Today's balance sits directly under the corridor because it is the only thing on
                // this page that is actionable TODAY. Everything below it is reference: how each of
                // the three routes arrives at its number, looked up on the day someone doubts one.
                todayBalanceCard
                // No segmented control any more. The corridor's own rows choose what is shown below
                // — the switch was a second, unlabelled copy of the same three-way choice, and it
                // hid whichever half of the answer you were not looking at.
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
                    SectionHeader("How much you burn a day", overline: "Three routes")
                    Spacer()
                    Button { infoTopic = .corridor } label: {
                        Image(systemName: "info.circle").foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                CorridorBar(entries: corridorEntries(corridor))
                corridorRow(String(localized: "Formula"), corridor.formulaKcal,
                            note: String(localized: "from your height, weight and age"),
                            icon: "function", tint: StrandPalette.metricAmber, page: .calculated)
                corridorRow(String(localized: "Your band"), corridor.measuredKcal,
                            note: qualityNote,
                            icon: "sensor.tag.radiowaves.forward.fill",
                            tint: StrandPalette.metricCyan, page: .measured)
                corridorRow(String(localized: "Food and scale"), corridor.balanceKcal,
                            note: balanceNote,
                            icon: "scalemass.fill", tint: StrandPalette.metricPurple, page: .measured)
                if let spread = corridor.spreadKcal {
                    Divider().background(StrandPalette.hairline)
                    Text("The three land \(Int(spread.rounded())) kcal apart. Work with that range, not with one number.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Only one route has data so far. Give the others a couple of weeks.")
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

    /// One route, and the way into what it rests on.
    ///
    /// Tapping it opens the section that explains that route rather than scrolling for it. This is
    /// what replaced the segmented control: the choice was already on screen three times over, in
    /// the bar, in these rows and in the switch, and only the switch decided anything.
    private func corridorRow(_ label: String, _ value: Double?, note: String?,
                             icon: String, tint: Color, page target: Page) -> some View {
        Button {
            page = target
        } label: {
            corridorRowLabel(label, value, note: note, icon: icon, tint: tint)
        }
        .buttonStyle(.plain)
    }

    private func corridorRowLabel(_ label: String, _ value: Double?, note: String?,
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
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
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
            return String(localized: "mostly modelled — only \(model.burn.measuredDays) of \(model.burn.totalDays) days measured")
        }
    }

    private var balanceNote: String? {
        guard let balance = model.balance else {
            return String(localized: "needs ~2 weeks of food logs and weigh-ins")
        }
        return String(localized: "\(balance.intakeDays) days logged out of \(balance.windowDays)")
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
                Text("These steps are conventions, not measurements — nobody's day is exactly ×\(model.activity.factor.formatted()). Which is why the figure below is a prediction, not a reading.")
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
                    SectionHeader("What your band recorded", overline: "Your data")
                    Spacer()
                    Button { infoTopic = .quality } label: {
                        Image(systemName: "info.circle").foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                Text("Average burn").font(StrandFont.subhead)
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
                    Text("Most people log 10–30 % less than they eat, which drags this figure down and makes the band look like it is overcounting. Worth checking your diary before you blame the band.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Needs about two weeks of food logs and regular weigh-ins. You have \(model.intakeDays) so far.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let thermic = model.thermicEffectKcal {
                    Divider().background(StrandPalette.hairline)
                    HStack {
                        Text("Digesting food").font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                        Text("≈\(Int(thermic.rounded())) kcal/day").font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textPrimary).monospacedDigit()
                    }
                    Text("Digesting food burns energy too — roughly a tenth of what you eat, more on a high-protein day. No band measures it, so it is counted here against your food rather than in the burn figures above.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // NOOP ships no food diary on purpose — that is a separate app, and one that would need
                // a server this project does not have. The intended path is a nutrition app the wearer
                // already uses, synced through Apple Health, so nothing has to be retyped here. The
                // manual entry below stays as a fallback for a day Health did not receive, not as the
                // way this is meant to be used.
                Label("Calories and macros come from Apple Health — whatever you log in another app counts here on its own.",
                      systemImage: "heart.text.square.fill")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    enteringIntake = true
                } label: {
                    Label("Add a day by hand", systemImage: "square.and.pencil")
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


    // MARK: - Today's balance

    /// Eaten today against what today is on course to cost.
    ///
    /// The page below this one answers the same question over a fortnight of intake and weigh-ins,
    /// which is the right horizon for whether a plan is working and the wrong one for someone who
    /// just logged lunch. This card is the day.
    private var todayBalanceCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                SectionHeader("Where today lands", overline: "Today")
                intakeRow
                if let balance = model.todayBalance {
                    Divider().background(StrandPalette.hairline)
                    verdictRow(balance)
                    row("Burn, projected", kcal(balance.projectedBurnKcal))
                    if balance.thermicKcal > 0 {
                        row("Digesting food", kcal(balance.thermicKcal))
                    }
                    if let target = model.targetDailyKcal {
                        row("Your target", signed(target))
                    }
                    Text(balanceFootnote(balance))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let burn = model.todayProjectedBurnKcal {
                    Divider().background(StrandPalette.hairline)
                    row("Projected burn", kcal(burn))
                    Text("Add what you have eaten to see where today lands.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No burn forecast yet — the day is still too young to project from. Check back in a few hours.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The entry lives here rather than only in the log below: this is the number someone types
    /// daily, and making them scroll past the verdict to reach the field is the friction the whole
    /// card exists to remove. It writes to the same manual source the log does.
    private var intakeRow: some View {
        HStack {
            Text("Eaten today").font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                // Placeholder "0" rather than "kcal": the unit is printed beside the field, and a
                // field whose placeholder repeats it reads as two labels and no input.
                TextField("0", text: $todayIntakeDraft)
                    .multilineTextAlignment(.trailing)
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .textFieldStyle(.plain)
                    .frame(width: 72)
                    .focused($intakeFieldFocused)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .onSubmit { submitIntake() }
                Text(verbatim: "kcal").font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    // Without this the unit is compressed into "k / c / al" when the label and the
                    // save button claim the row's width first.
                    .fixedSize()
            }
            .layoutPriority(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(StrandPalette.surfaceInset,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Button("Save") { submitIntake() }
                .buttonStyle(.borderless)
                .disabled(Double(todayIntakeDraft.trimmingCharacters(in: .whitespaces)) == nil)
        }
        .onChangeCompat(of: model.todayIntakeKcal) { _ in syncIntakeDraft() }
        .onAppear { syncIntakeDraft() }
    }

    private func syncIntakeDraft() {
        guard !intakeFieldFocused else { return }
        todayIntakeDraft = model.todayIntakeKcal.map { String(Int($0.rounded())) } ?? ""
    }

    private func submitIntake() {
        guard let value = Double(todayIntakeDraft.trimmingCharacters(in: .whitespaces)),
              value > 0 else { return }
        intakeFieldFocused = false
        Task { await model.recordTodayIntake(value, repo: repo, profile: analyticsProfile) }
    }

    @ViewBuilder private func verdictRow(_ balance: EnergyPlanning.DailyBalance) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verdictTitle(balance.verdict))
                    .font(StrandFont.headline)
                    .foregroundStyle(verdictColor(balance.verdict))
                // The band belongs under the verdict it qualifies, not in the footnote three lines
                // down where it read as a second, unrelated sentence.
                if balance.verdict != .tooEarly {
                    Text("Maintenance is ±\(Int(balance.maintenanceBandKcal.rounded())) kcal")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer(minLength: 8)
            if balance.verdict != .tooEarly {
                Text(signed(balance.balanceKcal))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }

    private func verdictTitle(_ verdict: EnergyPlanning.DailyBalance.Verdict) -> LocalizedStringKey {
        switch verdict {
        case .deficit:     return "Heading for a deficit"
        case .maintenance: return "Holding steady"
        case .surplus:     return "Heading for a surplus"
        case .tooEarly:    return "Still open"
        }
    }

    private func verdictColor(_ verdict: EnergyPlanning.DailyBalance.Verdict) -> Color {
        switch verdict {
        case .deficit, .surplus: return StrandPalette.textPrimary
        case .maintenance:       return StrandPalette.statusPositive
        case .tooEarly:          return StrandPalette.textSecondary
        }
    }

    /// Says that the second number is a forecast, and how wide it still is. Without this the card
    /// would state a deficit to the kilocalorie off a figure that has hours left to move.
    private func balanceFootnote(_ balance: EnergyPlanning.DailyBalance) -> LocalizedStringKey {
        guard let range = balance.range else {
            return "Measured against what today is on course to burn, not what it has burned so far."
        }
        // Through `signed`, so the bounds carry the same true minus sign as the headline figure
        // rather than a hyphen — the two sit four lines apart and were visibly different characters.
        let low = signed(range.lowerBound), high = signed(range.upperBound)
        if balance.verdict == .tooEarly {
            return "Today could still end between \(low) and \(high). Check back later."
        }
        // The maintenance band is already on the verdict row; repeating it here made a two-clause
        // sentence out of one fact.
        return "Projected, not measured — you will land between \(low) and \(high)."
    }

    /// A label with its figure, the shape the rest of this page's rows already use.
    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Text(value).font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
        }
    }

    private func kcal(_ value: Double) -> String {
        "\(Int(value.rounded()).formatted(.number.grouping(.automatic))) kcal"
    }

    /// "−700 kcal" / "+220 kcal" — a balance without its sign is not a balance.
    private func signed(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        let sign = rounded < 0 ? "\u{2212}" : "+"
        return "\(sign)\(abs(rounded).formatted(.number.grouping(.automatic))) kcal"
    }

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
                    Text("Using your own \(Int(observed.rounded())) kcal per kilogram, worked out from what you ate, burned and weighed. The usual 7,700 is a 1958 convention and runs optimistic over months.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Using the standard 7,700 kcal per kilogram — a 1958 convention that runs optimistic over months. Your own figure replaces it once you have logged enough food and weigh-ins.")
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
