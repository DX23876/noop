package com.noop.ui.forge

/**
 * What a strap row says about the link, decided in ONE place.
 *
 * Three surfaces state this fact: the device row behind the profile, the quick-action sheet's battery row
 * and Today's strap tile. Two of them used to decide it from the published registry NAME first, and that
 * name is refreshed on a handful of paths rather than on every change. After a pairing takeover it lagged,
 * so the row said "connect a wearable" and the sheet dropped its strap row entirely, both while the strap
 * was streaming one screen away. A tester reported exactly that and could find nothing that said his 4.0
 * was connected.
 *
 * So the link answers first. A connected strap is a fact these rows can see for themselves; its name is
 * decoration, and only an install with no link AND no named strap is one with nothing to show. The
 * surfaces keep their own wording, because the sheet and the row word the same state differently; what
 * they may not keep is their own rule.
 */
enum class StrapRow {
    /** Nothing paired and nothing on the air: the surfaces offer pairing, or show no row at all. */
    None,
    /** A strap is known but not on the air. */
    Disconnected,
    /** Connected, and history is coming over. */
    Syncing,
    /** Connected and on the charger. */
    Charging,
    /** Connected, with a battery reading. */
    Battery,
    /** Connected, with nothing more to say yet. */
    Connected,
}

object StrapRowStatus {
    /**
     * [named] is whether the registry names an active device at all. [onAir] is the link itself: a
     * surface that counts a bonded-but-not-yet-streaming strap as present passes `connected || bonded`,
     * one that waits for the stream passes `connected`. [syncing] should already be debounced where the
     * surface debounces it, since that is a presentation choice and not part of this rule.
     */
    fun of(named: Boolean, onAir: Boolean, syncing: Boolean, charging: Boolean?,
           batteryPct: Double?): StrapRow = when {
        !onAir && !named -> StrapRow.None
        !onAir -> StrapRow.Disconnected
        syncing -> StrapRow.Syncing
        charging == true -> StrapRow.Charging
        batteryPct != null -> StrapRow.Battery
        else -> StrapRow.Connected
    }
}
