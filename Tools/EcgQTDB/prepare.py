# Per QTDB record: a 30 s window around the cardiologist-annotated beats (q1c), both leads in µV at
# the native rate, and the reference intervals of the annotated beats that fall inside the window.
import sys, os, json, statistics as st
import wfdb
db, out = sys.argv[1], sys.argv[2]
recs = [l.strip() for l in open(os.path.join(db, "RECORDS")) if l.strip()]
meta = {}
for r in recs:
    try:
        ann = wfdb.rdann(os.path.join(db, r), "q1c")
    except Exception as e:
        continue
    rec = wfdb.rdrecord(os.path.join(db, r))
    fs = rec.fs
    sym, smp = ann.symbol, ann.sample
    beats = []
    for i, s in enumerate(sym):
        if s != "N": continue
        b = {"r": smp[i]}
        if i > 0 and sym[i-1] == "(": b["qon"] = smp[i-1]
        if i + 1 < len(sym) and sym[i+1] == ")": b["qoff"] = smp[i+1]
        # P: nearest 'p' before this N, with its '(' onset
        j = i - 1
        while j >= 0 and sym[j] not in ("N",):
            if sym[j] == "p" and j > 0 and sym[j-1] == "(": b["pon"] = smp[j-1]; break
            j -= 1
        k = i + 1
        while k < len(sym) and sym[k] != "N":
            if sym[k] == "t" and k + 1 < len(sym) and sym[k+1] == ")": b["tend"] = smp[k+1]; break
            k += 1
        beats.append(b)
    if len(beats) < 5: continue
    first = beats[0]["r"]
    start = max(0, int(first - 2 * fs))
    end = min(rec.sig_len, start + int(30 * fs))
    inside = [b for b in beats if start + 0.5 * fs < b["r"] < end - 0.6 * fs]
    def med(key_a, key_b):
        v = [(b[key_b] - b[key_a]) * 1000 / fs for b in inside if key_a in b and key_b in b]
        return (st.median(v), len(v)) if v else (None, 0)
    ref = {"pr": med("pon", "qon"), "qrs": med("qon", "qoff"), "qt": med("qon", "tend")}
    for lead in range(min(2, rec.n_sig)):
        sig = rec.p_signal[start:end, lead]
        unit = rec.units[lead].lower()
        scale = 1000.0 if unit == "mv" else 1.0
        with open(os.path.join(out, f"{r}_{lead}.txt"), "w") as f:
            f.write(f"{fs}\n" + ",".join(f"{x*scale:.2f}" for x in sig) + "\n")
    meta[r] = {"fs": fs, "start": start, "beats": len(inside), "ref": ref, "leads": rec.sig_name[:2]}
json.dump(meta, open(os.path.join(out, "meta.json"), "w"), indent=1)
print(len(meta), "records with q1c")
