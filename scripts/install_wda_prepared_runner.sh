#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/install_wda_prepared_runner.sh --device <UDID|name> [--wda-dir <path>] [--derived-data <path>] [--out <dir>] [--no-build] [--identity "<codesign identity>"]

What it does:
  1) (Optional) Builds WebDriverAgentRunner (build-for-testing)
  2) Prepares WebDriverAgentRunner-Runner.app for launching via tap/devicectl:
     - Removes Frameworks/XC*.framework
     - Re-signs the bundle
  3) Installs the prepared Runner to the device

Why:
  On iOS 17+/18, an unprepared Runner may crash immediately when launched directly
  (e.g. by tapping the icon), or fail to stay alive. Preparing the Runner makes
  it much more likely to be launchable without running xcodebuild test each time.

After install:
  - On the iPhone: open "WebDriverAgentRunner-Runner" to start WDA (8100)
  - Then open Safari: http://127.0.0.1:8100/agent
  - To stop WDA: force-quit the Runner app

Notes:
  - This script does NOT start WDA. It only installs a prepared Runner.
  - Installing/updating Runner may reset its "Wireless Data" permission to Off.
EOF
}

device=""
wda_dir=""
derived_data="$HOME/wda_derived_ondevice_agent"
out_dir="/tmp/WDA-Prepared"
do_build="1"
identity=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      device="${2:-}"; shift 2 ;;
    --wda-dir)
      wda_dir="${2:-}"; shift 2 ;;
    --derived-data)
      derived_data="${2:-}"; shift 2 ;;
    --out)
      out_dir="${2:-}"; shift 2 ;;
    --no-build)
      do_build="0"; shift ;;
    --identity)
      identity="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$device" ]]; then
  echo "Missing --device" >&2
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

if [[ "$do_build" == "1" ]]; then
  echo "[1/3] build-for-testing (DerivedData: $derived_data)"
  xcodebuild -project "$project" \
    -scheme WebDriverAgentRunner \
    -destination "platform=iOS,id=$device" \
    -derivedDataPath "$derived_data" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    build-for-testing
else
  echo "[1/3] build-for-testing skipped (--no-build)"
fi

runner_app=""
if [[ -d "$derived_data/Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app" ]]; then
  runner_app="$derived_data/Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app"
else
  runner_app="$(find "$derived_data/Build/Products" -maxdepth 3 -name 'WebDriverAgentRunner-Runner.app' -print 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "$runner_app" || ! -d "$runner_app" ]]; then
  echo "Could not find WebDriverAgentRunner-Runner.app under: $derived_data" >&2
  echo "Try rerun without --no-build, or set --derived-data to the correct path." >&2
  exit 1
fi

echo "[2/3] prepare runner (remove XC*.framework + re-sign)"
prep_script="$repo_root/scripts/prepare_wda_runner_for_devicectl.sh"
prep_args=(bash "$prep_script" --app "$runner_app" --out "$out_dir")
if [[ -n "$identity" ]]; then
  prep_args+=(--identity "$identity")
fi
"${prep_args[@]}"

prepared_app="$out_dir/WebDriverAgentRunner-Runner.app"
if [[ ! -d "$prepared_app" ]]; then
  echo "Prepared app not found at: $prepared_app" >&2
  exit 1
fi

bundle_id=""
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$prepared_app/Info.plist" 2>/dev/null || true)"
bundle_id="${bundle_id:-}"

echo "[3/3] install prepared runner to device: $device"
xcrun devicectl device install app --device "$device" "$prepared_app"

echo
echo "Installed: $prepared_app"
if [[ -n "$bundle_id" ]]; then
  echo "Bundle ID: $bundle_id"
fi
echo
echo "Next (on iPhone):"
echo "  1) Settings -> Apps -> WebDriverAgentRunner-Runner -> Wireless Data: set to WLAN / WLAN & Cellular Data"
echo "  2) Open WebDriverAgentRunner-Runner (starts WDA)"
echo "  3) Open Safari: http://127.0.0.1:8100/agent"
