#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/check_wda_patch_sync.sh [--wda-dir <path>]

What it checks:
  1) patches/webdriveragent_ondevice_agent_webui.patch applies cleanly to the pinned WebDriverAgent submodule commit
  2) wda_overlay mirrors the result of applying the patch for key files

Notes:
  - This does not modify your submodule working tree. It uses a temporary git worktree.
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

patched_files_from_patch() {
  local patch="$1"
  awk '
    /^diff --git a\// {
      p=$4;
      sub(/^b\//, "", p);
      print p;
    }
  ' "$patch" | sort -u
}

if [[ ! -f "$patch_path" ]]; then
  echo "Patch not found: $patch_path" >&2
  exit 2
fi
if [[ ! -e "$wda_dir/.git" ]]; then
  echo "WDA git repo not found at: $wda_dir" >&2
  echo "Tip: run 'git submodule update --init --recursive' in repo root." >&2
  exit 2
fi

files_to_check=()
while IFS= read -r line; do
  [[ -n "$line" ]] && files_to_check+=("$line")
done < <(patched_files_from_patch "$patch_path")
if [[ "${#files_to_check[@]}" -eq 0 ]]; then
  echo "No files found in patch: $patch_path" >&2
  exit 2
fi

tmp_worktree="$(mktemp -d)"
cleanup() {
  if [[ -d "$tmp_worktree" ]]; then
    git -C "$wda_dir" worktree remove --force "$tmp_worktree" >/dev/null 2>&1 || true
    rm -rf "$tmp_worktree" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

git -C "$wda_dir" worktree add --detach "$tmp_worktree" HEAD >/dev/null

git -C "$tmp_worktree" apply --check "$patch_path"
git -C "$tmp_worktree" apply "$patch_path"

for rel in "${files_to_check[@]}"; do
  overlay_path="$overlay_root/$rel"
  patched="$tmp_worktree/$rel"
  if [[ ! -f "$patched" ]]; then
    # Deleted by patch. Overlay must not keep a stale copy.
    if [[ -f "$overlay_path" ]]; then
      echo "Mismatch: overlay has file deleted by patch: $rel" >&2
      echo "Tip: run 'bash scripts/update_wda_overlay_from_patch.sh' to refresh overlay from patch." >&2
      exit 1
    fi
    continue
  fi

  if [[ ! -f "$overlay_path" ]]; then
    echo "Mismatch: overlay missing patched file: $rel" >&2
    echo "Tip: run 'bash scripts/update_wda_overlay_from_patch.sh' to refresh overlay from patch." >&2
    exit 1
  fi

  if ! diff -u "$overlay_path" "$patched" >/dev/null; then
    echo "Mismatch: overlay != patched result for $rel" >&2
    echo "Tip: run 'bash scripts/update_wda_overlay_from_patch.sh' to refresh overlay from patch." >&2
    diff -u "$overlay_path" "$patched" | head -n 80 >&2
    exit 1
  fi
done

echo "OK: patch applies cleanly and overlay matches patch result."
