// Tests the OURA_CLOUD_IMPORT-gated Oura import lane; compiled only when the flag is set
// (StrandTests shares the app's OuraConfig.xcconfig, so flag + creds arrive together).
#if OURA_CLOUD_IMPORT
import XCTest
@testable import Strand

final class OuraTokenStoreTests: XCTestCase {
    override func setUp() { super.setUp(); OuraTokenStore.clear() }
    override func tearDown() { OuraTokenStore.clear(); super.tearDown() }

    func testSaveLoadClearRoundTrip() {
        XCTAssertFalse(OuraTokenStore.isConnected)
        XCTAssertNil(OuraTokenStore.load())

        let exp = Date(timeIntervalSince1970: 2_000_000_000)
        let t = OuraTokens(accessToken: "acc", refreshToken: "ref", expiresAt: exp)
        XCTAssertTrue(OuraTokenStore.save(t))
        XCTAssertTrue(OuraTokenStore.isConnected)

        let loaded = OuraTokenStore.load()
        XCTAssertEqual(loaded, t)

        OuraTokenStore.clear()
        XCTAssertNil(OuraTokenStore.load())
        XCTAssertFalse(OuraTokenStore.isConnected)
    }

    func testExpiryUsesSkew() {
        let almostNow = OuraTokens(accessToken: "a", refreshToken: nil,
                                   expiresAt: Date(timeIntervalSinceNow: 30))   // <60 s away
        XCTAssertTrue(almostNow.isExpired)
        let later = OuraTokens(accessToken: "a", refreshToken: nil,
                               expiresAt: Date(timeIntervalSinceNow: 600))
        XCTAssertFalse(later.isExpired)
    }
}
#endif // OURA_CLOUD_IMPORT
