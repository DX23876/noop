import Foundation

/// What a nutrition label said, read from the text the phone recognised on it (Vision on Apple, Tesseract on
/// Android). Pure and platform-neutral, so both apps read a label the same way. The wearer checks every value
/// in a form before anything is saved; this only fills the form.
public struct NutritionLabelReading: Equatable, Sendable {
    public enum Basis: String, Sendable { case per100g, per100ml }

    /// Canonical nutrient keys (`FoodNutrient` raw values in StrandCore) per 100 g or 100 ml.
    public var per100: [String: Double]
    public var basis: Basis
    /// The portion the label names ("Portion (30 g)"), when it names one in grams or millilitres.
    public var servingAmount: Double?

    /// Energy and the three macronutrients were all found: enough to log the food.
    public var isComplete: Bool {
        ["energy_kcal", "protein_g", "carbs_g", "fat_g"].allSatisfy { per100[$0] != nil }
    }
}

public enum NutritionLabelParser {
    /// Label words in German and English, most specific first, so "davon gesättigte Fettsäuren" is read as
    /// saturated fat before "Fett" can claim it.
    static let labels: [(key: String, patterns: [String])] = [
        ("sat_fat_g", ["gesattigte fettsauren", "gesattigte", "saturates", "saturated fat", "saturated"]),
        ("mono_fat_g", ["einfach ungesattigte", "monounsaturates", "monounsaturated"]),
        ("poly_fat_g", ["mehrfach ungesattigte", "polyunsaturates", "polyunsaturated"]),
        ("sugar_g", ["zucker", "sugars", "sugar"]),
        ("fiber_g", ["ballaststoffe", "fibre", "fiber"]),
        ("fat_g", ["fett", "fat"]),
        ("carbs_g", ["kohlenhydrate", "kohlenhydrat", "carbohydrates", "carbohydrate", "carbs"]),
        ("protein_g", ["eiweiss", "protein"]),
        ("salt_g", ["salz", "salt"]),
        ("sodium_mg", ["natrium", "sodium"]),
        ("energy_kcal", ["brennwert", "energiewert", "energie", "energy", "kalorien", "calories"]),
    ]

    public static func parse(lines raw: [String]) -> NutritionLabelReading {
        let lines = raw.map(normalise).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let joined = lines.joined(separator: " ")
        let basis: NutritionLabelReading.Basis = joined.range(of: #"100\s?ml"#, options: .regularExpression) != nil
            && joined.range(of: #"100\s?g\b"#, options: .regularExpression) == nil ? .per100ml : .per100g
        var per100: [String: Double] = [:]
        var waiting: [String] = []   // labels read without a number, for labels printed as a column
        var numberLines: [[Double]] = []

        for line in lines {
            if let key = label(in: line) {
                if key == "energy_kcal", let kcal = energyKcal(in: line) {
                    if per100[key] == nil { per100[key] = kcal }
                } else if key != "energy_kcal", let value = numbers(in: afterLabel(line, key)).first {
                    if per100[key] == nil { per100[key] = value }
                } else if per100[key] == nil {
                    waiting.append(key)
                }
            } else if !line.contains(where: \.isLetter) || line.range(of: #"^[\d\s.,<>~kcaljmg()/%]+$"#,
                                                                     options: .regularExpression) != nil {
                let values = numbers(in: line)
                if !values.isEmpty { numberLines.append(values) }
                if let kcal = energyKcal(in: line), waiting.first == "energy_kcal" {
                    per100["energy_kcal"] = kcal
                    waiting.removeFirst()
                    numberLines.removeLast()
                }
            }
        }
        // A column of labels and a column of numbers, read one after the other: pair them in order.
        for (key, values) in zip(waiting, numberLines) where per100[key] == nil {
            if let first = values.first { per100[key] = first }
        }
        if per100["salt_g"] == nil, let sodium = per100["sodium_mg"] { per100["salt_g"] = sodium * 2.5 / 1000 }
        if per100["sodium_mg"] == nil, let salt = per100["salt_g"] { per100["sodium_mg"] = salt / 2.5 * 1000 }
        per100 = per100.filter { key, value in
            value.isFinite && value >= 0 && (key == "energy_kcal" ? value <= 950 : key == "sodium_mg" ? value <= 40_000 : value <= 100)
        }
        return NutritionLabelReading(per100: per100, basis: basis, servingAmount: serving(in: joined))
    }

    // MARK: Pieces

    /// Lower case, accents folded, decimal commas as points, OCR's usual letter-for-digit slips undone inside numbers.
    static func normalise(_ line: String) -> String {
        var text = line.lowercased()
        for (from, to) in [("ä", "a"), ("ö", "o"), ("ü", "u"), ("ß", "ss"), ("é", "e"), ("è", "e"), ("à", "a")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        text = text.replacingOccurrences(of: #"(\d),(\d)"#, with: "$1.$2", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<=\d)[oO](?=\d|\s?g\b)"#, with: "0", options: .regularExpression)
        return text
    }

    static func label(in line: String) -> String? {
        for entry in labels {
            for pattern in entry.patterns where line.range(of: #"\b"# + pattern, options: .regularExpression) != nil {
                return entry.key
            }
        }
        return nil
    }

    /// The text after the label word, so "Fett 3.1 g" reads 3.1 and not a number before the word.
    static func afterLabel(_ line: String, _ key: String) -> String {
        guard let entry = labels.first(where: { $0.key == key }) else { return line }
        for pattern in entry.patterns {
            if let range = line.range(of: #"\b"# + pattern + #"[a-z]*"#, options: .regularExpression) {
                return String(line[range.upperBound...])
            }
        }
        return line
    }

    /// Numbers in reading order. "<0.5" reads 0.5, "Spuren"/"traces" read 0.
    static func numbers(in text: String) -> [Double] {
        if text.range(of: #"\b(spuren|traces?)\b"#, options: .regularExpression) != nil { return [0] }
        let regex = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)"#)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            Double(ns.substring(with: $0.range(at: 1)))
        }
    }

    /// kcal from an energy line: the number before "kcal", or kJ / 4.184 when only kilojoules are printed.
    static func energyKcal(in line: String) -> Double? {
        if let match = first(#"(\d+(?:\.\d+)?)\s?kcal"#, in: line) { return match }
        if let kj = first(#"(\d+(?:\.\d+)?)\s?kj"#, in: line) { return (kj / 4.184 * 10).rounded() / 10 }
        return nil
    }

    static func serving(in text: String) -> Double? {
        for pattern in [#"(?:portion|serving|pro portion|per portion|per serving)\D{0,12}(\d+(?:\.\d+)?)\s?(?:g|ml)\b"#,
                        #"(\d+(?:\.\d+)?)\s?(?:g|ml)\s?(?:portion|serving)"#] {
            if let value = first(pattern, in: text), value > 0, value != 100 { return value }
        }
        return nil
    }

    private static func first(_ pattern: String, in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Double(ns.substring(with: match.range(at: 1)))
    }
}
