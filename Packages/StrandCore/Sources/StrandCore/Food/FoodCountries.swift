import Foundation

/// Open Food Facts country tags and their ISO 3166 codes, the same table `Tools/build_food_packs.py` uses
/// (`test_build_food_packs` checks they agree), so a country is named in the wearer's language on both apps.
public enum FoodCountries {
    public static let tagsByRegion: [String: String] = ["DE": "germany", "AT": "austria", "CH": "switzerland", "FR": "france", "BE": "belgium", "NL": "netherlands", "LU": "luxembourg", "IT": "italy", "ES": "spain", "PT": "portugal", "GB": "united-kingdom", "IE": "ireland", "US": "united-states", "CA": "canada", "MX": "mexico", "BR": "brazil", "AR": "argentina", "CL": "chile", "CO": "colombia", "PE": "peru", "DK": "denmark", "SE": "sweden", "NO": "norway", "FI": "finland", "IS": "iceland", "PL": "poland", "CZ": "czech-republic", "SK": "slovakia", "HU": "hungary", "RO": "romania", "BG": "bulgaria", "GR": "greece", "HR": "croatia", "SI": "slovenia", "RS": "serbia", "BA": "bosnia-and-herzegovina", "LT": "lithuania", "LV": "latvia", "EE": "estonia", "UA": "ukraine", "RU": "russia", "TR": "turkey", "IL": "israel", "MA": "morocco", "TN": "tunisia", "DZ": "algeria", "EG": "egypt", "ZA": "south-africa", "IN": "india", "JP": "japan", "KR": "south-korea", "CN": "china", "TW": "taiwan", "HK": "hong-kong", "SG": "singapore", "TH": "thailand", "MY": "malaysia", "ID": "indonesia", "PH": "philippines", "VN": "vietnam", "AU": "australia", "NZ": "new-zealand", "SA": "saudi-arabia", "AE": "united-arab-emirates", "RE": "reunion", "GP": "guadeloupe", "MQ": "martinique", "GF": "french-guiana", "NC": "new-caledonia", "PF": "french-polynesia", "CY": "cyprus", "MT": "malta", "AL": "albania", "MK": "north-macedonia", "MD": "moldova", "BY": "belarus", "KZ": "kazakhstan", "LB": "lebanon", "JO": "jordan"]

    public static func tag(forRegion region: String) -> String? { tagsByRegion[region.uppercased()] }

    public static func region(forTag tag: String) -> String? {
        tagsByRegion.first { $0.value == tag }?.key
    }

    /// The country's name in `locale`, or the tag in readable form for a country the table lacks.
    public static func name(forTag tag: String, locale: Locale) -> String {
        if let region = region(forTag: tag), let name = locale.localizedString(forRegionCode: region) { return name }
        return tag.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
