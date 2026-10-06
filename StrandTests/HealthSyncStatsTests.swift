import XCTest
@testable import Strand

/// #1578: the Apple Health observer path had no instrumentation at all, so neither the battery report
/// that prompted this nor the coalescing fix that came with it could be evaluated from a log.
///
/// These pin the header line, and one arithmetic case that the fix itself makes likely.
@MainActor
final class HealthSyncStatsTests: XCTestCase {

    override func setUp() async throws { HealthSyncStats.reset() }
    override func tearDown() async throws { HealthSyncStats.reset() }

    /// Silent when the observer path never ran.
    ///
    /// Most logs come from people with Health off or unauthorized. A line of zeros in every one of those
    /// is noise that trains a reader to skip the block — and this block is meant to be read.
    func testItSaysNothingWhenHealthSyncNeverRan() {
        XCTAssertTrue(HealthSyncStats.summaryLines().isEmpty)
    }

    /// The exact line.
    func testTheLineIsExactlyThis() {
        HealthSyncStats.recordWake(); HealthSyncStats.recordSync(millis: 800)
        HealthSyncStats.recordWake(); HealthSyncStats.recordSync(millis: 1200)
        HealthSyncStats.recordWake(); HealthSyncStats.recordCoalesced()
        HealthSyncStats.recordWake(); HealthSyncStats.recordEmptyWake()
        XCTAssertEqual(HealthSyncStats.summaryLines(),
                       ["Health sync: wakes=4 synced=2 coalesced=1 empty=1 avgSyncMs=1000",
                        "Health writes: saved=0 deleted=0 quietSyncs=2 lastSync=0/0"])
    }

    /// The case the fix is TRYING to produce: every wake coalesced, so no sync ran.
    ///
    /// `syncMillis / syncs` divides by zero there. A working coalescer would therefore crash the log
    /// export — on exactly the phones where it worked best — so this is pinned rather than assumed.
    func testAnAllCoalescedSessionDoesNotDivideByZero() {
        for _ in 0 ..< 6 { HealthSyncStats.recordWake(); HealthSyncStats.recordCoalesced() }
        XCTAssertEqual(HealthSyncStats.summaryLines(),
                       ["Health sync: wakes=6 synced=0 coalesced=6 empty=0 avgSyncMs=0",
                        "Health writes: saved=0 deleted=0 quietSyncs=0 lastSync=0/0"])
    }

    /// Wakes are counted separately from syncs on purpose.
    ///
    /// Coalescing reduces work per wake, NOT the number of wakes — iOS still resumes the process for every
    /// observer notification. A log showing many wakes and few syncs says the coalescing works and that
    /// what remains is the wake itself, which needs a different fix (fewer observers) rather than more of
    /// this one. If these two ever collapsed into one counter that signal would be lost.
    func testWakesAndSyncsAreCountedSeparately() {
        for _ in 0 ..< 10 { HealthSyncStats.recordWake() }
        HealthSyncStats.recordSync(millis: 500)
        let line = HealthSyncStats.summaryLines().first ?? ""
        XCTAssertTrue(line.contains("wakes=10"), line)
        XCTAssertTrue(line.contains("synced=1"), line)
    }

    /// A negative duration (a wall-clock correction mid-pass) must not drag the average below zero.
    func testANegativeDurationIsFloored() {
        HealthSyncStats.recordWake(); HealthSyncStats.recordSync(millis: -5_000)
        XCTAssertEqual(HealthSyncStats.summaryLines(),
                       ["Health sync: wakes=1 synced=1 coalesced=0 empty=0 avgSyncMs=0",
                        "Health writes: saved=0 deleted=0 quietSyncs=1 lastSync=0/0"])
    }

    /// Writes are attributed to the sync they happened in, and a sync that wrote nothing counts as quiet.
    /// This is the line that tells an idle sync apart from one that rewrites hours of heart rate.
    func testWritesAreAttributedToTheirSync() {
        HealthSyncStats.beginSync()
        HealthSyncStats.recordSaved(2_880); HealthSyncStats.recordDeleted(2_880)
        HealthSyncStats.recordSync(millis: 900)
        HealthSyncStats.beginSync()
        HealthSyncStats.recordSync(millis: 100)
        XCTAssertEqual(HealthSyncStats.summaryLines().last,
                       "Health writes: saved=2880 deleted=2880 quietSyncs=1 lastSync=0/0")
    }

    /// A foreground sync with no observer wake still reports, since it writes back too.
    func testAForegroundSyncWithoutWakesStillReports() {
        HealthSyncStats.beginSync()
        HealthSyncStats.recordSaved(3)
        HealthSyncStats.recordSync(millis: 50)
        XCTAssertEqual(HealthSyncStats.summaryLines(),
                       ["Health sync: wakes=0 synced=1 coalesced=0 empty=0 avgSyncMs=50",
                        "Health writes: saved=3 deleted=0 quietSyncs=0 lastSync=3/0"])
    }
}
