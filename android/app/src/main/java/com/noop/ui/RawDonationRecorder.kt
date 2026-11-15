package com.noop.ui

import android.content.Context
import com.noop.ble.WhoopBleClient
import com.noop.core.SwiftCore
import com.noop.testcentre.ImuSessionFileStore
import com.noop.ui.forge.RawDonationCapture
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * Records the donation windows during a workout. The Android twin of `RawDonationRecorder` on Apple,
 * and like it, it decides nothing: the window plan, the package and the upload all come from the core.
 *
 * - It does not arm itself. `begin` asks the core for a plan and gets null for a sport nobody ticked.
 * - It does not send. A finished recording becomes a pending donation and waits for a press.
 * - It stops when the strap is gone, rather than waiting through a dropout with the producer armed.
 *
 * What nobody has measured yet: whether a 100 Hz raw stream during a workout disturbs live heart rate
 * or the history offload. The page says so, and that is why nothing is ticked by default.
 */
object RawDonationRecorder {
    private data class Window(val start: Double, val duration: Double)

    private var windows: List<Window> = emptyList()
    private var sessionId: String? = null
    private var sport: String = ""
    private var recordingSince: Long = 0
    private var recordedMs: Long = 0
    @Volatile private var armed = false

    /** Called when a workout starts. Returns quietly when this sport was not ticked. */
    fun begin(sport: String, expectedSeconds: Double = 2700.0) {
        val answer = SwiftCore.call("donation.plan",
                                    JSONObject().put("sport", sport).put("expected", expectedSeconds).toString())
        val array = runCatching { JSONArray(answer ?: "null") }.getOrNull()
        if (array == null || array.length() == 0) {
            reset()
            return
        }
        windows = (0 until array.length()).mapNotNull { index ->
            val row = array.optJSONObject(index) ?: return@mapNotNull null
            Window(row.optDouble("start"), row.optDouble("duration"))
        }
        this.sport = sport
        sessionId = "donation-" + UUID.randomUUID().toString().take(8)
    }

    /** One second of the workout. Opens and closes the windows against the strap. */
    fun tick(elapsedSeconds: Double, ble: WhoopBleClient, strapConnected: Boolean) {
        val id = sessionId ?: return
        val wants = strapConnected && windows.any {
            elapsedSeconds >= it.start && elapsedSeconds < it.start + it.duration
        }
        if (wants && !armed) {
            if (!ble.startGroundTruthImuCapture(id)) return
            recordingSince = System.currentTimeMillis()
            armed = true
        } else if (!wants && armed) {
            close(ble)
        }
    }

    /** Called when the workout ends. Leaves a pending donation when a window actually recorded. */
    fun finish(context: Context, ble: WhoopBleClient, family: String, firmware: String?) {
        val id = sessionId ?: return reset()
        if (armed) close(ble)
        val seconds = (recordedMs / 1000L).toInt()
        if (seconds >= 30) {
            val store = ImuSessionFileStore(context)
            val payload = payload(store, id)
            SwiftCore.call("donation.record", JSONObject()
                .put("id", id).put("sport", sport).put("seconds", seconds)
                .put("bytes", payload.size).put("family", family)
                .put("firmware", firmware ?: JSONObject.NULL).toString())
            // The bytes stay on the phone until the wearer presses send on the donation page.
            RawDonationCapture.payloadProvider = { wanted ->
                if (wanted == id) payload(ImuSessionFileStore(context), id) else ByteArray(0)
            }
        }
        reset()
    }

    private fun payload(store: ImuSessionFileStore, id: String): ByteArray {
        val segments = runCatching { store.exportSegments(id, 0L, Long.MAX_VALUE / 2) }.getOrDefault(emptyList())
        var out = ByteArray(0)
        segments.forEach { out += it.data }
        return out
    }

    private fun close(ble: WhoopBleClient) {
        if (recordingSince > 0) recordedMs += System.currentTimeMillis() - recordingSince
        recordingSince = 0
        armed = false
        ble.stopGroundTruthImuCapture()
    }

    private fun reset() {
        windows = emptyList()
        sessionId = null
        sport = ""
        recordingSince = 0
        recordedMs = 0
        armed = false
    }
}
