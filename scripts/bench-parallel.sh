#!/usr/bin/env bash
# Does throughput scale with concurrency? Reads N slices of one large file in
# parallel, each from a different offset, so nothing is served from cache.
#   usage: scripts/bench-parallel.sh <mountpoint> <label> [streams] [base_MiB]
set -euo pipefail
MNT="${1:?}"; LABEL="${2:?}"; STREAMS="${3:-4}"; BASE="${4:-0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# site-specific values (cluster, mount points, benchmark targets)
[ -r "$ROOT/site.conf" ] && . "$ROOT/site.conf"

REL="${BENCH_BIGFILE:?BENCH_BIGFILE not set -- see site.conf.example}"
CHUNK=128   # MiB per stream
[ -r "$MNT/$REL" ] || { echo "not readable: $MNT/$REL" >&2; exit 1; }

a=$(python3 -c 'import time; print(time.monotonic())')
for i in $(seq 0 $((STREAMS-1))); do
  dd if="$MNT/$REL" bs=1m skip=$((BASE + i*CHUNK)) count=$CHUNK >/dev/null 2>&1 &
done
wait
b=$(python3 -c 'import time; print(time.monotonic())')
total=$((STREAMS * CHUNK))
printf 'label\tmetric\tstreams\tMiB\tseconds\tMB_per_s\n'
python3 -c "
s = $b - $a
print(f'$LABEL\tparallel_read\t$STREAMS\t$total\t{s:.2f}\t{$total*1.048576/s:.1f}')"
