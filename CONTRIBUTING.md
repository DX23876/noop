# Contributing to NOOP

Thanks for your interest in contributing. NOOP is a standalone, fully **offline**
companion app for WHOOP 4.0 and 5.0 / MG straps — it pairs over Bluetooth, stores
everything on-device in SQLite, and computes recovery / strain / HRV / sleep
locally. No servers, no accounts, no data leaving the device.

This file is a quick orientation. The **full contributing guide** —
repository layout, the design-system rules, the BLE safety contract, how to add a
metric / screen / command / migration, and the commit conventions — lives in
[`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md). Read that before opening a
non-trivial PR.

> NOOP is not affiliated with, endorsed by, or connected to WHOOP, Inc., and is
> not a medical device. See [`DISCLAIMER.md`](DISCLAIMER.md).

---

## Quick start

The codebase is reusable Swift packages (`Packages/`) plus a thin macOS app
(`Strand/`) and a full Android app (`android/`). The fastest feedback loop is the
packages — they build and test on their own, no Xcode project and no strap needed.

> **NOOP Forge fork (DX23876):** the Android app here is not an independent Kotlin
> reimplementation but a Kotlin/Compose shell around the shared Swift core
> (`Packages/StrandCore`, reached through `Packages/NoopCoreJNI`), in testing. Room is
> gone from the app; Android stores in the core's GRDB database. Building it needs the
> Swift toolchain, the Swift SDK for Android and NDK r30 (`android/swift-core/build-swift-core.sh`).
> Fork rules: [`docs/fork/AGENT_RULES.md`](docs/fork/AGENT_RULES.md); the local gate before a
> push is `Tools/local-tests.sh` (see [`docs/FORK_GUIDE.md`](docs/FORK_GUIDE.md)).

### Swift packages

```bash
# Test just the package you touched (substitute the name):
cd Packages/WhoopProtocol && swift build && swift test
```

The core packages are `WhoopProtocol` (BLE framing / decode), `WhoopStore`
(SQLite persistence), `StrandAnalytics` (recovery / strain / HRV / sleep math),
`StrandImport` (WHOOP CSV + Apple Health importers), and `StrandDesign` (the
SwiftUI design system). `Packages/` also holds `OuraProtocol`, `PolarProtocol`,
`StrandTraining`, `MuscleMap`, `SemanticMemory`, `NoopLocalAccess` and, in this fork,
`StrandCore` (the shared app core) and `NoopCoreJNI` (its Android bridge); see
[`docs/LIBRARY.md`](docs/LIBRARY.md).

### macOS app

The Xcode project is generated from `project.yml` and is **not** committed.

```bash
brew install xcodegen
xcodegen generate         # regenerate after any project.yml or file add/remove
open Strand.xcodeproj     # build and run from Xcode
```

For a runnable, ad-hoc-signed `NOOP.app` without an Apple ID, see
[`docs/BUILD.md`](docs/BUILD.md).

### Android app

```bash
cd android
./gradlew assembleFullDebug      # the real app (full flavour); JDK 17 required
./gradlew assembleDemoDebug      # demo flavour — 120 days of synthetic data, no strap
./gradlew testFullDebugUnitTest  # unit tests
```

**After switching branches, add `--no-build-cache --rerun-tasks`:**

```bash
./gradlew testFullDebugUnitTest --no-build-cache --rerun-tasks
```

Gradle's cache is keyed on inputs it can see, and a branch switch can leave generated sources (upstream:
Room DAOs, KSP output) from the previous branch in place, so the suite can run against code that is not the
code you have checked out.

If a failure looks unrelated to your change, re-run with those flags before concluding it is
pre-existing on `main`. CI always builds clean, so a red test only you can see is worth one clean
re-run before you write a note about it: several such failures have turned out not to reproduce.

---

## What CI checks

Some GitHub Actions workflows run on *every* PR; others are path-filtered and only run when
you touch what they cover. All of them compile and run unit tests only — no code signing, no
secrets, no release. The table is the source of truth, deliberately — the section this
replaced led with a count, and a count in prose is what goes stale while the list below it
looks fine.

> **Fork note:** no GitHub Actions run has started on `DX23876/noop` since 2026-11-02, and in this
> fork Swift Packages CI runs only on demand; the table describes the workflow triggers, not what
> ran. See "CI actually runs here" in [`docs/FORK_GUIDE.md`](docs/FORK_GUIDE.md).

The check names GitHub shows you are **job** names, which do not resemble the workflow
names. That column is why this table exists:

| Check you see | Workflow | Runs when |
|---|---|---|
| `check` | **i18n Coverage** (`i18n-coverage.yml`) | every PR |
| `doc-comments` | **Source Hygiene** (`source-hygiene.yml`) | every PR |
| `linux-capture` | **Tools Python CI** (`tools-python.yml`) | every PR |
| `windows-capture` | **Tools Python CI (Windows)** (`tools-python-windows.yml`) | `Tools/linux-capture/**` |
| `build-and-test` | **Android CI** (`android.yml`) | `android/**`, `Packages/**`, `Strand/**`, `project.yml`, `Tools/parity_cases/**`, its own workflow file |
| `test (…)`, `tools (…)` | **Swift Packages CI** (`swift-packages.yml`) | on demand only in this fork (and as a gate in `publish-ios-release.yml`) |
| `build (Strand, …)`, `build (NOOPiOS, …)` | **App build** (`app-build.yml`) | `Strand/**`, `StrandTests/**`, `StrandiOS/**`, `StrandiOSShared/**`, `StrandiOSWidgets/**`, `NOOPWatch/**`, `NOOPWatchComplications/**`, `Packages/**`, `project.yml`, its own workflow file |

Read that as a worked example: an Android-only PR runs Android CI plus the three that always
run, so a short list of checks does not mean little was checked.

**App build** compiles both Apple app targets and runs `StrandTests` on its macOS leg;
the iOS leg is compile-only. It is active on relevant PRs. Package checks alone do not
validate app-target Swift: build locally or verify the Apple app checks passed on the
current PR head. Android CI compiles Compose screens and runs Android unit tests.
App build has no push trigger, so a direct non-release commit to `main` needs a manual
dispatch. See [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md#what-ci-gates--and-what-it-deliberately-doesnt)
for the validation limits and checks gated at release time.

If CI fails on your PR, fix the cause rather than working around it. Never commit
generated output (`Strand.xcodeproj/`) or any secrets, keystores, or `local.properties`.

---

## Submitting a PR

1. One concern per PR where practical (keep protocol, schema, UI, and Android
   changes separate).
2. Fill in the [PR template](.github/PULL_REQUEST_TEMPLATE.md).
3. For anything on the BLE path, state what you tested **on real hardware** and on
   which strap. A green build is not proof a command behaves correctly.
4. For analytics changes, add a test and cite the method. If the change alters a
   scoring output, follow [`docs/VALIDATION_PROTOCOL.md`](docs/VALIDATION_PROTOCOL.md)
   and paste its checklist into the PR — a scoring change with no held-out number
   may ship behind a flag, but may not be described as an improvement.
5. For UI changes, use `StrandDesign` tokens only — no hardcoded colors, fonts,
   or spacing.

By opening a pull request you agree your contribution is licensed under the same
terms as the project — see [`LICENSE`](LICENSE).

---

## Reporting issues

- **Bugs and feature requests:** open an issue using the templates in
  [`.github/ISSUE_TEMPLATE`](.github/ISSUE_TEMPLATE). NOOP is on-device, so please
  leave out anything that identifies you.
- **Security issues:** see [`SECURITY.md`](SECURITY.md).

## Code of conduct

This project follows a [Code of Conduct](CODE_OF_CONDUCT.md). Be respectful and
keep discussion focused on the technical work.
