#!/usr/bin/env bash
# Ask the ceph-fuse client itself what it is doing during a sequential read:
# how many object requests, how long each takes, how many run concurrently.
# Only meaningful for ceph-fuse (needs its admin socket).
#   usage: scripts/bench-objecter.sh <mountpoint> <label> [skip_MiB]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# site-specific values (cluster, mount points, benchmark targets)
[ -r "$ROOT/site.conf" ] && . "$ROOT/site.conf"

MNT="${1:?}"; LABEL="${2:?}"; SKIP="${3:-0}"
REL="${BENCH_BIGFILE:?BENCH_BIGFILE not set -- see site.conf.example}"
ASOK="$(ls -t "$ROOT"/run/ceph-client.*.asok 2>/dev/null | head -1)"
[ -S "$ASOK" ] || { echo "no admin socket found in $ROOT/run" >&2; exit 1; }

python3 - "$ASOK" "$MNT/$REL" "$LABEL" "$SKIP" <<'PY'
import socket, struct, json, subprocess, sys, time
asok, path, label, skip = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
def ask(cmd):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(30); s.connect(asok)
    s.sendall(json.dumps(cmd).encode() + b'\0')
    n = struct.unpack(">I", s.recv(4))[0]
    buf = b''
    while len(buf) < n:
        c = s.recv(min(65536, n - len(buf)))
        if not c: break
        buf += c
    return json.loads(buf)
def counters():
    o = ask({"prefix": "perf dump"})["objecter"]
    l = o.get("op_latency", {})
    return o.get("op_r", 0), l.get("avgcount", 0), l.get("sum", 0.0)

r0, c0, s0 = counters()
t0 = time.monotonic()
subprocess.run(["dd", f"if={path}", "bs=1m", f"skip={skip}", "count=256"],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
secs = time.monotonic() - t0
r1, c1, s1 = counters()

ops, n, tot = r1 - r0, c1 - c0, s1 - s0
print("label\tmetric\tvalue")
print(f"{label}\tread_256MiB_seconds\t{secs:.2f}")
print(f"{label}\tread_256MiB_MB_per_s\t{256*1.048576/secs:.1f}")
print(f"{label}\tobject_read_ops\t{ops}")
if n:
    avg = tot / n
    print(f"{label}\tKiB_per_op\t{256*1024/n:.0f}")
    print(f"{label}\tops_per_second\t{n/secs:.1f}")
    print(f"{label}\tmean_op_latency_ms\t{avg*1000:.0f}")
    print(f"{label}\tmean_concurrency\t{n/secs*avg:.1f}")
    print(f"{label}\tMB_per_s_per_op\t{(256*1.048576/secs)/(n/secs*avg):.1f}")
PY
