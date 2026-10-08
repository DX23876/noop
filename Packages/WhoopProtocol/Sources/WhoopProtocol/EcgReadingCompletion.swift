/// A reading is publishable only after its save and cleanup have both settled. Generations reject
/// late callbacks from an earlier reading; a failed cleanup remains an explicit result.
public struct EcgReadingCompletion: Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var saving = false
    public private(set) var finishing = false
    public private(set) var cleanupSucceeded: Bool?
    public var canPublish: Bool { finishing && !saving && cleanupSucceeded != nil }

    public init() {}

    @discardableResult public mutating func begin() -> UInt64 {
        generation &+= 1
        saving = false
        finishing = false
        cleanupSucceeded = nil
        return generation
    }

    public func isCurrent(_ token: UInt64) -> Bool { token == generation }
    public mutating func beginSave() { saving = true }

    @discardableResult public mutating func saved(_ token: UInt64) -> Bool {
        guard isCurrent(token) else { return false }
        saving = false
        return true
    }

    @discardableResult public mutating func requestFinish() -> Bool {
        guard !finishing else { return false }
        finishing = true
        return true
    }

    public mutating func cleanedUp(_ token: UInt64, success: Bool) {
        guard isCurrent(token) else { return }
        cleanupSucceeded = success
    }
}
