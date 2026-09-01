#!/usr/bin/env bash
# Mirror CephFS group memberships into the local macOS user database.
#
# ceph-fuse sends the caller's uid/gid to the MDS, which checks them like a
# local filesystem would. Group-based access therefore only works when the
# cluster's numeric gids also exist locally for this user. Find the numbers on
# a Linux host that mounts the same CephFS with:  id -G
#
#   usage: sudo scripts/add-cluster-groups.sh <gid> [gid ...]
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }
[ $# -gt 0 ] || { echo "usage: sudo $0 <gid> [gid ...]" >&2; exit 1; }

TARGET_USER="${SUDO_USER:?run via sudo so I know which account to add}"

for GID in "$@"; do
  case "$GID" in (*[!0-9]*) echo "not a numeric gid: $GID" >&2; exit 1;; esac

  EXISTING="$(dscl . -search /Groups PrimaryGroupID "$GID" 2>/dev/null | head -1 | awk '{print $1}')"
  if [ -n "$EXISTING" ]; then
    GROUP="$EXISTING"
    echo "gid $GID already exists locally as '$GROUP'"
  else
    GROUP="cephfs$GID"
    dscl . -create "/Groups/$GROUP"
    dscl . -create "/Groups/$GROUP" PrimaryGroupID "$GID"
    dscl . -create "/Groups/$GROUP" RealName "CephFS group $GID"
    echo "created group '$GROUP' with gid $GID"
  fi

  if dseditgroup -o checkmember -m "$TARGET_USER" "$GROUP" >/dev/null 2>&1; then
    echo "  $TARGET_USER is already a member of '$GROUP'"
  else
    dseditgroup -o edit -a "$TARGET_USER" -t user "$GROUP"
    echo "  added $TARGET_USER to '$GROUP'"
  fi
done

echo
echo "Verify with:  id -G $TARGET_USER"
echo "Then remount: scripts/umount.sh <ceph-user> && scripts/mount.sh <ceph-user>"
