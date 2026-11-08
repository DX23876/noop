#if os(iOS)
import SwiftUI
import StrandCore
import StrandAnalytics

/// Up to three countries for the online search filter.
struct FoodCountriesSection: View {
    let offered: [String]?
    @AppStorage(FoodProductDataPrefs.countriesKey) private var countriesRaw = ""

    private var chosen: Set<String> {
        let saved = Set(countriesRaw.split(separator: ",").map(String.init))
        return saved.isEmpty ? Set(FoodProductDataPrefs.countries) : saved
    }

    private var tags: [String] {
        (offered ?? Array(FoodCountries.tagsByRegion.values)).sorted { name($0) < name($1) }
    }

    var body: some View {
        Section {
            ForEach(tags, id: \.self) { tag in
                Button { toggle(tag) } label: {
                    LabeledContent(name(tag)) {
                        if chosen.contains(tag) { Image(systemName: "checkmark").foregroundStyle(ForgeColor.accent) }
                    }
                }
                .foregroundStyle(ForgeColor.text)
                .accessibilityAddTraits(chosen.contains(tag) ? .isSelected : [])
            }
        } header: {
            Text("Countries to search")
        } footer: {
            Text("Up to three.")
        }
    }

    private func name(_ tag: String) -> String { FoodCountries.name(forTag: tag, locale: AppLanguage.activeLocale) }

    private func toggle(_ tag: String) {
        var set = chosen
        if set.contains(tag) { set.remove(tag) } else if set.count < 3 { set.insert(tag) }
        countriesRaw = set.sorted().joined(separator: ",")
    }
}
#endif
