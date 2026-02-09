#!/usr/bin/env python3
"""
macOS local UI remote tool (non-git helper)

Capabilities:
- Open / activate app
- Click by coordinate
- Swipe (mouse drag) by coordinate
- Screenshot full screen or region

Notes:
- Requires Accessibility permission for click/swipe.
- Requires Screen Recording permission for screenshots.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from typing import Optional


@dataclass
class ScreenSize:
    width: float
    height: float


def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True, check=check)


def run_osascript(script: str) -> str:
    proc = run(["osascript", "-e", script])
    return proc.stdout.strip()


def open_app(app: Optional[str], bundle_id: Optional[str]) -> None:
    if bool(app) == bool(bundle_id):
        raise SystemExit("Use exactly one of --app or --bundle-id")

    if app:
        run(["open", "-a", app])
        # Bring to foreground.
        run_osascript(f'tell application "{app}" to activate')
        print(f"Opened and activated app: {app}")
        return

    assert bundle_id is not None
    run(["open", "-b", bundle_id])
    print(f"Opened app by bundle id: {bundle_id}")


def activate_app(app: str) -> None:
    run_osascript(f'tell application "{app}" to activate')
    print(f"Activated app: {app}")


def get_main_screen_size() -> ScreenSize:
    script = r'''
import AppKit
if let s = NSScreen.main {
  let f = s.frame
  print("\(f.size.width),\(f.size.height)")
} else {
  print("0,0")
}
'''
    # Call Swift with stdin payload.
    p = subprocess.run(
        ["swift", "-"],
        input=script,
        text=True,
        capture_output=True,
        check=True,
    )
    out = p.stdout.strip().splitlines()[-1].strip()
    parts = [x.strip() for x in out.split(",")]
    if len(parts) != 2:
        raise RuntimeError(f"Cannot parse screen size from swift output: {out!r}")
    return ScreenSize(width=float(parts[0]), height=float(parts[1]))


def convert_point(
    x: float,
    y: float,
    *,
    coord_space: str,
    origin: str,
    size: ScreenSize,
) -> tuple[float, float]:
    if coord_space == "normalized":
        x = (x / 1000.0) * size.width
        y = (y / 1000.0) * size.height

    # CGEvent uses bottom-left origin in global display coordinates.
    if origin == "top-left":
        y = size.height - y

    return x, y


def swift_mouse_action(
    mode: str,
    *,
    x: float,
    y: float,
    x2: Optional[float] = None,
    y2: Optional[float] = None,
    duration_ms: int = 300,
    hold_ms: int = 80,
    down_ms: int = 20,
) -> None:
    if mode not in {"click", "swipe"}:
        raise ValueError(f"Unsupported mode: {mode}")

    args = {
        "mode": mode,
        "x": x,
        "y": y,
        "x2": x2,
        "y2": y2,
        "duration_ms": int(duration_ms),
        "hold_ms": int(hold_ms),
        "down_ms": int(down_ms),
    }

    script = r'''
import Foundation
import CoreGraphics

let json = "__ARGS_JSON__"
let data = json.data(using: .utf8)!
let obj = try! JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]
let mode = obj["mode"] as! String
let x = (obj["x"] as! NSNumber).doubleValue
let y = (obj["y"] as! NSNumber).doubleValue
let x2 = (obj["x2"] as? NSNumber)?.doubleValue
let y2 = (obj["y2"] as? NSNumber)?.doubleValue
let durationMs = (obj["duration_ms"] as! NSNumber).intValue
let holdMs = (obj["hold_ms"] as! NSNumber).intValue
let downMs = (obj["down_ms"] as! NSNumber).intValue

let src = CGEventSource(stateID: .hidSystemState)
let button: CGMouseButton = .left

func post(_ type: CGEventType, _ p: CGPoint) {
  guard let ev = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button) else {
    return
  }
  ev.post(tap: .cghidEventTap)
}

let p1 = CGPoint(x: x, y: y)
post(.mouseMoved, p1)
post(.leftMouseDown, p1)
if downMs > 0 { usleep(useconds_t(downMs * 1000)) }

if mode == "click" {
  post(.leftMouseUp, p1)
  exit(0)
}

guard let xx2 = x2, let yy2 = y2 else {
  post(.leftMouseUp, p1)
  exit(2)
}

let p2 = CGPoint(x: xx2, y: yy2)
let steps = max(2, durationMs / 16)
for i in 1...steps {
  let t = Double(i) / Double(steps)
  let px = p1.x + (p2.x - p1.x) * t
  let py = p1.y + (p2.y - p1.y) * t
  post(.leftMouseDragged, CGPoint(x: px, y: py))
  usleep(useconds_t(max(1, durationMs / steps) * 1000))
}

if holdMs > 0 {
  usleep(useconds_t(holdMs * 1000))
}
post(.leftMouseUp, p2)
'''
    script = script.replace(
        "__ARGS_JSON__",
        json.dumps(args).replace("\\", "\\\\").replace("\"", "\\\""),
    )

    p = subprocess.run(["swift", "-"], input=script, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"swift mouse action failed, code={p.returncode}")


def screenshot(
    out_path: str,
    *,
    region: Optional[tuple[float, float, float, float]] = None,
    coord_space: str,
    origin: str,
) -> None:
    out_path = os.path.abspath(out_path)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    cmd = ["screencapture", "-x"]
    if region is not None:
        size = get_main_screen_size()
        x, y, w, h = region

        if coord_space == "normalized":
            x = (x / 1000.0) * size.width
            y = (y / 1000.0) * size.height
            w = (w / 1000.0) * size.width
            h = (h / 1000.0) * size.height

        # screencapture -R expects top-left origin.
        if origin == "bottom-left":
            y = size.height - y - h

        rect = f"{int(round(x))},{int(round(y))},{int(round(w))},{int(round(h))}"
        cmd += ["-R", rect]

    cmd.append(out_path)
    run(cmd)
    print(out_path)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="macOS local UI remote tool: open/activate/click/swipe/screenshot"
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_open = sub.add_parser("open", help="Open and activate app")
    p_open.add_argument("--app", help='App display name, e.g. "Safari"')
    p_open.add_argument("--bundle-id", help='Bundle id, e.g. "com.apple.Safari"')

    p_activate = sub.add_parser("activate", help="Activate app")
    p_activate.add_argument("--app", required=True)

    p_size = sub.add_parser("size", help="Print main screen size in points")

    for name in ["click", "swipe"]:
        p = sub.add_parser(name, help=f"{name} at coordinates")
        p.add_argument("--coord-space", choices=["absolute", "normalized"], default="absolute")
        p.add_argument("--origin", choices=["top-left", "bottom-left"], default="top-left")
        p.add_argument("--x", type=float, required=True)
        p.add_argument("--y", type=float, required=True)
        if name == "swipe":
            p.add_argument("--x2", type=float, required=True)
            p.add_argument("--y2", type=float, required=True)
            p.add_argument("--duration-ms", type=int, default=300)
            p.add_argument("--hold-ms", type=int, default=120)
        else:
            p.add_argument("--down-ms", type=int, default=20)

    p_ss = sub.add_parser("screenshot", help="Take screenshot")
    p_ss.add_argument("--out", required=True)
    p_ss.add_argument("--coord-space", choices=["absolute", "normalized"], default="absolute")
    p_ss.add_argument("--origin", choices=["top-left", "bottom-left"], default="top-left")
    p_ss.add_argument("--x", type=float)
    p_ss.add_argument("--y", type=float)
    p_ss.add_argument("--w", type=float)
    p_ss.add_argument("--h", type=float)

    args = ap.parse_args()

    if args.cmd == "open":
        open_app(args.app, args.bundle_id)
        return 0

    if args.cmd == "activate":
        activate_app(args.app)
        return 0

    if args.cmd == "size":
        sz = get_main_screen_size()
        print(json.dumps({"width": sz.width, "height": sz.height}))
        return 0

    if args.cmd == "click":
        size = get_main_screen_size()
        x, y = convert_point(args.x, args.y, coord_space=args.coord_space, origin=args.origin, size=size)
        swift_mouse_action("click", x=x, y=y, down_ms=args.down_ms)
        print(json.dumps({"ok": True, "action": "click", "x": x, "y": y}))
        return 0

    if args.cmd == "swipe":
        size = get_main_screen_size()
        x1, y1 = convert_point(args.x, args.y, coord_space=args.coord_space, origin=args.origin, size=size)
        x2, y2 = convert_point(args.x2, args.y2, coord_space=args.coord_space, origin=args.origin, size=size)
        swift_mouse_action(
            "swipe",
            x=x1,
            y=y1,
            x2=x2,
            y2=y2,
            duration_ms=args.duration_ms,
            hold_ms=args.hold_ms,
        )
        print(json.dumps({"ok": True, "action": "swipe", "x1": x1, "y1": y1, "x2": x2, "y2": y2, "duration_ms": args.duration_ms, "hold_ms": args.hold_ms}))
        return 0

    if args.cmd == "screenshot":
        has_region = all(v is not None for v in [args.x, args.y, args.w, args.h])
        if any(v is not None for v in [args.x, args.y, args.w, args.h]) and not has_region:
            raise SystemExit("If region is provided, --x --y --w --h must all be set")
        region = (args.x, args.y, args.w, args.h) if has_region else None
        screenshot(args.out, region=region, coord_space=args.coord_space, origin=args.origin)
        return 0

    raise SystemExit(2)


if __name__ == "__main__":
    sys.exit(main())
