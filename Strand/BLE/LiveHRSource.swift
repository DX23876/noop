import Foundation

/// A non-WHOOP live BLE source the `SourceCoordinator` can run as the single active source (a generic HR
/// strap, an FTMS gym machine, an experimental Huami band, or an experimental Oura ring).
///
/// Deliberately MINIMAL: the coordinator only ever starts, targets, and stops a source, so this contract
/// is exactly `scan` / `connect` / `stop`. All the richer per-source state — `discovered`, `scanning`,
/// `batteryPct`, `needsPairing`, Oura's `adoptPhase` — stays on the concrete type for the wizard/live UI
/// to observe; it is NOT part of this protocol. That keeps the coordinator's active-source lifecycle
/// decoupled from the pairing/observation surface, so adding a brand is a factory arm, not new plumbing.
///
/// Every conformer owns its OWN `CBCentralManager` and never references `BLEManager`/`WhoopBleClient`
/// (the WHOOP-first isolation each source already documents), so nothing here can regress the WHOOP path.
///
/// Faithful twin of Android `com.noop.ble.LiveHrSource`.
@MainActor
protocol LiveHRSource: AnyObject {
    /// Discover and connect to the source's peripheral by scanning (the fallback when the registry row
    /// has no usable stored identifier).
    func scan()
    /// Connect directly to the source's known peripheral by its stable identifier (preferred over `scan`).
    func connect(_ id: UUID)
    /// Tear the source down and stop streaming. Idempotent.
    func stop()
}

// The four shipped sources already expose exactly `scan()` / `connect(_:)` / `stop()`, so conformance is
// a pure declaration with no logic change (Swift's retroactive-conformance analogue of Android adding
// `: LiveHrSource` + `override` to each class).
extension StandardHRSource: LiveHRSource {}
extension HuamiHRSource: LiveHRSource {}
extension FTMSSource: LiveHRSource {}
extension OuraLiveSource: LiveHRSource {}
