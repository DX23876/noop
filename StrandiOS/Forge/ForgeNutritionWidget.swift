#if os(iOS)
import SwiftUI
import StrandCore
import StrandDesign
import WhoopStore

/// Today's eating against its goal, with the macros (owner, 2026-11-18).
///
/// The Food page showed the plan's progress and the Energy card the burn; the macros stood nowhere at all,
/// and neither did "what may I still eat today". This tile answers both.
///
/// Small says what is left of the day and what has been eaten of the goal; two columns adds the three
/// macros against theirs; the whole row adds them as bars and the week's calories.
///
/// The goal is NOT resolved here. It comes from the one order the app resolves it in
/// (`FoodTargets.dayGoal`), over the same reads the Food page makes, so the tile and the page cannot name
/// different goals — the one number in this app where that matters most.
struct ForgeNutritionWidget: View {
    var compact: TileSize? = nil
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @State private var reading: ForgeNutritionReading?

    var body: some View {
        Group {
            if let compact {
                ForgeCardTile(symbol: "fork.knife", label: String(localized: "Nutrition"),
                              value: left, unit: "kcal",
                              caption: compact == .medium ? macroLine : eatenOfGoal,
                              tint: StrandPalette.energyHighlight, route: ForgeRoute.food)
            } else {
                full
            }
        }
        .task(id: repo.refreshSeq) { reading = await ForgeNutritionReading.load(repo: repo, profile: profile) }
    }

    private var left: String? {
        reading?.leftKcal.map { Int($0.rounded()).formatted(.number.locale(AppLanguage.activeLocale)) }
    }

    private var eatenOfGoal: String? {
        guard let eaten = reading?.eatenKcal, let goal = reading?.goalKcal else { return nil }
        let e = Int(eaten.rounded()).formatted(.number.locale(AppLanguage.activeLocale))
        let g = Int(goal.rounded()).formatted(.number.locale(AppLanguage.activeLocale))
        return String(localized: "\(e) of \(g) kcal eaten")
    }

    /// "P 142/160 · C 180/240 · F 55/70 g", the three macros against their goals.
    private var macroLine: String? {
        guard let r = reading, let p = r.proteinG, let c = r.carbsG, let f = r.fatG else { return nil }
        func g(_ v: Double) -> String { String(Int(v.rounded())) }
        guard let pg = r.proteinGoal, let cg = r.carbsGoal, let fg = r.fatGoal else {
            return String(localized: "P \(g(p)) · C \(g(c)) · F \(g(f)) g")
        }
        return String(localized: "P \(g(p))/\(g(pg)) · C \(g(c))/\(g(cg)) · F \(g(f))/\(g(fg)) g")
    }

    @ViewBuilder private var full: some View {
        NavigationLink(value: ForgeRoute.food) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Nutrition").font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(ForgeColor.tertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: left ?? "–").font(ForgeFont.figure(28)).foregroundStyle(ForgeColor.text)
                    Text("left today").font(.system(.subheadline)).foregroundStyle(ForgeColor.secondary)
                }
                if let eatenOfGoal {
                    Text(verbatim: eatenOfGoal).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
                if let r = reading {
                    macroBars(r)
                    if r.weekKcal.count > 1 {
                        Text("This week").font(ForgeFont.caption).foregroundStyle(ForgeColor.tertiary)
                        ForgeWeekBars(points: r.weekKcal.map { .init(day: $0.day, value: $0.kcal) },
                                      today: Repository.localDayKey(Date()), goal: r.goalKcal,
                                      tint: StrandPalette.energyHighlight, height: 56)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .forgeCard(radius: ForgeRadius.card, padding: 16)
        }
        .buttonStyle(LiquidPressStyle())
    }

    /// The three macros as bars against their goals, so "how far" is seen and not only read.
    @ViewBuilder private func macroBars(_ r: ForgeNutritionReading) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Each in its own colour, the same three the Food page's plate and week strip use (owner, 2026-11-25).
            macroBar(String(localized: "Protein"), r.proteinG, r.proteinGoal, tint: ForgeColor.protein)
            macroBar(String(localized: "Carbs"), r.carbsG, r.carbsGoal, tint: ForgeColor.carbs)
            macroBar(String(localized: "Fat"), r.fatG, r.fatGoal, tint: ForgeColor.fat)
        }
    }

    @ViewBuilder private func macroBar(_ label: String, _ value: Double?, _ goal: Double?, tint: Color) -> some View {
        if let value {
            HStack(spacing: 8) {
                Text(verbatim: label).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    .frame(width: 64, alignment: .leading)
                GeometryReader { geo in
                    let share = (goal.map { $0 > 0 ? min(1, max(0, value / $0)) : 0 }) ?? 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(ForgeColor.tertiary.opacity(0.25))
                        Capsule().fill(tint).frame(width: geo.size.width * share)
                    }
                }
                .frame(height: 8)
                Text(verbatim: goal.map { "\(Int(value.rounded())) / \(Int($0.rounded())) g" }
                     ?? "\(Int(value.rounded())) g")
                    .font(ForgeFont.caption.monospacedDigit()).foregroundStyle(ForgeColor.text)
                    .frame(width: 92, alignment: .trailing)
            }
        }
    }
}

/// What the Nutrition tile reads: today's eating, the day's goal and the week's calories.
struct ForgeNutritionReading {
    var eatenKcal: Double?
    var goalKcal: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?
    var proteinGoal: Double?
    var carbsGoal: Double?
    var fatGoal: Double?
    var weekKcal: [(day: String, kcal: Double)] = []

    /// What is left of today, never below nothing: past the goal there is nothing left, not a negative.
    var leftKcal: Double? { goalKcal.flatMap { g in eatenKcal.map { max(0, g - $0) } } }
    /// Whether anything has been logged at all. The gallery offers the tile only then, as it offers the
    /// cycle card only to the people it is for: an empty tile would be a goal with nothing to weigh.
    var logged: Bool { (eatenKcal ?? 0) > 0 || weekKcal.contains { $0.kcal > 0 } }

    /// The last reading, for the refresh it was read in. Today can hold three tiles that need this same
    /// answer (the Nutrition tile, the protein tile's goal, the energy card), and the energy plan behind
    /// it reads a month of summaries and a balance estimate over half a year. One resolver, asked once per
    /// refresh, rather than three loads of the same thing on one screen.
    @MainActor
    private static var cached: (seq: Int, day: String, reading: ForgeNutritionReading?)?

    /// Main-actor because the energy plan model is: the tile's own `.task` already runs there.
    @MainActor
    static func load(repo: Repository, profile: ProfileStore) async -> ForgeNutritionReading? {
        let todayKey = Repository.localDayKey(Date())
        if let cached, cached.seq == repo.refreshSeq, cached.day == todayKey { return cached.reading }
        let reading = await read(repo: repo, profile: profile)
        cached = (repo.refreshSeq, todayKey, reading)
        return reading
    }

    @MainActor
    private static func read(repo: Repository, profile: ProfileStore) async -> ForgeNutritionReading? {
        guard let store = await repo.storeHandle() else { return nil }
        let today = Repository.localDayKey(Date())
        let analytics = Repository.analyticsProfile(profile)

        // The base goal, from the energy plan the Food page reads.
        let energy = EnergyPlanModel()
        await energy.load(repo: repo, profile: analytics)
        let planned = FoodTargets.calories(measuredMeanKcal: energy.burn.measuredMeanKcal,
                                           allDaysMeanKcal: energy.burn.allDaysMeanKcal,
                                           formulaTdeeKcal: energy.formulaTdee(profile: analytics),
                                           dailyDeltaKcal: energy.targetDailyKcal)

        // The diet plan's own day, through the shared gathering the Android core calls too.
        var planDay: FoodTargets.DayGoal?
        var planResolved: FoodTargets.DayGoal?
        if let plan = DietPlan.decode(UserDefaults.standard.string(forKey: DietPlan.storageKey)),
           let burn = energy.burn.measuredMeanKcal ?? energy.burn.allDaysMeanKcal
               ?? energy.formulaTdee(profile: analytics) {
            let person = DietPerson(weightKg: profile.weightKg,
                                    heightCm: profile.heightCm > 0 ? profile.heightCm : nil,
                                    age: profile.age > 0 ? Int(profile.age) : nil,
                                    male: profile.sex.lowercased() == "male" ? true
                                        : profile.sex.lowercased() == "female" ? false : nil)
            let reader = repo.storeReader(store)
            let context = await DietDayContext.read(plan: plan, person: person, burn: burn,
                                                    kcalPerKg: energy.energyDensityKcalPerKg,
                                                    burnedByDay: energy.burnedByDay, dismissedWorkouts: [],
                                                    store: store, reader: reader, day: today)
            planDay = .init(calories: context.day.calories, macros: context.day.macros)
            let result = DietTargets.resolve(plan, person: context.person, burnKcal: context.day.planBurnKcal,
                                             kcalPerKg: energy.energyDensityKcalPerKg)
            planResolved = .init(calories: FoodTargets.calories(plan: plan, result: result, day: today),
                                 macros: FoodTargets.macros(plan: plan, result: result, day: today))
        }
        let d = UserDefaults.standard, split = FoodTargets.defaultSplit
        func share(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) as? Double ?? fallback }
        let goal = FoodTargets.dayGoal(planDay: planDay, planResolved: planResolved,
                                       fixedKcal: d.double(forKey: FoodTargets.Keys.calories),
                                       energyPlan: planned,
                                       proteinPercent: share(FoodTargets.Keys.proteinPercent, split.protein),
                                       carbsPercent: share(FoodTargets.Keys.carbsPercent, split.carbs),
                                       fatPercent: share(FoodTargets.Keys.fatPercent, split.fat))

        let day = await FoodLog.day(store: store, today)
        let from = MeasureFacts.dayKey(today, minusDays: 6)
        let week = await repo.intakeByDay(from: from, to: today)
        return ForgeNutritionReading(
            eatenKcal: day.totals.values[.energyKcal],
            goalKcal: goal?.calories.kcal,
            proteinG: day.totals.values[.proteinG], carbsG: day.totals.values[.carbsG],
            fatG: day.totals.values[.fatG],
            proteinGoal: goal?.macros?.proteinG, carbsGoal: goal?.macros?.carbsG, fatGoal: goal?.macros?.fatG,
            weekKcal: week.keys.sorted().map { (day: $0, kcal: week[$0] ?? 0) })
    }
}
#endif
