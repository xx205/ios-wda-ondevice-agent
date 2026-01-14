#!/usr/bin/env bash
set -euo pipefail

log() {
  printf "\n[install_iproxy_from_source] %s\n" "$*"
}

die() {
  printf "\n[install_iproxy_from_source] ERROR: %s\n" "$*" >&2
  exit 1
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "Missing required command: $1"
  fi
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  die "This script is intended for macOS (Darwin)."
fi

PREFIX="${PREFIX:-$HOME/.local}"
KEEP_BUILD_DIR="${KEEP_BUILD_DIR:-0}"

LIBPLIST_VERSION="${LIBPLIST_VERSION:-2.7.0}"
GLUE_VERSION="${GLUE_VERSION:-1.3.2}"
LIBUSBMUXD_VERSION="${LIBUSBMUXD_VERSION:-2.1.1}"

JOBS="${JOBS:-}"
if [[ -z "$JOBS" ]]; then
  JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
fi

TMP_BASE="${TMPDIR:-/tmp}"
BUILD_DIR="${BUILD_DIR:-}"
if [[ -z "$BUILD_DIR" ]]; then
  BUILD_DIR="$(mktemp -d "${TMP_BASE%/}/iproxy-build.XXXXXX")"
fi

cleanup() {
  if [[ "$KEEP_BUILD_DIR" == "1" ]]; then
    log "Keeping build dir: $BUILD_DIR"
    return
  fi
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

log "Prefix: $PREFIX"
log "Build dir: $BUILD_DIR"
log "Versions: libplist=$LIBPLIST_VERSION, glue=$GLUE_VERSION, libusbmuxd=$LIBUSBMUXD_VERSION"

need_cmd clang
need_cmd make
need_cmd curl
need_cmd tar
need_cmd pkg-config

mkdir -p "$PREFIX"

export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CPPFLAGS="-I$PREFIX/include ${CPPFLAGS:-}"
export LDFLAGS="-L$PREFIX/lib ${LDFLAGS:-}"

download_and_extract() {
  local url="$1"
  local archive="$2"
  local expected_dir="$3"

  cd "$BUILD_DIR"
  log "Downloading: $url"
  curl -fsSLo "$archive" "$url"
  log "Extracting: $archive"
  tar -xjf "$archive"
  [[ -d "$expected_dir" ]] || die "Expected directory not found after extraction: $expected_dir"
}

build_configure_make_install() {
  local src_dir="$1"
  shift
  local configure_args=("$@")

  cd "$src_dir"
  log "Configuring: $(basename "$src_dir")"
  ./configure --prefix="$PREFIX" "${configure_args[@]}"
  log "Building: $(basename "$src_dir")"
  make -j"$JOBS"
  log "Installing: $(basename "$src_dir")"
  make install
}

cd "$BUILD_DIR"

# 1) libplist
download_and_extract \
  "https://github.com/libimobiledevice/libplist/releases/download/${LIBPLIST_VERSION}/libplist-${LIBPLIST_VERSION}.tar.bz2" \
  "libplist-${LIBPLIST_VERSION}.tar.bz2" \
  "libplist-${LIBPLIST_VERSION}"

build_configure_make_install "$BUILD_DIR/libplist-$LIBPLIST_VERSION" --without-cython

# 2) libimobiledevice-glue
download_and_extract \
  "https://github.com/libimobiledevice/libimobiledevice-glue/releases/download/${GLUE_VERSION}/libimobiledevice-glue-${GLUE_VERSION}.tar.bz2" \
  "libimobiledevice-glue-${GLUE_VERSION}.tar.bz2" \
  "libimobiledevice-glue-${GLUE_VERSION}"

build_configure_make_install "$BUILD_DIR/libimobiledevice-glue-$GLUE_VERSION"

# 3) libusbmuxd (iproxy)
download_and_extract \
  "https://github.com/libimobiledevice/libusbmuxd/releases/download/${LIBUSBMUXD_VERSION}/libusbmuxd-${LIBUSBMUXD_VERSION}.tar.bz2" \
  "libusbmuxd-${LIBUSBMUXD_VERSION}.tar.bz2" \
  "libusbmuxd-${LIBUSBMUXD_VERSION}"

build_configure_make_install "$BUILD_DIR/libusbmuxd-$LIBUSBMUXD_VERSION"

IPROXY_BIN="$PREFIX/bin/iproxy"
if [[ ! -x "$IPROXY_BIN" ]]; then
  die "iproxy not found at: $IPROXY_BIN"
fi

log "Installed: $IPROXY_BIN"
"$IPROXY_BIN" --version || true

if command -v otool >/dev/null 2>&1; then
  log "Linkage check (otool -L):"
  otool -L "$IPROXY_BIN" || true
fi

cat <<EOF

Done.

Next:
  1) (Optional) Add to PATH:
       export PATH="$PREFIX/bin:\$PATH"

  2) Forward WebDriverAgent port 8100 over USB:
       $IPROXY_BIN -u <UDID> 8100:8100

  3) Verify WDA (requires WDA running on device):
       curl http://127.0.0.1:8100/status

Docs:
  - docs/recipes/iproxy_from_source.md
EOF
