import XCTest
@testable import Strand

/// The one-off bell entries that introduce a Lab feature after an update: each says what the feature is and
/// links to the Lab switch, appears once per device and never returns after the reader deletes it.
@MainActor
final class FeatureIntroInboxTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UpdateStore.shared.clearAll()
        FeatureIntro.allCases.forEach { UserDefaults.standard.removeObject(forKey: $0.seededKey) }
    }

    override func tearDown() {
        UpdateStore.shared.clearAll()
        FeatureIntro.allCases.forEach { UserDefaults.standard.removeObject(forKey: $0.seededKey) }
        super.tearDown()
    }

    private var intros: [UpdateItem] { UpdateStore.shared.items.filter { $0.deepLink?.hasPrefix("lab.") == true } }

    func testBothIntroductionsArePostedAsSeparateRows() {
        UpdateStore.shared.seedFeatureIntrosIfNeeded(isEnabled: { _ in false })
        XCTAssertEqual(Set(intros.compactMap(\.deepLink)), ["lab.ageless", "lab.rhythmAge"])
    }

    func testEveryIntroductionLinksToTheLabSwitches() {
        UpdateStore.shared.seedFeatureIntrosIfNeeded(isEnabled: { _ in false })
        for item in intros {
            XCTAssertEqual(NavRouter.Destination(deepLinkKey: item.deepLink!), .lab, item.deepLink!)
        }
    }

    func testADeletedIntroductionDoesNotComeBack() {
        let store = UpdateStore.shared
        store.seedFeatureIntrosIfNeeded(isEnabled: { _ in false })
        intros.forEach { store.remove($0.id) }
        store.seedFeatureIntrosIfNeeded(isEnabled: { _ in false })
        XCTAssertTrue(intros.isEmpty)
    }

    func testAFeatureAlreadySwitchedOnIsNotIntroduced() {
        UpdateStore.shared.seedFeatureIntrosIfNeeded(isEnabled: { $0 == .ageless })
        XCTAssertEqual(intros.compactMap(\.deepLink), ["lab.rhythmAge"])
    }
}
