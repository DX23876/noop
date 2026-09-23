import Foundation

/// Decides whether an answer contains the expected value. Answers are free text in English or German, so
/// numbers are read with either decimal separator and days in the usual written forms.
public enum Scorer {

    public static func isCorrect(_ answer: String, _ expected: Expected) -> Bool {
        switch expected {
        case .number(let value, let tolerance, let signAgnostic):
            return numbers(in: answer).contains { candidate in
                abs(candidate - value) <= tolerance + 1e-9
                    || (signAgnostic && abs(abs(candidate) - abs(value)) <= tolerance + 1e-9)
            }
        case .integer(let value):
            return numbers(in: answer).contains { $0 == Double(value) }
        case .day(let key):
            return dayForms(key).contains { containsStandalone($0, in: answer) }
        }
    }

    /// Every number in the text, each read both ways where the separators are ambiguous ("8.123" is 8.123
    /// in English and 8123 in German; "2,9" is 2.9 in German).
    public static func numbers(in text: String) -> [Double] {
        var normalised = text.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "–", with: "-")
        // Dates are not quantities: "2026-07-26" would otherwise read as 2026, 7 and 26, and the German
        // "3.9." as 3.9 — each a chance to match an expected value by coincidence.
        for datePattern in [#"\d{4}-\d{2}-\d{2}"#, #"(?<![\d.,])\d{1,2}\.\d{1,2}\.(?:\d{2,4})?(?![\d,])"#] {
            normalised = normalised.replacingOccurrences(of: datePattern, with: " ", options: .regularExpression)
        }
        let pattern = try! NSRegularExpression(pattern: #"-?\d+(?:[.,]\d+)*"#)
        var out: [Double] = []
        for match in pattern.matches(in: normalised, range: NSRange(normalised.startIndex..., in: normalised)) {
            guard let range = Range(match.range, in: normalised) else { continue }
            let token = String(normalised[range])
            // A leading "-" directly after a letter or digit is a hyphen ("7-day"), not a sign.
            let start = range.lowerBound
            let signed: String
            if token.hasPrefix("-"), start > normalised.startIndex,
               normalised[normalised.index(before: start)].isLetter || normalised[normalised.index(before: start)].isNumber {
                signed = String(token.dropFirst())
            } else {
                signed = token
            }
            out += interpretations(signed)
        }
        return out
    }

    static func interpretations(_ token: String) -> [Double] {
        var results: [Double] = []
        // English: "," groups thousands, "." is the decimal point.
        if let v = Double(token.replacingOccurrences(of: ",", with: "")) { results.append(v) }
        // German: "." groups thousands, "," is the decimal point.
        if let v = Double(token.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")) {
            results.append(v)
        }
        return results
    }

    /// Whether `form` occurs in `text` without a digit glued to either side, so "3 September" does not
    /// match inside "13 September" and "3.9." not inside "13.9.".
    static func containsStandalone(_ form: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: form, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : " "
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : " "
            if !before.isNumber && !after.isNumber { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }

    static func dayForms(_ key: String) -> [String] {
        let parts = key.split(separator: "-").map(String.init)
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return [key] }
        let en = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                  "October", "November", "December"][m - 1]
        let de = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September",
                  "Oktober", "November", "Dezember"][m - 1]
        return [
            key,
            "\(d). \(de)", "\(d) \(en)", "\(en) \(d)", "\(en.prefix(3)) \(d)", "\(d) \(en.prefix(3))",
            String(format: "%02d.%02d.", d, m), "\(d).\(m).", "\(d). \(de.prefix(3))",
        ]
    }
}
