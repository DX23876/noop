import XCTest
@testable import Strand

/// One Keychain slot per provider.
///
/// Every key used to share a single slot, and the vault deletes before it inserts, so comparing two
/// providers destroyed the first one's key every time. These run against an in-memory vault: key
/// handling must be covered without writing anything to the wearer's real Keychain.
final class CoachKeySlotTests: XCTestCase {

    /// A vault in memory, with the same contract as the Keychain one: one item per service and account,
    /// replaced whole.
    private final class MemoryVault: SecretVault {
        var items: [String: Data] = [:]
        private func key(_ service: String, _ account: String) -> String { service + "|" + account }
        func read(service: String, account: String) -> Data? { items[key(service, account)] }
        func write(_ data: Data, service: String, account: String) -> Bool {
            items[key(service, account)] = data
            return true
        }
        func delete(service: String, account: String) { items[key(service, account)] = nil }
    }

    private var vault = MemoryVault()
    private let ownerKey = "ai.keyProvider"

    override func setUp() {
        super.setUp()
        vault = MemoryVault()
        secretVaultOverride = vault
        UserDefaults.standard.removeObject(forKey: ownerKey)
    }

    override func tearDown() {
        secretVaultOverride = nil
        UserDefaults.standard.removeObject(forKey: ownerKey)
        super.tearDown()
    }

    /// The bug, as a test: saving a second provider's key must leave the first one's where it is.
    func testASecondProvidersKeyDoesNotCostTheFirstOneIts() {
        XCTAssertTrue(AIKeyStore.save("sk-anthropic", owner: AIProvider.anthropic.rawValue))
        XCTAssertTrue(AIKeyStore.save("sk-openrouter", owner: AIProvider.openRouter.rawValue))

        XCTAssertEqual(AIKeyStore.read(owner: AIProvider.anthropic.rawValue), "sk-anthropic")
        XCTAssertEqual(AIKeyStore.read(owner: AIProvider.openRouter.rawValue), "sk-openrouter")
    }

    /// A provider with no key of its own must read as having none, never as holding somebody else's.
    /// This is what keeps a key off an endpoint it was not meant for, the user-typed Custom URL above all.
    func testAProviderWithoutAKeyIsNeverHandedAnothersOne() {
        AIKeyStore.save("sk-anthropic", owner: AIProvider.anthropic.rawValue)
        XCTAssertNil(AIKeyStore.read(owner: AIProvider.gemini.rawValue))
        XCTAssertNil(AIKeyStore.read(owner: AIProvider.custom.rawValue))
    }

    func testForgettingOneProvidersKeyLeavesTheOthers() {
        AIKeyStore.save("sk-anthropic", owner: AIProvider.anthropic.rawValue)
        AIKeyStore.save("sk-openai", owner: AIProvider.openAI.rawValue)

        AIKeyStore.clear(owner: AIProvider.anthropic.rawValue)

        XCTAssertNil(AIKeyStore.read(owner: AIProvider.anthropic.rawValue))
        XCTAssertEqual(AIKeyStore.read(owner: AIProvider.openAI.rawValue), "sk-openai")
    }

    func testForgettingAllOfThemLeavesNothing() {
        AIKeyStore.save("sk-anthropic", owner: AIProvider.anthropic.rawValue)
        AIKeyStore.save("sk-openai", owner: AIProvider.openAI.rawValue)

        AIKeyStore.clearAll()

        for provider in AIProvider.allCases {
            XCTAssertNil(AIKeyStore.read(owner: provider.rawValue), "\(provider.rawValue) kept a key")
        }
    }

    // MARK: - The move out of the shared slot

    private func seedLegacyKey(_ key: String) {
        _ = vault.write(Data(key.utf8), service: "com.noop.aicoach", account: "api-key")
    }

    private var legacySlotHoldsAKey: Bool {
        vault.read(service: "com.noop.aicoach", account: "api-key") != nil
    }

    func testTheSharedSlotsKeyMovesToTheProviderTheMarkerNames() {
        seedLegacyKey("sk-legacy")
        UserDefaults.standard.set(AIProvider.anthropic.rawValue, forKey: ownerKey)

        AIKeyStore.migrateLegacyKey(currentProvider: AIProvider.gemini.rawValue)

        XCTAssertEqual(AIKeyStore.read(owner: AIProvider.anthropic.rawValue), "sk-legacy",
                       "the marker names the owner, not whichever provider happens to be selected")
        XCTAssertNil(AIKeyStore.read(owner: AIProvider.gemini.rawValue))
        XCTAssertFalse(legacySlotHoldsAKey, "the shared slot is emptied once the key has a home")
    }

    /// A key saved before the marker existed. It goes to the provider that is selected, which is the one
    /// it has been sent to all along, and it is not guessed from the key's own text and not discarded.
    func testAKeyWithNoMarkerGoesToTheSelectedProvider() {
        seedLegacyKey("sk-ownerless")

        AIKeyStore.migrateLegacyKey(currentProvider: AIProvider.openRouter.rawValue)

        XCTAssertEqual(AIKeyStore.read(owner: AIProvider.openRouter.rawValue), "sk-ownerless")
        XCTAssertFalse(legacySlotHoldsAKey)
    }

    /// It runs on every launch, so running it again must do nothing at all, and above all must not
    /// overwrite a key the wearer has saved since.
    func testTheMoveRunsOnceAndNeverOverwritesANewerKey() {
        seedLegacyKey("sk-legacy")
        UserDefaults.standard.set(AIProvider.anthropic.rawValue, forKey: ownerKey)
        AIKeyStore.migrateLegacyKey(currentProvider: AIProvider.anthropic.rawValue)

        AIKeyStore.save("sk-newer", owner: AIProvider.anthropic.rawValue)
        seedLegacyKey("sk-legacy")
        AIKeyStore.migrateLegacyKey(currentProvider: AIProvider.anthropic.rawValue)

        XCTAssertEqual(AIKeyStore.read(owner: AIProvider.anthropic.rawValue), "sk-newer")
    }

    func testWithNothingInTheSharedSlotTheMoveDoesNothing() {
        AIKeyStore.save("sk-openai", owner: AIProvider.openAI.rawValue)

        AIKeyStore.migrateLegacyKey(currentProvider: AIProvider.openAI.rawValue)

        XCTAssertEqual(AIKeyStore.read(owner: AIProvider.openAI.rawValue), "sk-openai")
    }
}
