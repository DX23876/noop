import struct
import whoop_activity as wa


def make_v18(unix=1000, hr=60, motion=0, wear=0, sleep_state=0,
             hr_fixed=0, rr_packed=0, cardiac_flags=0, cardiac_status=0,
             record_index=0, step_cadence=0, status_word=0, aux_f32=0.0,
             temp_aux_1=0, temp_aux_2=0, status_word_1=0, status_word_2=0,
             onwrist=0, wake_quality=0, aux_byte_82=0,
             version=18, length=124):
    """Build a synthetic v18 type-47 frame with fields at their real offsets."""
    f = bytearray(length)
    f[0] = 0xAA
    f[9] = version
    struct.pack_into("<I", f, 11, record_index & 0xFFFFFFFF)   # @11 record_index (u32)
    struct.pack_into("<I", f, 15, unix)
    f[22] = hr & 0xFF
    struct.pack_into("<H", f, 36, hr_fixed & 0xFFFF)     # @36 hr_fixed_8_8
    struct.pack_into("<H", f, 38, rr_packed & 0xFFFF)    # @38 rr_packed
    f[33] = cardiac_flags & 0xFF                          # @33 cardiac_flags
    f[40] = cardiac_status & 0xFF                         # @40 cardiac_status
    struct.pack_into("<H", f, 57, motion & 0xFFFF)
    f[59] = step_cadence & 0xFF                           # @59 step_cadence
    f[63] = wear & 0xFF                                   # @63 motion_wear_quality
    struct.pack_into("<h", f, 69, temp_aux_1)             # @69 temp_aux_1_raw (i16)
    struct.pack_into("<h", f, 71, temp_aux_2)             # @71 temp_aux_2_raw (i16)
    struct.pack_into("<H", f, 75, status_word & 0xFFFF)   # @75 status_word
    struct.pack_into("<H", f, 77, status_word_1 & 0xFFFF)  # @77 status_word_1
    struct.pack_into("<H", f, 79, status_word_2 & 0xFFFF)  # @79 status_word_2
    # @81: b0-1 onwrist, b2-3 wake_quality, b4-5 sleep_state (low nibble sub-flags otherwise ignored)
    f[81] = (onwrist & 3) | ((wake_quality & 3) << 2) | ((sleep_state & 3) << 4)
    f[82] = aux_byte_82 & 0xFF                            # @82 aux_byte_82
    struct.pack_into("<f", f, 113, aux_f32)               # @113 unknown_f32_113 (f32 LE)
    return bytes(f)


def test_decode_v18_roundtrips_fields():
    d = wa.decode_v18(make_v18(unix=1700000000, hr=58, motion=4000, wear=1, sleep_state=2))
    assert d == {"record_index": 0, "unix": 1700000000, "hr": 58,
                 "onwrist": 0, "wake_quality": 0, "sleep_state": 2, "aux_byte_82": 0,
                 "motion_count": 4000, "step_cadence": 0, "motion_wear_quality": 1,
                 "hr_fixed_8_8": 0, "rr_packed": 0, "cardiac_flags": 0, "cardiac_status": 0,
                 "temp_aux_1_raw": 0, "temp_aux_2_raw": 0,
                 "status_word": 0, "status_word_1": 0, "status_word_2": 0,
                 "unknown_f32_113": 0.0}


def test_decode_v18_higher_precision_hr():
    # @36 value/256 ≈ hr@22 — observable: divide and compare to the integer HR at the same second.
    d = wa.decode_v18(make_v18(hr=102, hr_fixed=25997))
    assert d["hr_fixed_8_8"] == 25997
    assert abs(d["hr_fixed_8_8"] / 256.0 - d["hr"]) < 1.0   # 25997/256 ≈ 101.55 ≈ 102


def test_decode_v18_late_fields():
    d = wa.decode_v18(make_v18(record_index=25_500_000, step_cadence=130, aux_f32=-1.875))
    assert d["record_index"] == 25_500_000      # @11 per-record counter
    assert d["step_cadence"] == 130             # @59 cadence-like byte (raw)
    assert d["unknown_f32_113"] == -1.875       # @113 f32 LE (purpose unknown; exact in float32)


def test_decode_v18_reads_sleep_state_high_nibble_only():
    f = bytearray(make_v18(sleep_state=3))
    f[81] = (3 << 4) | 0x05      # state 3 + sub-flags 0x05
    assert wa.decode_v18(bytes(f))["sleep_state"] == 3


def test_decode_v18_temp_aux_channels():
    # @69/@71 signed i16 LE; °C = value/10. Use a body-temp-like value (34.0 °C -> 340).
    d = wa.decode_v18(make_v18(temp_aux_1=340, temp_aux_2=337))
    assert d["temp_aux_1_raw"] == 340 and d["temp_aux_1_raw"] / 10.0 == 34.0
    assert d["temp_aux_2_raw"] == 337 and d["temp_aux_2_raw"] / 10.0 == 33.7


def test_decode_v18_temp_aux_signed():
    # i16 (not u16): a value above 0x7FFF must come back negative.
    d = wa.decode_v18(make_v18(temp_aux_1=-50, temp_aux_2=-1))
    assert d["temp_aux_1_raw"] == -50
    assert d["temp_aux_2_raw"] == -1


def test_decode_v18_status_word_siblings():
    d = wa.decode_v18(make_v18(status_word=0x0080, status_word_1=0x0081, status_word_2=0x0082))
    assert d["status_word"] == 0x0080      # @75
    assert d["status_word_1"] == 0x0081    # @77 (low nibble = 1)
    assert d["status_word_2"] == 0x0082    # @79 (low nibble = 2)


def test_decode_v18_byte_81_bitfields():
    # @81 packs onwrist(b0-1), wake_quality(b2-3), sleep_state(b4-5).
    d = wa.decode_v18(make_v18(onwrist=1, wake_quality=2, sleep_state=3))
    assert d["onwrist"] == 1
    assert d["wake_quality"] == 2
    assert d["sleep_state"] == 3


def test_decode_v18_aux_byte_82():
    d = wa.decode_v18(make_v18(aux_byte_82=0x2A))
    assert d["aux_byte_82"] == 0x2A        # @82 raw


def test_decode_v18_rejects_non_v18_and_short():
    assert wa.decode_v18(make_v18(version=26)) is None       # wrong version byte
    assert wa.decode_v18(b"\xaa" + b"\x00" * 40) is None     # too short to hold the late fields


def _recs(seq, start=1000):
    """seq = list of (motion, wear, sleep_state) at 1 Hz from `start`."""
    return [wa.decode_v18(make_v18(unix=start + i, motion=m, wear=w, sleep_state=s))
            for i, (m, w, s) in enumerate(seq)]


def test_step_deltas_wrap_aware():
    recs = _recs([(65530, 1, 0), (4, 1, 0)])     # 65530 -> 4 wraps: (4-65530)&0xffff = 10
    assert wa.step_deltas(recs) == [(1001, 10)]


def test_step_deltas_drops_sanity_jumps_and_gaps():
    recs = _recs([(0, 0, 0), (5000, 0, 0)])      # delta 5000 >= sanity_max -> dropped
    assert wa.step_deltas(recs) == []
    gapped = [wa.decode_v18(make_v18(unix=1000, motion=0)),
              wa.decode_v18(make_v18(unix=1100, motion=20))]   # >max_gap_s gap, not bridged
    assert wa.step_deltas(gapped) == []


def test_steps_total_and_by_hour():
    recs = _recs([(0, 1, 0), (2, 1, 0), (5, 1, 0)])   # diffs 2,3 -> total 5
    assert wa.steps_total(recs) == 5
    by_hour = wa.steps_by_hour(recs)
    assert sum(by_hour.values()) == 5


def test_wear_quality_minutes():
    recs = _recs([(0, 0, 0)] * 120 + [(0, 1, 0)] * 60 + [(0, 0xFF, 0)] * 60)
    wm = wa.wear_quality_minutes(recs)
    assert wm["good"] == 2 and wm["fair"] == 1 and wm["invalid"] == 1


def test_sleep_segments_collapse():
    # wake(2s) -> asleep(3s) -> up(1s) -> asleep(2s)
    seq = [(0, 0, 0), (0, 0, 0), (0, 0, 2), (0, 0, 2), (0, 0, 2), (0, 0, 3), (0, 0, 2), (0, 0, 2)]
    recs = _recs(seq, start=2000)
    segs = wa.sleep_segments(recs)
    states = [s[0] for s in segs]
    assert states == ["wake", "asleep", "up", "asleep"]
    assert segs[0] == ("wake", 2000, 2001)        # (state, start_unix, end_unix)
    assert segs[1] == ("asleep", 2002, 2004)


def test_sleep_state_minutes():
    seq = [(0, 0, 2)] * 180 + [(0, 0, 0)] * 60 + [(0, 0, 3)] * 60
    recs = _recs(seq, start=3000)
    m = wa.sleep_state_minutes(recs)
    assert m["asleep"] == 3 and m["wake"] == 1 and m["up"] == 1


import os
import sqlite3
import json
import subprocess
import sys


def _make_db(path, frames):
    """frames = list of (unix, frame_bytes) -> minimal frames table like whoop_sync's."""
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE frames (device_id INT, inner_type INT, unix INT, hex TEXT)")
    con.executemany("INSERT INTO frames VALUES (2, 47, ?, ?)",
                    [(u, fb.hex()) for u, fb in frames])
    con.commit()
    con.close()


def test_records_reads_and_decodes(tmp_path):
    db = tmp_path / "t.db"
    frames = [(1000 + i, make_v18(unix=1000 + i, motion=i, sleep_state=2)) for i in range(5)]
    frames.append((2000, make_v18(unix=2000, version=26)))   # non-v18 -> skipped
    _make_db(str(db), frames)
    recs = wa.records(str(db), device_id=2)
    assert len(recs) == 5 and all(r["sleep_state"] == 2 for r in recs)


def test_cli_steps_json(tmp_path):
    db = tmp_path / "t.db"
    frames = [(1000 + i, make_v18(unix=1000 + i, motion=i, wear=1)) for i in range(5)]
    _make_db(str(db), frames)
    here = os.path.dirname(wa.__file__)
    out = subprocess.check_output(
        [sys.executable, os.path.join(here, "whoop_activity.py"), "steps",
         "--db", str(db), "--device", "2", "--json"], text=True)
    data = json.loads(out)
    assert data["steps_total"] == 4          # diffs 1,1,1,1
    assert data["wear_quality_minutes"].get("fair", 0) == 0   # 5 s < 1 min


def test_cli_sleep_json(tmp_path):
    db = tmp_path / "t.db"
    frames = [(1000 + i, make_v18(unix=1000 + i, sleep_state=(2 if i < 3 else 0))) for i in range(5)]
    _make_db(str(db), frames)
    here = os.path.dirname(wa.__file__)
    out = subprocess.check_output(
        [sys.executable, os.path.join(here, "whoop_activity.py"), "sleep",
         "--db", str(db), "--device", "2", "--json"], text=True)
    data = json.loads(out)
    assert [s[0] for s in data["segments"]] == ["asleep", "wake"]


def test_integration_real_db_if_present():
    db = os.path.join(os.path.dirname(wa.__file__), "..", "..", "captures", "whoop4.db")
    if not os.path.exists(db):
        import pytest
        pytest.skip("real capture DB not present")
    import datetime as dt
    def u(s): return int(dt.datetime.fromisoformat(s).replace(tzinfo=dt.timezone.utc).timestamp())
    recs = wa.records(db, device_id=2, start=u("2026-06-09T00:00:00"), end=u("2026-06-10T00:00:00"))
    assert recs, "expected v18 records for 2026-06-09"
    total = wa.steps_total(recs)
    assert 1000 < total < 60000, f"daily steps out of sane range: {total}"
    assert wa.sleep_state_minutes(recs).get("asleep", 0) > 0
