#!/usr/bin/env bash
# Mount a CephFS via the locally built ceph-fuse.
#   usage: scripts/mount.sh <ceph-user> [remote-path] [mountpoint]
#
# ceph-fuse's own daemonize path dies silently on macOS: the mount shows up in
# the mount table but the process is gone, and every access returns ENXIO.
# Running it in the foreground (-f) works, so we background it ourselves and
# keep the pid.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# site-specific values (cluster, mount points, benchmark targets)
[ -r "$ROOT/site.conf" ] && . "$ROOT/site.conf"

USER_ID="${1:-${CEPH_USER:?no ceph user given and none in site.conf}}"
REMOTE="${2:-${CEPH_REMOTE_PATH:-/}}"
MNT="${3:-${CEPH_MOUNT:-$HOME/mnt/ceph/storage}}"
KEYRING="$HOME/.ceph/ceph.client.$USER_ID.keyring"
LOG="$ROOT/run/ceph-fuse-$USER_ID.out"
PIDFILE="$ROOT/run/ceph-fuse-$USER_ID.pid"

# development tree or distribution bundle
for cand in "$ROOT/src/ceph/build/bin/ceph-fuse" "$ROOT/bin/ceph-fuse"; do
  [ -x "$cand" ] && CEPH_FUSE="$cand" && break
done
[ -n "${CEPH_FUSE:-}" ] || { echo "ceph-fuse binary not found under $ROOT" >&2; exit 1; }

[ -r "$KEYRING" ] || { echo "missing keyring: $KEYRING" >&2; exit 1; }
mkdir -p "$MNT" "$ROOT/run"

# admin socket and log go to run_dir; create it if the config names one
RUN_DIR="$(awk -F= '/^[[:space:]]*run_dir[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2}' "$ROOT/etc/ceph.conf" 2>/dev/null | tail -1)"
[ -n "$RUN_DIR" ] && mkdir -p "$RUN_DIR"

if mount | grep -q " $MNT "; then
  echo "already mounted at $MNT"; exit 0
fi

# -o local        : Finder treats it as a local volume (avoids Spotlight stalls)
# -o noappledouble: no ._ resource-fork files on the share
nohup "$CEPH_FUSE" \
  --id "$USER_ID" \
  -c "$ROOT/etc/ceph.conf" \
  -k "$KEYRING" \
  -r "$REMOTE" "$MNT" \
  -o local,volname=cephfs-storage,noappledouble \
  -f > "$LOG" 2>&1 &
echo $! > "$PIDFILE"

for _ in $(seq 30); do
  if mount | grep -q " $MNT "; then
    echo "mounted $REMOTE at $MNT (pid $(cat "$PIDFILE"), log $LOG)"
    exit 0
  fi
  kill -0 "$(cat "$PIDFILE")" 2>/dev/null || { echo "ceph-fuse exited:" >&2; tail -20 "$LOG" >&2; exit 1; }
  sleep 1
done
echo "timed out waiting for the mount; see $LOG" >&2
exit 1
