package com.noop.data

/**
 * Which device id this process must work under once the registry has changed beneath it.
 *
 * The registry is the source of truth, but the process also holds the id in a field, because resolving it
 * is a database read and nearly every write path needs it. Two things move that field: a strap adopting
 * its serial identity, and the merge of several WHOOP entries into one. Only the first of them did
 * ([NoopApplication.onActiveDeviceAdopted]), so after a merge the registry read `whoop-<serial>` while
 * this process went on writing and reading under `my-whoop`, which now owned no days at all: the Today
 * cards said "No data" until the process was restarted.
 *
 * So the answer is given here, once, and both paths ask. The rule is the registry wins whenever it names
 * something; it names nothing on a fresh install, and an id that is blank or only spaces is nothing -
 * handing that on would blank the field, and the field's own getter reads blank as "not resolved yet".
 */
object ActiveDeviceResolution {

    /**
     * [registrySays] is the registry's answer, [inUse] the id this process is working under.
     */
    fun resolve(registrySays: String?, inUse: String): String =
        registrySays?.trim()?.takeIf { it.isNotEmpty() } ?: inUse
}
