# iOS On-Device Agent Based on WebDriverAgent

[English](README.md) | [简体中文](README.zh-CN.md)

This repository provides an **experimental** way to run a GUI agent loop inside the `WebDriverAgentRunner-Runner` (`.xctrunner`) test process.

The loop runs on the iPhone-side Runner process:

```text
screenshot -> call LLM -> parse action -> execute tap/swipe/type
```

You do not need to keep a Python control loop running on your Mac. The agent can be configured from Safari on the iPhone or from another machine on the same LAN, using fields such as `base_url`, `model`, `api_key`, and `task`.

> You still need macOS + Xcode at least once to build and install the Runner onto the iPhone. WDA/XCTest is what provides cross-app UI automation capability on iOS.

## TL;DR

```bash
git submodule update --init --recursive
bash scripts/configure_wda_signing.sh --team-id <TEAMID> --bundle-prefix <com.your.prefix>
bash scripts/apply_patch_to_wda.sh
bash scripts/install_wda_prepared_runner.sh --device <UDID>
```

Then, on the iPhone:

1. Open `WebDriverAgentRunner-Runner`.
2. Open Safari.
3. Visit `http://127.0.0.1:8100/agent`.
4. Fill in `Base URL`, `Model`, `API Key` if needed, and `Task`.
5. Tap **Start**.

## What This Repository Provides

This repository ships a patch for WebDriverAgent:

```text
patches/webdriveragent_ondevice_agent_webui.patch
```

The patch adds:

- `GET /agent`: a web UI served from the same WDA port, usually `8100`.
- Agent configuration from the iPhone or LAN: `base_url`, `model`, `api_key`, `task`, and related options.
- An agent loop inside the Runner process for screenshots, LLM calls, action parsing, and action execution.
- Trace export endpoints for training data, HTML reports, and review videos.

## Prerequisites

- macOS with Xcode installed.
- An iPhone with Developer Mode enabled.
- An Apple Developer Team ID. A Personal Team is enough for local testing.
- A unique bundle identifier prefix, for example `com.yourname.wda`.
- The target device UDID. You can find it in Xcode or with:

```bash
xcrun devicectl list devices
```

Security notes:

- Do not expose the WDA/Runner port, default `8100`, to the public Internet.
- LAN access to `/agent/*` requires an Agent Token. Configure and protect it before sharing any access link.
- Avoid "skip TLS verification" on untrusted networks, because API keys can be exposed to man-in-the-middle attacks.

## Quick Start

### 1. Fetch the WebDriverAgent submodule

This repository pins WebDriverAgent as a git submodule at `third_party/WebDriverAgent`.

```bash
git submodule update --init --recursive
```

### 2. Prepare Xcode signing

If this is your first time using Xcode or a Personal Team, run through:

- `docs/recipes/xcode_personal_team_quickstart.md`

Then configure WDA signing and bundle identifiers:

```bash
bash scripts/configure_wda_signing.sh --team-id <TEAMID> --bundle-prefix <com.your.prefix>
```

This modifies only your local `third_party/WebDriverAgent` working tree. It writes your Team ID into a local xcconfig file inside the submodule. Do not commit those submodule changes.

### 3. Apply the on-device agent patch

```bash
bash scripts/apply_patch_to_wda.sh
```

Seeing `m third_party/WebDriverAgent` in `git status` after this step is expected. The patch is applied to the submodule working tree so the Runner can expose `/agent/*`.

### 4. Install the prepared Runner

Because WDA source was changed by the patch, rebuild and reinstall `WebDriverAgentRunner-Runner` once:

```bash
bash scripts/install_wda_prepared_runner.sh --device <UDID>
```

The script builds WDA, prepares the Runner app for direct launch, re-signs it, and installs it to the device.

You can also use Xcode `Product > Test` or the `xcodebuild` flow described in:

- `docs/recipes/run_wda_xcodebuild.md`

### 5. Start WDA and open the agent UI

On the iPhone:

1. Open `WebDriverAgentRunner-Runner`.
2. Open Safari.
3. Visit:

```text
http://127.0.0.1:8100/agent
```

`127.0.0.1` here means the iPhone's own loopback address, because Safari is running on the iPhone. If you access WDA from your Mac through USB, use `iproxy` or another port-forwarding setup before using `http://127.0.0.1:8100` on the Mac.

For LAN access, use:

```text
http://<iphone-ip>:8100/agent
```

If LAN access does not work, check this setting on the iPhone:

```text
Settings -> Apps -> WebDriverAgentRunner-Runner -> Wireless Data
```

It should be `WLAN` or `WLAN & Cellular Data`, not `Off`.

## Access Control and Agent Token

The current Runner code protects `/agent/*` differently for loopback and LAN requests:

- Loopback requests from the iPhone itself, such as `http://127.0.0.1:8100/agent` in iPhone Safari, are allowed without an Agent Token.
- Non-loopback requests, such as `http://<iphone-ip>:8100/agent` from another device on Wi-Fi, require an Agent Token.
- If no Agent Token is saved on Runner, LAN requests are rejected with `LAN access denied. Set Agent Token in Console first.`
- Once a token is saved, LAN clients must send it by one of the supported mechanisms below.

Ways to create or update the token:

- In the Runner web UI, open `http://127.0.0.1:8100/agent` on the iPhone and tap **Rotate token**. The new token is shown once; keep it secret.
- In the native console app, use **Agent token (for LAN)** -> **Update token**. The app can also copy an access link.
- Programmatically, post `agent_token` to `/agent/config` from an already-authorized client.

How clients authenticate:

- Tools and native clients should send `X-OnDevice-Agent-Token: <token>`.
- The bundled Python tools accept `--agent-token <token>` or the `WDA_AGENT_TOKEN` environment variable.
- Browser access can use `http://<iphone-ip>:8100/agent?token=<token>` as a bootstrap link. If the token is valid, Runner upgrades it to an HttpOnly session cookie named `ondevice_agent_token` and the web UI strips `?token=` from the address bar.
- Query-token authentication is accepted for the web pages (`/agent` and `/agent/edit`) only. API calls should use the header or the HttpOnly cookie.

Example:

```bash
export WDA_AGENT_TOKEN="<your-token>"
python3 tools/wda_remote_tool.py --base-url http://<iphone-ip>:8100 status
```

## Local Build Verification

These commands are useful when you want to verify that the project compiles before touching a physical device or signing setup.

Build the native SwiftUI console app for an iOS Simulator:

```bash
SIMULATOR_NAME="iPhone 17"

xcodebuild \
  -project apps/OnDeviceAgentConsole/OnDeviceAgentConsole.xcodeproj \
  -scheme OnDeviceAgentConsole \
  -destination "platform=iOS Simulator,name=$SIMULATOR_NAME" \
  -derivedDataPath /tmp/mobile_gui_build/OnDeviceAgentConsole \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Build the patched WebDriverAgent Runner for testing on an iOS Simulator:

```bash
xcodebuild \
  -project third_party/WebDriverAgent/WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner \
  -destination "platform=iOS Simulator,name=$SIMULATOR_NAME" \
  -derivedDataPath /tmp/mobile_gui_build/WebDriverAgent \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

If your local simulator names differ, list available devices with:

```bash
xcrun simctl list devices available
```

## Native Console App

The repository includes a native SwiftUI console app:

```text
apps/OnDeviceAgentConsole
```

It calls `http://127.0.0.1:8100/agent/*` to configure, start, stop, reset, and inspect logs/chat. It does not replace `WebDriverAgentRunner-Runner`; the Runner is still the execution side.

The console app also manages LAN access:

- **Update token** generates a new Agent Token and syncs it to Runner.
- **Copy access link** builds a `http://<iphone-ip>:8100/agent?token=<token>` link for browser access from another device on the same LAN.

See:

- `docs/recipes/ondevice_agent_console_app.md`

## Export Traces and Reports

After the Runner finishes a task, export the canonical trace as a training dataset:

```bash
python3 tools/wda_training_export.py \
  --base-url http://127.0.0.1:8100 \
  --out-dir training_dataset \
  --source auto \
  --include-parsed-json \
  --include-repair-samples
```

The output directory contains:

- `trace.json`: canonical trace with manifest, prompts, states, model responses, parsed actions, action results, and screenshot references.
- `dataset.jsonl`: state/screenshot/action samples.
- `messages.jsonl`: chat-style SFT samples.
- `repair_samples.jsonl`: optional action repair samples.
- `images/`: per-step screenshots.
- `run_meta.json`: export metadata and counts.

If you access the iPhone over LAN and configured an Agent Token:

```bash
export WDA_AGENT_TOKEN="<your-token>"
python3 tools/wda_training_export.py --base-url http://<iphone-ip>:8100 --out-dir training_dataset
```

If your terminal has proxy environment variables, bypass proxies for local or LAN WDA access:

```bash
export NO_PROXY="127.0.0.1,localhost,<iphone-ip>"
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
```

PowerShell:

```powershell
$env:NO_PROXY = "127.0.0.1,localhost,<iphone-ip>"
Remove-Item Env:HTTP_PROXY,Env:HTTPS_PROXY,Env:ALL_PROXY,Env:http_proxy,Env:https_proxy,Env:all_proxy -ErrorAction SilentlyContinue
```

Generate a static HTML viewer:

```bash
python3 tools/wda_training_viewer.py --dataset-dir training_dataset
```

Generate a review video if `ffmpeg` is installed:

```bash
python3 tools/wda_training_video.py --dataset-dir training_dataset --out training_dataset/trace_review.mp4
```

Export a lightweight HTML report:

```bash
python3 tools/wda_rich_export.py --base-url http://127.0.0.1:8100 --html agent_report.html
```

## Developer Tools

Local scripts are available for development, regression checks, and diagnostics:

- `tools/wda_remote_tool.py`: control `/agent/*`, export chat/logs, and generate HTML reports.
- `tools/wda_rich_export.py`: export HTML reports with config, logs, token usage, and action overlays.
- `tools/wda_training_export.py`: export canonical traces, training JSONL, and screenshots.
- `tools/wda_training_viewer.py`: generate a static HTML viewer for a training dataset directory.
- `tools/wda_training_video.py`: render a training dataset directory into a review MP4.
- `tools/wda_longshot.py`: capture and stitch long screenshots through WDA.
- `tools/macos_remote_tool.py`: automate local macOS app open/activate, click, swipe, and screenshot operations.

See:

- `tools/README.md`

## API Reference

The patch adds these endpoints under the same WDA port, usually `8100`:

- `GET /agent`: configuration/start page.
- `GET /agent/edit`: full-screen text editor page for long task or prompt fields.
- `GET /agent/status`: current runtime status.
- `GET /agent/logs`: recent logs.
- `GET /agent/chat`: conversation history.
- `GET /agent/traces`: recorded canonical trace list.
- `GET /agent/trace/manifest`: manifest for a trace.
- `GET /agent/trace/turns`: per-turn JSONL for a trace.
- `GET /agent/trace/file`: base64 JSON for screenshots and files inside a trace.
- `GET /agent/events`: server-sent events stream for live status updates.
- `GET /agent/step_screenshot`: base64 PNG for one recorded step screenshot.
- `GET /agent/step_screenshots`: batched step screenshots.
- `POST /agent/config`: save configuration.
- `POST /agent/rotate_token`: generate and save a new Agent Token.
- `POST /agent/start`: save configuration and start.
- `POST /agent/stop`: stop the agent.
- `POST /agent/reset`: reset runtime state without clearing `base_url`, `model`, `task`, or remembered API key.
- `POST /agent/factory_reset`: stop the agent and clear saved config, including Agent Token and remembered API key.

## Model Provider Notes

Doubao / Volcengine Ark setup, API key instructions, Responses cache setup, and related configuration are documented in:

- `docs/recipes/volcengine_doubao_setup.md`

## Inspiration

This project was inspired by:

- Doubao Phone's on-device agent interaction model.
- The Open-AutoGLM open-source project.

## Disclaimer

This project provides iOS UI automation based on WebDriverAgent (WDA) for learning, research, and development/testing purposes only.

Please read before use:

- Authorization and compliance: Use only on devices, accounts, and apps you own or are explicitly authorized to access. Automating third-party apps may violate their Terms of Service and/or local laws. You are solely responsible for any consequences.
- Risky actions: Automation can mis-click or mis-type, potentially causing irreversible actions such as data modification, information disclosure, ordering, or payments. Be extra cautious with financial, privacy-sensitive, or important account apps, such as banking, payment, or admin consoles. Prefer human confirmation/takeover.
- Security: Do not expose the WDA/Runner port, default `8100`, to the public Internet. If LAN access is enabled, use and protect an Agent Token. Do not enable "skip TLS verification" on untrusted networks, or your API key may be exposed to MITM attacks.
- Privacy: Screenshots, logs, and exported reports may contain sensitive data. Redact and clean them before sharing or filing issues.
- No warranty: This project is provided "AS IS", without warranties of any kind, and the authors are not liable for any damages. By using this project, you acknowledge and accept these risks.

## License

- This repository is primarily licensed under the Apache License 2.0. See `LICENSE`.
- WebDriverAgent, the submodule, is licensed under BSD 3-Clause. Some files in this repository are derived from it. See `THIRD_PARTY_NOTICES.md`.
