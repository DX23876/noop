#if os(iOS)
import XCTest
@testable import NOOP_Staging

final class NomicTextEmbeddingProviderTests: XCTestCase {
    func testBundledModelLoadsRetrievesAndUnloads() async throws {
        let provider = NomicTextEmbeddingProvider()
        let initiallyLoaded = await provider.isLoaded()
        XCTAssertFalse(initiallyLoaded)

        let longText = Array(repeating: "Schlaf, Erholung und Abendroutine.", count: 500)
            .joined(separator: " ")
        let longVectors = try await provider.embedDocuments([longText])
        let longVector = try XCTUnwrap(longVectors.first)
        XCTAssertEqual(longVector.count, 256)
        let norm = sqrt(longVector.reduce(Float.zero) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1, accuracy: 0.001)

        let result = try await provider.runRetrievalSelfTest()
        XCTAssertTrue(
            result.passed,
            "Semantic \(result.semanticCorrect)/\(result.total), keyword "
                + "\(result.keywordCorrect)/\(result.total), exact "
                + "\(result.exactQueriesPreserved)"
        )
        let loadedAfterRetrieval = await provider.isLoaded()
        XCTAssertTrue(loadedAfterRetrieval)

        await provider.unload()
        let loadedAfterUnload = await provider.isLoaded()
        XCTAssertFalse(loadedAfterUnload)
    }
}
#endif
