# WHOOP 5/MG profile

<a id="whoop-5--mg-profile"></a>

Read the [scope and compatibility](PROTOCOL.md#scope-and-compatibility) before applying this page.

## Version and validation boundary

Unless a paragraph names an older observation, app version or firmware, the linked
command, transport, configuration, sensor and update contracts apply to 50.42.1.0.
They do not imply validation on every device state. Application-specific parsing,
timing and feature gating are documented separately, and older observations
remain bound to their stated firmware. No field or
operation on these pages should be backported to WHOOP 4 by subtracting an envelope
offset or substituting a low-number opcode.

| Topic | WHOOP 5/MG authority |
|---|---|
| GATT and connection hello | This page |
| Framing, replies, history and identity | [Transport](PROTOCOL_TRANSPORT.md#whoop-5mg) |
| Commands | [Comparative matrix](PROTOCOL_COMMANDS.md#canonical-command-matrix) and [WHOOP 5/MG contracts](PROTOCOL_COMMANDS.md#whoop-5mg) |
| Measurements and collection | [Sensors](PROTOCOL_SENSORS.md#whoop-5mg) and [configuration](PROTOCOL_CONFIGURATION.md#whoop-5mg) |
| Image and authorization interfaces | [Updates](PROTOCOL_UPDATES.md#whoop-5mg) |
| Alarms and haptics | [Alarms](PROTOCOL_ALARMS.md#whoop-5mg) |
| Shared concepts | [Shared concepts](PROTOCOL_CONCEPTS.md) |

## Hardware overview

The following components are documented for firmware 50.42.1.0. Part identities
explain which protocol contracts exist; they do not imply calibration or physical
validation.

| Function | Component | Protocol relationship |
|---|---|---|
| Optical front end and ECG front end | <a id="whoop5-max86176"></a>Analog Devices MAX86176 | AFE parameters (commands 61/62), optical records R20/R26, ECG records R16/R17 on MG; absolute ECG sample rate and volts per count are not documented. |
| 6-axis IMU with pedometer | <a id="whoop5-icm-45686"></a>TDK InvenSense ICM-45686 | IMU records R21 and stream types 51/52, gyro mode (150/152), step counters. |
| Haptics driver | <a id="whoop5-drv2625"></a>Texas Instruments DRV2625 | Alarm and haptic pattern commands. |
| Battery fuel gauge | <a id="whoop5-lc709205f"></a>onsemi LC709205F | Battery pack information (command 151), battery level (26). |
| Skin temperature sensor | <a id="whoop5-as6221"></a>ams OSRAM AS6221 | Temperature fields in biometric/history records. |

MG-only ECG depends on the MAX86176 ECG channel and the ECG-conductive clasp;
WHOOP 5.0 and MG otherwise share the sensor components listed here.

<a id="whoop-50--mg--service-fd4b0001-"></a>

## WHOOP 5/MG — service `fd4b0001-…`

The WHOOP 5/MG service exposes five characteristics, one more than the WHOOP 4 service.

| Role | UUID |
|------|------|
| Custom service | `fd4b0001-cce1-4033-93ce-002d5875f58a` |
| Command write | `fd4b0002-cce1-4033-93ce-002d5875f58a` |
| Notify channels | `fd4b0003`, `fd4b0004`, `fd4b0005`, `fd4b0007` (`…-cce1-4033-93ce-002d5875f58a`) |

The `fd4b` service carries the Maverick/Goose framing documented here. A separate
service family is identified at `11500001-6215-11ee-8c99-0242ac120002`; its
framing and supported operations remain unresolved.

<a id="9-whoop-50-vs-mg--telling-the-hardware-apart"></a>

## WHOOP 5.0 vs MG — telling the hardware apart

Both labels share the `fd4b…` GATT family and the same puffin envelope, so both are
framed and parsed as one family. Hardware capabilities and record availability still need to be checked separately. What differs is hardware —
an MG carries the ECG-conductive clasp, a 5.0 does not.

The standard BLE Device Information Service can expose model, serial and hardware
revision signals associated with the two variants. These observations do not
change frame parsing or establish a universal identification rule.

| Signal | DIS characteristic | Reads |
|---|---|---|
| Model number `MG` | Model Number String (`0x2A24`) | MG |
| Serial prefix `5AM` | Serial Number String (`0x2A25`) | MG |
| Serial prefix `5AG` | Serial Number String (`0x2A25`) | 5.0 |
| Hardware revision contains `WG50` | Hardware Revision String (`0x2A27`) | 5.0 |

Conflicting `5AM` serial and `WG50` hardware signals leave the variant unresolved.
An unresolved variant does not establish MG-only capability.
An MG has also been observed with a different serial prefix and hardware revision;
there is no universal MG hardware-revision token. Absence of a
recognized prefix therefore does not establish that the strap lacks MG hardware.

## Connection and frame format

Use the [Format 1 envelope](PROTOCOL_TRANSPORT.md#format-1-framing), including its
padding and response-correlation rules, before sending the Hello step. Subscribe
to the fd4b notification channels, then write the fixed client hello below to the
command characteristic with response. WHOOP 4's bond/hello sequence is a separate
profile; recovery is defined in [transport](PROTOCOL_TRANSPORT.md).

```text
AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D
```

## Operations and measurements

Use [commands](PROTOCOL_COMMANDS.md), [configuration](PROTOCOL_CONFIGURATION.md) and [sensor records](PROTOCOL_SENSORS.md) together. Packet type, record layout and inner version are different selectors; the receiver must decode what was emitted. MG [ECG](PROTOCOL_ECG.md) requires the appropriate hardware capability. A successful request alone does not prove sensor initialization or delivered data.
