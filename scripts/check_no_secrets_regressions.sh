#!/usr/bin/env bash
set -euo pipefail

# Static regression checks for common secret-leak footguns.
#
# This is not a full security audit. It is intended to catch accidental
# re-introductions such as:
# - persisting Agent Token in localStorage / JS-set cookies
# - forgetting to strip ?token= from the URL
# - missing basic redaction keys for raw capture / exports
#
# Usage:
#   bash scripts/check_no_secrets_regressions.sh

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

must_have() {
  local pattern="$1"
  local file="$2"
  if ! rg -n --hidden --no-ignore-vcs -- "$pattern" "$file" >/dev/null 2>&1; then
    fail "missing pattern '$pattern' in $file"
  fi
}

must_not_have() {
  local pattern="$1"
  local file="$2"
  if rg -n --hidden --no-ignore-vcs -- "$pattern" "$file" >/dev/null 2>&1; then
    fail "forbidden pattern '$pattern' found in $file"
  fi
}

wda_runner_dir="$repo_root/wda_overlay/WebDriverAgentRunner"
console_redaction="$repo_root/apps/OnDeviceAgentConsole/OnDeviceAgentConsole/Utilities/ConsoleRedaction.swift"

[[ -d "$wda_runner_dir" ]] || fail "missing $wda_runner_dir"
[[ -f "$console_redaction" ]] || fail "missing $console_redaction"

echo "== Runner web UI token storage =="
must_have "stripTokenFromURL\\(" "$wda_runner_dir"
must_not_have "localStorage\\.setItem\\('ondevice_agent_token'" "$wda_runner_dir"
must_not_have "document\\.cookie" "$wda_runner_dir"

echo "== Runner cookie attributes (session, Strict, HttpOnly) =="
must_have "SameSite=Strict" "$wda_runner_dir"
must_have "HttpOnly" "$wda_runner_dir"

echo "== Raw redaction keys include agent token =="
must_have "x-ondevice-agent-token" "$wda_runner_dir"
must_have "agent_token" "$wda_runner_dir"
must_have "ondevice_agent_token" "$wda_runner_dir"
must_have "authorization" "$wda_runner_dir"
must_have "api_key" "$wda_runner_dir"

echo "== Server logs must not print full request headers =="
route_req="$repo_root/wda_overlay/WebDriverAgentLib/Routing/FBRouteRequest.m"
[[ -f "$route_req" ]] || fail "missing $route_req"
must_not_have "Headers %@" "$route_req"

echo "== Console redaction covers agent token and auth =="
must_have "x-ondevice-agent-token" "$console_redaction"
must_have "agent_token" "$console_redaction"
must_have "ondevice_agent_token" "$console_redaction"
must_have "Authorization" "$console_redaction"

echo "OK: no-secrets regressions checks passed."
