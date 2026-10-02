import Foundation

/// Framework-independent two-dimensional motion value used between CoreMotion and the hero renderer.
public struct OrganicScoreVector: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = OrganicScoreVector(x: 0, y: 0)

    public var magnitude: Double { hypot(x, y) }

    fileprivate func clamped(to maximum: Double) -> OrganicScoreVector {
        let length = magnitude
        guard maximum > 0, length > maximum, length > 0 else { return self }
        let scale = maximum / length
        return OrganicScoreVector(x: x * scale, y: y * scale)
    }
}

/// Pure smoothing and impulse state for device-reactive organic rings.
///
/// CoreMotion supplies gravity and user acceleration; this value type owns the deterministic filtering
/// so sensor lifecycle and rendering remain separate concerns.
public struct OrganicScoreMotionFilter: Equatable, Sendable {
    public private(set) var gravity: OrganicScoreVector = .zero
    public private(set) var impulse: OrganicScoreVector = .zero

    public init() {}

    public mutating func update(
        gravity rawGravity: OrganicScoreVector,
        acceleration: OrganicScoreVector,
        deltaTime rawDeltaTime: Double
    ) {
        let deltaTime = min(max(rawDeltaTime, 0), 0.1)
        guard deltaTime > 0 else { return }

        let gravityTarget = rawGravity.clamped(to: 1)
        let gravityBlend = 1 - exp(-deltaTime / 0.18)
        gravity = OrganicScoreVector(
            x: gravity.x + (gravityTarget.x - gravity.x) * gravityBlend,
            y: gravity.y + (gravityTarget.y - gravity.y) * gravityBlend
        ).clamped(to: 1)

        let counterTarget = OrganicScoreVector(
            x: -acceleration.x * 0.45,
            y: -acceleration.y * 0.45
        ).clamped(to: 1)
        let impulseBlend = 1 - exp(-deltaTime / 0.06)
        impulse = OrganicScoreVector(
            x: impulse.x + (counterTarget.x - impulse.x) * impulseBlend,
            y: impulse.y + (counterTarget.y - impulse.y) * impulseBlend
        ).clamped(to: 1)
    }

    public mutating func reset() {
        gravity = .zero
        impulse = .zero
    }
}
