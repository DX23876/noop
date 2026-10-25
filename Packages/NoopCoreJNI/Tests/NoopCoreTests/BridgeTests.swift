import XCTest
import NoopCore

/// What the Android app gets from the core through the JNI entry points, checked without JNI.
final class BridgeTests: XCTestCase {
    func testTheRecipeIsTheCoresOwn() {
        XCTAssertGreaterThanOrEqual(Bridge.recipeVersion(), 31)
    }

    func testOpeningANewStoreRunsEveryMigration() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let applied = Bridge.openStore(path: dir.appendingPathComponent("noop.sqlite").path)
        XCTAssertGreaterThan(applied, 70, "a fresh store runs the whole migration list")
        XCTAssertEqual(Bridge.openStore(path: dir.appendingPathComponent("noop.sqlite").path), applied,
                       "reopening applies nothing new")
    }

    func testAnUnopenablePathIsANegativeAnswerNotACrash() {
        XCTAssertLessThan(Bridge.openStore(path: "/nonexistent-dir/x/y/noop.sqlite"), 0)
    }
}
