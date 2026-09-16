# Third-Party Exercise Content Notices

This record separates NOOP source code, exercise metadata, instructions and media. A licence in one domain is not treated as a licence in another.

| Source | Author / rights holder | Licence or known rights status | Attribution | Redistribution by NOOP | Local storage | Bundled | Separate user download | Last checked | Status |
|---|---|---|---|---|---|---|---|---|---|
| MuscleMap body geometry | melihcolpan / repository contributors | MIT licence in the source repository | “Body geometry: MuscleMap · MIT License” | Geometry used under its licence | App assets | Yes | No | 2026-09-15 | Enabled |
| ExerciseDB-compatible metadata endpoint | Endpoint operator and individual data contributors | Provider terms apply; metadata provenance must be checked per configured endpoint | Shown in the import flow | Only user-selected normalized definitions are stored | Private database | No | User supplies endpoint/access | 2026-09-15 | Optional |
| ExerciseDB v1 exercise DATA via hasaneyldrm/exercises-dataset | Hasan Emir Yıldırım and dataset contributors | **MIT** — the repository's `LICENSE` and `NOTICE.md` place names, categories, body parts, equipment, targets, muscle groups and instruction text under MIT | “Exercise data: ExerciseDB v1 via hasaneyldrm/exercises-dataset, MIT licence.” carried on every shipped definition and in the catalogue's rights block | Yes: the normalized catalogue ships in the app | Package resource `exercise-catalog.json` (1,324 exercises) + the on-device database | Yes | Not required | 2026-09-16 | Shipped |
| hasaneyldrm/exercises-dataset MEDIA (images/, videos/) | © Gym visual (https://gymvisual.com/); redistributed in that repository under a separate written permission | **Not licensed to NOOP.** `NOTICE.md`: “cloning this repo is not a license”; reuse is governed by Gym visual's Terms & Conditions and requires an own licence | “© Gym visual — https://gymvisual.com/”, required on any use | No: NOOP does not bundle, host, mirror or proxy the files | Would be private Application Support, excluded from backup | No | Blocked — the provider is withdrawn in `ExerciseMediaRegistry.withdrawnProviderIds` | 2026-09-16 | **Withdrawn** until NOOP holds its own licence |

If an upstream source becomes unavailable, incompatible or legally unsuitable, its provider can be disabled without affecting exercise identity, routines, workout history or analytics. The switch is `ExerciseMediaRegistry.withdrawnProviderIds`: a withdrawn provider stops resolving media, refuses new downloads and states this in Settings › Training › Exercise media.

For every installed pack NOOP records the source URL, attribution, rights holder, the rights status as known at download time, the SHA-256 of the archive and of each extracted file. That record is integrity and provenance evidence; it neither asserts nor creates a licence.

