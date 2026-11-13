package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * The Bluetooth decisions the shared core makes for both apps. The host owns the radio, the scan and the
 * timers; the rule is the core's (`StrapClaim`), so an Android install and an iPhone choose the same strap
 * from the same advertisements.
 */
object CoreBle {

    /** A strap a scan heard: the address the platform reconnects by, the advertised name, the signal. */
    data class Heard(val address: String, val name: String?, val rssi: Int)

    /** What to do with what was heard: [VERDICT_CONNECT] to [address], [VERDICT_ASK] with [choices] to
     *  put in front of the wearer, or [VERDICT_KEEP_LOOKING] to carry on scanning. */
    data class Choice(val verdict: String, val address: String?, val choices: List<Heard>)

    const val VERDICT_CONNECT = "connect"
    const val VERDICT_ASK = "ask"
    const val VERDICT_KEEP_LOOKING = "keepLooking"

    /** How long the host collects advertisements before asking (`StrapClaim.listenMilliseconds`). Held
     *  here as the one number the client posts its timer with; the core's own copy governs the rule. */
    const val LISTEN_MS = 4_000L

    /**
     * The core's verdict for [heard], where [claimed] is the strap the active WHOOP entry already names.
     * Null when this build has no core, which leaves the caller on its old behaviour rather than on a
     * guess made here.
     */
    fun strapChoice(heard: List<Heard>, claimed: String?): Choice? {
        if (!SwiftCore.available) return null
        val args = JSONObject().put("heard", JSONArray().apply {
            heard.forEach {
                put(JSONObject().put("address", it.address).put("rssi", it.rssi)
                        .apply { if (it.name != null) put("name", it.name) })
            }
        })
        if (claimed != null) args.put("claimed", claimed)
        val answer = SwiftCore.call("ble.strapChoice", args.toString()) ?: return null
        val o = runCatching { JSONObject(answer) }.getOrNull() ?: return null
        if (o.has("error")) return null
        val list = o.optJSONArray("choices") ?: JSONArray()
        return Choice(
            verdict = o.optString("verdict", VERDICT_KEEP_LOOKING),
            address = if (o.isNull("address")) null else o.optString("address").ifEmpty { null },
            choices = (0 until list.length()).map { i ->
                val c = list.getJSONObject(i)
                Heard(address = c.optString("address"),
                      name = if (c.isNull("name")) null else c.optString("name").ifEmpty { null },
                      rssi = c.optInt("rssi"))
            },
        )
    }
}
