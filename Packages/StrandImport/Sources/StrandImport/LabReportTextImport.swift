import Foundation

// MARK: - Local lab-report text extraction (review required)
//
// This is deliberately a narrow helper, not a clinical document interpreter. It recognises only a
// known marker label immediately followed by a finite numeric token. It does not infer a diagnosis,
// convert units, read reference ranges, or persist anything. The app must show every candidate to the
// user and obtain confirmation before it creates a Lab Book row.

/// One non-diagnostic, locally extracted candidate. The value and unit are copied exactly from the
/// report text (apart from numeric punctuation normalisation needed to parse a `Double`).
public struct LabReportTextCandidate: Sendable, Equatable, Identifiable {
    public let markerKey: String
    public let category: LabMarkerCategory
    public let value: Double
    public let unit: String

    public var id: String { markerKey + "\u{1}" + unit + "\u{1}" + String(value) }

    public init(markerKey: String, category: LabMarkerCategory, value: Double, unit: String) {
        self.markerKey = markerKey
        self.category = category
        self.value = value
        self.unit = unit
    }
}

/// Candidates from a text-based report. No date is guessed: the review UI asks the person to select
/// the report date before saving. `skippedLines` is informational only and never names the file.
public struct LabReportTextImportResult: Sendable, Equatable {
    public let candidates: [LabReportTextCandidate]
    public let skippedLines: Int
    public let textTooLarge: Bool

    public init(candidates: [LabReportTextCandidate], skippedLines: Int, textTooLarge: Bool) {
        self.candidates = candidates
        self.skippedLines = skippedLines
        self.textTooLarge = textTooLarge
    }
}

/// Text extraction for a PDF's embedded text (or a future on-device OCR result). It intentionally
/// accepts no file URL and performs no I/O, so it stays pure, testable and usable on both platforms.
public enum LabReportTextImport {
    /// A report should contain only a few pages of text. Bound the work before regular-expression scans.
    public static let maxCharacters = 500_000
    /// Provenance written by the app only after the user accepts the review sheet.
    public static let sourceId = "lab-document"

    public static func parse(text: String) -> LabReportTextImportResult {
        guard text.count <= maxCharacters else {
            return LabReportTextImportResult(candidates: [], skippedLines: 0, textTooLarge: true)
        }

        var byMarker: [String: LabReportTextCandidate] = [:]
        var skipped = 0
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let extracted = candidates(in: trimmed)
            if extracted.isEmpty { skipped += 1 }
            for candidate in extracted { byMarker[candidate.markerKey] = candidate }
        }
        return LabReportTextImportResult(
            candidates: byMarker.values.sorted { $0.markerKey < $1.markerKey },
            skippedLines: skipped,
            textTooLarge: false
        )
    }

    private static func candidates(in line: String) -> [LabReportTextCandidate] {
        var found: [LabReportTextCandidate] = []

        // Blood pressure is the one legitimate compound value. Preserve both values, never discard the
        // diastolic half. A user still sees and confirms both before either is stored.
        if matchesLabel(line, labels: ["blood pressure", "bp"]),
           let pair = firstNumberPair(afterKnownLabelIn: line) {
            found.append(.init(markerKey: "bp_systolic", category: .bloodPressure,
                               value: pair.systolic, unit: "mmHg"))
            found.append(.init(markerKey: "bp_diastolic", category: .bloodPressure,
                               value: pair.diastolic, unit: "mmHg"))
        }

        for definition in MarkerCatalog.builtIn {
            guard let suffix = suffixAfterKnownLabel(in: line, labels: labels(for: definition)) else { continue }
            guard let match = firstValueAndUnit(in: suffix),
                  let value = LabMarkerCsvImport.parseValue(match.value) else { continue }
            found.append(.init(markerKey: definition.key, category: definition.category, value: value,
                               unit: match.unit.isEmpty ? definition.canonicalUnit : match.unit))
        }
        return found
    }

    private static func labels(for definition: MarkerDefinition) -> [String] {
        var labels = [definition.displayName, definition.key.replacingOccurrences(of: "_", with: " ")]
        switch definition.key {
        case "hba1c": labels += ["A1c", "Hb A1c"]
        case "vitamin_d": labels += ["Vitamin D3", "25-OH Vitamin D", "Vit D"]
        case "vitamin_b12": labels += ["B12", "Vit B12"]
        case "haemoglobin": labels += ["Hemoglobin", "Hb"]
        case "crp": labels += ["hs-CRP", "C reactive protein"]
        case "free_t4": labels += ["FT4"]
        case "bp_systolic": labels += ["Systolic", "SBP"]
        case "bp_diastolic": labels += ["Diastolic", "DBP"]
        default: break
        }
        return labels.sorted { $0.count > $1.count }
    }

    private static func matchesLabel(_ line: String, labels: [String]) -> Bool {
        suffixAfterKnownLabel(in: line, labels: labels) != nil
    }

    /// Returns only text after a standalone label. Requiring a delimiter around the label prevents e.g.
    /// `AST` from matching inside an unrelated word.
    private static func suffixAfterKnownLabel(in line: String, labels: [String]) -> String? {
        for label in labels {
            let escaped = NSRegularExpression.escapedPattern(for: label)
            let pattern = "(?i)(?:^|[\\s|])\(escaped)(?=$|[\\s:=|])"
            guard let range = line.range(of: pattern, options: .regularExpression) else { continue }
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func firstNumberPair(afterKnownLabelIn line: String) -> (systolic: Double, diastolic: Double)? {
        guard let suffix = suffixAfterKnownLabel(in: line, labels: ["blood pressure", "bp"]) else { return nil }
        let valueStart = suffix.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":=")))
        let token = valueStart.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first.map(String.init) ?? ""
        return LabMarkerCsvImport.bloodPressurePair(token)
    }

    private static func firstValueAndUnit(in suffix: String) -> (value: String, unit: String)? {
        let pattern = "^[\\s:=]*([+-]?[0-9][0-9.,]*)(?:[\\s]*([^\\s()\\[\\],;]+))?"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: suffix, range: NSRange(suffix.startIndex..., in: suffix)),
              let valueRange = Range(match.range(at: 1), in: suffix) else { return nil }
        let unit = match.range(at: 2).location == NSNotFound
            ? "" : Range(match.range(at: 2), in: suffix).map { String(suffix[$0]) } ?? ""
        return (String(suffix[valueRange]), unit)
    }
}
