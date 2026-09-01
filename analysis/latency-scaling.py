#!/usr/bin/env python3
"""Do the measurements scale with network latency the way the round-trip
explanation predicts?

The claim from the protocol: a directory listing costs one serial MDS round
trip per entry (157 client.mdops for 112 entries). If that holds, listing time
should be roughly  fixed_cost + n_roundtrips * RTT  across networks -- and the
fitted slope should land near the number of entries.

    analysis/latency-scaling.py
"""
import os
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUNS = pathlib.Path(os.environ.get("RUNS_DIR", ROOT / "logs" / "runs"))


def rtt_ms(run):
    for line in (run / "env.txt").read_text().splitlines():
        if "min/avg/max" in line:
            return float(line.split("=")[-1].split("/")[1])
    return None


def metric(run, client, prefix):
    for f in run.glob(f"workload-{client}.tsv"):
        for line in f.read_text().splitlines():
            parts = line.split("\t")
            if len(parts) >= 3 and parts[1].startswith(prefix):
                return float(parts[2])
    return None


def fit(points):
    """least squares y = a + b*x, returns (a, b)"""
    n = len(points)
    sx = sum(x for x, _ in points); sy = sum(y for _, y in points)
    sxx = sum(x * x for x, _ in points); sxy = sum(x * y for x, y in points)
    b = (n * sxy - sx * sy) / (n * sxx - sx * sx)
    return (sy - b * sx) / n, b


runs = sorted((d for d in RUNS.iterdir() if d.is_dir() and (d / "env.txt").exists()),
              key=lambda d: rtt_ms(d) or 0)

print(f"{'Lauf':10s} {'RTT ms':>8s} {'listing s':>10s} {'upload s':>10s} {'download s':>11s}")
pts = []
for r in runs:
    t = metric(r, "ceph-fuse", "browse_listing_cold")
    up = metric(r, "ceph-fuse", "upload_")
    dn = metric(r, "ceph-fuse", "download_")
    rtt = rtt_ms(r)
    print(f"{r.name:10s} {rtt:8.1f} {t:10.2f} {up:10.1f} {dn:11.1f}")
    pts.append((rtt, t))

a, b = fit(pts)
print(f"\nAusgleichsgerade Listing: {a:.2f} s + {b*1000:.0f} ms x RTT[ms]")
print(f"  -> impliziert ~{b*1000:.0f} serielle Roundtrips")
print(f"  gemessen: 112 Verzeichniseintraege, 157 MDS-Ops je listdir")

print("\nVerhaeltnis ceph-fuse zu samba (kleiner = FUSE-Vorsprung schrumpft):")
for r in runs:
    row = []
    for label, prefix in (("upload", "upload_"), ("download", "download_")):
        f_, s_ = metric(r, "ceph-fuse", prefix), metric(r, "samba", prefix)
        if f_ and s_:
            row.append(f"{label} {s_/f_:.0f}x")
    print(f"  {r.name:10s} RTT {rtt_ms(r):5.1f} ms   " + "   ".join(row))
