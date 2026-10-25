package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * `OuraAuthWatchdog.step` — the escalation table for an unanswered `get_nonce` (#2304) — and the
 * driver's `authNonceRetryCommand`. Kotlin twin of `OuraAuthWatchdogTests.swift`.
 *
 * ORACLE: [SWIFT_ORACLE] below is the verbatim stdout of the Swift twin compiled standalone
 * (`swiftc -O OuraAuthWatchdog.swift main.swift`) over the same input grid — every 250 ms from 0 to
 * 30 s, plus the 9 999 / 10 000 / 10 001 ms boundary and a 52-minute late timer, each at attempts −1..5.
 * The Kotlin table is rendered the same way and compared as one string, so a divergence in either the
 * timeout or the step order fails here with the first differing cell, not on a strap.
 */
class OuraAuthWatchdogTest {

    private fun code(step: OuraAuthWatchdog.Step) = when (step) {
        OuraAuthWatchdog.Step.WAIT -> "W"
        OuraAuthWatchdog.Step.RESEND_NONCE -> "R"
        OuraAuthWatchdog.Step.TOGGLE_NOTIFY -> "T"
        OuraAuthWatchdog.Step.DROP_LINK -> "D"
    }

    private fun render(): String {
        val out = ArrayList<String>()
        val grid = (0..30_000 step 250).toList() + listOf(9_999, 10_000, 10_001, 3_120_000)
        for (ms in grid) {
            for (attempt in -1..5) {
                out.add("$ms:$attempt=" + code(OuraAuthWatchdog.step(ms.toLong(), attempt)))
            }
        }
        return out.joinToString(" ")
    }

    @Test
    fun tableMatchesTheSwiftOracleByteForByte() {
        assertEquals(SWIFT_ORACLE, render())
    }

    // --- The same named cases as the Swift suite, for a readable failure ---

    @Test
    fun waitsInsideTheTimeoutWhateverTheAttempt() {
        for (ms in listOf(0L, 500L, 1_000L, 5_000L, 9_990L)) {
            for (attempt in 0..3) {
                assertEquals("${ms}ms / attempt $attempt is inside the timeout",
                    OuraAuthWatchdog.Step.WAIT, OuraAuthWatchdog.step(ms, attempt))
            }
        }
    }

    @Test
    fun escalatesInOrderThenDrops() {
        assertEquals(OuraAuthWatchdog.Step.RESEND_NONCE, OuraAuthWatchdog.step(10_000, 0))
        assertEquals(OuraAuthWatchdog.Step.TOGGLE_NOTIFY, OuraAuthWatchdog.step(10_000, 1))
        assertEquals(OuraAuthWatchdog.Step.DROP_LINK, OuraAuthWatchdog.step(10_000, 2))
        for (attempt in 3..10) {
            assertEquals(OuraAuthWatchdog.Step.DROP_LINK, OuraAuthWatchdog.step(10_000, attempt))
        }
    }

    @Test
    fun timeoutBoundaryIsInclusive() {
        assertEquals(OuraAuthWatchdog.Step.WAIT, OuraAuthWatchdog.step(9_999, 0))
        assertEquals(OuraAuthWatchdog.Step.RESEND_NONCE, OuraAuthWatchdog.step(10_000, 0))
    }

    @Test
    fun aLateTimerStillEscalates() {
        assertEquals(OuraAuthWatchdog.Step.RESEND_NONCE, OuraAuthWatchdog.step(3_120_000, 0))
        assertEquals(OuraAuthWatchdog.Step.DROP_LINK, OuraAuthWatchdog.step(3_120_000, 2))
    }

    @Test
    fun negativeAttemptCountsAsNone() {
        assertEquals(OuraAuthWatchdog.Step.RESEND_NONCE, OuraAuthWatchdog.step(10_000, -1))
    }

    // --- The driver gate ---

    private val key: IntArray = IntArray(16) { it }

    @Test
    fun retryCommandIsTheReadyStepsGetNonce() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        val onReady = d.nextStep(OuraTransition.Ready)
        assertEquals(OuraDriverPhase.Authenticating, d.phase)
        val retry = d.authNonceRetryCommand()
        assertNotNull(retry)
        assertEquals("get_nonce", retry!!.label)
        assertEquals(onReady[1].bytes.toList(), retry.bytes.toList())
        assertEquals(OuraDriverPhase.Authenticating, d.phase)
    }

    @Test
    fun retryCommandIsNullOutsideAuthenticating() {
        val idle = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        assertNull(idle.authNonceRetryCommand())

        val keyless = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = null)
        keyless.nextStep(OuraTransition.Ready)
        assertEquals(OuraDriverPhase.NeedsKeyInstall, keyless.phase)
        assertNull(keyless.authNonceRetryCommand())

        val past = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        past.nextStep(OuraTransition.Ready)
        past.nextStep(OuraTransition.AuthCompleted(OuraAuthStatus.SUCCESS))
        assertEquals(OuraDriverPhase.EnablingLiveHR, past.phase)
        assertNull(past.authNonceRetryCommand())

        val failed = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        failed.nextStep(OuraTransition.Ready)
        failed.nextStep(OuraTransition.AuthCompleted(OuraAuthStatus.AUTH_ERROR))
        assertEquals(OuraDriverPhase.AuthFailed(OuraAuthStatus.AUTH_ERROR), failed.phase)
        assertNull(failed.authNonceRetryCommand())

        val stopped = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        stopped.nextStep(OuraTransition.Ready)
        stopped.stop()
        assertNull(stopped.authNonceRetryCommand())
    }

    @Test
    fun watchdogNeverReachesAuthFailed() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        d.nextStep(OuraTransition.Ready)
        val steps = ArrayList<OuraAuthWatchdog.Step>()
        for (attempt in 0 until 3) {
            val step = OuraAuthWatchdog.step(OuraAuthWatchdog.NONCE_TIMEOUT_MS, attempt)
            steps.add(step)
            if (step == OuraAuthWatchdog.Step.RESEND_NONCE || step == OuraAuthWatchdog.Step.TOGGLE_NOTIFY) {
                assertNotNull(d.authNonceRetryCommand())
            }
        }
        assertEquals(
            listOf(OuraAuthWatchdog.Step.RESEND_NONCE, OuraAuthWatchdog.Step.TOGGLE_NOTIFY, OuraAuthWatchdog.Step.DROP_LINK),
            steps,
        )
        assertEquals(OuraDriverPhase.Authenticating, d.phase)
    }

    private companion object {
        /** Verbatim stdout of the Swift twin over the grid described in the class doc. */
        const val SWIFT_ORACLE: String =
            "0:-1=W 0:0=W 0:1=W 0:2=W 0:3=W 0:4=W 0:5=W 250:-1=W 250:0=W 250:1=W 250:2=W 250:3=W 250:4=W " +
            "250:5=W 500:-1=W 500:0=W 500:1=W 500:2=W 500:3=W 500:4=W 500:5=W 750:-1=W 750:0=W 750:1=W " +
            "750:2=W 750:3=W 750:4=W 750:5=W 1000:-1=W 1000:0=W 1000:1=W 1000:2=W 1000:3=W 1000:4=W 1000:5=W " +
            "1250:-1=W 1250:0=W 1250:1=W 1250:2=W 1250:3=W 1250:4=W 1250:5=W 1500:-1=W 1500:0=W 1500:1=W " +
            "1500:2=W 1500:3=W 1500:4=W 1500:5=W 1750:-1=W 1750:0=W 1750:1=W 1750:2=W 1750:3=W 1750:4=W " +
            "1750:5=W 2000:-1=W 2000:0=W 2000:1=W 2000:2=W 2000:3=W 2000:4=W 2000:5=W 2250:-1=W 2250:0=W " +
            "2250:1=W 2250:2=W 2250:3=W 2250:4=W 2250:5=W 2500:-1=W 2500:0=W 2500:1=W 2500:2=W 2500:3=W " +
            "2500:4=W 2500:5=W 2750:-1=W 2750:0=W 2750:1=W 2750:2=W 2750:3=W 2750:4=W 2750:5=W 3000:-1=W " +
            "3000:0=W 3000:1=W 3000:2=W 3000:3=W 3000:4=W 3000:5=W 3250:-1=W 3250:0=W 3250:1=W 3250:2=W " +
            "3250:3=W 3250:4=W 3250:5=W 3500:-1=W 3500:0=W 3500:1=W 3500:2=W 3500:3=W 3500:4=W 3500:5=W " +
            "3750:-1=W 3750:0=W 3750:1=W 3750:2=W 3750:3=W 3750:4=W 3750:5=W 4000:-1=W 4000:0=W 4000:1=W " +
            "4000:2=W 4000:3=W 4000:4=W 4000:5=W 4250:-1=W 4250:0=W 4250:1=W 4250:2=W 4250:3=W 4250:4=W " +
            "4250:5=W 4500:-1=W 4500:0=W 4500:1=W 4500:2=W 4500:3=W 4500:4=W 4500:5=W 4750:-1=W 4750:0=W " +
            "4750:1=W 4750:2=W 4750:3=W 4750:4=W 4750:5=W 5000:-1=W 5000:0=W 5000:1=W 5000:2=W 5000:3=W " +
            "5000:4=W 5000:5=W 5250:-1=W 5250:0=W 5250:1=W 5250:2=W 5250:3=W 5250:4=W 5250:5=W 5500:-1=W " +
            "5500:0=W 5500:1=W 5500:2=W 5500:3=W 5500:4=W 5500:5=W 5750:-1=W 5750:0=W 5750:1=W 5750:2=W " +
            "5750:3=W 5750:4=W 5750:5=W 6000:-1=W 6000:0=W 6000:1=W 6000:2=W 6000:3=W 6000:4=W 6000:5=W " +
            "6250:-1=W 6250:0=W 6250:1=W 6250:2=W 6250:3=W 6250:4=W 6250:5=W 6500:-1=W 6500:0=W 6500:1=W " +
            "6500:2=W 6500:3=W 6500:4=W 6500:5=W 6750:-1=W 6750:0=W 6750:1=W 6750:2=W 6750:3=W 6750:4=W " +
            "6750:5=W 7000:-1=W 7000:0=W 7000:1=W 7000:2=W 7000:3=W 7000:4=W 7000:5=W 7250:-1=W 7250:0=W " +
            "7250:1=W 7250:2=W 7250:3=W 7250:4=W 7250:5=W 7500:-1=W 7500:0=W 7500:1=W 7500:2=W 7500:3=W " +
            "7500:4=W 7500:5=W 7750:-1=W 7750:0=W 7750:1=W 7750:2=W 7750:3=W 7750:4=W 7750:5=W 8000:-1=W " +
            "8000:0=W 8000:1=W 8000:2=W 8000:3=W 8000:4=W 8000:5=W 8250:-1=W 8250:0=W 8250:1=W 8250:2=W " +
            "8250:3=W 8250:4=W 8250:5=W 8500:-1=W 8500:0=W 8500:1=W 8500:2=W 8500:3=W 8500:4=W 8500:5=W " +
            "8750:-1=W 8750:0=W 8750:1=W 8750:2=W 8750:3=W 8750:4=W 8750:5=W 9000:-1=W 9000:0=W 9000:1=W " +
            "9000:2=W 9000:3=W 9000:4=W 9000:5=W 9250:-1=W 9250:0=W 9250:1=W 9250:2=W 9250:3=W 9250:4=W " +
            "9250:5=W 9500:-1=W 9500:0=W 9500:1=W 9500:2=W 9500:3=W 9500:4=W 9500:5=W 9750:-1=W 9750:0=W " +
            "9750:1=W 9750:2=W 9750:3=W 9750:4=W 9750:5=W 10000:-1=R 10000:0=R 10000:1=T 10000:2=D 10000:3=D " +
            "10000:4=D 10000:5=D 10250:-1=R 10250:0=R 10250:1=T 10250:2=D 10250:3=D 10250:4=D 10250:5=D " +
            "10500:-1=R 10500:0=R 10500:1=T 10500:2=D 10500:3=D 10500:4=D 10500:5=D 10750:-1=R 10750:0=R " +
            "10750:1=T 10750:2=D 10750:3=D 10750:4=D 10750:5=D 11000:-1=R 11000:0=R 11000:1=T 11000:2=D " +
            "11000:3=D 11000:4=D 11000:5=D 11250:-1=R 11250:0=R 11250:1=T 11250:2=D 11250:3=D 11250:4=D " +
            "11250:5=D 11500:-1=R 11500:0=R 11500:1=T 11500:2=D 11500:3=D 11500:4=D 11500:5=D 11750:-1=R " +
            "11750:0=R 11750:1=T 11750:2=D 11750:3=D 11750:4=D 11750:5=D 12000:-1=R 12000:0=R 12000:1=T " +
            "12000:2=D 12000:3=D 12000:4=D 12000:5=D 12250:-1=R 12250:0=R 12250:1=T 12250:2=D 12250:3=D " +
            "12250:4=D 12250:5=D 12500:-1=R 12500:0=R 12500:1=T 12500:2=D 12500:3=D 12500:4=D 12500:5=D " +
            "12750:-1=R 12750:0=R 12750:1=T 12750:2=D 12750:3=D 12750:4=D 12750:5=D 13000:-1=R 13000:0=R " +
            "13000:1=T 13000:2=D 13000:3=D 13000:4=D 13000:5=D 13250:-1=R 13250:0=R 13250:1=T 13250:2=D " +
            "13250:3=D 13250:4=D 13250:5=D 13500:-1=R 13500:0=R 13500:1=T 13500:2=D 13500:3=D 13500:4=D " +
            "13500:5=D 13750:-1=R 13750:0=R 13750:1=T 13750:2=D 13750:3=D 13750:4=D 13750:5=D 14000:-1=R " +
            "14000:0=R 14000:1=T 14000:2=D 14000:3=D 14000:4=D 14000:5=D 14250:-1=R 14250:0=R 14250:1=T " +
            "14250:2=D 14250:3=D 14250:4=D 14250:5=D 14500:-1=R 14500:0=R 14500:1=T 14500:2=D 14500:3=D " +
            "14500:4=D 14500:5=D 14750:-1=R 14750:0=R 14750:1=T 14750:2=D 14750:3=D 14750:4=D 14750:5=D " +
            "15000:-1=R 15000:0=R 15000:1=T 15000:2=D 15000:3=D 15000:4=D 15000:5=D 15250:-1=R 15250:0=R " +
            "15250:1=T 15250:2=D 15250:3=D 15250:4=D 15250:5=D 15500:-1=R 15500:0=R 15500:1=T 15500:2=D " +
            "15500:3=D 15500:4=D 15500:5=D 15750:-1=R 15750:0=R 15750:1=T 15750:2=D 15750:3=D 15750:4=D " +
            "15750:5=D 16000:-1=R 16000:0=R 16000:1=T 16000:2=D 16000:3=D 16000:4=D 16000:5=D 16250:-1=R " +
            "16250:0=R 16250:1=T 16250:2=D 16250:3=D 16250:4=D 16250:5=D 16500:-1=R 16500:0=R 16500:1=T " +
            "16500:2=D 16500:3=D 16500:4=D 16500:5=D 16750:-1=R 16750:0=R 16750:1=T 16750:2=D 16750:3=D " +
            "16750:4=D 16750:5=D 17000:-1=R 17000:0=R 17000:1=T 17000:2=D 17000:3=D 17000:4=D 17000:5=D " +
            "17250:-1=R 17250:0=R 17250:1=T 17250:2=D 17250:3=D 17250:4=D 17250:5=D 17500:-1=R 17500:0=R " +
            "17500:1=T 17500:2=D 17500:3=D 17500:4=D 17500:5=D 17750:-1=R 17750:0=R 17750:1=T 17750:2=D " +
            "17750:3=D 17750:4=D 17750:5=D 18000:-1=R 18000:0=R 18000:1=T 18000:2=D 18000:3=D 18000:4=D " +
            "18000:5=D 18250:-1=R 18250:0=R 18250:1=T 18250:2=D 18250:3=D 18250:4=D 18250:5=D 18500:-1=R " +
            "18500:0=R 18500:1=T 18500:2=D 18500:3=D 18500:4=D 18500:5=D 18750:-1=R 18750:0=R 18750:1=T " +
            "18750:2=D 18750:3=D 18750:4=D 18750:5=D 19000:-1=R 19000:0=R 19000:1=T 19000:2=D 19000:3=D " +
            "19000:4=D 19000:5=D 19250:-1=R 19250:0=R 19250:1=T 19250:2=D 19250:3=D 19250:4=D 19250:5=D " +
            "19500:-1=R 19500:0=R 19500:1=T 19500:2=D 19500:3=D 19500:4=D 19500:5=D 19750:-1=R 19750:0=R " +
            "19750:1=T 19750:2=D 19750:3=D 19750:4=D 19750:5=D 20000:-1=R 20000:0=R 20000:1=T 20000:2=D " +
            "20000:3=D 20000:4=D 20000:5=D 20250:-1=R 20250:0=R 20250:1=T 20250:2=D 20250:3=D 20250:4=D " +
            "20250:5=D 20500:-1=R 20500:0=R 20500:1=T 20500:2=D 20500:3=D 20500:4=D 20500:5=D 20750:-1=R " +
            "20750:0=R 20750:1=T 20750:2=D 20750:3=D 20750:4=D 20750:5=D 21000:-1=R 21000:0=R 21000:1=T " +
            "21000:2=D 21000:3=D 21000:4=D 21000:5=D 21250:-1=R 21250:0=R 21250:1=T 21250:2=D 21250:3=D " +
            "21250:4=D 21250:5=D 21500:-1=R 21500:0=R 21500:1=T 21500:2=D 21500:3=D 21500:4=D 21500:5=D " +
            "21750:-1=R 21750:0=R 21750:1=T 21750:2=D 21750:3=D 21750:4=D 21750:5=D 22000:-1=R 22000:0=R " +
            "22000:1=T 22000:2=D 22000:3=D 22000:4=D 22000:5=D 22250:-1=R 22250:0=R 22250:1=T 22250:2=D " +
            "22250:3=D 22250:4=D 22250:5=D 22500:-1=R 22500:0=R 22500:1=T 22500:2=D 22500:3=D 22500:4=D " +
            "22500:5=D 22750:-1=R 22750:0=R 22750:1=T 22750:2=D 22750:3=D 22750:4=D 22750:5=D 23000:-1=R " +
            "23000:0=R 23000:1=T 23000:2=D 23000:3=D 23000:4=D 23000:5=D 23250:-1=R 23250:0=R 23250:1=T " +
            "23250:2=D 23250:3=D 23250:4=D 23250:5=D 23500:-1=R 23500:0=R 23500:1=T 23500:2=D 23500:3=D " +
            "23500:4=D 23500:5=D 23750:-1=R 23750:0=R 23750:1=T 23750:2=D 23750:3=D 23750:4=D 23750:5=D " +
            "24000:-1=R 24000:0=R 24000:1=T 24000:2=D 24000:3=D 24000:4=D 24000:5=D 24250:-1=R 24250:0=R " +
            "24250:1=T 24250:2=D 24250:3=D 24250:4=D 24250:5=D 24500:-1=R 24500:0=R 24500:1=T 24500:2=D " +
            "24500:3=D 24500:4=D 24500:5=D 24750:-1=R 24750:0=R 24750:1=T 24750:2=D 24750:3=D 24750:4=D " +
            "24750:5=D 25000:-1=R 25000:0=R 25000:1=T 25000:2=D 25000:3=D 25000:4=D 25000:5=D 25250:-1=R " +
            "25250:0=R 25250:1=T 25250:2=D 25250:3=D 25250:4=D 25250:5=D 25500:-1=R 25500:0=R 25500:1=T " +
            "25500:2=D 25500:3=D 25500:4=D 25500:5=D 25750:-1=R 25750:0=R 25750:1=T 25750:2=D 25750:3=D " +
            "25750:4=D 25750:5=D 26000:-1=R 26000:0=R 26000:1=T 26000:2=D 26000:3=D 26000:4=D 26000:5=D " +
            "26250:-1=R 26250:0=R 26250:1=T 26250:2=D 26250:3=D 26250:4=D 26250:5=D 26500:-1=R 26500:0=R " +
            "26500:1=T 26500:2=D 26500:3=D 26500:4=D 26500:5=D 26750:-1=R 26750:0=R 26750:1=T 26750:2=D " +
            "26750:3=D 26750:4=D 26750:5=D 27000:-1=R 27000:0=R 27000:1=T 27000:2=D 27000:3=D 27000:4=D " +
            "27000:5=D 27250:-1=R 27250:0=R 27250:1=T 27250:2=D 27250:3=D 27250:4=D 27250:5=D 27500:-1=R " +
            "27500:0=R 27500:1=T 27500:2=D 27500:3=D 27500:4=D 27500:5=D 27750:-1=R 27750:0=R 27750:1=T " +
            "27750:2=D 27750:3=D 27750:4=D 27750:5=D 28000:-1=R 28000:0=R 28000:1=T 28000:2=D 28000:3=D " +
            "28000:4=D 28000:5=D 28250:-1=R 28250:0=R 28250:1=T 28250:2=D 28250:3=D 28250:4=D 28250:5=D " +
            "28500:-1=R 28500:0=R 28500:1=T 28500:2=D 28500:3=D 28500:4=D 28500:5=D 28750:-1=R 28750:0=R " +
            "28750:1=T 28750:2=D 28750:3=D 28750:4=D 28750:5=D 29000:-1=R 29000:0=R 29000:1=T 29000:2=D " +
            "29000:3=D 29000:4=D 29000:5=D 29250:-1=R 29250:0=R 29250:1=T 29250:2=D 29250:3=D 29250:4=D " +
            "29250:5=D 29500:-1=R 29500:0=R 29500:1=T 29500:2=D 29500:3=D 29500:4=D 29500:5=D 29750:-1=R " +
            "29750:0=R 29750:1=T 29750:2=D 29750:3=D 29750:4=D 29750:5=D 30000:-1=R 30000:0=R 30000:1=T " +
            "30000:2=D 30000:3=D 30000:4=D 30000:5=D 9999:-1=W 9999:0=W 9999:1=W 9999:2=W 9999:3=W 9999:4=W " +
            "9999:5=W 10000:-1=R 10000:0=R 10000:1=T 10000:2=D 10000:3=D 10000:4=D 10000:5=D 10001:-1=R " +
            "10001:0=R 10001:1=T 10001:2=D 10001:3=D 10001:4=D 10001:5=D 3120000:-1=R 3120000:0=R 3120000:1=T " +
            "3120000:2=D 3120000:3=D 3120000:4=D 3120000:5=D"
    }
}
