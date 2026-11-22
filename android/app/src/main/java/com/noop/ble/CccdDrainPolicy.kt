package com.noop.ble

/**
 * When a notify subscribe may be retried, when the 5/MG connect handshake may be called done, and what a
 * link whose handshake never finished is worth.
 *
 * Fork (DX23876), 2026-11-22. A tester's strap log carries twenty CLIENT_HELLO acks and only fourteen
 * `Subscribed fd4b0007` lines; five links never reached a single `Backfill: session started`, one of them
 * for 36 146 seconds, and the wearer's night only arrived after he disconnected the strap by hand and
 * reconnected it. Three separate things in the drain produced that, and all three are decided here so the
 * numbers can be tested without a strap:
 *
 *  - **The retry budget was shared.** `cccdRetries` is cleared on every CONFIRMED subscribe, so a run of
 *    failures spends one budget between all four puffin characteristics. With a flat 60 ms delay the four
 *    of them burned eight attempts in under half a second and every one was dropped — which is the 18:45
 *    link, where all four printed `writeDescriptor rejected … (gave up after 8 retries)` in the same
 *    second. [mayRetry] and [retryDelayMs] are per characteristic, and the delay escalates the way the
 *    command queue's has since #77, for the same reason: a stack that is busy now is busier in 60 ms.
 *
 *  - **An offload needs a channel to arrive on.** The historical records come in on fd4b0003/4/5/7. With
 *    none of them confirmed, declaring the handshake done sends SET_CLOCK and requests an offload that
 *    can only come back empty, which is what the 18:45 link did. [handshakeMayComplete] refuses that;
 *    with at least one channel the frames have somewhere to land, so it allows it.
 *
 *  - **Nothing watched a handshake that never finished.** The keep-alive's stall fuse watches INBOUND
 *    data, and live HR over 0x2A37 keeps flowing on a wedged link, so the fuse never trips (#580/#1414).
 *    [recovery] is what the keep-alive does instead, counted per link so a strap that cannot subscribe is
 *    bounced twice and then left alone rather than bounced every thirty seconds.
 *
 * And the consequence of the second point: a 5/MG whose offload came back empty while its subscriptions
 * were incomplete has proved nothing about its firmware. [countsTowardEmptyStreak] keeps that link out of
 * the empty-offload streak, which would otherwise latch "history sync is experimental on 5.0" and widen
 * the stall fuse to ten minutes on the evidence of our own failed subscribe.
 */
internal object CccdDrainPolicy {

    /** Retries for ONE characteristic's subscribe before it is given up. */
    const val MAX_RETRIES_PER_CHARACTERISTIC = 8

    /** First retry delay; later attempts escalate (see [retryDelayMs]). */
    const val BASE_RETRY_DELAY_MS = 60L

    /** The attempt at which the escalation stops growing, so the budget cannot run to minutes. */
    const val MAX_ESCALATION_STEPS = 8

    /**
     * How long a descriptor write may be in flight before the slot is taken back.
     *
     * The 21:24 link is why this exists: the write was ACCEPTED (no BUSY, no rejection) and
     * `onDescriptorWrite` never fired, so `cccdInFlight` stayed true for the rest of the link, the queue
     * never drained, and the handshake was never declared. Android's own GATT timeout is thirty seconds
     * and does not help here. A subscribe that has not answered in two seconds on a link that is
     * otherwise streaming live HR is not going to answer.
     */
    const val WRITE_TIMEOUT_MS = 2_000L

    /** Whether this characteristic's subscribe may be retried once more. */
    fun mayRetry(attemptsSoFar: Int): Boolean = attemptsSoFar < MAX_RETRIES_PER_CHARACTERISTIC

    /**
     * Delay before the next attempt for ONE characteristic. `attemptsSoFar` is how many have already
     * failed, so the first retry waits [BASE_RETRY_DELAY_MS] and the eighth waits eight times that.
     */
    fun retryDelayMs(attemptsSoFar: Int): Long =
        BASE_RETRY_DELAY_MS * minOf(maxOf(attemptsSoFar, 1), MAX_ESCALATION_STEPS)

    /**
     * Whether the 5/MG handshake tail (SET_CLOCK, then the first offload) may run. The offload arrives on
     * the puffin notify characteristics, so one confirmed channel is the floor: below it there is nothing
     * to receive on and "handshake done" would be a claim with no evidence behind it.
     */
    fun handshakeMayComplete(confirmedNotifyChars: Int): Boolean = confirmedNotifyChars > 0

    /** What the keep-alive does about a handshake that is still unfinished. */
    enum class Recovery {
        /** Queue the notify characteristics again and drain. */
        REDRAIN,

        /** Disconnect so the auto-reconnect rebuilds the link from scratch. */
        BOUNCE,

        /** Twice was enough; say so once and leave the link alone. */
        GIVE_UP,
    }

    /**
     * `attemptsSoFar` is how many recoveries this link has already had. Re-draining first is deliberate:
     * it costs nothing and keeps a link that is otherwise serving live HR, while a bounce throws away a
     * working stream to get the subscriptions back.
     */
    fun recovery(attemptsSoFar: Int): Recovery = when (attemptsSoFar) {
        0 -> Recovery.REDRAIN
        1 -> Recovery.BOUNCE
        else -> Recovery.GIVE_UP
    }

    /**
     * Whether an empty offload on this link is evidence about the strap's firmware. Only when every notify
     * channel was actually subscribed; otherwise the emptiness is ours.
     */
    fun countsTowardEmptyStreak(confirmedNotifyChars: Int, totalNotifyChars: Int): Boolean =
        confirmedNotifyChars >= totalNotifyChars

    /** The line for a handshake that cannot be declared because no channel was confirmed. */
    fun noConfirmedChannelsLine(totalNotifyChars: Int): String =
        "WHOOP 5/MG: none of the $totalNotifyChars notify channels confirmed — not declaring the connect " +
            "handshake done, because a historical offload has nowhere to arrive. The keep-alive will " +
            "re-subscribe, then rebuild the link."

    /** The line for a descriptor write that was accepted and never completed. */
    fun writeTimedOutLine(uuid: String): String =
        "writeDescriptor for $uuid was accepted but never completed within ${WRITE_TIMEOUT_MS}ms — " +
            "taking the GATT slot back and re-queueing it"

    /** The line for an empty offload that is not charged to the firmware. */
    fun emptyOffloadNotChargedLine(confirmedNotifyChars: Int, totalNotifyChars: Int): String =
        "Backfill: the offload was empty, but only $confirmedNotifyChars of $totalNotifyChars notify " +
            "channels were subscribed on this link — not counting it toward the empty-offload streak, " +
            "since the emptiness is as likely ours as the strap's."
}
