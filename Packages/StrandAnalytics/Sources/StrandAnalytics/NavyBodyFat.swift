import Foundation

// MARK: - Body fat from circumferences (Hodgdon & Beckett)
//
// The US Navy circumference method, published by Hodgdon & Beckett (1984) and still the standard
// tape-measure estimate. It is citable the way Epley is — a named formula with known behaviour, not
// something invented here.
//
// WHAT IT IS GOOD AT, and what it is not. Against DEXA it carries an error band of roughly ±3–4
// PERCENTAGE POINTS, and — this is the part that matters — the error is largely a per-person BIAS
// rather than random noise: someone reading three points high tends to keep reading three points
// high. So the level is weak and the TREND is strong. A wearer watching their own number fall over
// two months is looking at something real; a wearer comparing their number to a friend's, or to a
// published category, is not. Every surface that shows this figure says so.
//
// TWO EQUATIONS, CHOSEN, NOT ASSUMED. Hodgdon & Beckett fitted separate equations on male and female
// cohorts, and they are not interchangeable — the female equation takes a hip measurement the male
// one does not. This type therefore takes the EQUATION as an explicit argument rather than deriving
// it from a profile's sex field. A person whose sex is recorded as nonbinary has no published variant
// to fall back on, and quietly picking one for them would be both a modelling error and a claim NOOP
// has no business making. The choice belongs to the person; this code only computes what it is asked.
//
// The equations, with every measurement in centimetres:
//
//   male:   495 / (1.0324  − 0.19077 · log₁₀(waist − neck)        + 0.15456 · log₁₀(height)) − 450
//   female: 495 / (1.29579 − 0.35004 · log₁₀(waist + hip − neck)  + 0.22100 · log₁₀(height)) − 450
//
// Nothing is clamped. A tape reading that produces an impossible result is a measurement problem —
// most often neck and waist swapped, or inches entered as centimetres — and returning a number
// anyway would hide it behind a plausible-looking figure.

/// Which published Hodgdon & Beckett equation to apply. Chosen by the wearer, never inferred.
public enum NavyEquation: String, Codable, Equatable, Sendable, CaseIterable {
    /// Takes neck, waist and height.
    case male
    /// Takes neck, waist, hip and height.
    case female

    /// Whether this equation needs a hip measurement. The capture surface asks for one only here.
    public var needsHip: Bool { self == .female }
}

/// The Navy circumference estimate of body-fat percentage.
public enum NavyBodyFat {

    /// The published error band against DEXA, in percentage points. Exposed so every surface that
    /// shows an estimate can state it rather than restating a number from memory.
    public static let errorBandPercentagePoints = 4.0

    /// What a human body can actually carry. A result outside this came from the tape, not the body:
    /// swapped neck and waist, or inches typed into a centimetre field. Returning nil surfaces that;
    /// clamping would bury it.
    public static let plausibleRange: ClosedRange<Double> = 3...70

    /// The estimate, or nil when the measurements cannot produce a meaningful one.
    ///
    /// Nil means one of three things, all of which are the caller's cue to question the input rather
    /// than to substitute a default: a measurement is missing or non-positive, the equation's
    /// circumference difference is not positive (so its logarithm is undefined), or the result falls
    /// outside `plausibleRange`.
    public static func percent(equation: NavyEquation, heightCm: Double, neckCm: Double,
                               waistCm: Double, hipCm: Double? = nil) -> Double? {
        guard heightCm > 0, neckCm > 0, waistCm > 0,
              heightCm.isFinite, neckCm.isFinite, waistCm.isFinite else { return nil }

        let result: Double
        switch equation {
        case .male:
            let girth = waistCm - neckCm
            guard girth > 0 else { return nil }
            result = 495 / (1.0324 - 0.19077 * log10(girth) + 0.15456 * log10(heightCm)) - 450
        case .female:
            guard let hipCm, hipCm > 0, hipCm.isFinite else { return nil }
            let girth = waistCm + hipCm - neckCm
            guard girth > 0 else { return nil }
            result = 495 / (1.29579 - 0.35004 * log10(girth) + 0.22100 * log10(heightCm)) - 450
        }

        guard result.isFinite, plausibleRange.contains(result) else { return nil }
        return result
    }
}
