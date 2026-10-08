import sys, json, csv, statistics as st
meta=json.load(open(sys.argv[1])); recs=sorted(meta)
halves={"A (even)":set(recs[0::2]),"B (odd)":set(recs[1::2])}
for path in sys.argv[2:]:
    s={r["file"]:r for r in csv.DictReader(open(path))}
    for hn,hs in halves.items():
        out=[]
        for iv,tol in (("pr",25),("qrs",20),("qt",30)):
            e=[];tot=0
            for rec in hs:
                ref=meta[rec]["ref"][iv][0]
                if ref is None: continue
                for lead in (0,1):
                    r=s.get(f"{rec}_{lead}.txt")
                    if r is None: continue
                    tot+=1
                    if r[iv]: e.append(float(r[iv])-ref)
            out.append(f"{iv}: n{len(e)} bias{st.mean(e):+.0f} med|e|{st.median(abs(x) for x in e):.0f} ok{100*sum(abs(x)<=tol for x in e)/len(e):.0f}%")
        print(f"{path:16} {hn:9} "+" | ".join(out))
