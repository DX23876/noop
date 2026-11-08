# FAQ

Answers to the questions that come up most often in issues and on Discord. If your question isn't
here, [ANALYTICS.md](ANALYTICS.md) documents how every score is computed,
[PRIVACY_SECURITY.md](PRIVACY_SECURITY.md) covers what stays on your device, and the wiki has
[Troubleshooting](https://github.com/DX23876/noop/wiki/Troubleshooting) (pairing, sync, "no data") and
the [WHOOP 5.0 / MG status](https://github.com/DX23876/noop/wiki/WHOOP-5.0-and-MG-Status) page.

Something broken, or want to help? Jump to
[Help, bug reports and support](#help-bug-reports-and-support).

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
you configure; a source-built Oura lane pulls your own Oura history in; and the update checker reads
public release metadata from GitHub when you tap it or, when enabled, at most once per day. It never
installs anything and can be disabled under Settings → About.

Two exports can carry your data off-device **when you choose where to send them**:

- a `.noopbak` backup, which is a copy of the whole local database
- the CSV/JSON export

Both are user-initiated. See [docs/PRIVACY_SECURITY.md](PRIVACY_SECURITY.md).

## Are `.noopbak` backups compatible with RyanBR's NOOP?

**From RyanBR's NOOP to NOOP Forge: yes.** Forge migrates an upstream Apple database forward, and
`UpstreamStoreUpgradeTests` open stores from upstream 11.5 and 11.7 with their history intact.

**From NOOP Forge back to RyanBR's NOOP: not guaranteed.** Forge's database carries many more
migrations than upstream's (v85 in Forge 13.0.0; upstream was at v47 when they were last compared,
at 12.1.0), and some upstream migrations were renumbered when they were merged. GRDB ignores unknown later migrations, and
`testV40DatabaseRemainsReadableByRyanbrV37Migrator` pins that for an older reader, but no test opens a
current Forge backup in a current upstream build.

The retired Android parity contract means byte-for-byte Swift/Room agreement is no longer a release
gate, not that the backup was deliberately made incompatible. Keep an untouched backup before
switching between forks, and restore with the same or a newer build of the same app when possible.

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

---

# Help, bug reports and support

NOOP Forge is a free project built in spare time. There is no company behind it and no paid support,
so the questions below are about getting help quickly and about how to help back.

## Where do I ask a question, and where do I report a bug?

- **Questions, setup help, "is this normal?":** Discord, or
  [GitHub Discussions](https://github.com/DX23876/noop/discussions). Please read this FAQ and the
  [Troubleshooting](https://github.com/DX23876/noop/wiki/Troubleshooting) page first; most questions
  are already answered there.
- **Ideas and feature requests:** [GitHub Discussions](https://github.com/DX23876/noop/discussions).
- **A confirmed bug:** a [GitHub issue](https://github.com/DX23876/noop/issues/new/choose), using the
  bug template.

Bugs reported only in Discord tend to get lost: nobody can read the whole chat in their free time to
collect them. An issue is tracked until it is fixed.

Before opening an issue, search the
[existing issues](https://github.com/DX23876/noop/issues?q=is%3Aissue). If yours is already there, add
a 👍 or add **new** information (another device, another strap, a log). A comment that only says "same
here" changes nothing.

## What makes a bug report useful?

NOOP runs entirely on your device. There is no server to look at, so everything a fix needs has to be
in the report. "X doesn't work" on its own cannot be investigated. Please include:

- the NOOP version (Settings → About) and the platform with its OS version
- the strap model (WHOOP 4.0, 5.0 or MG) and where the data comes from (live strap, import)
- what you did, what you expected, and what happened instead
- when it happened, so the right part of the log can be found
- **the strap log**, which is the single most helpful thing you can attach:
  - iPhone, iPad and Mac: Settings → **Connection diagnostics** → *Strap log* → **Save…** (or
    **Copy**)
  - Android: Settings → **Help & Diagnostics** → **Share strap log**

Save the log soon after the problem happens, while the relevant part is still in it. It is your data,
so have a quick look before you post it publicly.

## Why is some text still in English?

The interface is being rebuilt screen by screen into a clearer layout. Translations are completed on
the new screens instead of being patched into old ones that are about to be replaced, so an older
screen can still show English text for a while.

If a **new** screen shows untranslated text, that is worth reporting; say which screen and which
language. Translation help is welcome too, and is easiest once a screen has been rebuilt.

## How can I help?

You do not need to be able to code. Any of these helps:

- **Test:** try new releases and report what breaks, and also what works ("works on iOS 18 with a 4.0"
  is useful information).
- **Report well:** a complete bug report with a log, as described above, often saves days of
  back-and-forth.
- **Give concrete feedback:** say what is confusing or hard to find and, ideally, suggest something
  better. That matters most right now, while the interface is being rebuilt.
- **Help others:** answer questions on Discord or point people to the right FAQ entry.
- **Translate:** help with a language you speak once a rebuilt screen lands.
- **Contribute code:** pull requests are welcome. Read [AGENTS.md](../AGENTS.md) and
  [CONTRIBUTING.md](CONTRIBUTING.md) first, keep one topic per pull request, and test on your own
  device before you submit. Untested patches have broken the app before.
- **Donate:** if you have neither time nor the skills, you can support NOOP Forge on
  [Ko-fi](https://ko-fi.com/dx23876). It is optional; the app is the same either way.
