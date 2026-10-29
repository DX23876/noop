# Third-Party Exercise Content Notices

This record separates NOOP source code, exercise metadata, instructions and media. A licence in one domain is not treated as a licence in another.

| Source | Author / rights holder | Licence or known rights status | Attribution | Redistribution by NOOP | Local storage | Bundled | Separate user download | Last checked | Status |
|---|---|---|---|---|---|---|---|---|---|
| MuscleMap body geometry (Exercise Library muscle picker) | melihcolpan / repository contributors | MIT licence in the source repository | Listed in Settings › Acknowledgements | Geometry used under its licence | App assets | Yes | No | 2026-09-15 | Enabled |
| react-native-body-highlighter body geometry (Muscle Load map) | Copyright (c) 2022 ELABBASSI Hicham | MIT licence, shipped in full as `Packages/StrandDesign/Sources/StrandDesign/Resources/MuscleMapPaths.LICENSE` | Listed in Settings › Acknowledgements | Paths converted offline to Bézier data (`Tools/svg_muscle_map.py`); no runtime SVG parsing of upstream code | App assets | Yes | No | 2026-09-16 | Enabled |
| ExerciseDB-compatible metadata endpoint | Endpoint operator and individual data contributors | Provider terms apply; metadata provenance must be checked per configured endpoint | Shown in the import flow | Only user-selected normalized definitions are stored | Private database | No | User supplies endpoint/access | 2026-09-15 | Optional |
| ExerciseDB v1 exercise DATA via hasaneyldrm/exercises-dataset | Hasan Emir Yıldırım and dataset contributors | **MIT** — the repository's `LICENSE` and `NOTICE.md` place names, categories, body parts, equipment, targets, muscle groups and instruction text under MIT | “Exercise data: ExerciseDB v1 via hasaneyldrm/exercises-dataset, MIT licence.” carried on every shipped definition and in the catalogue's rights block | Yes: the normalized catalogue ships in the app | Package resource `exercise-catalog.json` (1,324 exercises) + the on-device database | Yes | Not required | 2026-09-16 | Shipped |
| hasaneyldrm/exercises-dataset MEDIA (images/, videos/) | © Gym visual (https://gymvisual.com/); redistributed in that repository under a separate written permission | **Not licensed to NOOP.** `NOTICE.md`: “cloning this repo is not a license”; reuse is governed by Gym visual's Terms & Conditions and requires an own licence | “© Gym visual — https://gymvisual.com/”, shown under every animation and in Settings › Acknowledgements | No: NOOP does not bundle, host, mirror or proxy the files; a user-initiated download pulls the pinned archive directly from the upstream source into private, backup-excluded storage | Private Application Support, excluded from backup | No | Yes — a wearer-triggered, disclosed download; not enabled by default | 2026-09-16 | **Optional download**, disabled by default; `ExerciseMediaRegistry.withdrawnProviderIds` is the kill switch if it must be pulled again |

If an upstream source becomes unavailable, incompatible or legally unsuitable, its provider can be disabled without affecting exercise identity, routines, workout history or analytics. The switch is `ExerciseMediaRegistry.withdrawnProviderIds`: a withdrawn provider stops resolving media, refuses new downloads and states this in Settings › Training › Exercise media.

For every installed pack NOOP records the source URL, attribution, rights holder, the rights status as known at download time, the SHA-256 of the archive and of each extracted file. That record is integrity and provenance evidence; it neither asserts nor creates a licence.

## Day-cycle scene artwork

The Alps day-cycle set (`alps1`...`alps10` in `Strand/Resources/Assets.xcassets` and `StrandiOS/Resources/Assets.xcassets`) is ten AI-generated images of one imaginary Alpine lake scene, lit for ten times of day, produced with ChatGPT image generation from a text prompt by the fork's owner. It contains no photograph, no third-party artwork and no real place, and it is not derived from any source image. The Coast set (`coast1`...`coast10`) is made the same way: ten AI-generated images of one imaginary dune path to the sea, lit for ten times of day. The painted meadow set (`scene1`...`scene10`) predates it and is unchanged.

## Shared media integrity dependency

The shared media installer uses Swift Crypto 4.5.2 (Apache-2.0), pinned in `StrandCore/Package.swift`.
The package re-exports CryptoKit on Apple and provides the Android implementation. Its original
`LICENSE.txt` and `NOTICE.txt` are shipped as `SwiftCrypto-LICENSE.txt` and `SwiftCrypto-NOTICE.txt`
in the Apple app's `Resources/ThirdParty` and Android's `assets/licenses` directories. Upstream source:
[apple/swift-crypto, 4.5.2](https://github.com/apple/swift-crypto/tree/4.5.2).

The optional exercise pack remains a separate user-initiated download. On Android the completed pack
lives in private `noBackupFilesDir`; the operating system's temporary download is in app-specific
external storage, excluded from both cloud backup and device transfer by the app's extraction rules.

## Personal ExerciseDB metadata endpoint

The default optional endpoint is `https://oss.exercisedb.dev/api/v1/exercises`. Its
[official reference](https://oss.exercisedb.dev/docs) requires AscendAPI credit; the shared client records
“Exercise data: ExerciseDB V1 / AscendAPI — oss.exercisedb.dev.” on definitions received from that host.
The credit is visible in the app's Acknowledgements and survives selected-only storage; the selection preview does not repeat it. Provider terms still apply;
no exercise media is fetched by this metadata request. A single public `limit=1` request on 2026-10-27
returned a `data` array with one definition, plus `meta` and `success` fields. No personal credential or
health data was used. Other user-configured providers retain their own applicable terms.
