#!/usr/bin/env python3
"""Regenerate `r20_optical_oracle.json` from a WHOOP 5/MG deep-buffer capture.

The R20 (layout-v20, 2,140-byte) optical golden vectors are checked in twice — once for Swift, once
for Android — and the two copies must stay byte-identical. This script writes both from the same
buffer, so they cannot drift.

The expected values are produced here by a THIRD, independent implementation of the byte layout
(plain `struct.unpack` against the published offsets from issue #423). Swift and Kotlin then both have
to reproduce them, which is what makes the fixture a drift guard rather than a snapshot of whichever
decoder happened to run last.

Usage:

    Tools/gen_r20_oracle.py /path/to/buffers2140.jsonl [--lines 0,16475]

The input is the #454 deep-buffer recorder's own JSONL — one object per line with `hex`, `size` and
`strap_ts`. Default line numbers are the two records currently committed: an ordinary active record
carrying negative readings, and one that also hits the positive saturation rail.
"""
import argparse
import collections
import json
import struct
import zlib
from pathlib import Path

BLOCK_BASES = [26, 448, 870, 1292, 1714]
DEFAULT_NAMES = ["blk0_active_negatives", "rails_saturation_and_negatives"]
REPO_ROOT = Path(__file__).resolve().parent.parent
DESTS = [
    REPO_ROOT / "Packages/WhoopProtocol/Tests/WhoopProtocolTests/Resources/r20_optical_oracle.json",
    REPO_ROOT / "android/app/src/test/resources/r20_optical_oracle.json",
]


def u8(b, o): return b[o]
def u16(b, o): return struct.unpack_from("<H", b, o)[0]
def i16(b, o): return struct.unpack_from("<h", b, o)[0]
def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def i32(b, o): return struct.unpack_from("<i", b, o)[0]


def crc16_modbus(bs):
    crc = 0xFFFF
    for x in bs:
        crc ^= x
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def decode(b):
    """Independent reference decode, CRC-gated exactly as the shipped decoders are."""
    assert len(b) == 2140, f"expected 2140 bytes, got {len(b)}"
    assert b[0] == 0xAA, "sync byte"
    assert zlib.crc32(b[8:2136]) == u32(b, 2136), "CRC32 over [8:2136]"
    assert crc16_modbus(b[0:6]) == u16(b, 6), "CRC16-Modbus over [0:6]"
    assert b[8] == 0x2F and b[9] == 20, "record class / layout version"
    blocks = []
    for i, base in enumerate(BLOCK_BASES):
        n = u8(b, base)
        assert n <= 50, "sample count beyond slot capacity"
        blocks.append(collections.OrderedDict([
            ("index", i),
            ("sample_count", n),
            ("source_a", u8(b, base + 1)),
            ("drive_a", u16(b, base + 2)),
            ("source_b", u8(b, base + 4)),
            ("drive_b", u16(b, base + 5)),
            ("detector_a_select", u8(b, base + 7)),
            ("range_a", u32(b, base + 8)),
            ("offset_a", i16(b, base + 12)),
            ("detector_b_select", u8(b, base + 14)),
            ("range_b", u32(b, base + 15)),
            ("offset_b", i16(b, base + 19)),
            ("reserved", u8(b, base + 421)),
            ("readings_a", [i32(b, base + 21 + s * 4) for s in range(n)]),
            ("readings_b", [i32(b, base + 221 + s * 4) for s in range(n)]),
        ]))
    return collections.OrderedDict([
        ("layout_version", b[9]),
        ("record_class", b[8]),
        ("record_index", u32(b, 11)),
        ("base_ts", u32(b, 15)),
        ("checksum", u32(b, 2136)),
        ("sample_counts", [blk["sample_count"] for blk in blocks]),
        ("blocks", blocks),
    ])


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("corpus", help="deep-buffer JSONL from the #454 recorder")
    ap.add_argument("--lines", default="0,16475",
                    help="comma-separated 0-based line numbers to lift as golden vectors")
    ap.add_argument("--names", default=",".join(DEFAULT_NAMES),
                    help="comma-separated names, one per line number")
    args = ap.parse_args()

    line_nos = [int(x) for x in args.lines.split(",")]
    names = args.names.split(",")
    assert len(line_nos) == len(names), "--lines and --names must be the same length"
    wanted = dict(zip(line_nos, names))

    found = {}
    with open(args.corpus) as f:
        for i, line in enumerate(f):
            if i in wanted:
                found[i] = json.loads(line)
            if len(found) == len(wanted):
                break
    missing = set(wanted) - set(found)
    assert not missing, f"line numbers not present in {args.corpus}: {sorted(missing)}"

    out_records = []
    for line_no in line_nos:
        raw = found[line_no]
        b = bytes.fromhex(raw["hex"])
        exp = decode(b)
        assert exp["base_ts"] == raw["strap_ts"], "u32LE@15 must equal the recorder's strap_ts"
        out_records.append(collections.OrderedDict([
            ("name", wanted[line_no]),
            ("hex", raw["hex"]),
            ("expect", exp),
        ]))

    # Single-bit corruptions that MUST be rejected, applied to the first record. Each names the gate
    # it trips, so a regression tells you which check was lost.
    rejections = [
        ("reading_bit_flip", 47, 0x01, "a bit in blk0 readings_a[0] — CRC32 payload"),
        ("sample_count_bit_flip", 26, 0x01,
         "blk0 sample_count, the byte that sets the parse shape — CRC32 payload"),
        ("drive_bit_flip", 28, 0x01, "blk0 drive_a low byte — CRC32 payload"),
        ("checksum_bit_flip", 2136, 0x01, "the CRC32 trailer itself"),
        ("declared_length_bit_flip", 2, 0x01, "the declared length @2:3 — CRC16-Modbus header"),
    ]
    base_bytes = bytes.fromhex(out_records[0]["hex"])
    reject_cases = []
    for name, off, mask, why in rejections:
        mutated = bytearray(base_bytes)
        mutated[off] ^= mask
        m = bytes(mutated)
        # Prove here that the corruption really does break a checksum, so the fixture can never
        # silently assert "rejected" for a frame that is in fact valid.
        crc32_ok = zlib.crc32(m[8:2136]) == u32(m, 2136)
        crc16_ok = crc16_modbus(m[0:6]) == u16(m, 6)
        assert not (crc32_ok and crc16_ok), f"{name} did not break a checksum"
        reject_cases.append(collections.OrderedDict([
            ("name", name),
            ("offset", off),
            ("xor", mask),
            ("why", why),
            ("crc32_ok", crc32_ok),
            ("crc16_ok", crc16_ok),
        ]))

    doc = collections.OrderedDict([
        ("note",
         "Golden vectors for the WHOOP 5/MG layout-v20 (R20, 2,140-byte) optical record. Both `hex` "
         "strings are REAL records from a NOOP deep-buffer capture (issue #423); the expected values "
         "were produced by an independent third implementation of the published byte layout, so Swift "
         "and Kotlin each have to reproduce them rather than agreeing with each other by construction. "
         "Regenerate with Tools/gen_r20_oracle.py, which writes both copies at once — they MUST stay "
         "byte-identical."),
        ("layout", collections.OrderedDict([
            ("buffer_length", 2140),
            ("block_bases", BLOCK_BASES),
            ("block_length", 422),
            ("head_length", 21),
            ("slot_length", 200),
            ("slot_capacity", 50),
            ("checksum_offset", 2136),
            ("crc32_input", [8, 2136]),
            ("crc16_input", [0, 6]),
            ("sample_min", -524288),
            ("sample_max", 524287),
        ])),
        ("records", out_records),
        ("crc_rejection", collections.OrderedDict([
            ("source", out_records[0]["name"]),
            ("cases", reject_cases),
        ])),
    ])

    blob = json.dumps(doc, indent=2) + "\n"
    for d in DESTS:
        d.write_text(blob)
    print(f"wrote {len(blob)} bytes to {len(DESTS)} destinations")
    for r in out_records:
        e = r["expect"]
        readings = [v for blk in e["blocks"] for v in blk["readings_a"] + blk["readings_b"]]
        print(f"  {r['name']}: idx={e['record_index']} ts={e['base_ts']} "
              f"counts={e['sample_counts']} min={min(readings)} max={max(readings)}")
    print(f"  {len(reject_cases)} CRC rejection cases")


if __name__ == "__main__":
    main()
