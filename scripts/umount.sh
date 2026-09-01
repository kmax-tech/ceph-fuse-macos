#!/usr/bin/env bash
# Unmount the CephFS mount and stop the ceph-fuse process started by mount.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# site-specific values (cluster, mount points, benchmark targets)
[ -r "$ROOT/site.conf" ] && . "$ROOT/site.conf"

USER_ID="${1:-${CEPH_USER:?no ceph user given and none in site.conf}}"
MNT="${2:-${CEPH_MOUNT:-$HOME/mnt/ceph/storage}}"
PIDFILE="$ROOT/run/ceph-fuse-$USER_ID.pid"

umount "$MNT" 2>/dev/null || diskutil unmount force "$MNT" >/dev/null 2>&1 || true
if [ -f "$PIDFILE" ]; then
  kill "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$PIDFILE"
fi
mount | grep -q " $MNT " && { echo "still mounted: $MNT" >&2; exit 1; }
echo "unmounted $MNT"
