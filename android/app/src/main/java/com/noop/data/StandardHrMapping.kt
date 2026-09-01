package com.noop.data

import com.noop.protocol.StandardHrContact
import org.json.JSONObject

/** Durable mapping for standard-BLE contact readings; legacy HR rows have no companion event. */
object StandardHrMapping {
    const val CONTACT_EVENT_KIND = "STANDARD_HR_CONTACT"

    fun contactEvent(ts: Long, contact: StandardHrContact): EventEntry = EventEntry(
        ts = ts,
        kind = CONTACT_EVENT_KIND,
        payloadJSON = "{\"contact\":\"${contact.storageValue}\"}",
    )

    /**
     * Parse a persisted [CONTACT_EVENT_KIND] [EventRow.payloadJSON]. Throws [org.json.JSONException]
     * (or [IllegalArgumentException] for an unknown value) so a parse failure is not the same as
     * "no contact event" — absence is an empty query, not a skipped row.
     */
    fun contactSample(row: EventRow): StandardHrContactSample {
        val raw = JSONObject(row.payloadJSON).getString("contact")
        val contact = StandardHrContact.fromStorageValue(raw)
            ?: throw IllegalArgumentException("unknown STANDARD_HR_CONTACT value: $raw")
        return StandardHrContactSample(row.ts, contact)
    }
}

data class StandardHrContactSample(val ts: Long, val contact: StandardHrContact)
