# Android connection regression: protocol resources and scan cleanup

2026-10-26 · Analysis migration required: **no** · Physical-device retest pending

## Report and findings

The supplied WHOOP 4.0 reports came from a Pixel 8 Pro on Android 17, running 12.2.1-debug.
They show GATT connection, notification subscriptions and an acknowledged bond write. The separate
logcat then ends in `unable to find bundle named WhoopProtocol_WhoopProtocol` and SIGTRAP. The APK
contained `exercise-catalog.json` but omitted `whoop_protocol.json`. Its first custom notification
reached the shared Swift decoder, whose generated SwiftPM bundle accessor terminated the process.

The detailed capture also contains a permission failure followed by repeated `ALREADY_STARTED` scan
failures. `onScanFailed` cleared the client's scan flag, and `stopScan` used that flag to decide whether
to unregister Android's callback. A callback registration could therefore remain alive after the app
considered the scan stopped. Tests reproduce both a duplicate-start failure and a permission exception
after registration; both failed before the cleanup change.

## Repair

- Both Swift resources are APK assets. The app copies and validates the protocol schema before starting
  its core session. Failed setup leaves the session stopped and emits an error instead of accepting
  frames into an unconfigured decoder. Apple and standalone SwiftPM builds retain their bundle lookup.
- The scan's callback-cleanup obligation is tracked separately from its visible scan state. A failure
  unregisters the callback; a later scan also cleans any registration left by a thrown start or stop.
- The Forge pairing page shows its search indicator only while a scan is active. Diagnostic exports
  now include `BLUETOOTH_SCAN` separately from `BLUETOOTH_CONNECT`.
- `check-apk-resources.py` discovers production resources in the shared core's local package graph and
  checks their bytes inside both built APKs. CI and the committed-tree gate run it after assembly and
  compile the instrumentation replay APK.

## Verification and limits

| Check | Evidence |
|---|---|
| Installed-APK replay before repair | The emulator terminated with the same missing-WhoopProtocol-bundle fatal error as the Pixel. |
| Installed-APK replay after repair | Bond event, live HR, rejected bad-CRC notification and three captured WHOOP 4.0 history records pass through JNI, collection and storage; the chunk is reported banked. The test uses a fresh cache directory and sends nothing to a strap. |
| Scan recovery | Both real-client Robolectric regressions fail before the repair and pass afterwards. |
| Bluetooth and core JVM tests | 881 tests, zero failures. |
| WhoopProtocol | 846 tests, one skipped, zero failures; covers both device envelopes and decoder integrity. |
| NoopCoreJNI | 20 tests, one optional real-data test skipped, zero failures. |
| APK resource check | The old demo APK fails for the missing schema; corrected full and demo APKs pass. |

The connection implementation was compared with `ryanbr/noop` main at `2a1de7609`. Its newer BLE
changes concern ECG, and its scan cleanup still has the same flag-based early return. The fork's
handshake command order and payloads were not changed by this repair.

These checks do not prove Android radio behavior, OS pairing, background operation or overnight sync.
The corrected APK still needs the [physical-device checks](TESTING.md): pairing, live HR, a full history
offload and reconnect, each supported by a new strap log. The optional core-confirmed history-ack
switch also remains subject to its existing hardware acceptance check.

For the installed-APK regression, build `assembleFullDebug` and `assembleFullDebugAndroidTest`, then run
`Tools/android-core-replay.sh <full-debug.apk> <androidTest.apk>`. The script accepts only an emulator
and treats a native process crash as failure even though ADB itself returns success.
