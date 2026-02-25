# Next Steps Plan (post-2026-02-22 review)

This document tracks the **follow-up implementation plan** after the parallel codebase review.
It is intended to be updated over time as work lands or priorities change.

## Current status (implemented)

- ✅ Patch-driven overlay sync/check
  - `scripts/update_wda_overlay_from_patch.sh`: derive file list from `patches/webdriveragent_ondevice_agent_webui.patch`
  - `scripts/check_wda_patch_sync.sh`: verify overlay matches patched worktree for all files in patch
- ✅ Bounded Chat Completions history (sliding window)
  - `third_party/WebDriverAgent/WebDriverAgentRunner/UITestingUITests.m`: trim `self.context` in chat completions mode
- ✅ Reduce Agent Token leakage surface
  - Token is no longer persisted in localStorage; token-in-URL is stripped; LAN requires token; loopback bypass remains.
  - Rotation endpoint + UI exists; raw/log exports are redacted; regression script added.
- ✅ Stabilize plan identity (avoid “rephrase = new item”)
  - Plan items support stable `id`, merged via id + normalized keys; sticky done; repair attempts do not roll back plan.
  - Regression tests added for plan merge behavior.

## Next priorities (recommended order)

### P2-1: Web UI validation parity with Console

Mirror the console’s “required field” checks in Runner web UI; disable Start until satisfied and show inline error bullets.

### P2-2: Reduce polling + payload sizes

Prefer delta updates (SSE/long-poll) or reduce polling frequency; poll only when running or when a version counter changes.

### P2-3: Localize validation/errors consistently

Centralize strings and ensure zh/en are both covered.

### P2-4: Refactor ConsoleStore + add tests

Split large view model into smaller testable collaborators.

---

## Notes

- This doc is an output of the 2026-02-22 review and is now superseded by `docs/notes/next_modification_plan.md` for ongoing tracking.
