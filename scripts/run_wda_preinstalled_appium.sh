#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/run_wda_preinstalled_appium.sh --udid <UDID> --wda-bundle-id <base-bundle-id> [--port 4723] [--appium-version 2.19.0] [--xcuitest-version 7.6.0]

Example:
  bash scripts/run_wda_preinstalled_appium.sh --udid <UDID> --wda-bundle-id <WDA_BASE_BUNDLE_ID>

What it does:
  - Starts an Appium server locally
  - Creates an XCUITest session with usePreinstalledWDA=true (so WDA is launched without xcodebuild)
  - Keeps running until Ctrl-C

Notes:
  - The base bundle id is without ".xctrunner". For example:
      installed runner bundle id: <WDA_BASE_BUNDLE_ID>.xctrunner
      pass --wda-bundle-id:       <WDA_BASE_BUNDLE_ID>
EOF
}

udid=""
wda_bundle_id=""
port="4723"
appium_version="2.19.0"
xcuitest_version="7.6.0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid)
      udid="${2:-}"; shift 2 ;;
    --wda-bundle-id)
      wda_bundle_id="${2:-}"; shift 2 ;;
    --port)
      port="${2:-}"; shift 2 ;;
    --appium-version)
      appium_version="${2:-}"; shift 2 ;;
    --xcuitest-version)
      xcuitest_version="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$udid" || -z "$wda_bundle_id" ]]; then
  echo "Missing required args." >&2
  usage
  exit 2
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "npx not found in PATH. Install Node.js + npm." >&2
  exit 1
fi

appium_cmd=(npx -y "appium@${appium_version}")

echo "Ensuring XCUITest driver is installed (xcuitest@${xcuitest_version}) ..."
"${appium_cmd[@]}" driver install "xcuitest@${xcuitest_version}" >/dev/null

base_path="/wd/hub"
appium_url="http://127.0.0.1:${port}${base_path}"

log_file="/tmp/appium_${port}_$(date +%s).log"

echo "Starting Appium server at $appium_url ..."
"${appium_cmd[@]}" --port "$port" --base-path "$base_path" >"$log_file" 2>&1 &
appium_pid=$!

cleanup() {
  set +e
  if [[ -n "${session_id:-}" ]]; then
    curl -s -X DELETE "${appium_url}/session/${session_id}" >/dev/null 2>&1 || true
  fi
  if kill -0 "$appium_pid" 2>/dev/null; then
    kill -TERM "$appium_pid" 2>/dev/null || true
    wait "$appium_pid" 2>/dev/null || true
  fi
  echo "Appium log: $log_file"
}
trap cleanup INT TERM

echo "Waiting for Appium /status ..."
for _ in $(seq 1 60); do
  if curl -s "${appium_url}/status" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

if ! curl -s "${appium_url}/status" >/dev/null 2>&1; then
  echo "Appium did not become ready. Check log: $log_file" >&2
  exit 1
fi

payload="$(python3 - <<PY
import json
udid = ${udid!r}
wda_bundle_id = ${wda_bundle_id!r}
caps = {
  "capabilities": {
    "alwaysMatch": {
      "platformName": "iOS",
      "appium:automationName": "XCUITest",
      "appium:udid": udid,
      "appium:usePreinstalledWDA": True,
      "appium:updatedWDABundleId": wda_bundle_id,
      "appium:bundleId": "com.apple.Preferences",
      "appium:noReset": True,
      "appium:newCommandTimeout": 86400,
    },
    "firstMatch": [{}],
  }
}
print(json.dumps(caps))
PY
)"

echo "Creating Appium session (this should launch WDA) ..."
resp="$(curl -s -X POST "${appium_url}/session" -H 'Content-Type: application/json' -d "$payload")"

session_id="$(python3 - <<PY
import json, sys
resp = json.loads(${resp!r})
sid = resp.get("sessionId") or (resp.get("value") or {}).get("sessionId")
if not sid:
  print(resp, file=sys.stderr)
  raise SystemExit(1)
print(sid)
PY
)"

echo "Appium session id: $session_id"
echo "Keep this running. Ctrl-C to stop."
echo "Log: $log_file"

while true; do
  sleep 3600
done
