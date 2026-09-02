import XCTest
@testable import Strand

final class AppLanguageTests: XCTestCase {
    func testUnknownStoredValueFallsBackToSystem() {
        XCTAssertEqual(AppLanguage.resolve("unsupported"), .system)
    }

    func testChineseCatalogTagIsSupported() {
        XCTAssertEqual(AppLanguage.resolve("zh"), .chinese)
        XCTAssertEqual(AppLanguage.chinese.autonym, "简体中文")
    }

    func testPolishCatalogTagIsSupported() {
        XCTAssertEqual(AppLanguage.resolve("pl"), .polish)
        XCTAssertEqual(AppLanguage.polish.autonym, "Polski")
    }

    func testEveryCatalogLanguageCanBeSelected() {
        XCTAssertEqual(AppLanguage.resolve("it"), .italian)
        XCTAssertEqual(AppLanguage.resolve("ru"), .russian)
        XCTAssertEqual(AppLanguage.resolve("zh-Hant"), .traditionalChinese)
    }

    func testExplicitLanguageWritesAndSystemRemovesAppleOverride() throws {
        let suiteName = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AppLanguage.apply(AppLanguage.german.rawValue, defaults: defaults)
        // Read the suite's OWN persisted domain here for the same reason the removal check below does,
        // plus one specific to this fork: the Strand test scheme pins `language: en` (project.yml), so
        // the test host launches with `-AppleLanguages (en)` in NSArgumentDomain — which outranks any
        // suite domain. `stringArray(forKey:)` would answer "en" no matter what `apply` wrote.
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String], ["de"])

        AppLanguage.apply(AppLanguage.system.rawValue, defaults: defaults)
        // Read the suite's OWN persisted domain, not object(forKey:): the latter falls through to
        // NSGlobalDomain, where a CI runner (and most devices) has AppleLanguages set to the system
        // language — so the app-override removal must be checked against this suite alone.
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"])
    }
}
