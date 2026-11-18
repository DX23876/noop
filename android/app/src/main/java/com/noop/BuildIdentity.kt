package com.noop

/**
 * Which build this is, in one place.
 *
 * A tester's report is only usable against the code it was made on, and until now nothing in the app
 * said which build that was: `versionName` is the release train ("13.0.0") and `versionCode` has been 1
 * on every build ever made, so a strap log from the build that carried a fix read exactly like one from
 * the build before it (#47). The missing piece is [BuildConfig.BUILD_STAMP] — an opaque string the
 * builder supplies (CI passes the channel, the commit and the date, a local release build falls back to
 * the checkout's own commit) that this object never parses and only ever prints.
 *
 * Since 2026-11-18 that string LEADS with the channel, `testing` or `release`, because nothing else in
 * the app could say which kind of build it was: a testing build and the release of the same train both
 * read "13.0.0", and every workflow stamped the bare commit and date. The word is the builder's to
 * supply, not this object's to infer, so an unstamped build claims neither.
 *
 * ONE resolver, not a format repeated at every call site: the strap log, the Test Centre bundle and the
 * screen footers all have to name the same build, and the way two readouts of one fact start disagreeing
 * is each composing it for itself. The formatting functions take their parts, so they are testable
 * without a build variant, and the properties are the only place `BuildConfig` is read for identity.
 */
object BuildIdentity {

    /** The build stamp, or null on a build that was not stamped (every debug build, by design). */
    val stamp: String? get() = BuildConfig.BUILD_STAMP.trim().takeIf { it.isNotEmpty() }

    /** What a screen footer shows: the version, and the stamp when there is one. */
    val uiVersion: String get() = uiVersion(BuildConfig.VERSION_NAME, stamp)

    /** The `App:` line every shared diagnostic starts with. */
    val logLine: String
        get() = logLine(
            version = BuildConfig.VERSION_NAME,
            tier = BuildConfig.TIER,
            versionCode = BuildConfig.VERSION_CODE,
            applicationId = BuildConfig.APPLICATION_ID,
            stamp = stamp,
        )

    internal fun uiVersion(version: String, stamp: String?): String =
        if (stamp == null) version else "$version · $stamp"

    /**
     * An unstamped build says so rather than leaving the field out. Silence there reads as "this log is
     * from some build or other", which is the state we were in; "no build stamp" says the log cannot
     * name its build and that the build was not made by CI.
     */
    internal fun logLine(
        version: String,
        tier: String,
        versionCode: Int,
        applicationId: String,
        stamp: String?,
    ): String = "App:     $version ($tier) build $versionCode · ${stamp ?: "no build stamp"} · $applicationId"
}
