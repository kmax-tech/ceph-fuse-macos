#!/usr/bin/env bash
# Compare sequential read throughput of two mounts fairly.
#
# Reads a different 256 MiB slice of the same file each round, so every
# measurement is cold (the page cache never serves a repeat), and alternates
# between the mounts so network and cluster load hit both equally.
#
#   usage: scripts/bench-throughput.sh <mount-a> <label-a> <mount-b> <label-b> [rounds]
set -euo pipefail

A_MNT="${1:?}"; A_LAB="${2:?}"; B_MNT="${3:?}"; B_LAB="${4:?}"; ROUNDS="${5:-3}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# site-specific values (cluster, mount points, benchmark targets)
[ -r "$ROOT/site.conf" ] && . "$ROOT/site.conf"

REL="${BENCH_BIGFILE:?BENCH_BIGFILE not set -- see site.conf.example}"
CHUNK=256   # MiB per measurement

read_slice() {   # mount, skip in MiB -> MB/s
  local mnt="$1" skip="$2" start end secs
  start=$(python3 -c 'import time; print(time.monotonic())')
  dd if="$mnt/$REL" bs=1m skip="$skip" count=$CHUNK >/dev/null 2>&1 || true
  end=$(python3 -c 'import time; print(time.monotonic())')
  python3 -c "
secs = $end - $start
print(f'{secs:.2f}\t{$CHUNK * 1.048576 / secs:.1f}')"
}

printf 'round\tskip_MiB\tlabel\tseconds\tMB_per_s\n'
for r in $(seq "$ROUNDS"); do
  skip=$(( (r - 1) * CHUNK ))
  printf '%s\t%s\t%s\t%s\n' "$r" "$skip" "$A_LAB" "$(read_slice "$A_MNT" "$skip")"
  printf '%s\t%s\t%s\t%s\n' "$r" "$skip" "$B_LAB" "$(read_slice "$B_MNT" "$skip")"
done
