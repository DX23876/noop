import XCTest
@testable import Strand

/// Pins the safe-fallback half of `.localizedCatalogValue` (#P14): every call site that uses it —
/// `CoachView`'s header, `CoachGoalView.field`, the `statusLine` helpers — relies on it passing DYNAMIC,
/// non-catalog content (a user-typed title, a formatted date) straight through unchanged rather than
/// mangling it. The catalog-HIT path (a real translation) needs a compiled app bundle to verify and isn't
/// covered here; this is the invariant that keeps dynamic content safe regardless of that.
final class LocalizedCatalogValueTests: XCTestCase {

    func testUnknownStringPassesThroughUnchanged() {
        let s = "definitely-not-a-catalog-key-\(UUID().uuidString)"
        XCTAssertEqual(s.localizedCatalogValue, s)
    }

    func testEmptyStringPassesThroughUnchanged() {
        XCTAssertEqual("".localizedCatalogValue, "")
    }

    /// A realistic case: a user-typed conversation title or goal title that happens to collide with
    /// nothing in the catalog must reach the screen exactly as typed.
    func testUserTypedContentIsUnaffected() {
        let title = "My 5am rides"
        XCTAssertEqual(title.localizedCatalogValue, title)
    }
}
