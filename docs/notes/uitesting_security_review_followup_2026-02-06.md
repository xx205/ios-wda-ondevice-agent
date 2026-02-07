# UITestingUITests.m Security Review Follow-up (2026-02-06)

## Scope

- File under review: `wda_overlay/WebDriverAgentRunner/UITestingUITests.m`
- Related transport/routing files in WDA vendor stack were included where needed.

## Findings (from latest re-review)

1. `P0` localhost auth bypass risk
   - Current localhost decision can be fooled by URL host fallback behavior in HTTP parser.
2. `P1` token leakage surface too broad
   - Query token is accepted and web UI appends token into API URL query.
3. `P2` frontend/backend numeric validation mismatch
   - UI accepts some inputs that backend strict parser rejects.
4. `P2` strict numeric parser still accepts boolean NSNumber
   - `true/false` can pass as `1/0`.
5. `P3` `/agent` and `/agent/edit` remain anonymous
   - Control page exposure remains wider than API protection.

## Fix Progress

- [x] `P0` Replace localhost trust source with real client peer address from socket.
- [x] `P1` Remove token from API URL query usage in web UI and prefer header-only auth transport.
- [x] `P2` Align UI numeric validation with backend strict parsing rules.
- [x] `P2` Reject boolean NSNumber in strict int/double parsers.
- [x] `P3` Gate `/agent` and `/agent/edit` with A1 policy (first-link token bootstrap + API header-only).

### Progress Log

- 2026-02-06: Added `clientHost` propagation path from transport socket (`HTTPConnection` -> `RouteRequest` -> `FBRouteRequest`) and switched localhost authorization to trust socket peer host only.
- 2026-02-06: Token extraction is now header-only on runner side; web UI no longer appends token in API URL query and strips `token` from location using `history.replaceState` after bootstrap.
- 2026-02-06: Web UI numeric validation switched to strict integer/number patterns and `save config` now uses the same validation gate as `start`.
- 2026-02-06: Strict numeric parser now rejects boolean `NSNumber` and adds integer range guard for string-to-int parsing.
- 2026-02-06: Implemented A1 for pages: `/agent` and `/agent/edit` now require auth for LAN; token sources for page GET are header/query/cookie, while API remains header-only.
- 2026-02-06: Added Console UX entrypoint: `Copy one-time LAN link` using `/agent?token=...` bootstrap link.
- 2026-02-06: Validation run: `xcodebuild -project third_party/WebDriverAgent/WebDriverAgent.xcodeproj -scheme WebDriverAgentLib -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` succeeded (existing analyzer warning in `GCDAsyncUdpSocket.m`, unrelated).
- 2026-02-06: Validation run: `xcodebuild -project third_party/WebDriverAgent/WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` succeeded.
- 2026-02-06: Validation run: `xcodebuild -project apps/OnDeviceAgentConsole/OnDeviceAgentConsole.xcodeproj -scheme OnDeviceAgentConsole -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` succeeded (existing `onChange(of:perform:)` deprecation warnings in `ContentView.swift`, unrelated to this change).
- 2026-02-06: Synced latest `wda_overlay/WebDriverAgentRunner/UITestingUITests.m` into `third_party/WebDriverAgent/WebDriverAgentRunner/UITestingUITests.m` before real device build/install verification.
- 2026-02-06: Fixed strict-int parser compile blocker under `-Werror` on 64-bit by guarding `NSInteger` range check with `#if !__LP64__`.
- 2026-02-06: Real-device validation: rebuilt + prepared + installed Runner via `bash scripts/install_wda_prepared_runner.sh --device 00008110-000C044901E2801E`; then started by `run_wda_preinstalled_devicectl.sh start` and verified `/status` reachable (`build.time = "Feb  6 2026 22:47:31"`).
- 2026-02-06: Real-device endpoint content check: `/agent` and `/agent/edit` now include A1 bootstrap logic (`persistAgentToken`, `history.replaceState`, cookie/localStorage persist, and header `X-OnDevice-Agent-Token` usage).
- 2026-02-06: LAN smoke (non-loopback endpoint `http://169.254.206.250:8100`): with token set, `/agent` => `401` (no token), `/agent?token=...` => `200`, `/agent` + cookie => `200`; `/agent/status` => `401` (no header), `/agent/status?token=...` => `401`, `/agent/status` + `X-OnDevice-Agent-Token` => `200`.
- 2026-02-06: Console token UX simplified to two actions in Advanced section: `Update token` (rotate + sync to Runner) and `Copy access link` (copy-only, no token mutation). Removed inline full URL display text.
- 2026-02-06: Rebuilt and reinstalled latest Console app on device (`00008110-000C044901E2801E`) via `xcodebuild` + `xcrun devicectl`; install returned success for `com.example.ondevice-agent-console`.
- 2026-02-06: Updated token action controls to match `Start run`/`Stop run` visual pattern (headline-style blue link text) and split into two stacked rows for readability.
- 2026-02-06: Rebuilt + reinstalled Console again after the style/layout change; install returned success for `com.example.ondevice-agent-console`.
- 2026-02-06: Refined token action behavior to reduce confusion: `Update token` now syncs current token value first and only auto-generates when the field is empty; `Copy access link` remains copy-only.
- 2026-02-06: Added in-flight guard for token updates (`isUpdatingAgentToken`) so update/copy actions are not triggered concurrently.
- 2026-02-06: Unified bilingual copy for the token section (English + zh-Hans terminology and action descriptions).
- 2026-02-06: Rebuilt (simulator) and rebuilt+reinstalled (device `00008110-000C044901E2801E`) after the behavior/copy update; install returned success for `com.example.ondevice-agent-console`.
- 2026-02-06: Tightened token action tap behavior in UI by applying `.buttonStyle(.plain)` to token action rows, so taps on surrounding help text/blank area no longer trigger the action.
- 2026-02-06: Rebuilt (simulator) and rebuilt+reinstalled (device `00008110-000C044901E2801E`) after tap-target adjustment; install returned success for `com.example.ondevice-agent-console`.
- 2026-02-06: Follow-up fix for token action interactivity: removed update-in-flight lock gating (`isUpdatingAgentToken`) and made `Copy access link` tappable whenever token is non-empty; when LAN link cannot be built, the action now reports a clear error instead of staying permanently disabled.
- 2026-02-06: Rebuilt (simulator) and rebuilt+reinstalled (device `00008110-000C044901E2801E`) after interactivity fix; install returned success for `com.example.ondevice-agent-console`.
- 2026-02-06: Fixed token action hit-testing by splitting `Update token` / `Copy access link` into separate Form rows and applying `.buttonStyle(.borderless)`, preventing the first button from stealing taps intended for the second.
- 2026-02-06: Restored `Update token` semantics to always rotate (generate a new token) and sync to Runner, so repeated taps have visible feedback and copied links match the latest token.
- 2026-02-07: Follow-up UX tweak: removed `.buttonStyle(.borderless)` from the token action rows now that they are separate Form rows, restoring the same full-row tap behavior as `Start run` / `Stop run`.
- 2026-02-07: Fixed token rotation auth for non-loopback Runner URLs: `Update token` now authenticates using the previous token header while sending the new token in the request body, so LAN token rotation works when a token is already set.
- 2026-02-07: Rebuilt + reinstalled + launched Console on device (`00008110-000C044901E2801E`); install returned success for `com.example.ondevice-agent-console`.

## Notes

- Explicitly not changing in this pass:
  - `chat_completions` full-history behavior (including images).
  - hard caps for config/buffers.
