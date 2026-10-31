import Foundation

/// SET_CLOCK (cmd 10) body for WHOOP 5/MG, with the sub-second part filled in.
///
/// The 8-byte form is `[seconds u32 LE][subseconds u32 LE]`, the subseconds in 1/32768 s: the unit of the
/// EVENT header u16 at frame 16, of the GET_CLOCK reply and of the alarm body (`AlarmPayload`). Sending 0
/// floors the phone time to the whole second, so a strap set that way starts up to a second behind before
/// any radio latency. A 2026-10-31 MG capture (fw 50.41.1.0) sat 1.3 to 2.1 s behind after each set while
/// its RTC drifted less than 3 ppm, so the offset came from the set, not from the crystal. OpenStrap and
/// meta1971/noop-mg-ecg send the same fraction on MG straps.
///
/// Only the low u16 can be non-zero (the fraction is below 32768); the high u16 stays 0 as before. WHOOP 4
/// keeps `BLEManager.setClockPayload`, whose zero fraction is what fw 41.17.x was validated with (#120).
///
/// Kotlin twin: `com.noop.protocol.SetClockPayload`.
public enum SetClockPayload {

    /// The 8-byte body for the instant `epochMs` (Unix milliseconds). Both halves come from that one
    /// instant, so the seconds and the fraction cannot straddle a second boundary.
    public static func withSubseconds(epochMs: Int64) -> [UInt8] {
        let ms = max(0, epochMs)
        let seconds = UInt32(clamping: ms / 1000)
        let subseconds = UInt32((ms % 1000) * 32768 / 1000)
        return [UInt8(seconds & 0xFF), UInt8((seconds >> 8) & 0xFF),
                UInt8((seconds >> 16) & 0xFF), UInt8((seconds >> 24) & 0xFF),
                UInt8(subseconds & 0xFF), UInt8((subseconds >> 8) & 0xFF), 0, 0]
    }
}
