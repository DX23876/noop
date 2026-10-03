import XCTest
@testable import Strand

/// Liquid Today's fresh defaults apply only to keys that were never written; every saved choice wins.
final class LiquidTodayDefaultsTests: XCTestCase {

    func testFreshLayoutLeadsWithTheHeroAndHidesRecoveryVitals() {
        let visible = LiquidTodayDefaults.visibleSections(orderRaw: nil, hiddenRaw: nil)
        XCTAssertEqual(Array(visible.prefix(7)),
                       [.hero, .synthesis, .goals, .keyMetrics, .energy, .workouts, .heartRate])
        XCTAssertTrue(visible.contains(.yourCards))
        XCTAssertFalse(visible.contains(.recoveryVitals))
        XCTAssertFalse(visible.contains(.dataSources))
        // An @AppStorage String with a "" default reads an unset key as "", which must still be fresh.
        XCTAssertEqual(LiquidTodayDefaults.visibleSections(orderRaw: "", hiddenRaw: nil), visible)
    }

    func testFreshOrderCoversEveryCaseOnce() {
        XCTAssertEqual(Set(LiquidTodayDefaults.sectionOrder), Set(TodaySection.allCases))
        XCTAssertEqual(LiquidTodayDefaults.sectionOrder.count, TodaySection.allCases.count)
    }

    func testSavedLayoutIsHonouredExactly() {
        let saved: [TodaySection] = [
            .recoveryVitals, .hero, .coach, .keyMetrics, .synthesis, .goals, .energy, .workouts, .heartRate,
            .yourCards, .liveSession, .menstrualCycle, .journal, .dataSources, .addedCards,
        ]
        let orderRaw = TodayLayoutPrefs.encode(saved)
        let visible = LiquidTodayDefaults.visibleSections(orderRaw: orderRaw, hiddenRaw: "journal")
        XCTAssertEqual(visible, saved.filter { $0 != .journal && $0 != .dataSources },
                       "saved order and visibility survive, Recovery Vitals included")
    }

    func testExplicitlyUnhidingEverythingIsACustomisation() {
        // Unhiding every section writes "", which is a choice, not an unset key.
        let visible = LiquidTodayDefaults.visibleSections(orderRaw: nil, hiddenRaw: "")
        XCTAssertTrue(visible.contains(.recoveryVitals))
        XCTAssertEqual(visible.first, .coach, "a customised layout reads the shared order, not Liquid's")
    }

    func testEditorSeedKeepsHiddenSectionsInPlace() {
        let fresh = LiquidTodayDefaults.layout(orderRaw: nil, hiddenRaw: nil)
        XCTAssertEqual(fresh.hidden, [.recoveryVitals])
        XCTAssertTrue(fresh.order.contains(.recoveryVitals))
        XCTAssertFalse(fresh.order.contains(.dataSources))
    }

    func testClassicDefaultsAreUntouched() {
        XCTAssertEqual(TodayLayoutPrefs.visibleOrder(orderRaw: "", hiddenRaw: ""), TodaySection.defaultOrder)
        XCTAssertEqual(KeyMetricPrefs.decodeEnabled(""), KeyMetric.defaultOrder)
        XCTAssertTrue(KeyMetric.defaultOrder.contains(.calories))
        XCTAssertEqual(KeyMetricPrefs.columns(0), 3)
        XCTAssertEqual(DashboardCardPrefs.decodeEnabled(""), DashboardCard.defaultSelection)
    }

    func testKeyMetricDefaultsDropCaloriesAndUseTwoColumns() {
        let fresh = LiquidTodayDefaults.keyMetricSelection(nil)
        XCTAssertFalse(fresh.isExplicit)
        XCTAssertFalse(fresh.metrics.contains(.calories))
        // The hero rings already show the three scores.
        XCTAssertFalse(fresh.metrics.contains(.charge))
        XCTAssertFalse(fresh.metrics.contains(.effort))
        XCTAssertFalse(fresh.metrics.contains(.rest))
        XCTAssertEqual(LiquidTodayDefaults.keyMetricsColumns(nil, accessibilitySize: false), 2)
        XCTAssertEqual(LiquidTodayDefaults.keyMetricsColumns(3, accessibilitySize: false), 3)
        XCTAssertEqual(LiquidTodayDefaults.keyMetricsColumns(3, accessibilitySize: true), 1)

        let saved = LiquidTodayDefaults.keyMetricSelection("calories,hrv")
        XCTAssertTrue(saved.isExplicit)
        XCTAssertEqual(saved.metrics, [.calories, .hrv])
    }

    func testAutomaticMetricsHideEmptiesWhileChosenOnesStayLast() {
        let hasValue: (KeyMetric) -> Bool = { $0 != .weight && $0 != .bloodOxygen }

        let automatic = LiquidTodayDefaults.arrangedKeyMetrics(
            LiquidTodayDefaults.keyMetricSelection(nil), hasValue: hasValue)
        XCTAssertFalse(automatic.contains(.weight))
        XCTAssertFalse(automatic.contains(.bloodOxygen))

        let chosen = LiquidTodayDefaults.arrangedKeyMetrics(
            LiquidTodayDefaults.keyMetricSelection("weight,charge,bloodOxygen,hrv"), hasValue: hasValue)
        XCTAssertEqual(chosen, [.charge, .hrv, .weight, .bloodOxygen])
    }

    func testYourCardsFreshDefaultAndSavedSelection() {
        XCTAssertEqual(LiquidTodayDefaults.dashboardCards(nil), [.stress, .fitnessAge, .vitality])
        XCTAssertEqual(LiquidTodayDefaults.dashboardCards("  "), [.stress, .fitnessAge, .vitality])
        XCTAssertEqual(LiquidTodayDefaults.dashboardCards(DashboardCardPrefs.encode([.hrv, .restingHr])),
                       [.hrv, .restingHr])
    }

    /// Last Workouts writes the Effort band under the number; its edges are the app's Effort words.
    func testEffortBandWordFollowsTheEffortEdges() {
        func word(_ key: String) -> String { String(localized: String.LocalizationValue(key)).uppercased(with: AppLanguage.activeLocale) }
        XCTAssertNil(LiquidTodayDefaults.effortBandWord(stored: nil))
        XCTAssertEqual(LiquidTodayDefaults.effortBandWord(stored: 0), word("Light"))
        XCTAssertEqual(LiquidTodayDefaults.effortBandWord(stored: 28), word("Light"))
        XCTAssertEqual(LiquidTodayDefaults.effortBandWord(stored: 29), word("Moderate"))
        XCTAssertEqual(LiquidTodayDefaults.effortBandWord(stored: 47), word("Moderate"))
        XCTAssertEqual(LiquidTodayDefaults.effortBandWord(stored: 48), word("Strenuous"))
        XCTAssertEqual(LiquidTodayDefaults.effortBandWord(stored: 66), word("Strenuous"))
        XCTAssertEqual(LiquidTodayDefaults.effortBandWord(stored: 67), word("High"))
        XCTAssertEqual(LiquidTodayDefaults.effortBandWord(stored: 100), word("High"))
    }
}
