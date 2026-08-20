import XCTest
@testable import Strand

final class MarkerUnitsUnicodeTests: XCTestCase {
    func testSlugCanonicalizesNFCAndNFDBeforeSlugging() {
        // Byte comparison prevents Swift's canonical-equivalence String comparison from
        // accepting an NFD persisted identifier in place of the required NFC identifier.
        let expected: [UInt8] = [
            0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x5f, 0x63, 0x61, 0x66,
            0xc3, 0xa9, 0x5f, 0x6d, 0x61, 0x72, 0x6b, 0x65, 0x72,
        ]
        XCTAssertEqual(Array(MarkerUnits.slug("Caf\u{e9} Marker").utf8), expected)
        XCTAssertEqual(Array(MarkerUnits.slug("Cafe\u{301} Marker").utf8), expected)
        XCTAssertEqual(MarkerUnits.slug("Apo B"), "custom_apo_b")
    }
}
