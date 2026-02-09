#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/update_wda_overlay_from_patch.sh [--wda-dir <path>]

What it does:
  - Applies patches/webdriveragent_ondevice_agent_webui.patch to a temporary worktree of the WDA submodule
  - Copies key patched files into wda_overlay/ (readable mirror)

Why:
  This repo treats patches/*.patch as the source of truth. The overlay is a readable mirror.
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
      exit 2
      ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

if [[ -z "$wda_dir" ]]; then
  wda_dir="$repo_root/third_party/WebDriverAgent"
fi

patch_path="$repo_root/patches/webdriveragent_ondevice_agent_webui.patch"
overlay_root="$repo_root/wda_overlay"

files_to_copy=(
  "WebDriverAgentRunner/UITestingUITests.m"
  "WebDriverAgentLib/Routing/FBRouteRequest.h"
  "WebDriverAgentLib/Routing/FBRouteRequest-Private.h"
  "WebDriverAgentLib/Routing/FBRouteRequest.m"
  "WebDriverAgentLib/Routing/FBWebServer.m"
)

if [[ ! -f "$patch_path" ]]; then
  echo "Patch not found: $patch_path" >&2
  exit 2
fi
if [[ ! -e "$wda_dir/.git" ]]; then
  echo "WDA git repo not found at: $wda_dir" >&2
  echo "Tip: run 'git submodule update --init --recursive' in repo root." >&2
  exit 2
fi

mkdir -p "$overlay_root"

tmp_worktree="$(mktemp -d)"
cleanup() {
  if [[ -d "$tmp_worktree" ]]; then
    git -C "$wda_dir" worktree remove --force "$tmp_worktree" >/dev/null 2>&1 || true
    rm -rf "$tmp_worktree" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

git -C "$wda_dir" worktree add --detach "$tmp_worktree" HEAD >/dev/null
git -C "$tmp_worktree" apply "$patch_path"

for rel in "${files_to_copy[@]}"; do
  src="$tmp_worktree/$rel"
  dst="$overlay_root/$rel"
  if [[ ! -f "$src" ]]; then
    echo "Patched file not found: $src" >&2
    exit 2
  fi
  mkdir -p "$(dirname "$dst")"
  cp -f "$src" "$dst"
  echo "Updated overlay: $dst"
done
