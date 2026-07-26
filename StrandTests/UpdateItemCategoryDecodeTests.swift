import XCTest
@testable import Strand

/// Regression guard: `UpdateItem` gained `category`/`priority`/`expiresAt`/`actionRequired`/
/// `planProposalId`/`showOnToday` after rows were already persisted on-device with none of those keys.
/// A row like this MUST still decode, and must fall back to `Kind.defaultCategory` — the concrete proof
/// that an existing inbox survives the update instead of dropping every row.
final class UpdateItemCategoryDecodeTests: XCTestCase {

    /// A hand-written pre-category `UpdateItem` JSON blob — exactly the shape the old, compiler-
    /// synthesized `Codable` conformance wrote to disk. `"date":700000000` matches the fixed reference
    /// date already used by this suite's other legacy-decode tests.
    private func legacyItemJSON(kind: String) -> Data {
        """
        [{"id":"\(UUID().uuidString)","kind":"\(kind)","title":"T","message":"M",
          "date":700000000,"read":false}]
        """.data(using: .utf8)!
    }

    private func decodeLegacy(kind: String) throws -> UpdateItem {
        let items = try JSONDecoder().decode([UpdateItem].self, from: legacyItemJSON(kind: kind))
        return try XCTUnwrap(items.first)
    }

    func testLegacyDismissedCardDefaultsToStatusReminder() throws {
        XCTAssertEqual(try decodeLegacy(kind: "dismissedCard").category, .statusReminder)
    }

    func testLegacyWhatsNewDefaultsToInformative() throws {
        XCTAssertEqual(try decodeLegacy(kind: "whatsNew").category, .informative)
    }

    func testLegacyReadingDefaultsToInformative() throws {
        XCTAssertEqual(try decodeLegacy(kind: "reading").category, .informative)
    }

    func testLegacyStrapAlertDefaultsToStatusReminder() throws {
        XCTAssertEqual(try decodeLegacy(kind: "strapAlert").category, .statusReminder)
    }

    /// Every other new field must fall back to a safe, inert default on a legacy row.
    func testLegacyItemsDefaultToSafeValues() throws {
        let item = try decodeLegacy(kind: "reading")
        XCTAssertEqual(item.priority, .normal)
        XCTAssertNil(item.expiresAt)
        XCTAssertFalse(item.actionRequired)
        XCTAssertNil(item.planProposalId)
        XCTAssertFalse(item.showOnToday)
    }

    /// A freshly-constructed item (going through the memberwise init, not decode) still resolves its
    /// default category from `Kind.defaultCategory` when `category` isn't explicitly passed.
    func testMemberwiseInitDefaultsCategoryFromKind() {
        let item = UpdateItem(kind: .dismissedCard, title: "T", message: "M")
        XCTAssertEqual(item.category, .statusReminder)
    }

    /// A full round trip (encode with all new fields set, decode back) preserves every value — confirms
    /// `encode(to:)` staying compiler-synthesized still writes the new fields going forward.
    func testRoundTripPreservesNewFields() throws {
        let proposalId = UUID()
        let expiry = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let original = UpdateItem(kind: .dismissedCard, title: "T", message: "M",
                                  category: .actionable, priority: .high,
                                  expiresAt: expiry, actionRequired: true,
                                  planProposalId: proposalId, showOnToday: true)
        let decoded = try JSONDecoder().decode(UpdateItem.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.category, .actionable)
        XCTAssertEqual(decoded.priority, .high)
        XCTAssertEqual(decoded.expiresAt, expiry)
        XCTAssertTrue(decoded.actionRequired)
        XCTAssertEqual(decoded.planProposalId, proposalId)
        XCTAssertTrue(decoded.showOnToday)
    }
}
