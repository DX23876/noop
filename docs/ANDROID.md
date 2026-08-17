# Android status

This fork does **not** contain, build, or release an Android application. The former `android/`
tree and its Gradle/GitHub Actions jobs were removed on 2026-08-14 when the fork adopted an
Apple-only release pipeline.

For the actively maintained Android client, build instructions, APKs, and Kotlin implementation,
use [RyanBR's upstream NOOP repository](https://github.com/ryanbr/noop).

## Why this file remains

Older commits, release notes, protocol investigations, and design records refer to the former
Kotlin/Room implementation. Those references are historical provenance; they do not describe files
available in the current checkout. Keeping this short redirect prevents old links from silently
becoming misleading while preserving the repository's history in Git.

## Current platforms in this fork

- **iOS / iPadOS 17+** — unsigned AltStore/SideStore IPA or an Xcode source build.
- **macOS 13+** — packaged universal ZIP or an Xcode source build.
- **watchOS 10+ companion** — included in the Full iOS IPA and Xcode build.

See [iOS installation](IOS.md), [build instructions](BUILD.md), and the
[Apple-platform architecture](CROSS_PLATFORM.md).
