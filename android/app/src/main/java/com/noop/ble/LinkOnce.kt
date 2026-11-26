package com.noop.ble

/**
 * Something that happens once per connection: the first [claim] after a [reset] answers true, every later one
 * false. Single-threaded like the rest of the client's link state (the BLE handler thread).
 */
internal class LinkOnce {
    private var claimed = false

    /** True the first time it is asked on this link, and the caller then does the thing. */
    fun claim(): Boolean {
        if (claimed) return false
        claimed = true
        return true
    }

    /** A new link: the next [claim] answers true again. */
    fun reset() {
        claimed = false
    }
}
