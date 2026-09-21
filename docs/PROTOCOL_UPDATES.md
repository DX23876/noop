# Firmware updates and device authorization

This chapter follows the [shared scope](PROTOCOL.md#scope-and-compatibility). Image integrity, boot acceptance and session authorization are distinct mechanisms. These contracts describe boundaries, not a validated installation procedure.

Neither generation has a documented end-to-end installation procedure in this
reference. Do not send update, lock, trim, reboot or power-cycle commands based on
these pages; no validated or authorized flashing path is documented. A CRC-valid
container does not prove a WHOOP signature, board compatibility, version ordering
or recoverability.

<a id="whoop-4-boundary"></a>

## WHOOP 4

The documented WHOOP 4 package boundary is
`HARVARD`/`GEN_4`: MAXIM `41.17.6.0` plus bundled NORDIC `17.2.2.0`. It establishes
container and package facts, not a validated update or authorization interface.
Historical low-number image operations or shared numeric
IDs must not be mapped onto commands 142–159. Conversely, WHOOP 5/MG unsupported
status does not describe WHOOP 4.

| Layer | Documented contract | What remains unproven |
|---|---|---|
| Outer package | ZIP contains one HARVARD MAXIM ZBIN and one BOYLSTON Nordic DFU ZIP | service eligibility, device selection and install order |
| MAXIM container | 512-byte header followed by gzip payload | complete header schema, signature fields and bootloader interpretation |
| MAXIM payload CRC | stored payload CRC32 equals CRC32 of compressed bytes | authenticity and device acceptance |
| MAXIM header CRC | stored header CRC32 equals CRC32 over header bytes `[8,0x1f8)` | purpose of every covered field and anti-tamper policy |
| MAXIM image | gzip expands to a 1,315,584-byte image for version `41.17.6.0` | flash placement, activation and successful boot |
| Nordic DFU | The [nRF52840 BLE processor](PROTOCOL_WHOOP4.md#whoop4-nrf52840) application is separate from combined SoftDevice/bootloader data; declared sizes are 153,140 SoftDevice bytes and 40,452 bootloader bytes | init-packet trust validation, compatibility and successful flash |
| Nordic DFU transition | command 45 starts the Nordic DFU transition; response, disconnect, later advertisement and usable DFU service are separate observations | exact phone request, retry timing and completed transition |

WHOOP 4 supports START/LOAD/PROCESS/VERIFY operations at 36–38 and 83, with 85
sharing the LOAD operation. The protocol distinguishes update-region erase,
indexed data and length, load success/failure, image CRC pass/fail, signature
verification and staged completion. These are not aliases for WHOOP
5/MG commands 142–144. Exact request lengths, transfer chunk limits,
cryptographic key and signed-range rules, authorization,
anti-rollback, boot acceptance, rollback and interruption recovery remain open.

| WHOOP 4 command | 41.17.6.0 role | Contract boundary |
|---:|---|---|
| 36 | start load and erase update region | request revision/body and erase durability unresolved |
| 37, 85 | shared indexed firmware-data load operation | index and length are parsed; exact field widths/chunk maximum unresolved |
| 38 | process image and check image CRC | CRC pass is not authenticity or boot acceptance |
| 45 | request NORDIC DFU/bootloader mode | phone-visible response and successful Nordic transition unresolved |
| 83 | verify firmware image | algorithm, key and final trust decision unresolved |

<a id="whoop-5mg-version-baseline"></a>

## WHOOP 5/MG

Except for the separately labelled [WHOOP 4 boundary](#whoop-4), command
bodies, container fields and certificate rules in this chapter apply to **WHOOP
5/MG 50.42.1.0**. They are protocol contracts, not a validated installation or
flashing procedure.

### Image-transfer command boundaries

| Command | Request body | Response and limits |
|---:|---|---|
| 83 | `revision:u8=1` | Starts incremental image verification. Immediate completion/failure has body `[1]`; unfinished verification continues asynchronously. The final response retains the original request correlation, body `[1]`, and outer result 1 for integrity success or 0 for failure. |
| 142 | `revision:u8=1` | `[1, detail]`; success detail 0, preparation failure detail 10. |
| 143 | `revision:u8=1, offset:u32le, length:u8, data[length]` | Length at most 224. `[1, detail]`; success detail 0, otherwise a lower-layer error or preparation detail 10. Partition, alignment and storage constraints also apply. |
| 144 | `revision:u8=1` | Image integrity acceptance returns `[1,1]` with result 1 and queues lifecycle work. Preparation, integrity or revision failure returns `[1,0]` with result 0. Later boot acceptance remains a separate boundary. |

An incomplete successful command 83 verification step is followed by another step
without a final response in between. No additional client command is needed to
make verification proceed. Failure to close update storage does not replace the saved integrity
result. Timeout, disconnection and overlapping requests remain unresolved; wait
for the correlated result and do not treat silence as success.

Command 144 success confirms the application image CRC gate. A later disconnect,
reset or reconnect remains a separate observation and does not establish completed
installation, authenticity or boot acceptance. A reconnect does not by
itself identify the accepted image. Signature, compression and rollback policies
remain unspecified; CRC equality and version fields do not establish them.
These contracts do not supply an installation sequence.

### Image container and integrity fields

The documented container format has a **512-byte header** followed by its
payload. Offsets below are offsets within the file, not Bluetooth-frame or memory
addresses. Multibyte numeric fields are little-endian.

| File offset | Width | Meaning |
|---:|---:|---|
| 0 | 4 | CRC32 of all payload bytes starting at offset 512; this is not a magic value |
| 4 | 4 | Payload length, excluding the 512-byte header |
| 8 | 4 | Unresolved header word |
| 12 | 4 | Image-type selector |
| 16 | 4 | Unresolved header word |
| 504 | 4 | Header CRC32 over bytes 8–503 inclusive |

Both checks use the conventional reflected CRC32 result.
Unlisted header bytes include version/build information and unresolved fields;
this table does not define them as zero or freely editable. The payload CRC and
length are outside the header-CRC range.

The compressed `.zbin` container and its decompressed image each carry their own
header and payload checks. In the compared artifacts, type 5 carries a gzip
payload and type 1 carries the decompressed payload. This is a bounded type
mapping, not a complete type enumeration. Do not substitute one representation's
length or checksums for the other's.

Command 143 rejects chunks outside the accepted image range. Accepted chunk writes
are read back and compared; a mismatch fails the command. This is separate from
whole-image verification and eventual boot acceptance. These fields support
container validation; they do not establish which representation a complete
installation procedure must transfer or that a modified container will boot.

### Certificate command boundaries

Commands 155 through 159 cover certificate transfer and device authorization. They gate an authorization state that requires a validly signed, identity-matching certificate; NOOP implements no update, authorization or unlock path, and the signing key and detailed validation rules are outside this reference.

For sensor production, live/save policy, typed configuration and flag behavior use [configuration](PROTOCOL_CONFIGURATION.md); for ECG wrist/start/stop and independent raw/filtered routing use [ECG](PROTOCOL_ECG.md). Those pages separate requested state from applied state and packet delivery. Exact timing, energy cost, all reset paths and all hardware variants remain open unless a specific contract says otherwise.
