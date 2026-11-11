#if os(iOS)
import SwiftUI
import StrandCore
import StrandAnalytics

/// The food log's first-visit setup (owner, 2026-11-09): where branded products come from, then the extras.
/// Every choice writes the same key as Food data, and the texts that explain a switch are the same strings, so
/// the two places cannot describe a setting differently. Closing it in any way counts as done; the parent marks
/// it through `FoodProductDataPrefs.setupDoneKey`.
struct FoodSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FoodProductDataPrefs.modeKey) private var modeRaw = FoodProductDataMode.none.rawValue
    @AppStorage(FoodProductDataPrefs.unknownBarcodesOnlineKey) private var unknownBarcodesOnline = false
    @State private var packs = FoodPacksModel()
    @State private var showExtras = false

    private var mode: FoodProductDataMode { FoodProductDataMode(rawValue: modeRaw) ?? .none }

    var body: some View {
        NavigationStack {
            Form {
                FoodSetupHeader(image: "foodHero", title: String(localized: "Find your products"),
                                text: String(localized: "Forge always knows the German Nutrient Database and your own foods. Branded products and barcodes can come on top."))
                Section {
                    choice(.none, title: String(localized: "Off"),
                           detail: String(localized: "Forge searches the German Nutrient Database and your own foods on this iPhone. Nothing goes online."))
                    choice(.online, title: String(localized: "Search online"),
                           detail: String(localized: "Your search words and scanned barcodes go to Open Food Facts. No account, nothing else about you."))
                    choice(.packs, title: String(localized: "Download for offline"),
                           detail: String(localized: "Products of the countries you download are searched on this iPhone, without the internet."))
                } header: {
                    Text("Branded products")
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
            }
            .animation(.smooth, value: modeRaw)
            .navigationTitle("Set up Nutrition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Later", action: close) }
                ToolbarItem(placement: .confirmationAction) { Button("Continue", action: openExtras) }
            }
            .navigationDestination(isPresented: $showExtras) { FoodSetupExtras(done: close) }
            .task(id: modeRaw) { await packs.refresh(fetchManifest: mode != .none) }
        }
        .tint(ForgeColor.accent)
    }

    private func choice(_ value: FoodProductDataMode, title: String, detail: String) -> some View {
        Button { modeRaw = value.rawValue } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(ForgeColor.text)
                    Text(detail).font(.footnote).foregroundStyle(ForgeColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: mode == value ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(mode == value ? ForgeColor.accent : ForgeColor.tertiary)
                    .font(.title3)
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(mode == value ? [.isButton, .isSelected] : .isButton)
    }

    private func openExtras() { showExtras = true }
    private func close() { dismiss() }
}

/// The setup's second step: Apple Health, the Lab score and, with the coach on, filling missing nutrients.
private struct FoodSetupExtras: View {
    let done: () -> Void
    @AppStorage(FoodHealthSync.enabledKey) private var writeHealth = true
    @AppStorage(FoodEstimate.enabledKey) private var estimateMissing = false
    @AppStorage(FoodScore.enabledKey) private var showScore = false
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false

    var body: some View {
        Form {
            FoodSetupHeader(image: "foodScoreHero", title: String(localized: "A few extras"),
                            text: String(localized: "You can change all of this later under Food data."))
            Section {
                Toggle("Write meals to Apple Health", isOn: $writeHealth)
            } footer: {
                Text("Each meal goes to Apple Health with its nutrients. Forge does not read its own meals back, so nothing is counted twice.")
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
                Toggle("Nutrition score", isOn: $showScore)
            } header: {
                Text("Lab")
            } footer: {
                Text("A score for the last seven days from a widely used healthy eating index: vegetables, fruit, whole grains, nuts and pulses, fish, fats, salt, sweet drinks, red meat and alcohol. It needs five logged days of seven. It describes habits, not a single day.")
            }
        }
        .navigationTitle("Set up Nutrition")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) } }
    }
}

/// A setup step's picture, title and one sentence, standing free above the form.
private struct FoodSetupHeader: View {
    let image: String
    let title: String
    let text: String

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Image(image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .clipShape(.rect(cornerRadius: ForgeRadius.card))
                    .accessibilityHidden(true)
                Text(title).font(ForgeFont.rounded(24)).foregroundStyle(ForgeColor.text)
                Text(text).font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }
}
#endif
