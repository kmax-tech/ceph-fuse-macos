#!/usr/bin/env bash
# Configure and build only the ceph-fuse target on macOS/arm64.
# Everything not needed by the FUSE client is switched off on purpose.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src/ceph"
BREW="$(brew --prefix)"
ICU_ROOT="$(brew --prefix icu4c)"   # keg-only, FindICU needs it spelled out

# Ceph always configures src/pybind, which needs Cython. Use a dedicated venv
# instead of whatever python happens to be first in PATH (pyenv shims, an active
# project venv, ...) so the build does not depend on the current shell.
VENV="$ROOT/.venv-build"
if [ ! -x "$VENV/bin/python3" ]; then
  "$BREW/opt/python@3.12/bin/python3.12" -m venv "$VENV"
fi
# cython: src/pybind; pyyaml: y2c.py generates the options tables from YAML
"$VENV/bin/pip" install --quiet --upgrade pip cython pyyaml

# macFUSE installs into /usr/local even on Apple Silicon; Homebrew lives in /opt/homebrew.
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:\
$BREW/opt/nss/lib/pkgconfig:$BREW/opt/nspr/lib/pkgconfig:\
$BREW/opt/openssl@3/lib/pkgconfig:$ICU_ROOT/lib/pkgconfig"

CMAKE_ARGS=(
  -B build -G Ninja
  -DCMAKE_BUILD_TYPE=RelWithDebInfo
  -DENABLE_GIT_VERSION=ON
  -DWITH_CCACHE=ON
  -DICU_ROOT="$ICU_ROOT"
  # Homebrew ships CMake 4.x; bundled third-party projects (cpp_redis, ...)
  # still declare cmake_minimum_required < 3.5, which CMake 4 rejects.
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  -DPython3_EXECUTABLE="$VENV/bin/python3"
  -DWITH_FUSE=ON
  -DWITH_LIBCEPHFS=ON
  -DWITH_CEPHFS=OFF
  -DWITH_RBD=OFF -DWITH_KRBD=OFF
  -DWITH_RADOSGW=OFF
  -DWITH_MGR=OFF -DWITH_MGR_DASHBOARD_FRONTEND=OFF
  -DWITH_BLUESTORE=OFF -DWITH_SPDK=OFF -DWITH_DPDK=OFF -DWITH_RDMA=OFF
  -DWITH_JAEGER=OFF -DWITH_LTTNG=OFF -DWITH_BABELTRACE=OFF
  -DWITH_QATLIB=OFF -DWITH_QATZIP=OFF
  -DWITH_SYSTEMD=OFF -DWITH_XFS=OFF -DWITH_SELINUX=OFF
  -DWITH_TESTS=OFF -DWITH_MANPAGE=OFF
)

# Optional overrides, set from the environment when a fallback is needed:
#   USE_SYSTEM_BOOST=1  -> use Homebrew boost instead of the bundled one
#   USE_BREW_LLVM=1     -> use Homebrew clang instead of Apple clang
[ "${USE_SYSTEM_BOOST:-0}" = 1 ] && CMAKE_ARGS+=( -DWITH_SYSTEM_BOOST=ON )
[ "${USE_BREW_LLVM:-0}" = 1 ] && CMAKE_ARGS+=(
  -DCMAKE_C_COMPILER="$BREW/opt/llvm/bin/clang"
  -DCMAKE_CXX_COMPILER="$BREW/opt/llvm/bin/clang++"
  -DCMAKE_EXE_LINKER_FLAGS="-L$BREW/opt/llvm/lib/c++"
)

cd "$SRC"

# The tarball ships src/.git_version (upstream sha + 19.2.3), but that fallback
# only fires when no .git exists -- and we keep one for the patch series. Tag
# the vanilla commit instead: git describe then yields "19.2.3-<n>-g<sha>",
# upstream version plus our local commit count, which is exactly what the
# binary should report.
if ! git describe >/dev/null 2>&1; then
  VANILLA="$(git log --format=%H --grep='^vanilla ceph' | tail -1)"
  [ -n "$VANILLA" ] && git -c user.email=build@local -c user.name=build \
    tag -a v19.2.3 -m "upstream ceph 19.2.3 (tarball)" "$VANILLA"
fi

cmake "${CMAKE_ARGS[@]}"
ninja -C build ceph-fuse
