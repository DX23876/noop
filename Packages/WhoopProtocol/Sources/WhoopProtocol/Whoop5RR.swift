import Foundation

/// WHOOP 5 type-40 and v18 interval words are already milliseconds.
/// Proven from 71 464 CRC-verified frames across 19 captures (firmware 50.41.1.0) by four
/// independent internal estimators — elapsed-time slope, phase feasibility, longest
/// self-consistent run, and HR-byte cross-check — all converging near 1000 words/second.
/// Transport parity with the standard BLE 0x2A37 characteristic (same raw words on both
/// channels) means WHOOP 5 sends millisecond values there too, non-compliant with the BLE
/// spec's 1/1024-second unit.
/// Keep this separate from WHOOP 4 decoding, whose existing millisecond contract is unchanged.
public enum Whoop5RR {
    public static func milliseconds(ticks: UInt16) -> Int {
        Int(ticks)
    }

    /// Labelled wire observations resolve an unknown registry entry, but cannot override another family.
    public static func usesCanonicalSource(model: String?, brand: String?, hasTaggedIntervals: Bool) -> Bool {
        if let brand, !brand.isEmpty, brand.caseInsensitiveCompare("WHOOP") != .orderedSame { return false }
        switch DeviceFamily.confirmedRegistryFamily(model: model, brand: brand) {
        case .whoop4: return false
        case .whoop5: return true
        case nil: return hasTaggedIntervals
        }
    }

}
