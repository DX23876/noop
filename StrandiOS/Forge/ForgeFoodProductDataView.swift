#if os(iOS)
import SwiftUI
import StrandDesign
import StrandCore

/// Food settings: where product data comes from (online search, country packs or neither), the packs on
/// this iPhone, Apple Health writing and the data sources' credits. Nothing goes online before the wearer
/// picks a mode here (decision 2026-11-08).
struct ForgeFoodProductDataView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FoodProductDataPrefs.modeKey) private var modeRaw = FoodProductDataMode.none.rawValue
    @AppStorage(FoodProductDataPrefs.countriesKey) private var countriesRaw = ""
    @AppStorage(FoodProductDataPrefs.unknownBarcodesOnlineKey) private var unknownBarcodesOnline = false
    @AppStorage(FoodHealthSync.enabledKey) private var writeHealth = true
    @AppStorage(FoodEstimate.enabledKey) private var estimateMissing = false
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    @State private var manifest: FoodPackManifest?
    @State private var manifestFailed = false
    @State private var installed: [InstalledFoodPack] = []
    @State private var downloading: String?
    @State private var progress: Double = 0
    @State private var failure: String?

    private var mode: FoodProductDataMode { FoodProductDataMode(rawValue: modeRaw) ?? .none }
    private var chosenCountries: Set<String> {
        Set(countriesRaw.split(separator: ",").map(String.init))
    }

    var body: some View {
        NavigationStack {
            Form {
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
                    Section("Countries to search") { countryList(selectable: true) }
                }
                if mode == .packs {
                    Section {
                        if installed.isEmpty { Text("No country downloaded yet.").foregroundStyle(ForgeColor.secondary) }
                        ForEach(installed, id: \.country) { pack in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(FoodCountries.name(forTag: pack.country, locale: AppLanguage.activeLocale))
                                    Text("\(pack.rows.formatted(.number.locale(AppLanguage.activeLocale))) products")
                                        .font(.footnote).foregroundStyle(ForgeColor.secondary)
                                }
                                Spacer()
                                if let offered = manifest?.usable.first(where: { $0.country == pack.country }), offered.sha256 != pack.sha256 {
                                    Button("Update") { Task { await download(offered) } }.disabled(downloading != nil)
                                }
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    Task { await FoodCatalog.shared.removePack(country: pack.country); await refresh() }
                                }
                            }
                        }
                    } header: { Text("On this iPhone") }
                    Section {
                        if manifestFailed { Text("The list of countries could not be loaded.").foregroundStyle(ForgeColor.secondary) }
                        ForEach(manifest?.usable.filter { pack in !installed.contains { $0.country == pack.country } } ?? [], id: \.country) { pack in
                            Button { Task { await download(pack) } } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(FoodCountries.name(forTag: pack.country, locale: AppLanguage.activeLocale)).foregroundStyle(ForgeColor.text)
                                        Text("\(pack.rows.formatted(.number.locale(AppLanguage.activeLocale))) products · \(ByteCountFormatter.string(fromByteCount: Int64(pack.bytes), countStyle: .file))")
                                            .font(.footnote).foregroundStyle(ForgeColor.secondary)
                                    }
                                    Spacer()
                                    if downloading == pack.country { ProgressView(value: progress).frame(width: 60) }
                                    else { Image(systemName: "arrow.down.circle").foregroundStyle(ForgeColor.accent) }
                                }
                            }
                            .disabled(downloading != nil)
                        }
                    } header: { Text("Download") } footer: {
                        Text("A download is a public file from the NOOP Forge release on GitHub. It carries nothing about you.")
                    }
                    Section {
                        Toggle("Look up unknown barcodes online", isOn: $unknownBarcodesOnline)
                    } footer: {
                        Text("Only the barcode number is sent to Open Food Facts, and only for a product that is not on this iPhone.")
                    }
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(ForgeColor.effortInk) }
                }
                if coachFeatureEnabled {
                    Section {
                        Toggle(isOn: $estimateMissing) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Fill in missing nutrients")
                                Text("Recommended").font(.caption.weight(.semibold)).foregroundStyle(ForgeColor.accent)
                            }
                        }
                    } footer: {
                        Text("When a product leaves out vitamins and minerals, your coach picks the most similar food in the German Nutrient Database and Forge takes the missing values from it. Everything on the label stays. Borrowed values are marked as estimates. The product's name and stated values go to your coach's provider, once per product.")
                    }
                }
                Section {
                    Toggle("Write meals to Apple Health", isOn: $writeHealth)
                } footer: {
                    Text("Each meal goes to Apple Health with its nutrients. Forge does not read its own meals back, so nothing is counted twice.")
                }
                Section("Sources") {
                    Text("German Nutrient Database (Bundeslebensmittelschlüssel) 4.0, Max Rubner-Institut, CC BY 4.0.")
                    Text("Open Food Facts, openfoodfacts.org, ODbL 1.0. Product values are entered by volunteers.")
                }
                .font(.footnote)
            }
            .navigationTitle(Text("Food data"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: modeRaw) { await refresh() }
        }
    }

    private var modeFooter: String {
        switch mode {
        case .none:
            return String(localized: "Forge searches the German Nutrient Database and your own foods on this iPhone. Nothing goes online.")
        case .online:
            return String(localized: "Your search words and scanned barcodes go to Open Food Facts. No account, nothing else about you.")
        case .packs:
            return String(localized: "Products of the countries you download are searched on this iPhone, without the internet.")
        }
    }

    @ViewBuilder
    private func countryList(selectable: Bool) -> some View {
        let tags = manifest?.usable.map(\.country) ?? FoodCountries.tagsByRegion.values.sorted()
        let current = FoodProductDataPrefs.countries
        ForEach(tags.sorted { FoodCountries.name(forTag: $0, locale: AppLanguage.activeLocale) < FoodCountries.name(forTag: $1, locale: AppLanguage.activeLocale) }, id: \.self) { tag in
            Button {
                var set = chosenCountries.isEmpty ? Set(current) : chosenCountries
                if set.contains(tag) { set.remove(tag) } else if set.count < 3 { set.insert(tag) }
                countriesRaw = set.sorted().joined(separator: ",")
            } label: {
                HStack {
                    Text(FoodCountries.name(forTag: tag, locale: AppLanguage.activeLocale)).foregroundStyle(ForgeColor.text)
                    Spacer()
                    if (chosenCountries.isEmpty ? Set(current) : chosenCountries).contains(tag) {
                        Image(systemName: "checkmark").foregroundStyle(ForgeColor.accent)
                    }
                }
            }
        }
    }

    private func refresh() async {
        installed = await FoodCatalog.shared.installedPacks()
        guard mode != .none, manifest == nil else { return }
        do {
            var request = URLRequest(url: FoodPackManifest.manifestURL, timeoutInterval: 20)
            request.setValue(FoodOnline.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            manifest = FoodPackManifest.decode(data)
            manifestFailed = manifest == nil
        } catch {
            manifestFailed = true
        }
    }

    private func download(_ pack: FoodPackManifest.Pack) async {
        guard let manifest, let url = manifest.url(for: pack) else { return }
        downloading = pack.country
        progress = 0
        failure = nil
        defer { downloading = nil }
        do {
            var request = URLRequest(url: url, timeoutInterval: 120)
            request.setValue(FoodOnline.userAgent, forHTTPHeaderField: "User-Agent")
            let (file, _) = try await URLSession.shared.download(for: request, delegate: ProgressDelegate { progress = $0 })
            defer { try? FileManager.default.removeItem(at: file) }
            try await FoodCatalog.shared.installPack(archive: file, expectedSha256: pack.sha256)
            await refresh()
        } catch FoodCatalog.Failure.notEnoughSpace {
            failure = String(localized: "There is not enough free space on this iPhone.")
        } catch {
            failure = String(localized: "The download did not work. The previous data is still there.")
        }
    }
}

/// Download progress for one task.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate {
    let report: @MainActor (Double) -> Void
    private var observation: NSKeyValueObservation?
    init(report: @escaping @MainActor (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in report(value) }
        }
    }
}
#endif
