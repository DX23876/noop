import Foundation

/// How one reading sits against a range.
public enum LabRangeStatus: String, Sendable, Equatable {
    case low, inRange, high
}

/// A range to read a marker against, and whose range it is.
public struct LabReferenceRange: Sendable, Equatable {
    public enum Origin: Sendable, Equatable {
        /// Typed from the wearer's own lab report. It knows the lab's method, so it always wins.
        case ownReport
        /// The general adult figure below.
        case general
    }

    public let lower: Double?
    public let upper: Double?
    public let origin: Origin

    public init(lower: Double?, upper: Double?, origin: Origin) {
        self.lower = lower
        self.upper = upper
        self.origin = origin
    }

    public func status(of value: Double) -> LabRangeStatus {
        if let lower, value < lower { return .low }
        if let upper, value > upper { return .high }
        return .inRange
    }
}

/// General adult ranges for the catalog's blood and blood-pressure markers, in each marker's canonical unit.
///
/// Decided 2026-11-03 at the owner's request (see `docs/fork/decisions.md`): the logbook says whether a value
/// is high, in range or low. These are orientation only. A lab's own range differs by method, age and sex,
/// which is why a range the wearer typed from the report takes precedence, and why a reading in another unit
/// gets no rating rather than a converted guess. Where a limit differs by sex the wider one stands, so a rating
/// errs on the side of saying nothing.
///
/// Sources: ESC/EAS 2019 (LDL, total cholesterol, triglycerides), NCEP ATP III (HDL), ADA Standards of Care
/// (fasting glucose, HbA1c), IOM 2011 (vitamin D), WHO 2011 and 2020 (haemoglobin, ferritin), KDIGO 2012
/// (eGFR), ACC/AHA 2017 (blood pressure). The remaining markers use the common clinical laboratory intervals.
public enum LabReferenceRanges {
    private static let general: [String: (lower: Double?, upper: Double?, unit: String)] = [
        "total_cholesterol": (nil, 5.2, "mmol/L"),
        "ldl": (nil, 3.0, "mmol/L"),
        "hdl": (1.0, nil, "mmol/L"),
        "triglycerides": (nil, 1.7, "mmol/L"),
        "fasting_glucose": (3.9, 5.5, "mmol/L"),
        "hba1c": (nil, 38, "mmol/mol"),
        "ferritin": (15, 300, "µg/L"),
        "iron": (10, 30, "µmol/L"),
        "transferrin_saturation": (20, 50, "%"),
        "haemoglobin": (120, 175, "g/L"),
        "vitamin_d": (50, 125, "nmol/L"),
        "vitamin_b12": (200, 900, "ng/L"),
        "folate": (4, 20, "µg/L"),
        "tsh": (0.4, 4.0, "mIU/L"),
        "free_t4": (12, 22, "pmol/L"),
        "crp": (nil, 5, "mg/L"),
        "egfr": (60, nil, "mL/min/1.73m²"),
        "creatinine": (45, 110, "µmol/L"),
        "alt": (nil, 45, "U/L"),
        "ast": (nil, 40, "U/L"),
        "ggt": (nil, 60, "U/L"),
        "sodium": (135, 145, "mmol/L"),
        "potassium": (3.5, 5.1, "mmol/L"),
        "bp_systolic": (90, 129, "mmHg"),
        "bp_diastolic": (60, 79, "mmHg"),
        "resting_pulse": (nil, 100, "bpm"),
    ]

    /// The range this reading is read against, or nil when there is none it can honestly use.
    public static func range(markerKey: String, unit: String, referenceText: String?) -> LabReferenceRange? {
        if let own = parse(referenceText) { return own }
        guard let entry = general[markerKey], entry.unit == unit.trimmingCharacters(in: .whitespaces) else { return nil }
        return LabReferenceRange(lower: entry.lower, upper: entry.upper, origin: .general)
    }

    /// Reads "3.5-5.1", "3,5 – 5,1", "< 3.0" or "> 1.0" from a report's reference column; nil for anything else.
    public static func parse(_ text: String?) -> LabReferenceRange? {
        guard let text else { return nil }
        let cleaned = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        let number = #"(\d+(?:\.\d+)?)"#
        if let match = cleaned.firstMatch(of: try! Regex("^\(number)\\s*(?:-|–|—|to|bis)\\s*\(number)")),
           let low = match.output[1].substring.flatMap({ Double($0) }),
           let high = match.output[2].substring.flatMap({ Double($0) }), low <= high {
            return LabReferenceRange(lower: low, upper: high, origin: .ownReport)
        }
        if let match = cleaned.firstMatch(of: try! Regex("^(?:<|≤|<=)\\s*\(number)")),
           let high = match.output[1].substring.flatMap({ Double($0) }) {
            return LabReferenceRange(lower: nil, upper: high, origin: .ownReport)
        }
        if let match = cleaned.firstMatch(of: try! Regex("^(?:>|≥|>=)\\s*\(number)")),
           let low = match.output[1].substring.flatMap({ Double($0) }) {
            return LabReferenceRange(lower: low, upper: nil, origin: .ownReport)
        }
        return nil
    }
}
