#!/usr/bin/env bash
# Bundle ceph-fuse so it runs on another Apple Silicon Mac without Homebrew.
#
# The binary links against Homebrew's icu4c and openssl plus our own
# libceph-common. Copy those next to it and rewrite the install names to
# @executable_path, then ad-hoc sign (arm64 refuses unsigned binaries, and
# every install_name_tool edit invalidates an existing signature).
#
# macFUSE stays a prerequisite on the target machine -- it ships a kernel
# extension and cannot be bundled.
#
#   usage: scripts/package.sh [output-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/src/ceph/build/bin/ceph-fuse"
[ -x "$BIN" ] || { echo "not built yet: $BIN" >&2; exit 1; }

VERSION="$("$BIN" --version 2>&1 | awk '{print $3}')"
OUT="${1:-$ROOT/dist/ceph-fuse-$VERSION-macos-arm64}"

rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/lib" "$OUT/etc"
cp "$BIN" "$OUT/bin/ceph-fuse"

# --- collect dependencies (recursively, everything outside /usr/lib and
# /System, except macFUSE which the target must install itself) -------------
# $2 is where the object originally lived: @loader_path must be resolved
# against that, not against the copy we just made in the bundle.
collect() {
  local obj="$1" origdir="$2" dep
  otool -L "$obj" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/*|/usr/local/lib/libfuse*) continue ;;
      @rpath/*) dep="$ROOT/src/ceph/build/lib/${dep#@rpath/}" ;;
      @loader_path/*) dep="$origdir/${dep#@loader_path/}" ;;
      @executable_path/*) continue ;;
    esac
    [ -f "$dep" ] || { echo "  WARNUNG: nicht gefunden: $dep" >&2; continue; }
    local base; base="$(basename "$dep")"
    if [ ! -f "$OUT/lib/$base" ]; then
      cp "$dep" "$OUT/lib/$base"
      chmod u+w "$OUT/lib/$base"
      collect "$OUT/lib/$base" "$(dirname "$dep")"
    fi
  done
}
collect "$OUT/bin/ceph-fuse" "$(dirname "$BIN")"

# --- rewrite install names to be relocatable --------------------------------
for lib in "$OUT"/lib/*.dylib; do
  install_name_tool -id "@executable_path/../lib/$(basename "$lib")" "$lib"
done

retarget() {  # object file
  local obj="$1" dep base
  otool -L "$obj" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/*|/usr/local/lib/libfuse*|@executable_path/*) continue ;;
    esac
    base="$(basename "$dep")"
    [ -f "$OUT/lib/$base" ] || continue
    install_name_tool -change "$dep" "@executable_path/../lib/$base" "$obj"
  done
}
retarget "$OUT/bin/ceph-fuse"
for lib in "$OUT"/lib/*.dylib; do retarget "$lib"; done

# --- sign (ad-hoc): arm64 rejects unsigned code, and every edit above
# invalidated whatever signature the Homebrew libraries carried -------------
for f in "$OUT"/lib/*.dylib "$OUT/bin/ceph-fuse"; do
  codesign --force --sign - --timestamp=none "$f" 2>/dev/null
done

# --- config template and a runner that finds the bundled binary -------------
# ship the template, never the local configuration
sed -e 's|^\( *run_dir *= *\).*|\1/tmp/ceph-fuse|' \
    "$ROOT/etc/ceph.conf.example" > "$OUT/etc/ceph.conf"
cp "$ROOT/scripts/mount.sh" "$ROOT/scripts/umount.sh" "$OUT/bin/"

cat > "$OUT/README.txt" <<TXT
ceph-fuse $VERSION for macOS on Apple Silicon
=============================================

Prerequisites on this machine:
  1. macFUSE 5.3+           brew install --cask macfuse
     then allow the kernel extension: System Settings > Privacy & Security >
     allow software from "Benjamin Fleischer", reboot. If the Mac is still at
     full boot security, macOS sends you through Recovery once.
  2. Network access to the cluster (VPN or campus network).
  3. A cephx key.

Setup:
  mkdir -p ~/.ceph
  printf '[client.USER]\\n\\tkey = YOUR-KEY\\n' > ~/.ceph/ceph.client.USER.keyring
  chmod 600 ~/.ceph/ceph.client.USER.keyring

  Edit etc/ceph.conf: check mon host / fsid, and set run_dir to a writable path.

Mount:
  bin/mount.sh USER /remote/path ~/mnt/ceph/storage
  bin/umount.sh USER ~/mnt/ceph/storage

If macOS refuses to run the binary because it was downloaded:
  xattr -dr com.apple.quarantine .

This bundle is ad-hoc signed, not notarised. Everything except macFUSE and
system libraries is included; nothing from Homebrew is required.

Built from https://github.com/... (see BUILDING-macos.md for the six patches
against Ceph $VERSION and every problem they solve).
TXT

# --- verify: run it. A missing library only shows up here, not in otool.
if ! "$OUT/bin/ceph-fuse" --version >/dev/null 2>&1; then
  echo "FEHLER: das gebuendelte Binary startet nicht:" >&2
  "$OUT/bin/ceph-fuse" --version 2>&1 | head -5 >&2
  exit 1
fi

echo "bundle: $OUT"
du -sh "$OUT"
echo
echo "verbleibende externe Referenzen (soll: nur /usr/lib, /System, macFUSE):"
otool -L "$OUT/bin/ceph-fuse" | tail -n +2 | awk '{print "   ", $1}'
