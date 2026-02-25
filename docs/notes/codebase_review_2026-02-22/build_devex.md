## Build/Install/DevEx Review

### Findings

- **P1: Overlay sync scripts miss patched files.**  
  `scripts/update_wda_overlay_from_patch.sh` and `scripts/check_wda_patch_sync.sh` only copy/check a small allowlist of files, but the patch also touches additional files (e.g. `WebDriverAgentLib/Vendor/RoutingHTTPServer/RoutingConnection.{h,m}` in recent work). This can leave `wda_overlay/` stale while the “sync check” still passes, undermining the mirror workflow.

- **P2: Install flow can silently ship an unpatched Runner.**  
  `scripts/install_wda_prepared_runner.sh` builds/installs without verifying that `patches/webdriveragent_ondevice_agent_webui.patch` is applied. A fresh user can follow docs, run install, and end up with a vanilla WDA lacking `/agent/*` endpoints with no clear warning.

- **P2: `run_wda_preinstalled_devicectl.sh` assumes `python3` exists.**  
  The script uses embedded `python3` snippets but doesn’t check for `python3` or document it. On systems without `python3`, it fails mid-flow in confusing ways.

### Recommendations

1. **Make overlay sync/check cover all patched files** (ideally derive the list from the patch itself).
2. **Fail fast in install scripts** if patch isn’t applied (or auto-apply with a prompt).
3. **Add toolchain dependency checks** (e.g., `python3`) + document them in recipes.

