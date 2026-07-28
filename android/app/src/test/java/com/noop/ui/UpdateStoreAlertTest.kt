package com.noop.ui

import android.content.SharedPreferences
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Plain-JVM mirror of UpdateInboxAlertTests: event rows refresh by day key and expire locally. */
class UpdateStoreAlertTest {
    @Test
    fun sameAlertKey_refreshesOneRow_rearmsUnread_andPersists() {
        val prefs = FakeSharedPreferences()
        val store = UpdateStore.forTesting(prefs)
        val first = 900_000_000_000L
        store.postOrRefreshAlert("battery-low:2028-07-10", "Low battery", "20% remaining", "devices", first + DAY, first)
        val id = store.items.single().id
        store.markRead(id)

        store.postOrRefreshAlert("battery-low:2028-07-10", "Low battery", "15% remaining", "devices", first + 2 * DAY, first + 60_000L)

        assertEquals(1, store.items.size)
        assertEquals(id, store.items.single().id)
        assertEquals("15% remaining", store.items.single().message)
        assertFalse(store.items.single().read)
        val reloaded = UpdateStore.forTesting(prefs)
        assertEquals("battery-low:2028-07-10", reloaded.items.single().alertKey)
    }

    @Test
    fun expiryAtNow_removesOnlyTheAlert() {
        val store = UpdateStore.forTesting(FakeSharedPreferences())
        val now = 900_000_000_000L
        store.post(UpdateItem(kind = UpdateKind.WHATS_NEW, title = "Release", message = "Still here", date = now))
        store.postOrRefreshAlert("inactivity:2028-07-10", "Time to move", "Walk", expiresAt = now + DAY, now = now)

        store.pruneExpired(now + DAY)

        assertEquals(1, store.items.size)
        assertEquals(UpdateKind.WHATS_NEW, store.items.single().kind)
    }

    @Test
    fun legacyJsonWithoutAlertFields_remainsReadable() {
        val item = UpdateItem.fromJson(JSONObject("""{"id":"1","kind":"reading","title":"T","message":"M","date":1,"read":false}"""))
        assertNull(item.alertKey)
        assertNull(item.expiresAt)
        assertEquals(UpdateKind.READING, item.kind)
    }

    @Test
    fun alertKinds_matchAppleTargetsAndLifetimes() {
        assertEquals("devices", AlertInbox.Kind.BATTERY_LOW.deepLink)
        assertEquals("devices", AlertInbox.Kind.BATTERY_RUNTIME.deepLink)
        assertEquals("devices", AlertInbox.Kind.BATTERY_FULL.deepLink)
        assertNull(AlertInbox.Kind.ILLNESS.deepLink)
        assertNull(AlertInbox.Kind.INACTIVITY.deepLink)
        assertNull(AlertInbox.Kind.SMART_ALARM.deepLink)
        assertTrue(AlertInbox.Kind.BATTERY_LOW.lifetimeMs > AlertInbox.Kind.ILLNESS.lifetimeMs)
    }

    private class FakeSharedPreferences : SharedPreferences {
        private val map = HashMap<String, Any?>()
        override fun getAll(): MutableMap<String, *> = HashMap(map)
        override fun getString(key: String, defValue: String?): String? = map[key] as? String ?: defValue
        override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? = map[key] as? MutableSet<String> ?: defValues
        override fun getInt(key: String, defValue: Int): Int = map[key] as? Int ?: defValue
        override fun getLong(key: String, defValue: Long): Long = map[key] as? Long ?: defValue
        override fun getFloat(key: String, defValue: Float): Float = map[key] as? Float ?: defValue
        override fun getBoolean(key: String, defValue: Boolean): Boolean = map[key] as? Boolean ?: defValue
        override fun contains(key: String): Boolean = map.containsKey(key)
        override fun edit(): SharedPreferences.Editor = Editor()
        override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
        override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit

        private inner class Editor : SharedPreferences.Editor {
            private val pending = HashMap<String, Any?>()
            override fun putString(key: String, value: String?) = apply { pending[key] = value }
            override fun putStringSet(key: String, values: MutableSet<String>?) = apply { pending[key] = values }
            override fun putInt(key: String, value: Int) = apply { pending[key] = value }
            override fun putLong(key: String, value: Long) = apply { pending[key] = value }
            override fun putFloat(key: String, value: Float) = apply { pending[key] = value }
            override fun putBoolean(key: String, value: Boolean) = apply { pending[key] = value }
            override fun remove(key: String) = apply { pending[key] = null }
            override fun clear() = apply { map.clear() }
            override fun commit(): Boolean { apply(); return true }
            override fun apply() { pending.forEach { (key, value) -> if (value == null) map.remove(key) else map[key] = value } }
        }
    }

    private companion object {
        const val DAY = 24L * 60L * 60L * 1000L
    }
}
