# WHOOP BLE protocol

An interoperability reference for apps communicating directly with WHOOP straps.
Start with the device profile, then follow the operation or record you need.
Documentation coverage is broader than any one implementation's command and record subset.

## Scope and compatibility

WHOOP 4 and WHOOP 5/MG share protocol concepts, but have different GATT services,
frame headers and connection flows. A shared command name does not establish the
same request or response bytes. WHOOP 5 historical data is not a WHOOP 4 layout
with shifted offsets.

The WHOOP 5/MG topic references use **firmware 50.42.1.0** as their common version baseline
unless a passage explicitly identifies an earlier observation or a client-only
interpretation. WHOOP 5 and MG use one shared protocol profile at this version,
while ECG still depends on hardware capability. This does not establish identical
features across every release or both devices. These baseline contracts do not
claim device validation.

Earlier observations cover ECG on MG **50.39.1.0**, optical/IMU records and
reboot on **50.40.1.0**, R-R conversion on **50.41.1.0**, and older Hello decoding
on **50.38.1.0**. The WHOOP 4 profile is centered on **41.17.6.0** where
that version is retained; feature-name enumeration is a separately bounded
**41.16.6.0** capture, and 41.17.6.0 can emit version-25 records depending on
device configuration. Their distinct limits remain at the relevant operation;
they do not override the baseline. WHOOP 4 is a version-bounded wire profile.
It is documented to the same topical
boundaries as WHOOP 5/MG, but it does not inherit the 50.42.1.0 command set,
configuration namespaces, sensor layouts or update interfaces where no WHOOP 4
contract is documented.

Each contract states its applicable family and version. Observed device behavior,
application behavior and version-specific support are kept distinct;
successful acknowledgement is never treated as proof of persistence or physical
effect.

| Profile | Start here | Interpretation |
|---|---|---|
| WHOOP 4 | [WHOOP 4 profile](PROTOCOL_WHOOP4.md) | Legacy connection, framing, identity and record conventions |
| WHOOP 5/MG | [WHOOP 5/MG profile](PROTOCOL_WHOOP5.md) | Shared transport; check capabilities independently |
| All readers | [Shared concepts](PROTOCOL_CONCEPTS.md) | Integrity, request lifecycle and durable history handling |

Command revision, record layout and inner record version remain explicit byte
selectors throughout the reference. Unknown means unresolved, not unsupported.
“Defined” does not mean available in every state or implemented by every application.

## Reading guide

| Task | Authoritative topic |
|---|---|
| Frame, correlate and recover a connection | [Transport](PROTOCOL_TRANSPORT.md) |
| Compare an operation or its limitations | [Command matrix](PROTOCOL_COMMANDS.md#canonical-command-matrix): every ID 1–159 once; the documented WHOOP 4 firmware 41.17.6.0 command set has 85 `S` and 47 `U` entries across IDs 1–132, while WHOOP 5/MG has 71 supported and 88 unsupported IDs |
| Configure collection and output | [Configuration](PROTOCOL_CONFIGURATION.md): 8 device keys and 25 feature descriptors |
| Decode measurements | [Sensor records](PROTOCOL_SENSORS.md) |
| Control and decode MG ECG | [ECG](PROTOCOL_ECG.md) |
| Schedule or stop an alarm | [Alarms](PROTOCOL_ALARMS.md) |
| Understand image transfer and authorization | [Updates and authorization](PROTOCOL_UPDATES.md) |
| Know the hardware behind a contract | Hardware overview on the [WHOOP 4](PROTOCOL_WHOOP4.md#hardware-overview) and [WHOOP 5/MG](PROTOCOL_WHOOP5.md#hardware-overview) profile pages |
| Work on the NOOP integration | [Contract-to-implementation map](PROTOCOL_IMPLEMENTATION.md#protocol-contract-to-implementation-map) |
| Reproduce selected parsing rules | [Constructed examples](protocol-examples/validate_examples.py) |

Each contract has one authoritative topic. Historical experiments and
application-specific timing or interpretation conventions are labeled separately. In particular, the older
[deep-data experiment](WHOOP5_DEEP_DATA.md) is not a universal enable recipe.

## Remaining boundaries

Absolute ECG sample timing and voltage calibration, some physiological field
meanings, complete bootloader acceptance and several runtime/error interactions
remain unresolved. Local limits are recorded beside each contract. Constructed
examples check selected arithmetic and state rules; they are not device tests.

## Project and credits

NOOP is an independent, offline companion and is not affiliated with WHOOP or a
medical device. See [disclaimer](../DISCLAIMER.md) and [attribution](../ATTRIBUTION.md).
The existing work builds on `johnmiddleton12/my-whoop` (WHOOP 4) and
`b-nnett/goose` (WHOOP 5); further credits remain with the historical observations.
The Swift protocol package and Android protocol entry points are indexed in the
[file map](PROTOCOL_IMPLEMENTATION.md#11-file-map).

## Legacy anchors

The following anchors keep older links into this page resolvable.

<a id="whoop-40--service-61080001-"></a>
<a id="whoop-50--mg--service-fd4b0001-"></a>
<a id="21-whoop-40-envelope"></a>
<a id="22-whoop-50--mg-envelope"></a>
<a id="5-bond-handshake--connect-lifecycle-whoop-40"></a>
<a id="9-whoop-50-vs-mg--telling-the-hardware-apart"></a>
<a id="get_hello_harvard-35-response--the-whoop-40-serial"></a>
<a id="extended-protocol-reference"></a>
<a id="1-gatt-topology"></a>
<a id="diagnostic-only-whoop-service-families"></a>
<a id="standard-sig-services-both-generations"></a>
<a id="2-frame-envelope"></a>
<a id="23-family-aware-entry-points"></a>
<a id="24-command_response-body"></a>
<a id="25-checksums"></a>
<a id="26-reassembly"></a>
<a id="3-packettype-offset-4-or-8-on-50"></a>
<a id="4-eventnumber-event-type-48"></a>
<a id="6-commandnumber-sending--the-safe-subset"></a>
<a id="additional-5-class-command-numbers"></a>
<a id="destructive-commands--do-not-send"></a>
<a id="7-historical-data-offload-backfill"></a>
<a id="71-metadatatype-metadata6"></a>
<a id="72-history_end-payload-layout"></a>
<a id="73-session-state-machine"></a>
<a id="74-safe-trim-invariant"></a>
<a id="75-watchdog--liveness"></a>
<a id="8-decoded-output-parsedframe"></a>
<a id="91-ecg-labrador-on-the-mg"></a>
<a id="10-spo₂-on-50--mg--what-the-wire-does-and-does-not-carry"></a>
<a id="companion-reference-corrections--504210"></a>
<a id="previous-section-links"></a>
<a id="11-file-map"></a>
