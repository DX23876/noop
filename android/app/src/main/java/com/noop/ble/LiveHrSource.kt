package com.noop.ble

/**
 * A non-WHOOP live BLE source the [SourceCoordinator] can run as the single active source (a generic HR
 * strap, an FTMS gym machine, an experimental Huami band, or an experimental Oura ring).
 *
 * Deliberately MINIMAL: the coordinator only ever starts, targets, and stops a source, so this contract
 * is exactly [scan] / [connect] / [stop]. All the richer per-source state — discovered peripherals, the
 * scanning flag, battery, needs-pairing, Oura's adopt phase — stays on the concrete type for the
 * wizard/live UI to observe; it is NOT part of this interface. That keeps the coordinator's active-source
 * lifecycle decoupled from the pairing/observation surface, so adding a brand is a factory arm, not new
 * plumbing.
 *
 * Every implementer owns its OWN scanner/GATT and never references [WhoopBleClient] (the WHOOP-first
 * isolation each source already documents), so nothing here can regress the WHOOP path.
 *
 * Faithful twin of Strand/BLE/LiveHRSource.swift.
 */
interface LiveHrSource {
    /** Discover and connect to the source's peripheral by scanning (the fallback when the registry row
     *  has no usable stored address). */
    fun scan()

    /** Connect directly to the source's known peripheral by its stable BLE [address] (preferred over
     *  [scan]). */
    fun connect(address: String)

    /** Tear the source down and stop streaming. Idempotent. */
    fun stop()
}
