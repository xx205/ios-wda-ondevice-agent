# Summary (2026-02-22)

This is an aggregated view of the parallel review tracks in this folder.

## P0 / P1 priorities (recommended)

### ✅ Implemented: Make overlay sync/check complete
- `scripts/update_wda_overlay_from_patch.sh` and `scripts/check_wda_patch_sync.sh` now derive the file list from `patches/webdriveragent_ondevice_agent_webui.patch`, avoiding stale overlays with false “in sync”.

### ✅ Implemented: Bound Chat Completions history
- Chat Completions mode uses a sliding window for `self.context` to avoid context blowups on long runs.

### ✅ Implemented: Reduce Agent Token leakage surface
- Avoid long-lived tokens in query/cookies/localStorage; support rotate; scope `?token=` to initial pairing and strip it from URL.

### ✅ Implemented: Fix plan identity drift
- Plan item rephrases no longer count as “new items”; normalize keys + stable IDs are supported; plan progress is monotonic.

## P2 improvements (nice to have soon)
- Web UI validation parity with Console (missing required fields should be caught before Start).
- Reduce polling/data transfer (deltas, lower frequency, bounded exports).
- Localize all validation errors and centralize strings.
- Refactor `ConsoleStore` into smaller collaborators and add tests.

## Files
- Track reports: see `security_privacy.md`, `correctness_reliability.md`, `ux_product.md`, `build_devex.md`, `performance_cost.md`, `code_health.md`.
