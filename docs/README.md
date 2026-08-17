# Documentation map

This index separates current guidance from historical records. The current fork ships iOS, macOS,
widgets/Live Activity, and an optional watchOS companion. It does not contain or release Android;
use [RyanBR's upstream NOOP](https://github.com/ryanbr/noop) for Android.

## Start here

- [README](../README.md) — product overview and downloads.
- [iOS installation](IOS.md) — AltStore/SideStore, Full IPA, and source builds.
- [Build and release](BUILD.md) — XcodeGen, package/app builds, and publication.
- [Features](FEATURES.md) — current product surfaces.
- [FAQ](FAQ.md) — common score, privacy, and calibration questions.
- [Privacy and security](PRIVACY_SECURITY.md) — exact local/network boundaries.

## Contributor and architecture guides

- [Contributing](CONTRIBUTING.md)
- [System architecture](ARCHITECTURE.md)
- [Apple-platform architecture](CROSS_PLATFORM.md)
- [Package library](LIBRARY.md)
- [Data model](DATA_MODEL.md)
- [Analytics](ANALYTICS.md)
- [Fork maintenance](FORK_GUIDE.md)
- [Scope and non-goals](SCOPE.md)
- [GitHub and release safeguards](SAFEGUARDS.md)

## Protocol and device references

- [WHOOP protocol](PROTOCOL.md)
- [BLE reverse engineering](BLE_REVERSE_ENGINEERING.md)
- [WHOOP 5/MG deep data](WHOOP5_DEEP_DATA.md)
- [WHOOP 5/MG optical experiment](WHOOP5_OPTICAL_EXPERIMENT.md)
- [Oura BLE protocol](OURA_PROTOCOL.md)
- [Device support roadmap](DEVICE_SUPPORT_ROADMAP.md)
- [Device-driver architecture](DEVICE_DRIVER_ARCHITECTURE.md)

Some protocol documents retain clearly labelled Kotlin/Android observations as historical
provenance. Those references do not imply that the files still exist in this fork.

## Historical records — do not rewrite as current behavior

- `docs/releases/` — upstream-era release notes.
- `docs/fork/releases/` — released fork notes, including 10.1.1.
- `docs/fork/decisions.md` — chronological decisions; later rows may supersede earlier rows.
- `docs/superpowers/` — dated plans and specifications.
- `docs/fork/redesign-*` and `docs/fork/feature-spec.md` — implementation inputs retained for
  design provenance.
- [Android status](ANDROID.md) — redirect explaining removal of the former Android tree.
- [R-R optimization](RR-OPTIMIZATION.md) — historical experiment record plus current Swift outcome.

When current guidance conflicts with a historical record, the current guide and the source tree win.
