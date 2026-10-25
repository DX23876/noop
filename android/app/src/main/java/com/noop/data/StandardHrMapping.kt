package com.noop.data

import com.noop.protocol.StandardHrContact
import org.json.JSONObject

/** Durable mapping for standard-BLE contact readings; legacy HR rows have no companion event. */
object StandardHrMapping {
    const val CONTACT_EVENT_KIND = "STANDARD_HR_CONTACT"

    /**
     * Should this reading record a contact event, given the last one recorded?
     *
     * Contact is a STATE, not a measurement: it changes when the strap goes on or comes off, a handful of
     * times a day, while the standard 0x2A37 stream arrives at ~1 Hz. Writing one row per reading stored
     * ~86,400 rows a day per device to say the same thing 86,390 times, into a local-first database, for a
     * read side that reconstructs "the value at or before ts" and therefore only ever needed the changes.
     *
     * `previous == null` records, so every session opens with its starting state and a reader never has to
     * assume one. Twin of Swift `StandardHRMapping.shouldRecordContact`.
     */
    fun shouldRecordContact(previous: StandardHrContact?, current: StandardHrContact): Boolean =
        previous != current

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
