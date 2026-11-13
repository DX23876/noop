package com.noop.core

import com.noop.data.DeviceRegistry
import org.json.JSONObject

/** Deletes and re-keys a device's rows in the shared core; a no-op success when this build has no core. */
object CoreDeviceData : DeviceRegistry.SharedCore {
    override fun deleteData(id: String): Boolean = run("device.deleteData", JSONObject().put("id", id))
    override fun reKey(from: String, to: String): Boolean =
        run("device.reKey", JSONObject().put("from", from).put("to", to))

    // MARK: - One WHOOP entry
    //
    // The merge and the pairing takeover are the core's (`WhoopRowFold`), the same code the Apple apps run;
    // nothing here decides anything. The fold comes a chunk at a time because a progress closure cannot
    // cross this bridge, and `done` says when to stop asking.

    /** Whether extra WHOOP entries can be merged, and which strap stays connected. */
    data class MergeOffer(
        val needed: Boolean,
        val keeperId: String?,
        val keeperName: String?,
        /** What `bind` and every step take on: null when the keeper already is the one WHOOP entry. */
        val identityFrom: String?,
    )

    /** One chunk of the merge: rows moved, and whether there is anything left. */
    data class MergeStep(val moved: Int, val done: Boolean)

    /** A pairing takeover: whether the one WHOOP entry adopted the strap, and whether the live link has
     *  to be re-pointed because the row was already the active one. */
    data class TakeOver(val took: Boolean, val retarget: Boolean)

    fun mergeOffer(): MergeOffer? = answer("device.whoopMergeOffer", JSONObject())?.let {
        MergeOffer(needed = it.optBoolean("needed"), keeperId = it.string("keeperId"),
                   keeperName = it.string("keeperName"), identityFrom = it.string("identityFrom"))
    }

    fun mergeBind(identityFrom: String?): Boolean =
        run("device.whoopMergeBind", JSONObject().putOrNull("identityFrom", identityFrom))

    fun mergeStep(identityFrom: String?, chunk: Int): MergeStep? =
        answer("device.whoopMergeStep",
               JSONObject().putOrNull("identityFrom", identityFrom).put("chunk", chunk))?.let {
            if (it.has("error")) null else MergeStep(it.optInt("moved"), it.optBoolean("done"))
        }

    fun takeOver(peripheralId: String, model: String, nickname: String?, makeActive: Boolean): TakeOver? =
        answer("device.whoopTakeOver",
               JSONObject().put("peripheralId", peripheralId).put("model", model)
                   .putOrNull("nickname", nickname).put("makeActive", makeActive))?.let {
            if (it.has("error")) null else TakeOver(it.optBoolean("took"), it.optBoolean("retarget"))
        }

    /** A value the core left out, as null rather than as the empty string `optString` would hand back. */
    private fun JSONObject.string(key: String): String? =
        if (isNull(key)) null else optString(key).ifEmpty { null }

    private fun JSONObject.putOrNull(key: String, value: String?): JSONObject =
        if (value == null) this else put(key, value)

    private fun answer(op: String, args: JSONObject): JSONObject? {
        if (!SwiftCore.available) return null
        val answer = SwiftCore.call(op, args.toString()) ?: return null
        return runCatching { JSONObject(answer) }.getOrNull()
    }

    private fun run(op: String, args: JSONObject): Boolean {
        if (!SwiftCore.available) return true
        val answer = SwiftCore.call(op, args.toString()) ?: return false
        return runCatching { JSONObject(answer).optBoolean("ok") }.getOrDefault(false)
    }
}
