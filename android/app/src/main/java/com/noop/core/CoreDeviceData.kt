package com.noop.core

import com.noop.data.DeviceRegistry
import org.json.JSONObject

/** Deletes and re-keys a device's rows in the shared core; a no-op success when this build has no core. */
object CoreDeviceData : DeviceRegistry.SharedCore {
    override fun deleteData(id: String): Boolean = run("device.deleteData", JSONObject().put("id", id))
    override fun reKey(from: String, to: String): Boolean =
        run("device.reKey", JSONObject().put("from", from).put("to", to))

    private fun run(op: String, args: JSONObject): Boolean {
        if (!SwiftCore.available) return true
        val answer = SwiftCore.call(op, args.toString()) ?: return false
        return runCatching { JSONObject(answer).optBoolean("ok") }.getOrDefault(false)
    }
}
