#!/usr/bin/env bash
# Write a cephx keyring from the clipboard (or stdin) and validate it first.
# The secret is never echoed.
#   usage: scripts/set-keyring.sh <ceph-user>        # reads the clipboard
#          scripts/set-keyring.sh <ceph-user> -      # reads stdin
set -euo pipefail

USER_ID="${1:?usage: set-keyring.sh <ceph-user> [-]}"
SRC="${2:-clipboard}"

if [ "$SRC" = "-" ]; then
  KEY="$(cat)"
else
  KEY="$(pbpaste)"
fi
KEY="$(printf '%s' "$KEY" | tr -d '[:space:]')"

python3 - "$KEY" <<'PY'
import sys, re, base64
k = sys.argv[1]
problems = []
if len(k) != 40:
    problems.append(f"length is {len(k)}, a cephx secret has 40 characters")
if not k.startswith("AQ"):
    problems.append(f"starts with {k[:2]!r}, a cephx secret starts with 'AQ'")
if not re.fullmatch(r'[A-Za-z0-9+/=]+', k):
    problems.append("contains characters outside the base64 alphabet")
else:
    try:
        base64.b64decode(k, validate=True)
    except Exception as e:
        problems.append(f"not valid base64: {e}")
if problems:
    print("refusing to write the keyring:", file=sys.stderr)
    for p in problems:
        print("  -", p, file=sys.stderr)
    sys.exit(1)
PY

KEYRING="$HOME/.ceph/ceph.client.$USER_ID.keyring"
mkdir -p "$HOME/.ceph"
umask 077
printf '[client.%s]\n\tkey = %s\n' "$USER_ID" "$KEY" > "$KEYRING"
chmod 600 "$KEYRING"
echo "wrote $KEYRING (secret validated, not printed)"
