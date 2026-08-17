# FAQ

Answers to the questions that come up most often in issues. If your question isn't here,
[ANALYTICS.md](ANALYTICS.md) documents how every score is computed and
[PRIVACY_SECURITY.md](PRIVACY_SECURITY.md) covers what stays on your device.

---

## Why is NOOP's resting heart rate lower than the WHOOP app's?

**Because they are different statistics over the same night, and the gap is expected.**

NOOP's resting HR is the **lowest sustained level** during your in-bed window — the minimum of the
night's 5-minute non-overlapping bin means. That rejects single-beat dips while capturing the night's
true floor.

The WHOOP app's figure sits closer to the **whole-night average**, which is naturally a few bpm
higher. Typical reported gaps are 5–8 bpm.

Neither number is wrong. NOOP logs both side by side so you can check it yourself — look for this
line in your strap log:

```
rhr day=2026-07-16 floor=44 nightMean=50 inBedSamples=30247
(floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
```

`floor` is what NOOP shows you; `nightMean` is the number closer to what the WHOOP app displays. If
the difference between those two is roughly the difference you're seeing between the apps, there is
nothing wrong with your data.

## Why is my HRV different from the WHOOP app's?

HRV is computed from the R-R (beat-to-beat) intervals your strap banks overnight, and small
differences in which beats are accepted move the number. A large difference — roughly double — is
worth reporting, because it usually means the R-R stream is over-covered.

Your strap log carries the diagnostic:

```
hrv diag day=2026-07-16 rmssd=52ms sdnn=98ms coverage=2.54 collapsedCov=1.99 dupBeats=62
```

`coverage` above 1.0 means more R-R data arrived than wall-clock time allows, which points at
duplicated beats. Include that line if you file an issue — it turns a "my HRV looks wrong" report
into something diagnosable.

## Does my data ever leave my device?

NOOP has no server, account, telemetry, or cloud sync. Raw sensor streams and the local database stay
on your device unless you explicitly export/share them. Three user-controlled paths can use the
network: the optional Coach sends your question and an approved compact text summary to the provider
you configure; a source-built Oura lane pulls your own Oura history in; and **Check for updates**
reads public release metadata from GitHub when you tap it.

Two exports can carry your data off-device **when you choose where to send them**:

- a `.noopbak` backup, which is a copy of the whole local database
- the CSV/JSON export

Both are user-initiated. See [docs/PRIVACY_SECURITY.md](PRIVACY_SECURITY.md).

## Are `.noopbak` backups compatible with RyanBR's NOOP?

For the current releases, yes in both practical directions: NOOP AI 10.1.1 migrates older upstream
Apple backups forward, and its v40 database remains readable by RyanBR's current v37 Apple migrator.
That backwards-reader behavior has a regression test in `WhoopStore`.

The retired Android parity contract means byte-for-byte Swift/Room agreement is no longer a release
gate, not that the backup was deliberately made incompatible. Future compatibility cannot be
guaranteed across arbitrary version gaps, so keep an untouched backup before switching between
forks and restore with the same or a newer build when possible.

## Which numbers are measured, and which are NOOP's own estimates?

Measured from the strap: heart rate, R-R intervals, resting HR, skin temperature, respiratory rate,
sleep duration and stages.

NOOP's own on-device scores, not clinical measures: Charge (recovery), Effort (strain), Rest (sleep
performance), Stress, Fitness Age and Vitality. [docs/ANALYTICS.md](ANALYTICS.md) documents the
formula behind each one.

NOOP does not invent values it cannot measure. Where a figure needs an input your strap doesn't
provide, the feature stays locked and says so rather than guessing.

## Why does a score say "Calibrating"?

Baseline-relative scores need history before they mean anything. Charge needs several nights of HRV
before it can tell a high night from a low one, so it shows a countdown instead of a number.

Tapping **Recalibrate baseline** restarts that countdown from zero — it discards the nights already
banked. If you're sitting at "Calibrating" and tap it again, you reset your own progress.

## Is NOOP a medical device?

No. It is not a medical device and makes no diagnostic claim. Values are raw readings or
locally-computed estimates, for personal and informational use only.
