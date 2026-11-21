#if os(iOS)
import SwiftUI
import StrandCore
import StrandAnalytics

/// Food settings: where branded products come from (off, online search or country packs), the packs on this
/// iPhone, filling missing nutrients, Apple Health writing and the sources' credits. Nothing goes online before
/// the wearer picks a mode here (decision 2026-11-08).
struct FoodDataSettingsView: View {
    /// Asks the food log to show its first-visit setup once these settings have closed.
    var openSetup: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FoodProductDataPrefs.modeKey) private var modeRaw = FoodProductDataMode.none.rawValue
    @AppStorage(FoodProductDataPrefs.unknownBarcodesOnlineKey) private var unknownBarcodesOnline = false
    @AppStorage(FoodHealthSync.enabledKey) private var writeHealth = true
    @AppStorage(FoodEstimate.enabledKey) private var estimateMissing = false
    @State private var morningOn = FoodReminders.morningOn
    @State private var eveningOn = FoodReminders.eveningOn
    @AppStorage(FoodReminders.warnKey) private var warnOn = true
    @State private var remindersDenied = false
    /// With a diet plan the goals live in the plan, one place for them (decision 2026-11-09).
    @AppStorage(DietPlan.storageKey) private var planRaw = ""
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    @State private var packs = FoodPacksModel()
    @AppStorage(FoodTargets.Keys.calories) private var fixedKcal = 0.0
    @AppStorage(FoodTargets.Keys.proteinPercent) private var proteinPercent = FoodTargets.defaultSplit.protein
    @AppStorage(FoodTargets.Keys.carbsPercent) private var carbsPercent = FoodTargets.defaultSplit.carbs
    @AppStorage(FoodTargets.Keys.fatPercent) private var fatPercent = FoodTargets.defaultSplit.fat

    private var mode: FoodProductDataMode { FoodProductDataMode(rawValue: modeRaw) ?? .none }

    var body: some View {
        NavigationStack {
            Form {
                if DietPlan.decode(planRaw) == nil {
                    FoodGoalsSection(fixedKcal: $fixedKcal, protein: $proteinPercent, carbs: $carbsPercent, fat: $fatPercent)
                } else {
                    Section("Goals") {
                        Text("Your calories and macros come from your diet plan. Change them on the plan page at the top of Nutrition.")
                            .foregroundStyle(ForgeColor.secondary)
                    }
                }
                Section {
                    Picker("Branded products", selection: $modeRaw) {
                        Text("Off").tag(FoodProductDataMode.none.rawValue)
                        Text("Search online").tag(FoodProductDataMode.online.rawValue)
                        Text("Download for offline").tag(FoodProductDataMode.packs.rawValue)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Branded products")
                } footer: {
                    Text(modeFooter)
                }
                if mode == .online {
                    FoodCountriesSection(offered: packs.manifest?.usable.map(\.country))
                }
                if mode == .packs {
                    FoodPacksSection(packs: packs)
                    Section {
                        Toggle("Look up unknown barcodes online", isOn: $unknownBarcodesOnline)
                    } footer: {
                        Text("Only the barcode number goes to Open Food Facts, and only for a product that is not on this iPhone.")
                    }
                }
                if coachFeatureEnabled {
                    Section {
                        Toggle(isOn: $estimateMissing) {
                            Text("Fill in missing nutrients")
                            Text("Recommended")
                        }
                    } footer: {
                        Text("When a product leaves out vitamins and minerals, your coach finds the most similar food in the German Nutrient Database and Forge takes the missing values from it. If none is close enough, your coach estimates them. Label values always stay, and every estimate is marked. The product's name and stated values go to your coach's provider, once per product.")
                    }
                }
                Section {
                    Toggle("Write meals to Apple Health", isOn: $writeHealth)
                } footer: {
                    Text("Each meal goes to Apple Health with its nutrients. Forge does not read its own meals back, so nothing is counted twice.")
                }
                Section {
                    Toggle("Morning look back", isOn: $morningOn)
                        .onChange(of: morningOn) { _, on in apply(FoodReminders.morningKey, on: on) }
                    Toggle("Evening reminder", isOn: $eveningOn)
                        .onChange(of: eveningOn) { _, on in apply(FoodReminders.eveningKey, on: on) }
                    Toggle("Warn while logging", isOn: $warnOn)
                } header: {
                    Text("Reminders")
                } footer: {
                    Text("Each morning a look back on yesterday's note and goal, on Mondays on the week. In the evening only when one meal can still close a gap. The warning appears while you log, only when you are losing weight and an entry takes the day more than a fifth over your goal.")
                }
                if let openSetup {
                    Section {
                        Button("Show the setup again") { openSetup(); dismiss() }
                    }
                }
                Section("Sources") {
                    Text("German Nutrient Database (Bundeslebensmittelschlüssel) 4.0, Max Rubner-Institut, CC BY 4.0.")
                    Text("Open Food Facts, openfoodfacts.org, ODbL 1.0. Product values are entered by volunteers.")
                }
                .font(.footnote)
            }
            .alert("Notifications are off", isPresented: $remindersDenied) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Allow notifications for Forge in the iPhone's Settings to get the reminders.")
            }
            .navigationTitle("Food data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) } }
            .task(id: modeRaw) { await packs.refresh(fetchManifest: mode != .none) }
        }
    }

    private var modeFooter: String {
        switch mode {
        case .none: String(localized: "Forge searches the German Nutrient Database and your own foods on this iPhone. Nothing goes online.")
        case .online: String(localized: "Your search words and scanned barcodes go to Open Food Facts. No account, nothing else about you.")
        case .packs: String(localized: "Products of the countries you download are searched on this iPhone, without the internet.")
        }
    }

    private func close() { dismiss() }

    /// A reminder switch asks for permission when turned on and falls back when it is refused.
    private func apply(_ key: String, on: Bool) {
        Task {
            guard await !FoodReminders.set(key, on: on) else { return }
            if key == FoodReminders.morningKey { morningOn = false } else { eveningOn = false }
            remindersDenied = true
        }
    }
}
#endif
