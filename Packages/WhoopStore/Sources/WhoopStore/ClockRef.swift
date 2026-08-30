import Foundation

/// The strap-clock ↔ wall-clock correlation captured at the start of a session.
///
/// Declared here rather than beside the raw outbox because it has nothing to do with it. This is the
/// type the LIVE and BACKFILL paths carry — `Collector`, `Backfiller`, `ClockCorrelation` and
/// `BLEManager` all hold one, and every historical decode is offset by it. It reached the raw outbox
/// only because `RawBatchMeta` stores the same pair alongside a batch.
///
/// It previously lived inside `RawOutbox.swift`, which is wrapped whole in `#if canImport(Compression)`
/// so the zlib-backed outbox compiles only on Apple platforms. That guard took this type with it, so on
/// a platform without Compression the entire clock-correlation vocabulary vanished from the module's
/// public API — a file-level guard reaching well past the surface it was meant to gate.
public struct ClockRef: Equatable, Codable {
    public let device: Int
    public let wall: Int
    public init(device: Int, wall: Int) { self.device = device; self.wall = wall }
}
