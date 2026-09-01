#!/usr/bin/env bash
# Run the whole measurement set against both access paths and freeze the
# environment alongside the numbers, so runs taken on different networks stay
# comparable and interpretable later.
#
#   usage: scripts/bench-run.sh <run-label> [testset-dir]
#          e.g. scripts/bench-run.sh lan   /path/to/testset-100
#               scripts/bench-run.sh wifi  /path/to/testset-100
#
# Writes logs/runs/<run-label>/: env.txt plus one TSV per measurement.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# site-specific values (cluster, mount points, benchmark targets)
[ -r "$ROOT/site.conf" ] && . "$ROOT/site.conf"

RUN="${1:?usage: bench-run.sh <run-label> [testset-dir]}"
SET="${2:-/private/tmp/claude-501/-Users-max-projects-ceph-macos/testset-100}"
OUT="${RUNS_DIR:-$ROOT/logs/runs}/$RUN"
FUSE_MNT="${CEPH_MOUNT:-$HOME/mnt/ceph/storage}"

mkdir -p "$OUT"
SMB_MNT="$(mount | awk '/smbfs/ {print $3; exit}')"

# ---- freeze the environment -------------------------------------------------
{
  echo "run_label: $RUN"
  echo "timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC)"
  echo "testset: $SET ($(ls "$SET" | wc -l | tr -d ' ') files, $(du -sk "$SET" | awk '{print $1}') KiB)"
  echo
  echo "## network"
  echo "default routes:"; netstat -rn -f inet | awk '$1=="default"{print "  ", $2, $4}'
  echo "route to cluster:"; route -n get "${CEPH_MON_HOST:-$(awk -F'[][= ]+' '/mon host/{print $3}' "$ROOT/etc/ceph.conf" 2>/dev/null)}" 2>/dev/null | awk '/interface|gateway/{print "  ", $0}'
  echo "active service IPs:"
  networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | while read -r s; do
    ip=$(networksetup -getinfo "$s" 2>/dev/null | awk '/^IP address:/{print $3; exit}')
    [ -n "$ip" ] && echo "   $s -> $ip"
  done || true   # the loop ends on read EOF, which is not an error
  echo "wifi:"; networksetup -getairportnetwork en0 2>/dev/null | sed 's/^/   /'
  echo "rtt to cluster:"; ping -c 5 -q "${CEPH_MON_HOST:-$(awk -F'[][= ]+' '/mon host/{print $3}' "$ROOT/etc/ceph.conf" 2>/dev/null)}" 2>/dev/null | tail -1 | sed 's/^/   /'
  echo
  echo "## mounts"
  mount | grep -E 'macfuse|smbfs' | sed 's/^/   /'
  echo
  echo "## client"
  echo "   ceph-fuse: $("$ROOT/src/ceph/build/bin/ceph-fuse" --version 2>&1 | head -1)"
  echo "   source commit: $(git -C "$ROOT/src/ceph" rev-parse --short HEAD 2>/dev/null)"
  echo "   local patches: $(ls "$ROOT/patches"/*.patch 2>/dev/null | wc -l | tr -d ' ')"
  echo "   ceph.conf (client section):"
  sed -n '/^\[client\]/,$p' "$ROOT/etc/ceph.conf" | grep -vE '^\s*#|^\s*$' | sed 's/^/     /'
} > "$OUT/env.txt"

echo "environment frozen in $OUT/env.txt"

# ---- measurements -----------------------------------------------------------
echo "[1/5] workload: ceph-fuse"
"$ROOT/scripts/bench-workload.sh" "$FUSE_MNT" "ceph-fuse" "$SET" > "$OUT/workload-ceph-fuse.tsv" || true
if [ -n "$SMB_MNT" ]; then
  echo "[2/5] workload: samba  (slow: SMB pays several round trips per file)"
  "$ROOT/scripts/bench-workload.sh" "$SMB_MNT" "samba" "$SET" > "$OUT/workload-samba.tsv" || true
else
  echo "[2/5] workload: samba  SKIPPED (no smbfs mount)"
fi

echo "[3/5] sequential throughput, alternating between the mounts"
if [ -n "$SMB_MNT" ]; then
  "$ROOT/scripts/bench-throughput.sh" "$FUSE_MNT" ceph-fuse "$SMB_MNT" samba 2 > "$OUT/throughput.tsv" || true
else
  echo "  SKIPPED (no smbfs mount)"
fi

echo "[4/5] concurrency scaling (ceph-fuse: 1 and 4 streams)"
{ "$ROOT/scripts/bench-parallel.sh" "$FUSE_MNT" ceph-fuse 1 1024
  "$ROOT/scripts/bench-parallel.sh" "$FUSE_MNT" ceph-fuse 4 1536 | tail -1
} > "$OUT/parallel.tsv" 2>/dev/null || true
if [ -n "$SMB_MNT" ]; then
  "$ROOT/scripts/bench-parallel.sh" "$SMB_MNT" samba 4 2048 2>/dev/null | tail -1 >> "$OUT/parallel.tsv" || true
fi

echo "[5/5] objecter view from inside the client"
"$ROOT/scripts/bench-objecter.sh" "$FUSE_MNT" ceph-fuse 2560 > "$OUT/objecter.tsv" 2>/dev/null || true

echo
echo "done -> $OUT"
ls -1 "$OUT"
