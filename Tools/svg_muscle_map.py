#!/usr/bin/env python3
"""Convert the muscle-map SVG artwork into the form StrandDesign ships.

Provenance
----------
Source: https://github.com/HichamELBSI/react-native-body-highlighter
        (assets/bodyFront.ts, assets/bodyBack.ts), MIT licensed,
        Copyright (c) 2022 ELABBASSI Hicham.

The licence text travels with the copy as
`Packages/StrandDesign/Sources/StrandDesign/Resources/MuscleMapPaths.LICENSE` and must stay there.

Why this runs OFFLINE rather than in the app
--------------------------------------------
Two thirds of the source paths use elliptical arcs, and arc-to-Bezier is maths that fails quietly and
slightly — a body that is subtly wrong in one thigh is exactly the kind of defect that survives review.
Doing the conversion once, here, against a renderer someone can look at is safer than doing it on every
launch. The app therefore only ever parses `M`, `C` and `Z`.

The other trap, and the reason the parser is written the way it is: SVG packs the elliptical arc's two
boolean flags WITHOUT separators, so "a1.5 1.5 0 013 3" means flags 0 and 1 then x=3. A plain number
scanner reads "013" as thirteen, and 115 of the 159 paths failed that way before the flags got their own
single-character reader.

Usage
-----
    curl -sL <repo>/main/assets/bodyFront.ts -o bodyFront.ts
    curl -sL <repo>/main/assets/bodyBack.ts  -o bodyBack.ts
    python3 svg_muscle_map.py --emit      # writes MuscleMapPaths.json beside the inputs

Output: absolute cubic Beziers normalised to a 0..1 unit box (front viewBox "0 0 724 1448", back
"724 0 724 1448"), split into an untintable silhouette and the shadeable regions.
"""

import json
import math
import re
import sys

NUM = re.compile(r'[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?')
WS = ' ,\t\n\r'


class Cursor:
    """Reads an SVG `d` string with COMMAND CONTEXT.

    Tokenizing the whole string into numbers up front does not work: the elliptical-arc command packs
    its two boolean flags without separators, so "a1.5 1.5 0 013 3" means flags 0 and 1 then x=3 — and a
    plain number scanner reads "013" as thirteen. Every arc in this asset is written that way, which is
    why 115 of 159 paths failed to parse before the flags got their own reader.
    """

    def __init__(self, d):
        self.d, self.i = d, 0

    def skip(self):
        while self.i < len(self.d) and self.d[self.i] in WS:
            self.i += 1

    def eof(self):
        self.skip()
        return self.i >= len(self.d)

    def peek_cmd(self):
        self.skip()
        if self.i < len(self.d) and self.d[self.i].isalpha():
            c = self.d[self.i]
            self.i += 1
            return c
        return None

    def num(self):
        self.skip()
        m = NUM.match(self.d, self.i)
        if not m:
            raise ValueError(f"expected number at {self.i}: {self.d[self.i:self.i+12]!r}")
        self.i = m.end()
        return float(m.group())

    def flag(self):
        """One character, 0 or 1 — never a full number."""
        self.skip()
        c = self.d[self.i]
        if c not in '01':
            raise ValueError(f"expected arc flag at {self.i}, got {c!r}")
        self.i += 1
        return int(c)


def arc_to_cubics(x0, y0, rx, ry, phi_deg, large, sweep, x, y):
    """SVG endpoint arc -> list of cubic segments. Standard F.6.5 implementation."""
    if x0 == x and y0 == y: return []
    if rx == 0 or ry == 0: return [((x0+ (x-x0)/3, y0+(y-y0)/3), (x0+2*(x-x0)/3, y0+2*(y-y0)/3), (x, y))]
    rx, ry = abs(rx), abs(ry)
    phi = math.radians(phi_deg)
    cosp, sinp = math.cos(phi), math.sin(phi)
    dx2, dy2 = (x0 - x) / 2.0, (y0 - y) / 2.0
    x1p =  cosp*dx2 + sinp*dy2
    y1p = -sinp*dx2 + cosp*dy2
    lam = x1p*x1p/(rx*rx) + y1p*y1p/(ry*ry)
    if lam > 1:
        s = math.sqrt(lam); rx *= s; ry *= s
    sign = -1 if large == sweep else 1
    num = rx*rx*ry*ry - rx*rx*y1p*y1p - ry*ry*x1p*x1p
    den = rx*rx*y1p*y1p + ry*ry*x1p*x1p
    co = sign * math.sqrt(max(0.0, num/den)) if den else 0.0
    cxp =  co * rx * y1p / ry
    cyp = -co * ry * x1p / rx
    cx = cosp*cxp - sinp*cyp + (x0 + x)/2
    cy = sinp*cxp + cosp*cyp + (y0 + y)/2
    def ang(ux, uy, vx, vy):
        d = (ux*vx + uy*vy) / (math.hypot(ux,uy)*math.hypot(vx,vy))
        a = math.acos(max(-1.0, min(1.0, d)))
        return -a if ux*vy - uy*vx < 0 else a
    th1 = ang(1, 0, (x1p-cxp)/rx, (y1p-cyp)/ry)
    dth = ang((x1p-cxp)/rx, (y1p-cyp)/ry, (-x1p-cxp)/rx, (-y1p-cyp)/ry)
    if not sweep and dth > 0: dth -= 2*math.pi
    if sweep and dth < 0: dth += 2*math.pi
    n = max(1, int(math.ceil(abs(dth) / (math.pi/2))))
    out, delta = [], dth / n
    t = 4/3 * math.tan(delta/4)
    for i in range(n):
        a1 = th1 + i*delta; a2 = a1 + delta
        c1, s1 = math.cos(a1), math.sin(a1)
        c2, s2 = math.cos(a2), math.sin(a2)
        p1 = (cx + rx*c1*cosp - ry*s1*sinp, cy + rx*c1*sinp + ry*s1*cosp)
        p2 = (cx + rx*c2*cosp - ry*s2*sinp, cy + rx*c2*sinp + ry*s2*cosp)
        d1 = (-rx*s1*cosp - ry*c1*sinp, -rx*s1*sinp + ry*c1*cosp)
        d2 = (-rx*s2*cosp - ry*c2*sinp, -rx*s2*sinp + ry*c2*cosp)
        out.append(((p1[0]+t*d1[0], p1[1]+t*d1[1]), (p2[0]-t*d2[0], p2[1]-t*d2[1]), p2))
    return out

def to_cubics(d):
    """-> list of subpaths; each is (start, [ (c1, c2, end), ... ]). Everything becomes a cubic."""
    cur = Cursor(d)
    pos = (0.0, 0.0)
    start = None
    subpaths, segs = [], []
    cmd = None
    while not cur.eof():
        c = cur.peek_cmd()
        if c is not None:
            cmd = c
        elif cmd is None:
            raise ValueError("path does not start with a command")
        if cmd in 'Zz':
            if segs:
                subpaths.append((start, segs)); segs = []
            if start: pos = start
            cmd = None
            continue
        if cmd in 'Mm':
            x, y = cur.num(), cur.num()
            if segs:
                subpaths.append((start, segs)); segs = []
            pos = (x, y) if cmd == 'M' else (pos[0] + x, pos[1] + y)
            start = pos
            # A repeated coordinate pair after a moveto is an implicit lineto.
            cmd = 'L' if cmd == 'M' else 'l'
        elif cmd in 'Ll':
            x, y = cur.num(), cur.num()
            p = (x, y) if cmd == 'L' else (pos[0] + x, pos[1] + y)
            segs.append(line(pos, p)); pos = p
        elif cmd in 'Hh':
            x = cur.num()
            p = (x, pos[1]) if cmd == 'H' else (pos[0] + x, pos[1])
            segs.append(line(pos, p)); pos = p
        elif cmd in 'Vv':
            y = cur.num()
            p = (pos[0], y) if cmd == 'V' else (pos[0], pos[1] + y)
            segs.append(line(pos, p)); pos = p
        elif cmd in 'Cc':
            v = [cur.num() for _ in range(6)]
            if cmd == 'c':
                v = [pos[0]+v[0], pos[1]+v[1], pos[0]+v[2], pos[1]+v[3], pos[0]+v[4], pos[1]+v[5]]
            segs.append(((v[0], v[1]), (v[2], v[3]), (v[4], v[5]))); pos = (v[4], v[5])
        elif cmd in 'Qq':
            v = [cur.num() for _ in range(4)]
            if cmd == 'q':
                v = [pos[0]+v[0], pos[1]+v[1], pos[0]+v[2], pos[1]+v[3]]
            qx, qy, ex, ey = v
            c1 = (pos[0] + 2/3*(qx-pos[0]), pos[1] + 2/3*(qy-pos[1]))
            c2 = (ex + 2/3*(qx-ex), ey + 2/3*(qy-ey))
            segs.append((c1, c2, (ex, ey))); pos = (ex, ey)
        elif cmd in 'Aa':
            rx, ry, rot = cur.num(), cur.num(), cur.num()
            la, sw = cur.flag(), cur.flag()
            x, y = cur.num(), cur.num()
            if cmd == 'a':
                x, y = pos[0] + x, pos[1] + y
            for seg in arc_to_cubics(pos[0], pos[1], rx, ry, rot, la, sw, x, y):
                segs.append(seg)
            pos = (x, y)
        else:
            raise ValueError(f"unsupported command {cmd!r}")
    if segs:
        subpaths.append((start, segs))
    return subpaths


def line(p0, p1):
    return ((p0[0] + (p1[0]-p0[0])/3, p0[1] + (p1[1]-p0[1])/3),
            (p0[0] + 2*(p1[0]-p0[0])/3, p0[1] + 2*(p1[1]-p0[1])/3), p1)


def parse_file(path):
    d = open(path).read()
    blocks = re.split(r'\{\s*slug:', d)[1:]
    out = {}
    for b in blocks:
        slug = re.match(r'\s*"([a-z-]+)"', b).group(1)
        out[slug] = re.findall(r'"(M[^"]+)"', b)
    return out

if __name__ == "__main__":
    for f, ox in (('bodyFront.ts', 0.0), ('bodyBack.ts', 724.0)):
        data = parse_file(f)
        total = sum(len(v) for v in data.values())
        bad = 0
        for slug, paths in data.items():
            for p in paths:
                try: to_cubics(p)
                except Exception as e: bad += 1; print("FAIL", slug, e)
        print(f, "paths", total, "failed", bad)


# --- Emitter -------------------------------------------------------------------------------------

REGION = {
    "chest": "chest", "abs": "abdominals", "biceps": "biceps", "triceps": "triceps",
    "neck": "neck", "trapezius": "traps", "deltoids": "shoulders", "adductors": "adductors",
    "quadriceps": "quadriceps", "calves": "calves", "forearm": "forearms",
    "upper-back": "upperBack", "lower-back": "lowerBack", "gluteal": "glutes",
    "hamstring": "hamstrings",
}
SILHOUETTE = {"head", "hair", "hands", "feet", "ankles", "knees", "obliques", "tibialis"}

def fmt(v):
    return f"{v:.4f}".rstrip("0").rstrip(".")

def emit(paths, ox):
    """Absolute cubics in unit space, as 'M x y C ... Z' with a single leading M per subpath."""
    out = []
    for d in paths:
        for start, segs in to_cubics(d):
            if not segs:
                continue
            s = [f"M{fmt((start[0]-ox)/724)} {fmt(start[1]/1448)}"]
            for c1, c2, e in segs:
                s.append("C" + " ".join(fmt(v) for v in (
                    (c1[0]-ox)/724, c1[1]/1448, (c2[0]-ox)/724, c2[1]/1448,
                    (e[0]-ox)/724, e[1]/1448)))
            out.append("".join(s) + "Z")
    return out

def build():
    doc = {
        "_source": "https://github.com/HichamELBSI/react-native-body-highlighter (assets/bodyFront.ts, assets/bodyBack.ts)",
        "_license": "MIT",
        "_copyright": "Copyright (c) 2022 ELABBASSI Hicham",
        "_note": "SVG paths converted to absolute cubic Beziers and normalised to a 0..1 unit box "
                 "(front viewBox 0 0 724 1448, back viewBox 724 0 724 1448). See MuscleMapPaths.LICENSE.",
    }
    for face, (f, ox) in (("front", ("bodyFront.ts", 0.0)), ("back", ("bodyBack.ts", 724.0))):
        data = parse_file(f)
        regions, sil = {}, []
        for slug, paths in data.items():
            e = emit(paths, ox)
            if slug in SILHOUETTE:
                sil += e
            elif slug in REGION:
                regions.setdefault(REGION[slug], []).extend(e)
            else:
                raise SystemExit("unmapped slug: " + slug)
        doc[face] = {"silhouette": sil, "regions": regions}
    return doc

if __name__ == "__main__" and "--emit" in sys.argv:
    doc = build()
    open("MuscleMapPaths.json", "w").write(json.dumps(doc, separators=(",", ":")))
    for face in ("front", "back"):
        print(face, "silhouette", len(doc[face]["silhouette"]),
              "regions", {k: len(v) for k, v in doc[face]["regions"].items()})
