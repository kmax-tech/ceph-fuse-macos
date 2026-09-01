#!/usr/bin/env bash
# Realistic workloads instead of raw sequential throughput:
#   browse      - repeated directory listings (cold once, then warm)
#   thumbnails  - open many small files and read the first 8 KiB of each,
#                 the pattern a file browser or image viewer produces
#   upload      - copy a local set of many small files onto the share
#   download    - copy that set back off the share
#
#   usage: scripts/bench-workload.sh <mountpoint> <label> <local-testset>
set -euo pipefail

MNT="${1:?usage: bench-workload.sh <mountpoint> <label> <local-testset>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# site-specific values (cluster, mount points, benchmark targets)
[ -r "$ROOT/site.conf" ] && . "$ROOT/site.conf"

LABEL="${2:?missing label}"
SET="${3:?missing local testset directory}"

BROWSE_REL="${BENCH_TREE:?BENCH_TREE not set -- see site.conf.example}"
# data-tmp/2026 carries a distributed pin: each direct child is hashed onto an
# MDS rank. Giving every access path its own child would measure them against
# different, differently loaded MDSs. Put both under one shared parent instead
# -- the parent gets pinned once, its children inherit that rank.
REMOTE_PARENT="$MNT/${BENCH_SCRATCH:?BENCH_SCRATCH not set -- see site.conf.example}"
REMOTE="$REMOTE_PARENT/$LABEL-$$"
BACK="$(mktemp -d)"
cleanup() {
  rm -rf "$REMOTE" "$BACK" 2>/dev/null || true
  rmdir "$REMOTE_PARENT" 2>/dev/null || true   # only when the last run leaves
}
trap cleanup EXIT

t() {  # elapsed seconds of a command
  local a b
  a=$(python3 -c 'import time; print(time.monotonic())')
  "$@" >/dev/null 2>&1 || true
  b=$(python3 -c 'import time; print(time.monotonic())')
  python3 -c "print(f'{$b - $a:.2f}')"
}

files=$(ls "$SET" | wc -l | tr -d ' ')
bytes=$(du -sk "$SET" | awk '{print $1}')
printf 'label\tmetric\tseconds\n'

# 1. browsing: first listing is cold, the next two are warm
printf '%s\tbrowse_listing_cold\t%s\n'  "$LABEL" "$(t ls -l "$MNT/$BROWSE_REL")"
printf '%s\tbrowse_listing_warm1\t%s\n' "$LABEL" "$(t ls -l "$MNT/$BROWSE_REL")"
printf '%s\tbrowse_listing_warm2\t%s\n' "$LABEL" "$(t ls -l "$MNT/$BROWSE_REL")"

# 2. upload many small files
mkdir -p "$REMOTE_PARENT" "$REMOTE"
printf '%s\tupload_%s_files_%sKiB\t%s\n' "$LABEL" "$files" "$bytes" \
  "$(t cp -R "$SET/." "$REMOTE/")"

# 3. thumbnail pattern over those files: cold, then warm
head8k() { for f in "$REMOTE"/*; do dd if="$f" bs=8k count=1 2>/dev/null; done; }
printf '%s\tthumbnails_%s_files_cold\t%s\n' "$LABEL" "$files" "$(t head8k)"
printf '%s\tthumbnails_%s_files_warm\t%s\n' "$LABEL" "$files" "$(t head8k)"

# 4. download them again
printf '%s\tdownload_%s_files_%sKiB\t%s\n' "$LABEL" "$files" "$bytes" \
  "$(t cp -R "$REMOTE/." "$BACK/")"

# integrity: same number of files came back
got=$(ls "$BACK" | wc -l | tr -d ' ')
printf '%s\tfiles_returned\t%s\n' "$LABEL" "$got"
