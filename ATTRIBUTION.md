# Attribution

NOOP is an independent, unofficial, local-first app for macOS, Android and iOS. It is not affiliated
with, endorsed by, or connected to WHOOP, Inc. "WHOOP" is used nominatively only to
identify the hardware the app interoperates with.

NOOP builds on prior community reverse-engineering and interoperability work:

## WHOOP 4.0 protocol + Swift packages
- **`johnmiddleton12/my-whoop`** — the `WhoopProtocol` and `WhoopStore` Swift packages
  (vendored under `Packages/`), the WHOOP 4.0 BLE framing/command/decode work, and the
  iOS collection logic that NOOP's `WhoopBLE`/`Collect` layers are adapted from.
  See `DISCLAIMER.md` (carried over from that project).

## WHOOP 5.0 / MG protocol
- **`b-nnett/goose`** — the WHOOP 5.0 BLE reverse-engineering (service UUID family
  `fd4b0001-…`, CRC16-Modbus header, CLIENT_HELLO, and the "puffin" packet types)
  that NOOP's `DeviceFamily` Whoop-5 path and `whoop5_protocol.json` are ported from.
- **OpenStrap** (`OpenStrap/edge`, `OpenStrap/protocol`, MIT, Copyright (c) 2026 OpenStrap)
  — the WHOOP MG ECG reading flow (the R17 reading state machine, the result-plus-heart-rate
  category table and the capture lifecycle), ported to Swift in `Whoop5EcgReading.swift` and
  `EcgReadingController.swift` from release v0.10.0. The MIT notice applies to those ports:
  "Permission is hereby granted, free of charge, to any person obtaining a copy of this
  software and associated documentation files (the "Software"), to deal in the Software
  without restriction, including without limitation the rights to use, copy, modify, merge,
  publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
  to whom the Software is furnished to do so, subject to the following conditions: The above
  copyright notice and this permission notice shall be included in all copies or substantial
  portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND."

## Xiaomi Smart Band (Mi Band) import
- **`artyomxx/xiaomi-band-ios-export`** — documented the Mi Fitness iOS app's on-device
  SQLite layout (`DataBase/<user_id>/de/<user_id>.db`, JSON `value` columns, the `*_day`
  rollups and the `sleep` table's `items[]` hypnogram with state codes). NOOP's
  `XiaomiBandImporter` is **re-derived** from those findings and verified against a real
  Mi Band 10 export; **no code is copied** (the reference tool is AGPL, NOOP is not).
- **Gadgetbridge** (`Freeyourgadget/Gadgetbridge`) — referenced only for *protocol facts*
  about the live Mi-protobuf BLE stack in the roadmap's research notes. GPLv3; NOOP copies
  **none** of its code and has not built the live lane.

## Facts learned from a decompiled app

The facts-only doctrine above is usually applied to other open-source RE projects. It applies the same
way when a fact originates in a **decompile of the vendor's own app** — a case that recurs because
several third-party WHOOP projects are decompile-derived.

The line is between the fact and the expression of it:

- **A protocol fact may be re-derived** — a byte offset, field width, enum value, scale factor. It is
  attributed at the point of use, and it ships as an **unvalidated candidate**: decoded and logged,
  never backing a shipped metric, until independent captures from real hardware clear it.
- **The implementation may not be copied** — not verbatim, not transcribed. Nor may string literals,
  assets, or anything else that is authored expression rather than an observation about the wire.

This is long-standing practice, not a one-off. Worked examples already in the tree:

- **`spo2_candidate_82`** (`Interpreter.swift`) — WHOOP 5 v18 byte `@82` read as a strap-computed SpO₂
  percentage, attributed as *"a decompile-sourced decode (gen5.rs `spo2_pct`), reimplemented here as a
  protocol fact with attribution"*. A guard test stops it ever writing `spo2Pct`, and it is still a
  candidate because the cross-device evidence is split.
- **The R22 config opcodes** (`Whoop5Config.swift` / `.kt`) — `SET_FF_VALUE (0x78)` and the flag key
  names, corroborated against *Asherlc/dofek docs/whoop-ble-protocol.md (Android APK decompilation)*
  and validated byte-for-byte against a decrypted HCI capture.
- **The disputed battery opcode** (`Commands.swift`, `Enums.kt`) — a decompile reads
  `GET_EXTENDED_BATTERY_INFO` as 87 where our table says 98. Both readings are recorded and the
  question is settled by probing real firmware, not by picking a source.
- **The MG ECG ("Labrador") packet layouts** (`Whoop5Ecg.swift` / `.kt`, `docs/PROTOCOL.md` §9.1) —
  field order, widths and enum values for `FilteredLabradorPacket` / `RawLabradorPacket`, plus the
  `{revision, arg, padding}` command payload shape, re-derived from static analysis of the vendor's iOS
  client. The four command NUMBERS were already in our own `CommandNumber` table from the whoomp/goose
  work above. Most of it still ships as an **unvalidated candidate**: the decode backs no metric, and the
  fields nobody can attest (the wrist enum's raw values, the progress "timed out" sentinel, the ECG
  sample unit, the packet type byte) are carried raw rather than named. **One exception is now attested
  rather than inferred:** `ControlSignal`'s raw values were also read off the client's enum order, and a
  WHOOP MG (`WS50_r00`, fw `50.39.1.0`) contradicts that reading — `1` stops generation, `2` starts it,
  `0` is refused. The enum now carries the hardware values with the device and firmware named. A
  hardware-observed value is strictly stronger than the inference it replaces, but it is one device.
  The on-strap rhythm classifier's verdict is decoded as a byte and is never presented as a finding —
  NOOP is not a medical device.

And the line held from the other side:

- **`StrainTargetNotifier`** (both platforms) — *"CLEAN-ROOM: this reimplements the BEHAVIOUR only. The
  copy is NOOP's own — NOT WHOOP's decompiled strings."* Behaviour re-derived; the user-facing text
  written fresh.
- **The `LINK_VALID` handshake**, rejected in
  [`docs/BLE_REVERSE_ENGINEERING.md`](docs/BLE_REVERSE_ENGINEERING.md) — its reply payload is a
  literal string lifted from the app. Expression, not a fact about the wire, so it stays out
  regardless of whether the handshake turns out to be real.

## Oura ring (gen 3/4/5) protocol
NOOP's Oura code is **original clean-room** work. The local BLE source
(`Strand/BLE/OuraLiveSource.swift` + `android/.../ble/OuraLiveSource.kt`) and the JVM/Swift-pure
`OuraProtocol` package (`Packages/OuraProtocol/`, `android/.../com/noop/oura/`) were written from
**documented protocol facts only**, cited tersely in `docs/OURA_PROTOCOL.md`. The community
reverse-engineering resources below were consulted as **facts-only references** (byte layouts,
service/characteristic UUIDs, framing and auth shapes); **no RE source code is copied** into NOOP.
- **`open_ring`**: consulted for protocol facts only. Licensed **GPL-3.0**; NOOP copies none of
  its code and is not a derivative work of it.
- **`open_oura`**, **`ringverse`**, **`relue`**: consulted for protocol facts only. These carry
  **no license**, so NOOP treats them as reference documentation of observed behaviour only and
  copies no code from them.

NOOP reads only the ring's own decoded raw signals and its own open event tags, computes NOOP's
own Charge/Rest, and **never** reads or displays Oura's encrypted readiness or sleep scores. The
documented Oura file-import lane (`Packages/StrandImport/Sources/StrandImport/OuraExportParser.swift`)
remains available as a fallback.

## NOOP Forge: work adopted from other people

NOOP Forge (this fork) takes most of its foundation from [ryanbr/noop](https://github.com/ryanbr/noop) and
its contributors, merged regularly; their credits live in that project's history and release notes.
The people below are credited here because the fork took their work **directly**: from their own forks,
or from pull requests to ryanbr/noop before or without ryanbr merging them. Each adopting commit names the
source and carries a `Co-authored-by` line where the work was taken as code.

### Pull requests to ryanbr/noop, adopted directly

| Who | What NOOP Forge took | Source |
|---|---|---|
| [@UtkuDenizAltiok](https://github.com/UtkuDenizAltiok) | Deleted nights listed with recompute and hide; a reminder when the strap has not synced for 3 hours; daily SDNN refuses over-counted or banked beats; wind-down nudge timed from the personal sleep need; skin temperature shown once and in the reader's unit; "Building" and "Push" translations | ryanbr/noop#2660, #2661, #2722, #2906, #2899, #2904, #2897 |
| [@kavemang](https://github.com/kavemang) | Typed sleep marks through Shortcuts; DST day-membership tests; cheaper gravity witness; a saved workout edit shows before the rescore finishes | ryanbr/noop#2651, #2694, #2705, #2706 |
| [@paradix86](https://github.com/paradix86) | Italian WHOOP export import | ryanbr/noop#2712 |
| [@christophersarmiento](https://github.com/christophersarmiento) | The seeded strap model is stamped only once a scan accepts a strap | ryanbr/noop#2750 |
| [@JohanStefanes](https://github.com/JohanStefanes) | The one-shot buzz on a WHOOP 5/MG no longer sends RUN_ALARM (hardware-tested) | ryanbr/noop#2797 |
| [@fadkeprasad](https://github.com/fadkeprasad) | Power saving's cadence holds for automatic sync triggers | ryanbr/noop#2837 |
| [@spidervirus](https://github.com/spidervirus) | Startup zero heart rate dropped from realtime frames and HR buckets | ryanbr/noop#2840 |
| [@goodgord](https://github.com/goodgord) | Sleep runs are no longer merged across a data gap | ryanbr/noop#2849 |
| [@msff](https://github.com/msff) | The Mac menu-bar label redraws only when what it shows changes | ryanbr/noop#2889 |
| [@andynilson](https://github.com/andynilson) | Charge and Effort translations | ryanbr/noop#2878 |

### Other forks and projects

| Who | What NOOP Forge took | Source |
|---|---|---|
| [@ayiskakov](https://github.com/ayiskakov) | Offload data-loss paths closed; the link is ended when Bluetooth powers off; an off-wrist empty offload is no clock fault; deep sleep held back after onset; a data delete is not undone by a re-score | [ayiskakov/noop](https://github.com/ayiskakov/noop) |
| [@Iskrata](https://github.com/Iskrata) | WHOOP's absolute skin temperature stored as such on import; beat-to-beat intervals written to Apple Health; nightly vitals stamped inside the night | [Iskrata/noop](https://github.com/Iskrata/noop) |
| [@gdorgian](https://github.com/gdorgian) | Liquid clocks stand down once the liquid stops moving; a short last stretch that continues the night is kept | gdorgian/noop |
| [@mohamedchnafy-ds](https://github.com/mohamedchnafy-ds) | Weekly sets per muscle against the research band (idea); recent naps in the coach's context | [mohamedchnafy-ds/noop](https://github.com/mohamedchnafy-ds/noop) |
| [@shajidahmed](https://github.com/shajidahmed) | A config read-back never confirms with the first byte of a longer value | [shajidahmed/pulsekeep](https://github.com/shajidahmed/pulsekeep) |
| [@abhilashvadnala](https://github.com/abhilashvadnala) | The day cycle opens on an early bedtime and closes long gaps at midnight | [abhilashvadnala/noop](https://github.com/abhilashvadnala/noop) |
| [@reinmaker](https://github.com/reinmaker) | A split night's consistency is scored at its last wake | [reinmaker/noop](https://github.com/reinmaker/noop) |
| [@Billytheking954](https://github.com/Billytheking954) | The rollback copy before a restore reads through the WAL | Billytheking954/noop-whoop- |
| [@J-Gur](https://github.com/J-Gur) | Health Connect permissions for distance and VO₂ max | [J-Gur/noopjg](https://github.com/J-Gur/noopjg) |
| [@rntcruz23](https://github.com/rntcruz23) | A clear message when the strap never answers a connect | [rntcruz23/noop](https://github.com/rntcruz23/noop) |
| [@bartmuskala](https://github.com/bartmuskala) | One resolver for the maximum heart rate (modelled on theirs) | [bartmuskala/noop](https://github.com/bartmuskala/noop) |
| bogaczcyprien-svg | Respiratory rate off the 0.25 s resample grid | [bogaczcyprien-svg/noop](https://github.com/bogaczcyprien-svg/noop) |
| aansun | Off-wrist stretches cut out of a kept sleep run | [aansun/PHMNoop](https://github.com/aansun/PHMNoop) |
| denismanulov | An offload data-loss path | [denismanulov/reNOOP](https://github.com/denismanulov/reNOOP) |
| meta1971, OpenStrap | Real sub-seconds in the WHOOP 5/MG SET_CLOCK; the full MG ECG reading (OpenStrap, MIT) | [meta1971/noop-mg-ecg](https://github.com/meta1971/noop-mg-ecg), OpenStrap |

Bundled third-party content is credited separately: the body geometry (MuscleMap,
react-native-body-highlighter) and the ExerciseDB exercise data in
[docs/fork/THIRD_PARTY_NOTICES.md](docs/fork/THIRD_PARTY_NOTICES.md) and the app's Acknowledgements screen,
llama.cpp and the nomic embedding model in [NOTICE](NOTICE). The app's Acknowledgements screen also lists
the people above.

## Other
- **GRDB.swift** (`groue/GRDB.swift`) — SQLite persistence (via Swift Package Manager).
- **MarkdownUI** (`gonzalezreal/swift-markdown-ui`) — renders the AI Coach's Markdown
  replies (via Swift Package Manager).

NOOP contains no WHOOP proprietary code, binaries, firmware, logos, or assets, and
performs no DRM circumvention. It operates only with the user's own device and data.
NOOP is **not a medical device**; all metrics (HR, HRV, recovery, strain, sleep,
SpO₂, temperature) are approximations and not clinically validated.
