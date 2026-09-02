import Foundation
import WhoopProtocol

/// Pure parser for the standard BLE Heart Rate Measurement characteristic (0x2A37).
/// Returns the heart rate (bpm), R-R intervals (ms), and the contact state. Pure → unit-testable.
public enum StandardHeartRate {
    public static func parse(_ data: [UInt8]) -> (hr: Int, rr: [Int], contact: StandardHRContact)? {
        guard !data.isEmpty else { return nil }
        let flags = data[0]
        let contact = StandardHRContact.fromMeasurementFlags(flags)
        var idx = 1
        let hr: Int
        if flags & 0x01 != 0 {                       // 16-bit HR
            guard idx + 1 < data.count else { return nil }
            hr = Int(data[idx]) | (Int(data[idx + 1]) << 8); idx += 2
        } else {                                     // 8-bit HR
            guard idx < data.count else { return nil }
            hr = Int(data[idx]); idx += 1
        }
        if flags & 0x08 != 0 { idx += 2 }            // skip Energy Expended (bit 3)
        var rr: [Int] = []
        if (flags >> 4) & 0x01 != 0 {                // R-R present (bit 4)
            while idx + 1 < data.count {
                let raw = Int(data[idx]) | (Int(data[idx + 1]) << 8)
                rr.append(Int((Double(raw) / 1024.0 * 1000.0).rounded()))   // 1/1024 s → ms
                idx += 2
            }
        }
        return (hr, rr, contact)
    }
}
