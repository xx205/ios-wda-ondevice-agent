#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/prepare_wda_runner_for_devicectl.sh --app <WebDriverAgentRunner-Runner.app> --out <output-dir> [--identity "<codesign identity>"]

What it does:
  - Copies the given WDA Runner .app to <output-dir>
  - Removes Frameworks/XC*.framework (required for devicectl launch on iOS 17+ in Appium "preinstalled WDA" setups)
  - Re-signs the modified app bundle using the original signing identity (or --identity)

Notes:
  - Removing files breaks code signature, so re-sign is mandatory.
  - This script does not install anything onto the device.
EOF
}

app_path=""
out_dir=""
identity=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      app_path="${2:-}"; shift 2 ;;
    --out)
      out_dir="${2:-}"; shift 2 ;;
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

if [[ -z "$app_path" || -z "$out_dir" ]]; then
  echo "Missing required args." >&2
  usage
  exit 2
fi

if [[ ! -d "$app_path" || "${app_path##*.}" != "app" ]]; then
  echo "Invalid --app path: $app_path" >&2
  exit 2
fi

mkdir -p "$out_dir"

tmp_app="$out_dir/$(basename "$app_path")"
rm -rf "$tmp_app"
cp -R "$app_path" "$tmp_app"

if [[ -z "$identity" ]]; then
  identity="$(codesign -dvv "$tmp_app" 2>&1 | grep '^Authority=' | head -n 1 | sed 's/^Authority=//')"
fi

if [[ -z "$identity" ]]; then
  echo "Could not detect codesign identity. Provide --identity manually." >&2
  exit 1
fi

echo "Using codesign identity: $identity"

ent_app="$out_dir/entitlements.app.plist"
ent_xctest="$out_dir/entitlements.xctest.plist"

codesign -d --entitlements :- "$tmp_app" >"$ent_app" 2>/dev/null || true
if [[ -d "$tmp_app/PlugIns/WebDriverAgentRunner.xctest" ]]; then
  codesign -d --entitlements :- "$tmp_app/PlugIns/WebDriverAgentRunner.xctest" >"$ent_xctest" 2>/dev/null || true
fi

echo "Removing Frameworks/XC*.framework ..."
if [[ -d "$tmp_app/Frameworks" ]]; then
  rm -rf "$tmp_app/Frameworks/"XC*.framework 2>/dev/null || true
fi

sign_one() {
  local path="$1"
  local entitlements="${2:-}"

  if [[ -n "$entitlements" && -s "$entitlements" ]]; then
    codesign --force --sign "$identity" --timestamp=none --entitlements "$entitlements" "$path"
  else
    codesign --force --sign "$identity" --timestamp=none "$path"
  fi
}

echo "Re-signing nested code ..."
{
  find "$tmp_app" -type d -name "*.framework" -print 2>/dev/null || true
  find "$tmp_app" -type f -name "*.dylib" -print 2>/dev/null || true
} | sort | while IFS= read -r item; do
  sign_one "$item"
done

if [[ -d "$tmp_app/PlugIns/WebDriverAgentRunner.xctest" ]]; then
  sign_one "$tmp_app/PlugIns/WebDriverAgentRunner.xctest" "$ent_xctest"
fi

echo "Re-signing app ..."
sign_one "$tmp_app" "$ent_app"

echo "Verifying signature ..."
codesign --verify --deep --strict "$tmp_app"

echo "Prepared app: $tmp_app"
