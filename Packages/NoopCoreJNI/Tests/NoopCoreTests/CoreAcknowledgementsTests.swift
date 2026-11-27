import XCTest
import StrandCore
@testable import NoopCore

/// The credit list both platforms show (Settings parity, package 6): one list in StrandCore, a wire shape for
/// Android that never names a dependency only the Apple apps contain, and the fork's credit rule held by a test.
final class CoreAcknowledgementsTests: XCTestCase {
    func testTheOperationAnswersWithTheWire() async throws {
        let json = await CoreCall.run("about.acknowledgements", "{}")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((object["contributors"] as? [[String: Any]])?.count, Acknowledgements.contributors.count)
        XCTAssertEqual((object["licenses"] as? [[String: Any]])?.count, 4)
        XCTAssertEqual((object["content"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual(object["attributionUrl"] as? String, Acknowledgements.attributionURL)
    }

    func testTheWireCarriesEveryContributorInOrder() throws {
        let wire = CoreAcknowledgements.wire()
        XCTAssertEqual(wire.contributors.map(\.handle), Acknowledgements.contributors.map(\.handle))
        // Every credited person once, however many the list holds (a fixed count went stale with each credit).
        XCTAssertEqual(Set(wire.contributors.map(\.handle)).count, wire.contributors.count, "a handle is credited once")
        XCTAssertEqual(wire.contributors.first?.handle, "@UtkuDenizAltiok")
        XCTAssertEqual(wire.contributors.last?.handle, "meta1971, OpenStrap")
    }

    func testAndroidNeverNamesAnAppleOnlyDependency() {
        let titles = CoreAcknowledgements.wire(android: true).licenses.map(\.title)
        XCTAssertEqual(titles, ["GRDB.swift", "ZIPFoundation", "Swift Crypto", "OpenStrap"])
        XCTAssertFalse(titles.contains("llama.cpp"))
        XCTAssertFalse(titles.contains("MarkdownUI"))
        XCTAssertEqual(CoreAcknowledgements.wire(android: false).licenses.count, Acknowledgements.bundledLicenses.count)
    }

    func testEveryLicenceNamesItsFileAndEveryContentEntryHasALink() {
        for license in Acknowledgements.bundledLicenses {
            XCTAssertEqual(license.fileLabel, license.licenseName + " · " + license.resource + ".txt")
            XCTAssertTrue(license.link.hasPrefix("https://"))
        }
        XCTAssertEqual(Acknowledgements.contentEntries.count, 3)
        XCTAssertTrue(Acknowledgements.contentEntries.allSatisfy { $0.link?.hasPrefix("https://") == true })
        XCTAssertNil(Acknowledgements.mediaEntry.link)
    }

    func testTheCreditRuleHolds() throws {
        // AGENT_RULES.md: everyone the fork adopted work from is in ATTRIBUTION.md and in this list. A handle in the
        // list that ATTRIBUTION.md does not name has no source behind it.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let attribution = root.appendingPathComponent("ATTRIBUTION.md")
        guard let text = try? String(contentsOf: attribution, encoding: .utf8) else {
            throw XCTSkip("ATTRIBUTION.md is not beside the package in this checkout")
        }
        for person in Acknowledgements.contributors where person.handle.hasPrefix("@") {
            XCTAssertTrue(text.contains(String(person.handle.dropFirst())), "\(person.handle) is not in ATTRIBUTION.md")
        }
    }
}
