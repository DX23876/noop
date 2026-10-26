# Testing NOOP Forge on Android

The Android build is in **testing** (decision D9 in [`PLAN.md`](PLAN.md)). It stays labelled that way, in the
app and on the release, until three testers on different phones have confirmed the four things below, each with
a strap log. Thank you for being one of them.

## Install

1. On the [releases page](https://github.com/DX23876/noop/releases), download
   `NOOP-Forge-android-<version>-testing.apk` from the newest release that has one.
2. Open it on the phone and allow installing from this source when Android asks.
3. Open NOOP Forge, accept the terms and go through the setup. It pairs your strap on the way.

Android 8 or later and a WHOOP 4.0, 5.0 or MG. Everything stays on the phone: no account, no server.

## What to confirm

Each one counts once it worked, with a strap log from that day (**More → Share strap log**).

| | What | How you can tell |
|---|---|---|
| 1 | **Pairing** | More → Strap shows your strap as connected |
| 2 | **Live heart rate** | Today shows a heart rate card marked live while you wear the strap |
| 3 | **Overnight sync** | The next morning Today has Charge and Rest, and Sleep shows last night |
| 4 | **Reconnect** | Walk out of range for a few minutes, come back: the strap connects again by itself |

Report the result as an issue with the **Android bug report (testing)** form, also when everything worked (say
so in "What happened"). Attach the strap log.

## The experimental switch

**More → Experimental → Shared core confirms history** is off by default. On, the strap only deletes its
history after the app's shared core has saved it. If you turn it on, keep it on for a night and send the strap
log of the next morning: each history chunk should appear as acked, and a line starting with
`Backfill: holding ack` means the core was too slow for that chunk (the strap keeps it and sends it again,
nothing is lost).

## If something goes wrong

- The classic screens are still there: **More → Classic screens**. Their Settings switch back.
- **More → Export backup** saves everything as a `.noopbak` file before you try something risky. Importing a
  large backup (a phone with months of history) can take many minutes; keep the app open until it finishes.
- A crash or a strap that will not connect: open the bug form, describe what you did, attach the strap log.
