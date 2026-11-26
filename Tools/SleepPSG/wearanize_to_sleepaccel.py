"""Convert Wearanize+ OA (Radboud University, CC BY 4.0, doi:10.34973/xrmf-5726) into the sleep-accel layout.

    <venv>/bin/python -I Tools/SleepPSG/wearanize_to_sleepaccel.py <out_root> [subject ids ...]
    <venv>/bin/python -I Tools/SleepPSG/wearanize_to_sleepaccel.py <out_root> --local <parquet> <e4 zip> <id>

Needs `pyarrow` and `neurokit2` (README). Keeps only what a wrist strap could see, from the Empatica E4: per-second
gravity (ACC / 64 g), its 1 Hz heart rate and its PPG inter-beat intervals. From the PSG it keeps the first human
hypnogram and uses the ECG for one purpose only, to put the E4 on the PSG clock: the E4 drifts against the PSG
recorder by a few seconds an hour, so a linear E4 -> PSG time map is fitted per subject from the cross-correlation
of E4 inter-beat intervals with ECG R-R intervals, hour by hour. No sleep label takes part in the alignment. The
method follows ayiskakov's `Tools/SleepTrain/prepare_wearanize.py`.

out_root/labels/<id>_labeled_sleep.txt   "t code"     0 wake, 1 N1, 2 N2, 3 N3, 5 REM, -1 unscored
out_root/motion/<id>_acceleration.txt    "t x y z"    per-second mean acceleration in g
out_root/heart_rate/<id>_heartrate.txt   "t bpm"      the E4's 1 Hz heart rate, whole bpm
out_root/rr/<id>_rr.txt                  "t rr_ms"    E4 inter-beat intervals, stamped with the beat's whole second
All times are seconds from the first PSG epoch. Raw downloads are deleted after each subject.
"""
import io
import os
import subprocess
import sys
import tempfile
import zipfile
from multiprocessing import Pool

import numpy as np

BASE = "https://webdav.data.ru.nl/dcmn/DSC_wrnzpoa_t0000925a_195_v1"
CODE = {0: 0, 1: 1, 2: 2, 3: 3, 4: 5}
CURL = ["curl", "-sf", "--retry", "6", "--retry-delay", "15", "--retry-all-errors"]


def extract(pqf, zf):
    import pyarrow.parquet as pq
    import neurokit2 as nk
    cols = ["Device", "SamplingRate", "SleepScores"] + [f"SignalData.{c}" for c in ("ACCX", "ACCY", "ACCZ", "HR",
                                                                                   "ECG 2")]
    tb = pq.read_table(pqf, columns=cols)
    devs = tb.column("Device").to_pylist()
    e4 = devs.index("Empatica E4")
    psg = next(i for i in range(len(devs)) if (tb.column("SleepScores")[i].as_py() or {}).get("ManualScores1"))
    fs_e4, fs_psg = tb.column("SamplingRate")[e4].as_py(), tb.column("SamplingRate")[psg].as_py()

    def get(c, i):
        return np.array(tb.column(c)[i].as_py(), float)
    # pyarrow names a nested column it was asked for as "SignalData.X" by its leaf, "X".
    ax, ay, az, hr, ecg = get("ACCX", e4), get("ACCY", e4), get("ACCZ", e4), get("HR", e4), get("ECG 2", psg)
    scores = tb.column("SleepScores")[psg].as_py()["ManualScores1"]
    fsa, fse = fs_e4["ACCX"], fs_psg["ECG 2"]
    dur = len(ecg) / fse
    ns = int(len(ax) // fsa)
    grav = np.stack([a[: int(ns * fsa)].reshape(ns, int(fsa)).mean(1) / 64.0 for a in (ax, ay, az)], 1)
    _, info = nk.ecg_peaks(nk.ecg_clean(ecg, sampling_rate=fse), sampling_rate=fse, correct_artifacts=False)
    peaks = np.asarray(info["ECG_R_Peaks"]) / fse

    # The parquet E4 streams start at an unknown offset into the raw recording: find it by matching the raw heart
    # rate exactly, then carry the raw inter-beat timestamps across.
    z = zipfile.ZipFile(zf)
    raw_hr = np.loadtxt(io.StringIO(z.read("HR.csv").decode()))
    raw_hr0, raw_hr_vals = raw_hr[0], raw_hr[2:]
    ibi_text = z.read("IBI.csv").decode()
    ibi = np.loadtxt(io.StringIO(ibi_text), delimiter=",", skiprows=1, ndmin=2)
    ibi0 = float(ibi_text.split(",")[0])
    n = 600
    off = next((k for k in range(0, len(raw_hr_vals) - n)
                if abs(raw_hr_vals[k] - hr[0]) < 0.01 and np.allclose(raw_hr_vals[k:k + n], hr[:n], atol=0.01)), None)
    if off is None:
        raise RuntimeError("raw HR does not match the parquet HR")
    ibi_t = ibi[:, 0] + ibi0 - (raw_hr0 + off)

    lags, centres = [], []
    for h0 in range(0, int(dur), 3600):
        m = (ibi_t >= h0 + 60) & (ibi_t < h0 + 3600)
        if m.sum() < 300:
            continue
        shifts = np.arange(-240, 240, 0.25)
        corr = [np.corrcoef(np.interp(ibi_t[m] + s, peaks[1:], np.diff(peaks)), ibi[m, 1])[0, 1] for s in shifts]
        j = int(np.nanargmax(corr))
        if corr[j] > 0.5:
            lags.append(shifts[j]); centres.append(np.median(ibi_t[m]))
    if len(lags) >= 2:
        b, a = np.polyfit(centres, lags, 1)
    elif len(lags) == 1:
        b, a = 0.0, lags[0]
    else:
        raise RuntimeError("no reliable E4/ECG alignment")

    def warp(t):
        return t + a + b * t
    return dict(grav_t=warp(np.arange(ns) + 0.5), grav=grav, hr_t=warp(np.arange(len(hr)) + 0.5), hr=hr,
                ibi_t=warp(ibi_t), ibi=ibi[:, 1], scores=np.array(scores, int), lags=len(lags))


def write(out, sid, d):
    with open(os.path.join(out, "labels", f"{sid}_labeled_sleep.txt"), "w") as fh:
        for i, c in enumerate(d["scores"]):
            fh.write("%d %d\n" % (30 * i, CODE.get(int(c), -1)))
    with open(os.path.join(out, "motion", f"{sid}_acceleration.txt"), "w") as fh:
        for t, (x, y, z) in zip(np.floor(d["grav_t"]), d["grav"]):
            fh.write("%d %.6f %.6f %.6f\n" % (t, x, y, z))
    with open(os.path.join(out, "heart_rate", f"{sid}_heartrate.txt"), "w") as fh:
        for t, v in zip(np.floor(d["hr_t"]), np.round(d["hr"])):
            if v > 0:
                fh.write("%d %d\n" % (t, v))
    order = np.argsort(d["ibi_t"], kind="stable")
    with open(os.path.join(out, "rr", f"{sid}_rr.txt"), "w") as fh:
        for t, v in zip(np.floor(d["ibi_t"][order]), np.round(d["ibi"][order] * 1000.0)):
            fh.write("%d %d\n" % (t, v))


def one(args):
    out, sid = args
    if os.path.exists(os.path.join(out, "labels", f"{sid}_labeled_sleep.txt")):
        return sid, "already done"
    with tempfile.TemporaryDirectory(dir=os.path.join(out, "_tmp")) as tmp:
        pqf, zf = f"{tmp}/Sub{sid}s1.parquet", f"{tmp}/Sub{sid}s1_e4.zip"
        try:
            subprocess.run(CURL + ["-o", zf, f"{BASE}/Wearanize%2B_OA_raw_v1.1/1.Raw_data/Sub{sid}s1/3.Empatica/"
                                             f"Sub{sid}s1_Empatica_data.zip"], check=True)
            subprocess.run(CURL + ["-o", pqf, f"{BASE}/Wearanize%2B_OA_PlugNPlay_Parquet_v1.1/Sub{sid}s1.parquet"],
                           check=True)
            d = extract(pqf, zf)
            write(out, sid, d)
            return sid, "ok (%d hourly lags)" % d["lags"]
        except subprocess.CalledProcessError:
            return sid, "skipped: no E4 recording or no parquet on the server"
        except Exception as e:  # a subject without E4, ECG or scores is skipped, not fatal
            return sid, "skipped: %s" % e


def main(argv):
    out = argv[0]
    for d in ("labels", "motion", "heart_rate", "rr", "_tmp"):
        os.makedirs(os.path.join(out, d), exist_ok=True)
    if len(argv) > 1 and argv[1] == "--local":
        d = extract(argv[2], argv[3])
        write(out, argv[4], d)
        print(argv[4], "ok (%d hourly lags)" % d["lags"])
        return
    ids = argv[1:] or [f"{i:03d}" for i in range(1, 131)]
    with Pool(2) as p:
        for sid, msg in p.imap(one, [(out, s) for s in ids]):
            print(sid, msg, flush=True)


if __name__ == "__main__":
    main(sys.argv[1:])
