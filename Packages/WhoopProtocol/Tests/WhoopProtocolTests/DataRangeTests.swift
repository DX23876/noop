import XCTest
@testable import WhoopProtocol

/// Byte-parity twin of the Kotlin `DataRangeScanTest`: `DataRange.newestUnix` offset/future-date
/// correctness (#451/#928/#1012). Same real WHOOP 4.0 GET_DATA_RANGE fixtures, so a Swift-side edit that
/// drifts from Kotlin fails here (the app-target copies were Kotlin-tested only before this extraction).
final class DataRangeTests: XCTestCase {

    private let skew48h = 48 * 3600         // AUTO_CONTINUE_FUTURE_SKEW_SECONDS twin
    private let wallNow = 1_783_786_000      // 2026-07-11 ~16:06, just after the captured newest
    private let realNewest = 1_783_785_625   // 2026-07-11 16:00:25 (frame a)

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map { off in
            let start = s.index(s.startIndex, offsetBy: off)
            let end = s.index(start, offsetBy: 2)
            return UInt8(s[start..<end], radix: 16)!
        }
    }

    /// Little-endian u32 `value` written at `offset` into a `size`-byte frame (rest zero).
    private func frameWithU32(_ size: Int, _ offset: Int, _ value: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: size)
        for k in 0..<4 { b[offset + k] = UInt8((value >> (8 * k)) & 0xFF) }
        return b
    }

    func testReadsRealWhoop4NewestAtByteOffset8() {
        // Three real captured frames → their true newest (offset-8 u32), all 2026-07-11 ~16:00.
        let expected: [(String, Int)] = [
            ("aa100057305d22009968526a083900001d2e2263", 1_783_785_625), // 16:00:25
            ("aa10005730612200a268526ab0290000e87d155d", 1_783_785_634), // 16:00:34
            ("aa100057307c2200e768526a78760000c997138d", 1_783_785_703), // 16:01:43
        ]
        for (h, ts) in expected {
            XCTAssertEqual(DataRange.newestUnix(from: hex(h), wallNowUnix: wallNow, futureSkewSeconds: skew48h),
                           ts, "newest for \(h) should be its offset-8 value, not nil")
        }
    }

    func testLoneFutureStraddleNeverBecomesFrontier() {
        let future = wallNow + 400 * 86_400
        var frame = frameWithU32(16, 4, realNewest)
        for k in 0..<4 { frame[10 + k] = UInt8((future >> (8 * k)) & 0xFF) }
        XCTAssertEqual(DataRange.newestUnix(from: frame, wallNowUnix: wallNow, futureSkewSeconds: skew48h),
                       realNewest)
    }

    func testAllFutureFrameStillReturnsFutureSoTheGuardFires() {
        let future = wallNow + 400 * 86_400
        XCTAssertEqual(DataRange.newestUnix(from: frameWithU32(12, 4, future),
                                            wallNowUnix: wallNow, futureSkewSeconds: skew48h), future)
    }

    func testValueJustInsideTheSkewIsPresentNotFuture() {
        let within = wallNow + 40 * 3600     // 40h ahead, under the 48h skew
        XCTAssertEqual(DataRange.newestUnix(from: frameWithU32(12, 4, within),
                                            wallNowUnix: wallNow, futureSkewSeconds: skew48h), within)
    }

    // MARK: - oldestUnix (aligned-from-7; asymmetric with newestUnix by design)

    /// The whole reason `oldestUnix` scans the aligned grid instead of every offset: the real WHOOP 4.0
    /// frame carries a spurious plausible straddle at byte offset 6 (1_754_857_506, ~11 months BEFORE the
    /// true newest at offset 8). An any-offset MIN would return it → a bogus deep backlog. The aligned grid
    /// skips it, so this frame (no distinct oldest word) → nil. Guards against a future "consistency" refactor.
    func testOldestAlignedScanSkipsTheSpuriousOffset6Straddle() {
        XCTAssertNil(DataRange.oldestUnix(from: hex("aa100057305d22009968526a083900001d2e2263")))
    }

    func testOldestReadsAGridAlignedWord() {
        XCTAssertEqual(DataRange.oldestUnix(from: frameWithU32(12, 7, 1_750_000_000)), 1_750_000_000)
    }

    func testOldestKeepsTheMinimumAcrossGridWords() {
        var frame = frameWithU32(16, 7, 1_800_000_000)              // grid offset 7
        for k in 0..<4 { frame[11 + k] = UInt8((1_750_000_000 >> (8 * k)) & 0xFF) } // grid offset 11
        XCTAssertEqual(DataRange.oldestUnix(from: frame), 1_750_000_000)
    }
}
