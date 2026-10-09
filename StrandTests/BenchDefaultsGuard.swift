import XCTest
@testable import Strand

/// The opt-in store benchmarks run inside the macOS test host, which is the app itself: its standard
/// defaults and App Group suite are the ones the installed app reads. A benchmark against a cloned store
/// writes the analysis watermark, goal snapshots and energy cursors there, so it takes both domains as
/// they were and puts them back when the test ends.
enum BenchDefaultsGuard {
    @MainActor
    static func preserve(in testCase: XCTestCase) {
        var domains: [(name: String, values: [String: Any]?)] = []
        if let bundle = Bundle.main.bundleIdentifier {
            domains.append((bundle, UserDefaults.standard.persistentDomain(forName: bundle)))
        }
        domains.append((WidgetSnapshot.suiteName, UserDefaults.standard.persistentDomain(forName: WidgetSnapshot.suiteName)))
        testCase.addTeardownBlock {
            for domain in domains {
                if let values = domain.values {
                    UserDefaults.standard.setPersistentDomain(values, forName: domain.name)
                } else {
                    UserDefaults.standard.removePersistentDomain(forName: domain.name)
                }
            }
        }
    }
}
