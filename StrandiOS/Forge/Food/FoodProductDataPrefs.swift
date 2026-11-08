#if os(iOS)
import Foundation
import StrandCore
import StrandAnalytics

/// Where product data comes from, as the wearer chose it after installing (decision 2026-11-08). Same keys as
/// Android's `FoodDataPrefs`.
enum FoodProductDataPrefs {
    static let modeKey = "food.productData.mode"
    static let countriesKey = "food.productData.countries"
    static let unknownBarcodesOnlineKey = "food.productData.unknownBarcodesOnline"

    static var mode: FoodProductDataMode {
        FoodProductDataMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .none
    }

    /// Open Food Facts country tags for the online filter; the phone's region when none was chosen.
    static var countries: [String] {
        let saved = (UserDefaults.standard.string(forKey: countriesKey) ?? "").split(separator: ",").map(String.init)
        if !saved.isEmpty { return saved }
        return [FoodCountries.tag(forRegion: Locale.current.region?.identifier ?? "DE") ?? "germany"]
    }

    static var language: String { AppLanguage.activeLocale.language.languageCode?.identifier ?? "de" }

    /// Whether a barcode the phone does not know may be looked up online.
    static var looksUpOnline: Bool {
        mode == .online || (mode == .packs && UserDefaults.standard.bool(forKey: unknownBarcodesOnlineKey))
    }
}
#endif
