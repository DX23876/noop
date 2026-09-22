# iOS folder picker after sideload re-signing

Date: 2026-09-22

## Question

Why can a device build installed from Xcode select an external Backup & Sync folder, while the same
app re-signed and installed through Feather, SideStore, or AltStore can open the system Files picker
but cannot confirm a folder? Is there an established entitlement or API fix?

## Conclusion

This is a known *class* of iOS document-picker failure, but there is no documented iOS entitlement
that grants access to arbitrary user-selected folders and no established Feather/SideStore/AltStore
switch that fixes this exact symptom. Apple's supported design is already the relevant one:
`UIDocumentPickerViewController` opened for `UTType.folder`, followed by security-scoped access and a
persistent bookmark. Apple documents that flow specifically for directories outside an app's
sandbox [1][2].

The strongest repository-specific lead was NOOP's speculative `directoryURL` workaround. When no old
folder could be resolved, NOOP forced the picker to begin in the app's own Documents directory. The
code itself said that this workaround was never reproduced in-house and that `directoryURL` is only
a hint. The matching upstream report establishes a different environment boundary: the failure
occurs for every local and iCloud folder in a Feather-signed build, while the simulator works [3].

The first low-risk code experiment was therefore to return to Apple's canonical presentation:
leave `directoryURL` unset unless NOOP has a previously selected, successfully resolved external
folder. That change was implemented on 2026-09-22. It removes the unverified app-container starting
point without changing the folder type, bookmark format, or backup data. It remains a well-founded
hypothesis until it is verified on an affected physical device with a re-signed build.

If that does not fix the re-signed build, the next boundary to isolate is NOOP's distributed IPA,
not a mythical folder entitlement: compare a minimal main-app-only IPA with the current app-plus-
widget package, and compare the final installed entitlements/profile after each signer. All three
named installers re-sign the bundle; AltStore explicitly describes installing apps with the user's
development certificate, SideStore's source runs a prepare/provision/sign pipeline, and Feather
describes itself as an on-device IPA signer [4][5][6].

## Evidence

### 1. The supported Apple flow does not require an iCloud-container entitlement

Apple's directory-access documentation uses a document picker configured to open `UTType.folder`.
The returned URL is security-scoped; the app starts access, coordinates file operations, and can
persist access with bookmark data [1]. The general document-picker documentation likewise says that
open/move operations provide security-scoped URLs outside the app sandbox [2]. Neither API contract
requires the app to own an iCloud container merely to let the user select a directory.

An iCloud-container entitlement is relevant when the app owns and addresses its own ubiquitous
container. That is a different storage model from a user choosing a folder through the Files picker.
Adding such an entitlement is therefore not the standard fix for this bug.

### 2. NOOP's picker type and Info.plist keys are already appropriate

`Strand/System/DocumentPicker.swift` constructs the picker with
`forOpeningContentTypes: [.folder], asCopy: false`, disables multiple selection, and hands the chosen
URL to the backup layer. `StrandiOS/Resources/Info.plist` contains both
`LSSupportsOpeningDocumentsInPlace = true` and `UIFileSharingEnabled = true`.

The backup layer calls `startAccessingSecurityScopedResource()` while creating the bookmark. That is
after the picker callback, so it cannot explain a button that never produces a selected URL. It does
mean the initial grant/bookmark path is broadly aligned with Apple's model.

There is a separate robustness issue after selection: Apple's directory-access guidance calls for
coordinated reads and writes to the granted directory [1]. NOOP's external backup operations should
use `NSFileCoordinator`, but adding it cannot repair a picker that never returns a URL.

### 3. The forced start directory is an unverified NOOP-specific deviation

Before the fix, `DocumentPicker.pickFolder` did this when there was no saved folder:

```swift
picker.directoryURL = root
    ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
```

That behavior entered in commit `3a55428c4` as a workaround for a reported disabled button. Its
comment explicitly records that the failure could not be reproduced and that Apple's
`directoryURL` property is only a hint. The implementation now omits the property for the first pick,
letting the system choose its normal starting location. It retains the hint only for a previously
granted external folder, preserving the useful part of the feature.

This matters particularly after re-signing because the app identity and container are transformed.
Starting inside the re-signed app's own Files-visible Documents provider is the only nonstandard
picker input in NOOP that directly changes the initial picker state.

### 4. The exact upstream case remains open and is not provider-specific

RyanBR/noop issue #2356 reports the same behavior: the picker opens, but choosing a different backup
folder does not complete. The reporter later confirms that it fails for every tested folder,
including local folders and fully downloaded iCloud folders, and asks whether Feather signing is the
cause. A simulator build works. The issue remains open [3].

Commit `1dadf8702` / PR #2359 improves diagnostics around a picker that closes without returning a
folder. It deliberately does not fix the selection failure [7].

This evidence rules against a single broken cloud provider or an undownloaded iCloud item. Apple and
third-party reports do contain greyed-out folder choices caused by individual file providers, but
those explanations do not fit a failure across both local storage and iCloud Drive.

### 5. Code signing should not normally change the picker API's behavior

In an Apple Developer Forums investigation of a document-picker path that worked in Debug but not
Release, Apple DTS stated that behavior on a real device should be the same for Development and
Distribution signing, while also warning that the simulator does not accurately reproduce the iOS
sandbox [8]. The concrete bug in that thread was an `assert` whose side effect disappeared under
optimization. NOOP does not put its security-scope call inside an assertion, so that exact fix does
not apply here.

The useful inference is narrower: re-signing is not supposed to remove a general user-selected-folder
capability. If the final signed build changes behavior, investigate a transformed or inconsistent
bundle/profile/container, or an interaction triggered by that identity, rather than looking for a
documented prohibition on sideloaded apps.

### 6. The distributed IPA has a meaningful common packaging path

`Tools/package-ios-ipas.sh` keeps the iOS widget in the SideStore/AltStore IPA, removes the Watch app,
and then calls `Tools/prepare-ios-sideload-app.sh`. That script ad-hoc signs the staged main app and
widget with HealthKit and App Group capability templates so a later signer can discover and provision
them.

A local inspection of the distributed `NOOP-ios-unsigned-v11.8.2-dx.ipa` found:

- the main app and widget were already ad-hoc signed as intended;
- the main app carried HealthKit and the staging App Group capability template;
- `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` were present;
- the package contained the widget extension.

This does not prove that those capabilities cause the picker failure. It identifies the shared input
to Feather, SideStore, and AltStore and explains why a main-app-only comparison is more discriminating
than testing three signers against the same complex IPA.

Repository search in the public Feather, SideStore, and AltStore issue trackers did not find a
matching, documented direct-sideload folder-selection fix. A SideStore item mentioning a document
picker concerned opening an IPA *in SideStore itself*, not a re-signed app selecting a directory [9].

## Recommended order

1. Done on 2026-09-22: remove only the fallback that sets `directoryURL` to NOOP's own Documents
   directory. A resolved, previously chosen external folder remains an optional start hint.
2. Test the resulting IPA on one affected physical device after Feather/SideStore signing. Simulator
   success is not sufficient evidence for sandbox behavior.
3. If still broken, build a main-app-only diagnostic IPA without the widget/App Group template and
   compare it with the normal IPA under the same signer and certificate.
4. Capture the final installed app and extension entitlements/provisioning profiles from both a
   working Xcode install and failing re-signed install. Compare effective application identifier,
   team identifier, App Groups, and nested-extension identities.
5. Independently add coordinated file access for external backup reads/writes after selection. Treat
   this as correctness work, not as the picker-button fix.

The first change is small and API-conformant. The second comparison cleanly separates NOOP's package
shape from the individual signing tool. Neither requires users to export every backup manually or
accept deletion-prone app-container storage as the product design.

## Sources

1. Apple, [Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories)
2. Apple, [`UIDocumentPickerViewController`](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller)
3. RyanBR/noop, [Issue #2356: Can't choose a folder from iCloud Drive to store backups](https://github.com/ryanbr/noop/issues/2356)
4. AltStore, [official repository](https://github.com/altstoreio/AltStore)
5. SideStore, [`ResignAppOperation.swift`](https://github.com/SideStore/SideStore/blob/develop/SideStore/Core/Operations/PipelineOperations/ResignAppOperation.swift)
6. Feather, [official wiki](https://github.com/claration/Feather/wiki)
7. RyanBR/noop, [PR #2359: Backup picker: report what the sheet did, not why](https://github.com/ryanbr/noop/pull/2359)
8. Apple Developer Forums, [document picker works in debug but not release](https://developer.apple.com/forums/thread/713814)
9. SideStore, [PR #419](https://github.com/SideStore/SideStore/pull/419)

Analysis migration required: no — the picker presentation change and this research do not change
scoring math, stored analysis, source precedence, baselines, or invalidation semantics.
