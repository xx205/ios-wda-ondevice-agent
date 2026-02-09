# Local Developer Tools

This directory contains local utility scripts for debugging and operating the on-device agent stack.

These tools are not required for end users to run the product flow, but they are useful for development, regression checks, and UI diagnostics.

## Included scripts

- `tools/wda_remote_tool.py`
  - Controls `/agent/*` endpoints exposed by Runner.
  - Supports polling, start/stop/reset, chat/log export, and HTML report generation with screenshots.

- `tools/wda_longshot.py`
  - Captures and stitches long screenshots from iPhone via WDA.
  - Useful for reviewing a full scrollable settings page in one image.

- `tools/macos_remote_tool.py`
  - Local macOS UI automation helper.
  - Supports app open/activate, click, swipe (drag), and screenshot.
  - Requires Accessibility permission for click/swipe and Screen Recording permission for screenshots.

## Quick examples

```bash
# Query runner status
python3 tools/wda_remote_tool.py --base-url http://127.0.0.1:8100 status

# Export chat as HTML report
python3 tools/wda_remote_tool.py --base-url http://127.0.0.1:8100 chat --html /tmp/agent_chat.html

# Capture long screenshot from iPhone via WDA
python3 tools/wda_longshot.py --base http://127.0.0.1:8100 --out-dir /tmp/run_longshot

# macOS: open app, click, screenshot
python3 tools/macos_remote_tool.py open --app "Safari"
python3 tools/macos_remote_tool.py click --coord-space normalized --x 500 --y 500
python3 tools/macos_remote_tool.py screenshot --out /tmp/macos_full.png
```
