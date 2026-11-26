"""Convert the Newcastle PSG + GENEActiv study (Zenodo 1160410) into the sleep-accel layout SleepPSG reads.

    python3 -I Tools/SleepPSG/newcastle_to_sleepaccel.py <dataset_psgnewcastle2015_v1.0> <out_root> <left|right|nondominant>

out_root/labels/<id>_labeled_sleep.txt   "t code"   t = seconds since the first PSG epoch, codes as sleep-accel:
                                                    0 wake, 1 N1, 2 N2, 3 N3, 5 REM, -1 unscored
out_root/motion/<id>_acceleration.txt    "t x y z"  per-second mean acceleration in g, same clock
out_root/heart_rate/                     empty: this study recorded no heart rate on the wrist

Both clocks are the devices' local wall clocks (the PSG export prints clock times, the GENEActiv pages
carry their own); they are matched as naive local times, as the study's own processing does.
"""
import datetime as dt
import os
import re
import sys
from multiprocessing import Pool

import numpy as np

STAGE = {"W": 0, "N1": 1, "N2": 2, "N3": 3, "R": 5}
PAD = 3 * 3600


def naive_seconds(d):
    return int((d - dt.datetime(1970, 1, 1)).total_seconds())


def read_psg(path):
    with open(path, "r", encoding="latin-1") as fh:
        lines = [l.rstrip("\r\n") for l in fh]
    date = None
    rows = []
    started = False
    time_col = None
    for l in lines:
        if l.startswith("Recording Date:"):
            date = dt.datetime.strptime(l.split("\t")[-1].strip() or l.split(":", 1)[1].strip(), "%d/%m/%Y")
        if l.startswith("Sleep Stage"):
            started = True
            time_col = [c.strip() for c in l.split("\t")].index("Time [hh:mm:ss]")
            continue
        if started and l.strip():
            parts = l.split("\t")
            if len(parts) <= time_col:
                continue
            rows.append((parts[0].strip(), parts[time_col].strip()))
    out = []
    day = date
    prev = None
    for stage, clock in rows:
        h, m, s = (int(x) for x in clock.split(":"))
        t = day.replace(hour=h, minute=m, second=s)
        if prev is not None and t < prev:
            day = day + dt.timedelta(days=1)
            t = day.replace(hour=h, minute=m, second=s)
        prev = t
        out.append((naive_seconds(t), STAGE.get(stage, -1)))
    return out


def read_geneactiv(path, lo, hi):
    """Per-second mean (x, y, z) in g for naive-local seconds in [lo, hi)."""
    gain, offset = {}, {}
    handed = None
    secs, xs, ys, zs = [], [], [], []
    page_time = None
    freq = None
    expect_hex = False
    with open(path, "r", encoding="latin-1") as fh:
        for raw in fh:
            line = raw.strip()
            if expect_hex:
                expect_hex = False
                if page_time is None or not freq or page_time < lo - 10 or page_time > hi + 10:
                    continue
                b = np.frombuffer(bytes.fromhex(line[: (len(line) // 12) * 12]), dtype=np.uint8).reshape(-1, 6)
                b = b.astype(np.int64)
                w = (b[:, 0] << 40) | (b[:, 1] << 32) | (b[:, 2] << 24) | (b[:, 3] << 16) | (b[:, 4] << 8) | b[:, 5]
                def s12(v):
                    return np.where(v >= 2048, v - 4096, v)
                x = s12((w >> 36) & 0xFFF)
                y = s12((w >> 24) & 0xFFF)
                z = s12((w >> 12) & 0xFFF)
                n = len(w)
                secs.append(np.floor(page_time + np.arange(n) / freq).astype(np.int64))
                xs.append((x * 100 - offset["x"]) / gain["x"])
                ys.append((y * 100 - offset["y"]) / gain["y"])
                zs.append((z * 100 - offset["z"]) / gain["z"])
                continue
            if ":" not in line:
                continue
            key, _, val = line.partition(":")
            key = key.strip().lower()
            val = val.strip()
            if key in ("x gain", "y gain", "z gain"):
                gain[key[0]] = float(val)
            elif key in ("x offset", "y offset", "z offset"):
                offset[key[0]] = float(val)
            elif key == "handedness code":
                handed = val.lower()
            elif key == "page time":
                d, t = val.split(" ")
                hh, mm, ss, ms = t.split(":")
                stamp = dt.datetime.strptime(d + " " + hh + ":" + mm + ":" + ss, "%Y-%m-%d %H:%M:%S")
                page_time = naive_seconds(stamp) + int(ms) / 1000.0
            elif key == "measurement frequency" and page_time is not None:
                freq = float(val.split(" ")[0])
                expect_hex = True
    if not secs:
        return handed, None
    s = np.concatenate(secs); x = np.concatenate(xs); y = np.concatenate(ys); z = np.concatenate(zs)
    keep = (s >= lo) & (s < hi)
    s, x, y, z = s[keep], x[keep], y[keep], z[keep]
    uniq, inv, cnt = np.unique(s, return_inverse=True, return_counts=True)
    mx = np.bincount(inv, weights=x) / cnt
    my = np.bincount(inv, weights=y) / cnt
    mz = np.bincount(inv, weights=z) / cnt
    return handed, (uniq, mx, my, mz)


def convert(args):
    root, out_root, side, num = args
    pid = "mecsleep%02d" % num
    psg = read_psg(os.path.join(root, "psg", pid + "_psg.txt"))
    if not psg:
        return pid, "no psg"
    t0 = psg[0][0]
    lo, hi = t0 - PAD, psg[-1][0] + 30 + PAD
    files = {}
    for name in os.listdir(os.path.join(root, "acc")):
        m = re.match(r"MECSLEEP(\d+)_(left|right) wrist_", name)
        if m and int(m.group(1)) == num:
            files[m.group(2)] = os.path.join(root, "acc", name)
    chosen = side
    if side == "nondominant":
        handed, _ = read_geneactiv(files.get("left") or files.get("right"), 0, 0)
        chosen = "right" if (handed or "").startswith("left") else "left"
    if chosen not in files:
        return pid, "no %s wrist" % chosen
    _, acc = read_geneactiv(files[chosen], lo, hi)
    if acc is None:
        return pid, "no accelerometer pages in the PSG window"
    secs, mx, my, mz = acc
    covered = int(np.sum((secs >= t0) & (secs < psg[-1][0] + 30)))
    if covered == 0:
        return pid, "skipped: no accelerometer second overlaps the PSG night"
    with open(os.path.join(out_root, "labels", pid + "_labeled_sleep.txt"), "w") as fh:
        for t, c in psg:
            fh.write("%d %d\n" % (t - t0, c))
    with open(os.path.join(out_root, "motion", pid + "_acceleration.txt"), "w") as fh:
        for i in range(len(secs)):
            fh.write("%d %.6f %.6f %.6f\n" % (secs[i] - t0, mx[i], my[i], mz[i]))
    return pid, "%s wrist, %d PSG epochs, %d accelerometer seconds inside the PSG window" % (chosen, len(psg), covered)


if __name__ == "__main__":
    root, out_root, side = sys.argv[1], sys.argv[2], sys.argv[3]
    for d in ("labels", "motion", "heart_rate"):
        os.makedirs(os.path.join(out_root, d), exist_ok=True)
    nums = sorted(int(re.match(r"mecsleep(\d+)_psg\.txt", n).group(1))
                  for n in os.listdir(os.path.join(root, "psg")) if n.endswith("_psg.txt"))
    with Pool(8) as p:
        for pid, msg in p.map(convert, [(root, out_root, side, n) for n in nums]):
            print(pid, msg)
