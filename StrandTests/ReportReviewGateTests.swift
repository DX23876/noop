import XCTest
@testable import Strand
import StrandAnalytics

/// The review-before-share gate is mandatory and not skippable (spec sections 9, 12). It must surface
/// the exact text the user is about to share (so they can redact), and only clear on an explicit
/// confirm. A fresh gate, or one the user dismissed, never reports cleared.
final class ReportReviewGateTests: XCTestCase {

    private func sampleEntries() -> [FileExport.BundleEntry] {
        [FileExport.BundleEntry(name: "report.txt",
                                data: Data("NOOP strap log\nline 1\nline 2".utf8))]
    }

    func testFreshGateIsNotCleared() {
        let gate = ReportReviewGate(entries: sampleEntries())
        XCTAssertFalse(gate.isCleared)
    }

    func testPreviewShowsTheReportTextUserWillShare() {
        let gate = ReportReviewGate(entries: sampleEntries())
        XCTAssertTrue(gate.previewText.contains("line 1"))
        XCTAssertTrue(gate.previewText.contains("line 2"))
    }

    func testConfirmClearsAndCancelDoesNot() {
        var gate = ReportReviewGate(entries: sampleEntries())
        gate.cancel()
        XCTAssertFalse(gate.isCleared)
        gate.confirm()
        XCTAssertTrue(gate.isCleared)
    }

    /// The large raw research streams (raw-capture + the Oura Tier-B sidecars) must NEVER be inlined into
    /// the preview: laying out a multi-MB `oura-raw.jsonl` as one SwiftUI Text pinned the main thread in
    /// CoreText glyph layout (>1 GB, hung). They are still NAMED so the review stays honest.
    func testLargeRawStreamsAreNamedNotInlined() {
        let bigOura = String(repeating: "A", count: 2 * 1024 * 1024)   // 2 MB of would-be inline text
        let entries = [
            FileExport.BundleEntry(name: "report.txt", data: Data("visible report body".utf8)),
            FileExport.BundleEntry(name: "raw-capture.jsonl", data: Data("raw whoop bytes".utf8)),
            FileExport.BundleEntry(name: "oura-raw.jsonl", data: Data(bigOura.utf8)),
            FileExport.BundleEntry(name: "oura-ibihr.jsonl", data: Data("ring hr".utf8)),
            FileExport.BundleEntry(name: "oura-activity.jsonl", data: Data("ring met".utf8)),
        ]
        let preview = ReportReviewGate(entries: entries).previewText
        // report.txt is shown in full…
        XCTAssertTrue(preview.contains("visible report body"))
        // …but none of the large stream CONTENT is inlined (the 2 MB blob never reaches the Text).
        XCTAssertFalse(preview.contains(bigOura))
        XCTAssertFalse(preview.contains("=== oura-raw.jsonl ===\nA"))
        // Every excluded stream is still NAMED under the attached note, so the review is honest.
        for name in ["raw-capture.jsonl", "oura-raw.jsonl", "oura-ibihr.jsonl", "oura-activity.jsonl"] {
            XCTAssertTrue(preview.contains(name), "\(name) must be named in the review")
        }
        // The whole preview stays tiny regardless of the 2 MB stream.
        XCTAssertLessThan(preview.count, 10_000)
    }
}
