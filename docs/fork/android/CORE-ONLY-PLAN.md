# Android without Room: the core as the only store

Branch `feature/android-core-only`, decided by the owner on 2026-11-01. Ends in one new testing build
(`testing-latest`, version stays 13.0.0). Status of the parity work before this step: [`STATUS.md`](STATUS.md).

## Why

Testers do not report back, so the testing build should already be the finished shape. An Android `.noopbak`
from ryanbr's app or from Forge's classic backup is refused by the core today (`BackupArchive.restore` treats
any Room file as a foreign backup), and Forge's scheduled backup still archives Room rather than the core.

## Decisions

1. **Room leaves the APK completely**: library, entities, DAOs, migrations. The core reads an old Room file as
   plain SQLite, copying by column name, so no Room code is needed for it.
2. **An existing install is adopted once on first start**: the core copies every Room table it shares. The old
   file is renamed and kept. Settings offers to delete it; it is deleted on its own 30 days after a successful
   adoption.
3. **Every Room backup restores**, whatever Room version wrote it. Columns the old file lacks take their
   default; tables it lacks are skipped.
4. **Derived values are recomputed by the core** wherever raw strap data exists. Rows Kotlin computed for days
   without raw data are kept. Imported and wearer-entered rows are inputs and are copied unchanged.
5. **The strap's history is acknowledged only after the core stored it** (the former Lab switch *Shared core
   confirms history*, now always on). A failed core write withholds the acknowledgement, so the strap keeps the
   data. Unverified on hardware; the release notes say so.
6. **Every Kotlin computation moves to the core.** Only presentation helpers stay Kotlin. The two without a
   Swift twin, nap detection (`NapDetector`) and the 5.0/MG skin-temperature suite (`V5HealthSignals`), are
   ported into `StrandAnalytics`; iOS presentation of them is a later, separate step.
7. **Backup**: one path through the core for manual and scheduled backups, carrying every setting. Shared
   settings use the Apple keys, Android-only ones their own. The restore ceiling rises from 2 GB to 5 GB. The
   compact table layout is a separate later migration.
8. **Imports**: every file import parses with `StrandImport` in the core. Health Connect stays a Kotlin read
   (an Android API) and writes into the core.
9. **The old Kotlin coach's `coachMessage` history** is adopted into the core coach's history when the format
   fits without changing the coach's storage; otherwise it is dropped and the release notes say so.
10. **Other devices** (standard heart-rate straps, Amazfit, Mi Band, Garmin broadcast, FTMS, Oura): Kotlin keeps
    the Bluetooth link and the decoding; the samples are written into the core's tables.

## Acceptance before the testing build

`Tools/local-tests.sh`, the Android unit tests, an emulator round (update over an install with Room data,
restore an old Room backup, every tab against iOS on demo data) and the real-data comparison on the owner's
iPhone copy (B4 in `STATUS.md`), since the backup change touches iOS as well.

Analysis migration required: no. The Apple recipe is unchanged; an adopted Android store runs the core's
rebuild once because its derived tables start empty.

## Status (2026-11-01)

Done on the branch:

- Room adoption in the core (`RoomStoreAdoption`), used by a Room backup's restore and by the first start of an
  install that still has `noop_whoop.db` (waiting screen, then a restart). Checked on the emulator over a Room v41
  and a Room v42 (demo) install.
- One backup path through the core for manual, scheduled and classic backups, with the app's whitelisted settings;
  the restore ceiling is 5 GiB. Settings shows backups only under Data & Backup (CSV export moved there).
- Room, its migrations and KSP are out of the APK. `Tools/gen_core_dao.py` writes `CoreWhoopDao` from the DAO
  declarations; every statement runs in the core's store (`CoreDb`, `sql.query`, `sql.exec`). The core gains
  Room's three Android-only tables (GRDB v84).
- The core banks a WHOOP strap's frames alone and the history ack waits for it; other devices write their
  samples into the core's tables through the same data access. The Kotlin scoring engine stands down.
- File imports parse in the core with the Apple importers (`import.file`). Nap detection runs in the core.
- Emulator round: Today, Trends, Training, Sleep and More render from the core with no data-access error.

Open before the testing build:

- The 5.0/MG skin-temperature suite (`V5HealthSignals`: cycle phase, body clock, illness heads-up) still runs as
  Kotlin over the core's daily rows. It stores nothing; on iOS the same adapter sits in `AppModel`, not in a
  package. Moving it means one shared adapter plus its result types across the bridge.
- Restoring a real Room `.noopbak` through the picker on the emulator (the path is covered by
  `BackupArchiveTests`), the full local gate on the final tree, the B4 real-data comparison, release notes.
- Unverified on hardware: pairing, live heart rate, offload and the core-gated ack.
