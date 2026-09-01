#!/usr/bin/env bash
# One command after a network switch: bring both access paths back.
# ceph-fuse hangs after every network change (dead TCP sessions are never
# given up); macOS SMB mounts need a fresh mount as well. This forces both.
#
#   usage: scripts/remount.sh [ceph-user]     (default: CEPH_USER from site.conf)
#
# SMB only works non-interactively when the password is in the keychain
# (mount via Finder once with "remember in keychain").
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# site-specific values (cluster, mount points, benchmark targets)
[ -r "$ROOT/site.conf" ] && . "$ROOT/site.conf"

USER_ID="${1:-${CEPH_USER:?no ceph user given and none in site.conf}}"
SMB_MNT="${SMB_MOUNT:-$HOME/mnt/smb/storage}"

echo "== ceph-fuse =="
"$ROOT/scripts/umount.sh" "$USER_ID" >/dev/null 2>&1
"$ROOT/scripts/mount.sh" "$USER_ID"
timeout 20 ls "${CEPH_MOUNT:-$HOME/mnt/ceph/storage}" >/dev/null 2>&1 \
  && echo "   ok" || echo "   FEHLER: mount steht, antwortet aber nicht"

if [ -z "${SMB_SERVER:-}" ]; then
  echo "== smb == uebersprungen (kein SMB_SERVER in site.conf)"
  exit 0
fi

echo "== smb =="
# an existing but dead smb mount blocks a fresh one -- clear it first
for m in $(mount | awk '/smbfs/ {print $3}'); do
  timeout 10 ls "$m" >/dev/null 2>&1 || { umount -f "$m" 2>/dev/null; echo "   toten Mount $m entfernt"; }
done
if mount | grep -q smbfs; then
  echo "   ok (bestehender Mount antwortet)"
else
  mkdir -p "$SMB_MNT"
  if timeout 30 mount_smbfs "//$USER_ID@$SMB_SERVER/${SMB_SHARE:-storage}" "$SMB_MNT" </dev/null 2>/dev/null; then
    echo "   ok ($SMB_MNT)"
  else
    echo "   nicht verbunden -- Passwort nicht im Schluesselbund?"
    echo "   einmalig: Finder > Cmd-K > smb://$SMB_SERVER (Passwort sichern)"
  fi
fi
