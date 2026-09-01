#!/usr/bin/env python3
"""Turn the measurement TSVs into the comparison tables.

The point is that no number in the protocol is typed by hand: run this and
paste (or --check) what it prints.

    analysis/summarize.py                 # tables for every run found
    analysis/summarize.py --run lan       # one run
    analysis/summarize.py --check         # completeness: what is missing?
"""
import argparse
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUNS = pathlib.Path(os.environ.get("RUNS_DIR", ROOT / "logs" / "runs"))

# metric -> (pretty name, lower_is_better)
WORKLOAD = [
    ("browse_listing_cold", "Verzeichnis listen, kalt", True),
    ("browse_listing_warm2", "Verzeichnis listen, warm", True),
    ("upload_", "kleine Dateien hochladen", True),
    ("download_", "kleine Dateien herunterladen", True),
    ("thumbnails_", "Thumbnail-Muster (erste 8 KiB je Datei)", True),
]


def read_tsv(path):
    if not path.exists():
        return []
    rows = []
    for line in path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        if line.split("\t")[0] in ("label", "round"):   # header row
            continue
        rows.append(line.split("\t"))
    return rows


def workload(run_dir):
    """{label: {metric: seconds}} plus the file count taken from the metric name."""
    out, nfiles = {}, None
    for f in sorted(run_dir.glob("workload-*.tsv")):
        for label, metric, secs in (r[:3] for r in read_tsv(f)):
            if metric == "files_returned":
                out.setdefault(label, {})["_returned"] = float(secs)
                continue
            if metric.startswith(("upload_", "download_", "thumbnails_")):
                parts = metric.split("_")
                if len(parts) > 1 and parts[1].isdigit():
                    nfiles = int(parts[1])
            out.setdefault(label, {})[metric] = float(secs)
    return out, nfiles


def fmt_rate(seconds, n):
    if seconds <= 0:
        return "-"
    r = n / seconds
    return f"{r:.1f}/s" if r < 10 else f"{r:.0f}/s"


def table_workload(run_dir):
    data, nfiles = workload(run_dir)
    if not data:
        return "keine Workload-Daten"
    labels = sorted(data)
    lines = ["| Workload | " + " | ".join(labels) + " |",
             "|---" * (len(labels) + 1) + "|"]
    for prefix, pretty, _ in WORKLOAD:
        cells = []
        for lab in labels:
            hit = next((m for m in data[lab] if m.startswith(prefix)), None)
            if hit is None:
                cells.append("-")
                continue
            secs = data[lab][hit]
            if prefix in ("upload_", "download_") and nfiles:
                cells.append(f"{secs:.1f} s ({fmt_rate(secs, nfiles)})")
            else:
                cells.append(f"{secs:.2f} s")
        lines.append(f"| {pretty} | " + " | ".join(cells) + " |")
    return "\n".join(lines)


def table_simple(run_dir, name, title, cols):
    rows = read_tsv(run_dir / name)
    if not rows:
        return None
    lines = [f"**{title}**", "", "| " + " | ".join(cols) + " |",
             "|---" * len(cols) + "|"]
    for r in rows:
        lines.append("| " + " | ".join(r[:len(cols)]) + " |")
    return "\n".join(lines)


def rtt_of(run_dir):
    env = run_dir / "env.txt"
    if not env.exists():
        return "?"
    for line in env.read_text().splitlines():
        if "min/avg/max" in line:
            return line.split("=")[-1].split("/")[1].strip() + " ms"
    return "?"


def compare(dirs):
    """One row per metric, one column per run -- for spotting replication."""
    rows = [("Verzeichnis listen, kalt", "browse_listing_cold", "s"),
            ("Verzeichnis listen, warm", "browse_listing_warm2", "s"),
            ("Dateien hochladen", "upload_", "rate"),
            ("Dateien herunterladen", "download_", "rate"),
            ("Thumbnail-Muster", "thumbnails_", "s")]
    data = {d.name: workload(d) for d in dirs}
    names = [d.name for d in dirs]

    out = ["| Messung | " + " | ".join(f"{n} ({rtt_of(d)})" for n, d in zip(names, dirs)) + " |",
           "|---" * (len(names) + 1) + "|"]
    for pretty, prefix, kind in rows:
        for client in ("ceph-fuse", "samba"):
            cells = []
            for n in names:
                metrics, nfiles = data[n]
                m = metrics.get(client, {})
                hit = next((k for k in m if k.startswith(prefix)), None)
                if hit is None:
                    cells.append("-")
                    continue
                secs = m[hit]
                cells.append(f"{secs:.1f} s ({fmt_rate(secs, nfiles)})" if kind == "rate" and nfiles
                             else f"{secs:.2f} s")
            out.append(f"| {pretty} — {client} | " + " | ".join(cells) + " |")
    return "\n".join(out)


def check(run_dir):
    """Report what is missing rather than silently showing a short table."""
    problems = []
    expected = ["env.txt", "workload-ceph-fuse.tsv", "workload-samba.tsv",
                "throughput.tsv", "parallel.tsv", "objecter.tsv"]
    for name in expected:
        if not (run_dir / name).exists():
            problems.append(f"fehlt: {name}")
    data, nfiles = workload(run_dir)
    for lab, metrics in data.items():
        got = metrics.get("_returned")
        if got is None:
            problems.append(f"{lab}: kein files_returned (Integritaetspruefung fehlt)")
        elif nfiles and got != nfiles:
            problems.append(f"{lab}: {got:.0f} von {nfiles} Dateien zurueck -- Kopie unvollstaendig")
    for f in run_dir.glob("*.tsv"):
        if "timeout" in f.read_text():
            problems.append(f"{f.name}: enthaelt eine Messung, die ins Zeitlimit lief")
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", help="only this run label")
    ap.add_argument("--check", action="store_true", help="report gaps instead of tables")
    ap.add_argument("--compare", action="store_true", help="one table across all runs")
    args = ap.parse_args()

    if not RUNS.exists():
        sys.exit(f"no runs under {RUNS} -- use scripts/bench-run.sh <label> first")
    dirs = sorted(d for d in RUNS.iterdir() if d.is_dir())
    if args.run:
        dirs = [d for d in dirs if d.name == args.run] or sys.exit(f"no run '{args.run}'")

    if args.compare:
        print(compare(dirs))
        return

    failed = False
    for d in dirs:
        print(f"\n## Lauf: {d.name}\n")
        if args.check:
            problems = check(d)
            if problems:
                failed = True
                for p in problems:
                    print(f"  - {p}")
            else:
                print("  vollstaendig")
            continue
        env = d / "env.txt"
        if env.exists():
            for line in env.read_text().splitlines():
                if line.startswith(("timestamp:", "testset:")) or "->" in line and "	" not in line:
                    print(f"    {line.strip()}")
        print()
        print(table_workload(d))
        for name, title, cols in [
            ("throughput.tsv", "Sequenzieller Durchsatz (256 MiB je Messung, kalt)",
             ["round", "skip_MiB", "label", "seconds", "MB_per_s"]),
            ("parallel.tsv", "Skalierung mit Parallelitaet",
             ["label", "metric", "streams", "MiB", "seconds", "MB_per_s"]),
            ("objecter.tsv", "Sicht des Clients auf seine Objekt-Anfragen",
             ["label", "metric", "value"]),
        ]:
            t = table_simple(d, name, title, cols)
            if t:
                print("\n" + t)
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
