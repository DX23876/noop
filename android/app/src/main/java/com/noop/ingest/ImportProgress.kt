package com.noop.ingest

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.noop.R
import com.noop.ui.appLaunchIntent
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Fork (DX23876), 2026-11-15: where an import has got to, resolved ONCE and read by everything that
 * shows it.
 *
 * A Health Connect import over the ten-year window can run for minutes, and until now it said nothing
 * at all: the Data sources screen greyed every button while it ran and the strap log carried one line
 * when it started and one when it ended. A tester watched that for a quarter of an hour on 2026-11-14
 * and could report only that it was stuck, which is the one thing the evidence could not distinguish
 * from slow. The screen could not say either, because it had nothing to say.
 *
 * Three readers now: the screen the wearer started it from, the home screen, and a notification that
 * carries it to the lock screen. They must not be able to disagree, so none of them works anything out.
 * [state] is the single fact, every writer below sets it, and the strap log is written from the same
 * call. What the log gets is the technical detail (the record type's own name), what a screen gets is
 * the step in the wearer's language and a count — the type names are not user copy and translating
 * fourteen of them would buy nothing.
 *
 * A step is not a percentage. Health Connect does not say how many records a type holds before it is
 * read, so the honest readout is which step is running and how much has come back so far. A progress
 * bar would have to invent a total.
 */
object ImportProgress {

    /** The steps an import passes through, in order. */
    enum class Step { READING, SORTING, SAVING }

    /**
     * [source] is the importer's own label ("health-connect"), which goes to the LOG only: it is the name
     * the closing "Import <source>: …" summary already uses, and it is not language anybody speaks. A
     * screen says only that an import is running, since one runs at a time. [detail] is the technical name
     * of what is being read right now, also log-only and null once the reads are done, and [records] is
     * everything read so far across every type.
     */
    data class State(val source: String, val step: Step, val detail: String?, val records: Int)

    /**
     * Something the last import could not do. [kindKey] is the data type's own storage key
     * (`HealthConnectImporter.ImportType.storageKey`) when the failure belongs to one, so a screen can
     * name it in the wearer's language without this object knowing any language; null when it belongs to
     * the import as a whole. [reason] is what actually threw, kept verbatim: it is usually Health
     * Connect's own English sentence, and a translated "something went wrong" would be the one thing a
     * reader cannot act on.
     */
    data class Problem(val kindKey: String?, val reason: String)

    private val _state = MutableStateFlow<State?>(null)
    private val _problems = MutableStateFlow<List<Problem>>(emptyList())

    /** Null when no import is running. */
    val state: StateFlow<State?> = _state.asStateFlow()

    /**
     * What the last import could not do, kept after it ends and cleared when the next one begins.
     *
     * Until 2026-11-15 these were swallowed where they happened: a record type Health Connect refused was
     * written to Android's own log, which an exported strap log does not contain and a wearer cannot see
     * at all, and four healing and side steps were caught and dropped in silence. The import then reported
     * a cheerful row count for data that was missing, and there was no way to tell a type that holds
     * nothing from one that could not be read.
     */
    val problems: StateFlow<List<Problem>> = _problems.asStateFlow()

    /** True while an import is running, for a screen that only disables its buttons. */
    val running: Boolean get() = _state.value != null

    private const val CHANNEL_ID = "noop_import_progress"
    private const val NOTIF_ID = 4215

    /**
     * Starts an import's progress. [source] is the importer's label, as it already appears in the strap
     * log's "Import <source>: …" summary, so the running lines and the closing one name the same thing.
     */
    fun begin(context: Context, source: String) {
        _state.value = State(source, Step.READING, detail = null, records = 0)
        _problems.value = emptyList()
        log(context, "Import $source: started")
        notify(context)
    }

    /**
     * A failure the wearer should see, because it is about data they asked for: a record type that could
     * not be read, a write that did not land. It goes to the strap log as well, with the detail, so the
     * screen and the log cannot tell different stories about the same run.
     *
     * Recorded even when no import is running, unlike a step: a failure is worth keeping whether or not
     * the run that produced it reported a start, and dropping it is the behaviour being fixed here.
     */
    fun problem(context: Context, kindKey: String?, reason: String) {
        _problems.value = _problems.value + Problem(kindKey, reason)
        val source = _state.value?.source ?: "import"
        log(context, "Import $source: ${kindKey ?: "a step"} failed — $reason")
    }

    /**
     * A failure that belongs in the log but not on screen: the healing and refiling steps an import runs
     * before its own work, which are best-effort by design and name nothing a wearer chose. Silence was
     * still wrong — one of them failing every time is exactly the kind of thing nobody finds — but a note
     * about "refiling legacy rows" under the import button would be noise in front of the real ones.
     */
    fun quietFailure(context: Context, step: String, reason: String) {
        log(context, "Import ${_state.value?.source ?: "import"}: $step failed — $reason (best effort, continuing)")
    }

    /**
     * The step changed. [detail] names what it is working on for the log only. Silent when no import is
     * running: an importer that does not report a start must not be able to leave a step on screen.
     */
    fun step(context: Context, step: Step, detail: String? = null) {
        val current = _state.value ?: return
        _state.value = current.copy(step = step, detail = detail)
        log(context, "Import ${current.source}: ${step.name.lowercase()}" +
            (detail?.let { " $it" } ?: "") + " (${current.records} record(s) so far)")
        notify(context)
    }

    /**
     * Records that came back from one read. Deliberately NOT logged: a line per read would bury the
     * steps, and the count is carried into the next step's line anyway. It still updates [state], so a
     * screen watching a long read sees the number climb rather than a frozen step.
     */
    fun read(records: Int) {
        if (records <= 0) return
        val current = _state.value ?: return
        _state.value = current.copy(records = current.records + records)
        // No notification refresh here: a read can return thousands of times and the system throttles an
        // over-eager notifier. The step changes carry it.
    }

    /**
     * The import is over, however it went. The closing summary line is the importer's own, so this one
     * says nothing more than that the progress is gone. Safe to call when none was running.
     */
    fun end(context: Context) {
        if (_state.value == null) return
        _state.value = null
        runCatching { NotificationManagerCompat.from(context).cancel(NOTIF_ID) }
    }

    /** The strap log, so an import's course sits in the same exported file as everything else. */
    private fun log(context: Context, line: String) {
        runCatching {
            (context.applicationContext as? com.noop.NoopApplication)?.ble?.externalLog(line)
        }
    }

    /**
     * The lock-screen readout: an ongoing, silent notification that is updated on each step and cancelled
     * at the end. Not a foreground service, so it does not let the import outlive the app being killed —
     * what it does is let the wearer watch it without keeping the screen on the import page, which is the
     * thing that was missing. It is also why the import must not be tied to a screen's lifetime.
     */
    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    private fun notify(context: Context) {
        val current = _state.value ?: return
        runCatching {
            val manager = NotificationManagerCompat.from(context)
            if (!manager.areNotificationsEnabled()) return
            ensureChannel(context)
            val open = android.app.PendingIntent.getActivity(
                context, 15, appLaunchIntent(context),
                android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(context.getString(R.string.forge_import_progress_title))
                .setContentText(stepLabel(context, current))
                .setContentIntent(open)
                .setOngoing(true)
                .setSilent(true)
                .setProgress(0, 0, true)
                .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .build()
            manager.notify(NOTIF_ID, notification)
        }
    }

    /**
     * The one sentence a reader sees, in the wearer's language: the step, and the records so far once
     * there are any. Shared by the notification and the screens so the lock screen cannot word it
     * differently from the page the import was started on.
     */
    fun stepLabel(context: Context, state: State): String = joinedLabel(
        step = context.getString(
            when (state.step) {
                Step.READING -> R.string.forge_import_step_reading
                Step.SORTING -> R.string.forge_import_step_sorting
                Step.SAVING -> R.string.forge_import_step_saving
            },
        ),
        entries = if (state.records > 0) {
            context.getString(R.string.forge_import_progress_entries, state.records)
        } else {
            null
        },
    )

    /**
     * The two halves joined, apart from the resources so it can be tested where a unit test has none
     * (this module does not build its resources for them). It takes no [State]: that is what keeps the
     * importer's own key out of what a wearer reads, by construction rather than by a reviewer noticing.
     * A count of zero arrives here as null, since "0 entries" beside "Reading data" says less than the
     * step alone and reads like a failure while a long first read is still running.
     */
    internal fun joinedLabel(step: String, entries: String?): String =
        if (entries.isNullOrEmpty()) step else "$step · $entries"

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Import progress", NotificationManager.IMPORTANCE_LOW)
                    .apply { description = "How far a running data import has got." },
            )
        }
    }
}
