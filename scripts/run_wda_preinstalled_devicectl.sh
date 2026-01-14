#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/run_wda_preinstalled_devicectl.sh start --device <UDID|name> --bundle-id <xctrunner-bundle-id> [--wda-url <url>] [--port 8100]
  bash scripts/run_wda_preinstalled_devicectl.sh stop  --device <UDID|name> --bundle-id <xctrunner-bundle-id>

Examples:
  bash scripts/run_wda_preinstalled_devicectl.sh start \
    --device "<UDID|DEVICE_NAME>" \
    --bundle-id "<WDA_XCTRUNNER_BUNDLE_ID>" \
    --wda-url "http://<IPHONE_IP>:8100"

  # USB + iproxy
  bash scripts/run_wda_preinstalled_devicectl.sh start \
    --device "<UDID|DEVICE_NAME>" \
    --bundle-id "<WDA_XCTRUNNER_BUNDLE_ID>" \
    --wda-url http://127.0.0.1:8100

Notes:
  - MUST use --no-activate when launching an .xctrunner, otherwise it can fail with:
      "Failed to background test runner within 30.0s."
  - This does not (re)install WDA. Install it once via Xcode first.
EOF
}

cmd="${1:-}"
shift || true

device=""
bundle_id=""
wda_url=""
port="8100"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      device="${2:-}"; shift 2 ;;
    --bundle-id)
      bundle_id="${2:-}"; shift 2 ;;
    --wda-url)
      wda_url="${2:-}"; shift 2 ;;
    --port)
      port="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$cmd" ]]; then
  usage
  exit 2
fi

if [[ -z "$device" || -z "$bundle_id" ]]; then
  echo "Missing --device or --bundle-id" >&2
  usage
  exit 2
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun not found. Install Xcode Command Line Tools." >&2
  exit 1
fi

wait_for_wda() {
  local url="$1"
  if [[ -z "$url" ]]; then
    return 0
  fi
  echo "Waiting for WDA: $url/status"
  for _ in $(seq 1 60); do
    if curl -sf --max-time 1 "${url%/}/status" >/dev/null 2>&1; then
      echo "WDA is reachable."
      return 0
    fi
    sleep 0.5
  done
  echo "Timed out waiting for WDA at: ${url%/}/status" >&2
  return 1
}

get_pid_by_bundle_id() {
  local device_arg="$1"
  local bundle="$2"
  local tmp_apps="/tmp/devicectl_apps_$$.json"
  local tmp_procs="/tmp/devicectl_processes_$$.json"
  rm -f "$tmp_apps" "$tmp_procs"

  xcrun devicectl device info apps --device "$device_arg" --bundle-id "$bundle" --json-output "$tmp_apps" >/dev/null
  xcrun devicectl device info processes --device "$device_arg" --json-output "$tmp_procs" >/dev/null

  python3 - <<PY "$tmp_apps" "$tmp_procs" "$bundle"
import json, sys
apps_path, procs_path, bundle = sys.argv[1], sys.argv[2], sys.argv[3]

with open(apps_path, "r", encoding="utf-8") as f:
    apps_data = json.load(f) or {}
apps = (apps_data.get("result") or {}).get("apps") or []
if not apps:
    raise SystemExit(0)
app_url = apps[0].get("url") or ""
if not isinstance(app_url, str) or not app_url:
    raise SystemExit(0)
app_url = app_url.rstrip("/")

with open(procs_path, "r", encoding="utf-8") as f:
    procs_data = json.load(f) or {}
procs = (procs_data.get("result") or {}).get("runningProcesses") or []
for proc in procs:
    exe = proc.get("executable") or ""
    if isinstance(exe, str) and exe.startswith(app_url + "/"):
        pid = proc.get("processIdentifier")
        if pid is not None:
            print(pid)
        break
PY

  rm -f "$tmp_apps" "$tmp_procs"
}

case "$cmd" in
  start)
    echo "Launching $bundle_id via devicectl (no-activate) ..."
    xcrun devicectl device process launch \
      --device "$device" \
      --no-activate \
      --terminate-existing \
      --environment-variables "{\"USE_PORT\":\"$port\",\"WDA_PRODUCT_BUNDLE_IDENTIFIER\":\"$bundle_id\"}" \
      "$bundle_id" \
      >/dev/null

    wait_for_wda "$wda_url"
    ;;
  stop)
    pid="$(get_pid_by_bundle_id "$device" "$bundle_id")"
    if [[ -z "$pid" ]]; then
      echo "No running process found for $bundle_id"
      exit 0
    fi
    echo "Terminating $bundle_id (pid=$pid) ..."
    xcrun devicectl device process terminate --device "$device" --pid "$pid" >/dev/null
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage
    exit 2
    ;;
esac
