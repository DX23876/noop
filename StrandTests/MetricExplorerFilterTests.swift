import XCTest
@testable import Strand

final class MetricExplorerFilterTests: XCTestCase {
    private func metric(_ key: String, _ title: String, source: String = "my-whoop") -> MetricDescriptor {
        MetricDescriptor(key: key, title: title, category: "Heart", unit: "", source: source,
                         icon: "heart", decimals: 0, higherIsBetter: nil)
    }

    func testSearchMatchesTitleKeySourceAndCategoryIgnoringCaseAndAccents() {
        let hrv = [metric("hrv", "HRV"), metric("hrv", "HRV", source: "apple-health")]
        XCTAssertTrue(MetricExplorerFilter.matches(hrv, query: "  hr ", categoryName: "Herz"))
        XCTAssertTrue(MetricExplorerFilter.matches(hrv, query: "apple", categoryName: "Herz"))
        XCTAssertTrue(MetricExplorerFilter.matches(hrv, query: "herz", categoryName: "Herz"))
        XCTAssertTrue(MetricExplorerFilter.matches([metric("x", "Résumé")], query: "resume", categoryName: ""))
        XCTAssertFalse(MetricExplorerFilter.matches(hrv, query: "weight", categoryName: "Herz"))
        XCTAssertTrue(MetricExplorerFilter.matches(hrv, query: "   ", categoryName: "Herz"))
    }

    func testWithDataUsesTheCheapProbeAndNeverBlanksBeforeIt() {
        let hrv = [metric("hrv", "HRV"), metric("hrv", "HRV", source: "apple-health")]
        let steps = [metric("steps", "Steps")]
        let groups = [hrv, steps]

        XCTAssertEqual(MetricExplorerFilter.visibleGroups(groups, query: "", categoryName: "",
                                                          availability: .withData, nonEmptyIDs: nil).count, 2)
        let probed: Set<String> = ["apple-health:hrv"]
        XCTAssertEqual(MetricExplorerFilter.visibleGroups(groups, query: "", categoryName: "",
                                                          availability: .withData, nonEmptyIDs: probed), [hrv],
                       "a measurement with data in any source stays")
        XCTAssertEqual(MetricExplorerFilter.visibleGroups(groups, query: "", categoryName: "",
                                                          availability: .all, nonEmptyIDs: probed).count, 2)
    }

    func testAvailabilityDefaultsToAllAndRoundTrips() {
        XCTAssertEqual(MetricExplorerFilter.availability(""), .all)
        XCTAssertEqual(MetricExplorerFilter.availability("bogus"), .all)
        XCTAssertEqual(MetricExplorerFilter.availability(MetricExplorerAvailability.withData.rawValue), .withData)
    }

    func testSearchExpandsTemporarilyAndClearingRestoresCollapsedState() {
        let order = MetricCatalog.categories
        let stored = MetricExplorerFilter.encodeCollapsed(["Rest", "Heart"], order: order)
        XCTAssertEqual(stored, "Heart,Rest", "stored in catalog order, not set order")
        let collapsed = MetricExplorerFilter.decodeCollapsed(stored)

        XCTAssertFalse(MetricExplorerFilter.isExpanded(category: "Heart", collapsed: collapsed, query: ""))
        XCTAssertTrue(MetricExplorerFilter.isExpanded(category: "Effort", collapsed: collapsed, query: ""))
        XCTAssertTrue(MetricExplorerFilter.isExpanded(category: "Heart", collapsed: collapsed, query: "hr"))
        XCTAssertFalse(MetricExplorerFilter.isExpanded(category: "Heart", collapsed: collapsed, query: ""),
                       "the stored state is untouched by a search")
        XCTAssertTrue(MetricExplorerFilter.decodeCollapsed("").isEmpty, "every category starts expanded")
    }
}
