#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/run_wda_xcodebuild.sh --udid <UDID> [--wda-dir <path>] [--derived-data <path>] [--no-build]

What it does:
  - (Optional) xcodebuild build-for-testing once (to generate *.xctestrun)
  - xcodebuild test-without-building to start WDA (UITestingUITests/testRunner)

Notes:
  - WDA is started from an XCTest UI test. Launching the *.xctrunner with devicectl usually exits quickly.
  - This script keeps xcodebuild running (WDA server stays up). Press Ctrl-C to stop.
EOF
}

udid=""
wda_dir=""
derived_data="$HOME/wda_derived_ondevice_agent"
do_build="1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid)
      udid="${2:-}"; shift 2 ;;
    --wda-dir)
      wda_dir="${2:-}"; shift 2 ;;
    --derived-data)
      derived_data="${2:-}"; shift 2 ;;
    --no-build)
      do_build="0"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$udid" ]]; then
  echo "Missing --udid" >&2
  usage
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

if [[ -z "$wda_dir" ]]; then
  wda_dir="$repo_root/third_party/WebDriverAgent"
fi

project="$wda_dir/WebDriverAgent.xcodeproj"
if [[ ! -d "$project" ]]; then
  echo "WebDriverAgent project not found at: $project" >&2
  echo "Tip: run 'git submodule update --init --recursive' in repo root." >&2
  exit 2
fi

mkdir -p "$derived_data"

find_xctestrun() {
  local dd="$1"
  local found
  found="$(ls -1 "$dd/Build/Products/"WebDriverAgentRunner_iphoneos*.xctestrun 2>/dev/null | head -n 1 || true)"
  if [[ -z "$found" ]]; then
    found="$(find "$dd/Build/Products" -maxdepth 2 -name 'WebDriverAgentRunner_iphoneos*.xctestrun' -print 2>/dev/null | head -n 1 || true)"
  fi
  echo "$found"
}

if [[ "$do_build" == "1" ]]; then
  echo "[1/2] build-for-testing (DerivedData: $derived_data)"
  xcodebuild -project "$project" \
    -scheme WebDriverAgentRunner \
    -destination "platform=iOS,id=$udid" \
    -derivedDataPath "$derived_data" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    build-for-testing
fi

xctestrun="$(find_xctestrun "$derived_data")"
if [[ -z "$xctestrun" ]]; then
  echo "Could not find *.xctestrun under: $derived_data" >&2
  echo "Try rerun without --no-build, or set --derived-data to the correct path." >&2
  exit 1
fi

echo "[2/2] test-without-building (xctestrun: $xctestrun)"
echo "Press Ctrl-C to stop."

xcodebuild test-without-building \
  -xctestrun "$xctestrun" \
  -destination "platform=iOS,id=$udid" \
  -only-testing:WebDriverAgentRunner/UITestingUITests/testRunner &

xcb_pid=$!

cleanup() {
  if kill -0 "$xcb_pid" 2>/dev/null; then
    echo
    echo "Stopping xcodebuild (pid=$xcb_pid)..."
    kill -TERM "$xcb_pid" 2>/dev/null || true
    wait "$xcb_pid" 2>/dev/null || true
  fi
}

trap cleanup INT TERM
wait "$xcb_pid"
