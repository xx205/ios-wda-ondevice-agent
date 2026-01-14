#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/apply_patch_to_wda.sh [--wda-dir <path>]

What it does:
  - Applies patches/webdriveragent_ondevice_agent_webui.patch to a WebDriverAgent repo

Default WDA directory:
  third_party/WebDriverAgent (git submodule)

Notes:
  - This does NOT commit anything in the WDA repo; it only updates the working tree.
  - If the patch is already applied, the script exits successfully.
EOF
}

wda_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wda-dir)
      wda_dir="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2 ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

if [[ -z "$wda_dir" ]]; then
  wda_dir="$repo_root/third_party/WebDriverAgent"
fi

if [[ ! -d "$wda_dir/WebDriverAgent.xcodeproj" ]]; then
  echo "WebDriverAgent project not found at: $wda_dir/WebDriverAgent.xcodeproj" >&2
  echo "Tip: run 'git submodule update --init --recursive' in repo root." >&2
  exit 2
fi

patch_path="$repo_root/patches/webdriveragent_ondevice_agent_webui.patch"
if [[ ! -f "$patch_path" ]]; then
  echo "Patch not found: $patch_path" >&2
  exit 2
fi

target_file="$wda_dir/WebDriverAgentRunner/UITestingUITests.m"
if [[ ! -f "$target_file" ]]; then
  echo "Target file not found: $target_file" >&2
  exit 2
fi

if grep -q "FBOnDeviceAgentCommands" "$target_file" >/dev/null 2>&1; then
  echo "Patch already applied (found FBOnDeviceAgentCommands)."
  exit 0
fi

echo "Applying patch to: $wda_dir"
cd "$wda_dir"
git apply "$patch_path"
echo "Done."
