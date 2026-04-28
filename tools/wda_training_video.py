#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:  # pragma: no cover - handled at runtime for users.
    Image = None  # type: ignore[assignment]
    ImageDraw = None  # type: ignore[assignment]
    ImageFont = None  # type: ignore[assignment]


Color = Tuple[int, int, int]
Rgba = Tuple[int, int, int, int]

BG = (241, 245, 249)
PANEL = (255, 255, 255)
SOFT_PANEL = (248, 250, 252)
TEXT = (15, 23, 42)
MUTED = (100, 116, 139)
LINE = (203, 213, 225)
TEAL = (15, 118, 110)
BLUE = (37, 99, 235)
ORANGE = (249, 115, 22)
AMBER = (180, 83, 9)
GREEN = (21, 128, 61)
PURPLE = (124, 58, 237)
SLATE = (71, 85, 105)
MOMENTS_SAFE_AREA_RATIO = (0.108, 0.056, 0.0924, 0.056)


def _read_jsonl(path: Path) -> List[Dict[str, Any]]:
    items: List[Dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, 1):
            text = line.strip()
            if not text:
                continue
            try:
                obj = json.loads(text)
            except json.JSONDecodeError as e:
                raise ValueError(f"{path}:{line_no}: invalid JSONL: {e}") from e
            if isinstance(obj, dict):
                items.append(obj)
    return items


def _read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def _json_from_model_text(text: str) -> Dict[str, Any]:
    s = str(text or "").strip()
    if not s:
        return {}
    if s.startswith("```"):
        s = re.sub(r"^```(?:json)?\s*", "", s, flags=re.IGNORECASE)
        s = re.sub(r"\s*```$", "", s)
    candidates = [s]
    first = s.find("{")
    last = s.rfind("}")
    if first >= 0 and last > first:
        candidates.append(s[first : last + 1])
    for candidate in candidates:
        try:
            obj = json.loads(candidate)
        except Exception:
            continue
        if isinstance(obj, dict):
            return obj
    return {}


def _terminal_from_action(action: Dict[str, Any]) -> bool:
    name = action.get("name") if isinstance(action.get("name"), str) else ""
    return name.strip().lower() in {"done", "finish", "finished", "stop"}


def _task_from_trace(trace: Dict[str, Any]) -> str:
    task = trace.get("task")
    if isinstance(task, str) and task:
        return task
    manifest = trace.get("manifest") if isinstance(trace.get("manifest"), dict) else {}
    task = manifest.get("task")
    return task if isinstance(task, str) else ""


def _config_from_trace(trace: Dict[str, Any]) -> Dict[str, Any]:
    cfg = trace.get("config") if isinstance(trace.get("config"), dict) else {}
    if cfg:
        return cfg
    manifest = trace.get("manifest") if isinstance(trace.get("manifest"), dict) else {}
    return manifest.get("config") if isinstance(manifest.get("config"), dict) else {}


def _canonical_response_for_turn(turn: Dict[str, Any]) -> Dict[str, Any]:
    response = turn.get("model_response") if isinstance(turn.get("model_response"), dict) else {}
    parse = turn.get("parse") if isinstance(turn.get("parse"), dict) else {}
    try:
        attempt_used = int(parse.get("attempt_used"))
    except Exception:
        attempt_used = 0
    if attempt_used <= 0:
        return response
    attempts = turn.get("repair_attempts") if isinstance(turn.get("repair_attempts"), list) else []
    for attempt in attempts:
        if not isinstance(attempt, dict):
            continue
        try:
            current = int(attempt.get("attempt"))
        except Exception:
            current = -1
        if current != attempt_used:
            continue
        repair_response = attempt.get("response") if isinstance(attempt.get("response"), dict) else {}
        if repair_response:
            return repair_response
    return response


def _canonical_parsed_json_for_turn(turn: Dict[str, Any], response: Dict[str, Any]) -> Dict[str, Any]:
    parse = turn.get("parse") if isinstance(turn.get("parse"), dict) else {}
    parsed_json = parse.get("action") if isinstance(parse.get("action"), dict) else {}
    if parsed_json:
        return parsed_json
    return _json_from_model_text(str(response.get("content") or ""))


def _canonical_image_for_turn(turn: Dict[str, Any]) -> str:
    state = turn.get("state") if isinstance(turn.get("state"), dict) else {}
    image = state.get("image") if isinstance(state.get("image"), dict) else {}
    ref = image.get("ref")
    return ref if isinstance(ref, str) else ""


def _samples_from_trace(trace: Dict[str, Any]) -> List[Dict[str, Any]]:
    run_id = trace.get("run_id") if isinstance(trace.get("run_id"), str) else ""
    task = _task_from_trace(trace)
    cfg = _config_from_trace(trace)
    model = trace.get("model") if isinstance(trace.get("model"), str) else str(cfg.get("model") or "")
    api_mode = trace.get("api_mode") if isinstance(trace.get("api_mode"), str) else str(cfg.get("api_mode") or "")
    turns = trace.get("turns") if isinstance(trace.get("turns"), list) else []
    samples: List[Dict[str, Any]] = []
    for index, turn_obj in enumerate(turns):
        if not isinstance(turn_obj, dict):
            continue
        step = turn_obj.get("step") if isinstance(turn_obj.get("step"), int) else index
        state = turn_obj.get("state") if isinstance(turn_obj.get("state"), dict) else {}
        req = turn_obj.get("request") if isinstance(turn_obj.get("request"), dict) else {}
        if not req and state:
            req = {"text": state.get("user_text", ""), "parsed": {}}
        resp = turn_obj.get("response") if isinstance(turn_obj.get("response"), dict) else {}
        if not resp and isinstance(turn_obj.get("model_response"), dict):
            resp = _canonical_response_for_turn(turn_obj)
        action = resp.get("action") if isinstance(resp.get("action"), dict) else {}
        parsed_json = resp.get("parsed_json") if isinstance(resp.get("parsed_json"), dict) else {}
        if not parsed_json and "parse" in turn_obj:
            parsed_json = _canonical_parsed_json_for_turn(turn_obj, resp)
        if not parsed_json:
            parsed_json = _json_from_model_text(str(resp.get("content") or ""))
        if not action and isinstance(parsed_json.get("action"), dict):
            action = parsed_json["action"]
        image = turn_obj.get("image") if isinstance(turn_obj.get("image"), str) else _canonical_image_for_turn(turn_obj)
        samples.append(
            {
                "id": f"{run_id}_step_{step:04d}" if run_id else f"trace_step_{step:04d}",
                "run_id": run_id,
                "step": step,
                "task": task,
                "input": {
                    "text": req.get("text") if isinstance(req.get("text"), str) else "",
                    "parsed": req.get("parsed") if isinstance(req.get("parsed"), dict) else {},
                    "image": image,
                },
                "assistant": {
                    "content": resp.get("content") if isinstance(resp.get("content"), str) else "",
                    "reasoning": resp.get("reasoning") if isinstance(resp.get("reasoning"), str) else "",
                    "action": action if isinstance(action, dict) else {},
                    "parsed_json": parsed_json if isinstance(parsed_json, dict) else {},
                },
                "meta": {
                    "response_ts": resp.get("ts", "") if isinstance(resp.get("ts"), str) else "",
                    "source_model": model,
                    "api_mode": api_mode,
                    "terminal": _terminal_from_action(action if isinstance(action, dict) else {}),
                    "source": "trace.json",
                },
            }
        )
    return samples


def _task_from_run_meta(run_meta: Dict[str, Any], samples: List[Dict[str, Any]]) -> str:
    source_config = run_meta.get("source_config") if isinstance(run_meta, dict) else {}
    task = source_config.get("task") if isinstance(source_config, dict) and isinstance(source_config.get("task"), str) else ""
    if task:
        return task
    return next((s.get("task") for s in samples if isinstance(s.get("task"), str) and s.get("task")), "")


def _load_visual_samples(dataset_dir: Path) -> Tuple[List[Dict[str, Any]], str, str]:
    trace_path = dataset_dir / "trace.json"
    if not trace_path.exists():
        raise FileNotFoundError(f"missing canonical trace.json: {trace_path}")
    trace = _read_json(trace_path, {})
    if not isinstance(trace, dict) or not isinstance(trace.get("turns"), list):
        raise ValueError(f"invalid canonical trace.json: {trace_path}")
    samples = _samples_from_trace(trace)
    task = _task_from_trace(trace)
    return samples, task, "trace.json"


def _ensure_pillow() -> bool:
    if Image is not None and ImageDraw is not None and ImageFont is not None:
        return True
    print("[error] Pillow is required for frame rendering.", file=sys.stderr)
    print("Install it in the Python environment you use to run this tool:", file=sys.stderr)
    print("  python -m pip install pillow", file=sys.stderr)
    return False


def _font_candidates(bold: bool) -> List[str]:
    if bold:
        return [
            r"C:\Windows\Fonts\msyhbd.ttc",
            r"C:\Windows\Fonts\simhei.ttf",
            r"C:\Windows\Fonts\seguisb.ttf",
            r"C:\Windows\Fonts\arialbd.ttf",
        ]
    return [
        r"C:\Windows\Fonts\msyh.ttc",
        r"C:\Windows\Fonts\simhei.ttf",
        r"C:\Windows\Fonts\segoeui.ttf",
        r"C:\Windows\Fonts\arial.ttf",
    ]


def _latin_font_candidates(bold: bool) -> List[str]:
    if bold:
        return [
            r"C:\Windows\Fonts\seguisb.ttf",
            r"C:\Windows\Fonts\segoeuib.ttf",
            r"C:\Windows\Fonts\arialbd.ttf",
            r"C:\Windows\Fonts\msyhbd.ttc",
        ]
    return [
        r"C:\Windows\Fonts\segoeui.ttf",
        r"C:\Windows\Fonts\arial.ttf",
            r"C:\Windows\Fonts\msyh.ttc",
    ]


def _load_font(size: int, *, bold: bool = False) -> Any:
    assert ImageFont is not None
    for path in _font_candidates(bold):
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                pass
    return ImageFont.load_default()


def _load_latin_font(size: int, *, bold: bool = False) -> Any:
    assert ImageFont is not None
    for path in _latin_font_candidates(bold):
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                pass
    return _load_font(size, bold=bold)


def _text_bbox(draw: Any, text: str, font: Any) -> Tuple[int, int, int, int]:
    try:
        return draw.textbbox((0, 0), text, font=font)
    except Exception:
        w, h = draw.textsize(text, font=font)
        return 0, 0, w, h


def _text_size(draw: Any, text: str, font: Any) -> Tuple[int, int]:
    box = _text_bbox(draw, text, font)
    return box[2] - box[0], box[3] - box[1]


def _truncate_text(draw: Any, text: str, font: Any, max_width: int) -> str:
    value = str(text or "").replace("\r", " ").replace("\n", " ").strip()
    if not value:
        return ""
    if _text_size(draw, value, font)[0] <= max_width:
        return value
    suffix = "..."
    lo = 0
    hi = len(value)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        candidate = value[:mid].rstrip() + suffix
        if _text_size(draw, candidate, font)[0] <= max_width:
            lo = mid
        else:
            hi = mid - 1
    return value[:lo].rstrip() + suffix


def _wrap_text(draw: Any, text: str, font: Any, max_width: int, max_lines: int) -> List[str]:
    normalized = str(text or "").replace("\r", "\n").strip()
    if not normalized:
        return []
    lines: List[str] = []
    for block in normalized.splitlines():
        block = block.strip()
        if not block:
            continue
        current = ""
        chars = list(block)
        for i, ch in enumerate(chars):
            candidate = current + ch
            if not current or _text_size(draw, candidate, font)[0] <= max_width:
                current = candidate
                continue
            lines.append(current)
            current = ch
            if len(lines) >= max_lines:
                lines[-1] = _truncate_text(draw, lines[-1] + "".join(chars[i:]), font, max_width)
                return lines
        if current:
            lines.append(current)
        if len(lines) >= max_lines:
            return lines[:max_lines]
    return lines[:max_lines]


def _note_lines(draw: Any, text: str, font: Any, max_width: int, max_lines: int = 6) -> List[str]:
    raw = str(text or "").strip()
    if not raw:
        return []
    lines = [line.strip() for line in raw.splitlines() if line.strip()]
    if not lines:
        lines = [raw]
    selected = lines[:max_lines]
    if len(lines) > max_lines and selected:
        selected[-1] = selected[-1] + " ..."
    return [_truncate_text(draw, line, font, max_width) for line in selected]


def _rounded(draw: Any, box: Tuple[int, int, int, int], radius: int, fill: Color | Rgba, outline: Optional[Color | Rgba] = None, width: int = 1) -> None:
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def _shadow(base: Any, box: Tuple[int, int, int, int], radius: int = 18) -> None:
    assert Image is not None and ImageDraw is not None
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    x1, y1, x2, y2 = box
    for spread, alpha in [(18, 28), (10, 34), (4, 30)]:
        d.rounded_rectangle((x1 - spread, y1 - spread, x2 + spread, y2 + spread), radius=radius + spread, fill=(15, 23, 42, alpha))
    base.alpha_composite(overlay)


def _action(sample: Dict[str, Any]) -> Dict[str, Any]:
    assistant = sample.get("assistant")
    if isinstance(assistant, dict) and isinstance(assistant.get("action"), dict):
        return assistant["action"]
    return {}


def _action_name(sample: Dict[str, Any]) -> str:
    action = _action(sample)
    name = action.get("name")
    return name.strip() if isinstance(name, str) and name.strip() else "Unknown"


def _params(sample: Dict[str, Any]) -> Dict[str, Any]:
    action = _action(sample)
    params = action.get("params")
    return params if isinstance(params, dict) else {}


def _point(value: Any) -> Optional[Tuple[float, float]]:
    if not isinstance(value, list) or len(value) < 2:
        return None
    try:
        x = float(value[0])
        y = float(value[1])
    except Exception:
        return None
    if not math.isfinite(x) or not math.isfinite(y):
        return None
    return max(0.0, min(1000.0, x)), max(0.0, min(1000.0, y))


def _map_point(point: Tuple[float, float], phone_box: Tuple[int, int, int, int]) -> Tuple[int, int]:
    x1, y1, x2, y2 = phone_box
    return int(x1 + point[0] / 1000.0 * (x2 - x1)), int(y1 + point[1] / 1000.0 * (y2 - y1))


def _draw_label(draw: Any, text: str, anchor: Tuple[int, int], font: Any) -> None:
    x, y = anchor
    label = _truncate_text(draw, text, font, 160)
    tw, th = _text_size(draw, label, font)
    bx1 = x + 14
    if bx1 + tw + 18 > 1260:
        bx1 = x - tw - 28
    by1 = max(18, y - th - 18)
    box = (bx1, by1, bx1 + tw + 16, by1 + th + 10)
    _rounded(draw, box, 7, (15, 23, 42, 224))
    draw.text((box[0] + 8, box[1] + 4), label, fill=(255, 255, 255), font=font)


def _draw_crosshair(draw: Any, center: Tuple[int, int], *, kind: str, label: str, label_font: Any) -> None:
    x, y = center
    color = TEAL
    radius = 16 if kind == "tap" else 19
    if kind == "double":
        draw.ellipse((x - 23, y - 23, x + 23, y + 23), outline=(15, 118, 110, 70), width=6)
    if kind == "long":
        for start in range(0, 360, 30):
            draw.arc((x - 23, y - 23, x + 23, y + 23), start, start + 16, fill=color, width=4)
    else:
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=(15, 118, 110, 34), outline=(255, 255, 255), width=7)
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), outline=color, width=4)
    draw.line((x - 10, y, x + 10, y), fill=color, width=3)
    draw.line((x, y - 10, x, y + 10), fill=color, width=3)
    _draw_label(draw, label, (x, y), label_font)


def _draw_arrow(draw: Any, start: Tuple[int, int], end: Tuple[int, int], label_font: Any) -> None:
    x1, y1 = start
    x2, y2 = end
    draw.line((x1, y1, x2, y2), fill=(255, 255, 255), width=11)
    draw.line((x1, y1, x2, y2), fill=ORANGE, width=6)
    angle = math.atan2(y2 - y1, x2 - x1)
    size = 18
    left = (x2 - size * math.cos(angle - math.pi / 6), y2 - size * math.sin(angle - math.pi / 6))
    right = (x2 - size * math.cos(angle + math.pi / 6), y2 - size * math.sin(angle + math.pi / 6))
    draw.polygon([(x2, y2), left, right], fill=ORANGE)
    draw.ellipse((x1 - 10, y1 - 10, x1 + 10, y1 + 10), fill=(14, 165, 233), outline=(255, 255, 255), width=4)
    draw.ellipse((x2 - 10, y2 - 10, x2 + 10, y2 + 10), fill=ORANGE, outline=(255, 255, 255), width=4)
    _draw_label(draw, "Swipe", (x2, y2), label_font)


def _panel_color(kind: str) -> Color:
    lower = kind.lower()
    if lower == "launch":
        return TEAL
    if lower == "type":
        return AMBER
    if lower == "wait":
        return BLUE
    if lower == "finish":
        return GREEN
    if lower in {"home", "back"}:
        return PURPLE
    return SLATE


def _draw_action_panel(
    frame: Any,
    box: Tuple[int, int, int, int],
    *,
    title: str,
    lines: List[str],
    placement: str,
    token_color: Color,
    title_font: Any,
    text_font: Any,
) -> None:
    assert Image is not None and ImageDraw is not None
    x1, y1, x2, y2 = box
    margin = 16
    width = x2 - x1 - margin * 2
    measure = ImageDraw.Draw(frame)
    line_h = max(18, _text_size(measure, "Ag", text_font)[1] + 6)
    note_mode = title.lower() == "note"
    if note_mode:
        panel_h = 46 + min(len(lines), 6) * line_h + 8
    else:
        panel_h = max(58, min(2, max(1, len(lines))) * line_h + 26)
    if placement == "top":
        px1, py1 = x1 + margin, y1 + margin
    elif placement == "center":
        px1, py1 = x1 + margin, y1 + (y2 - y1 - panel_h) // 2
    else:
        px1, py1 = x1 + margin, y2 - margin - panel_h
    px2, py2 = px1 + width, py1 + panel_h
    overlay = Image.new("RGBA", frame.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    for spread, alpha in [(12, 22), (4, 20)]:
        _rounded(d, (px1 - spread, py1 - spread, px2 + spread, py2 + spread), 12 + spread, (15, 23, 42, alpha))
    bg = (255, 251, 235, 240) if title.lower() == "type" else (240, 253, 244, 240) if title.lower() == "finish" else (255, 255, 255, 238)
    _rounded(d, (px1, py1, px2, py2), 8, bg, (203, 213, 225, 210), 1)
    token_w = max(64, _text_size(d, title, title_font)[0] + 24)
    token_h = max(25, _text_size(d, title, title_font)[1] + 10)
    if note_mode:
        _draw_pill(d, (px1 + 12, py1 + 10, px1 + 12 + token_w, py1 + 10 + token_h), title, token_color, title_font)
        ty = py1 + 44
        for line in lines[:6]:
            d.text((px1 + 14, ty), _truncate_text(d, line, text_font, width - 28), fill=TEXT, font=text_font)
            ty += line_h
    else:
        token_y = py1 + (panel_h - token_h) // 2
        _draw_pill(d, (px1 + 12, token_y, px1 + 12 + token_w, token_y + token_h), title, token_color, title_font)
        tx = px1 + 24 + token_w + 12
        ty = py1 + (panel_h - line_h * min(2, max(1, len(lines)))) // 2 - 1
        for line in lines[:2]:
            d.text((tx, ty), _truncate_text(d, line, text_font, px2 - tx - 12), fill=TEXT, font=text_font)
            ty += line_h
    frame.alpha_composite(overlay)


def _draw_action_overlay(
    frame: Any,
    sample: Dict[str, Any],
    phone_box: Tuple[int, int, int, int],
    fonts: Dict[str, Any],
) -> None:
    assert ImageDraw is not None
    draw = ImageDraw.Draw(frame, "RGBA")
    name = _action_name(sample)
    lower = name.lower()
    params = _params(sample)
    point = _point(params.get("element"))
    if point is not None:
        label = name
        kind = "tap"
        if "double" in lower:
            kind = "double"
        if "long" in lower:
            kind = "long"
            if params.get("seconds") is not None:
                label = f"{name} {params.get('seconds')}s"
        _draw_crosshair(draw, _map_point(point, phone_box), kind=kind, label=label, label_font=fonts["label"])
        return

    start = _point(params.get("start"))
    end = _point(params.get("end"))
    if start is not None and end is not None:
        _draw_arrow(draw, _map_point(start, phone_box), _map_point(end, phone_box), fonts["label"])
        return

    width = phone_box[2] - phone_box[0]
    text_width = max(80, width - 56)
    if lower == "type":
        lines = [_truncate_text(draw, str(params.get("text") or ""), fonts["small"], text_width)]
        _draw_action_panel(frame, phone_box, title="Type", lines=lines, placement="bottom", token_color=AMBER, title_font=fonts["chip"], text_font=fonts["small"])
    elif lower == "launch":
        lines = [_truncate_text(draw, str(params.get("app") or params.get("bundle_id") or "App"), fonts["small"], text_width)]
        _draw_action_panel(frame, phone_box, title="Launch", lines=lines, placement="top", token_color=TEAL, title_font=fonts["chip"], text_font=fonts["small"])
    elif lower == "wait":
        x1, y1, x2, y2 = phone_box
        cx = (x1 + x2) // 2
        cy = (y1 + y2) // 2 - 48
        draw.ellipse((cx - 16, cy - 16, cx + 16, cy + 16), outline=(37, 99, 235, 150), width=4, fill=(37, 99, 235, 28))
        lines = [f"{params.get('seconds')}s" if params.get("seconds") is not None else "until stable"]
        _draw_action_panel(frame, phone_box, title="Wait", lines=lines, placement="center", token_color=BLUE, title_font=fonts["chip"], text_font=fonts["small"])
    elif lower == "note":
        lines = _note_lines(draw, str(params.get("message") or ""), fonts["small"], text_width, 6)
        _draw_action_panel(frame, phone_box, title="Note", lines=lines, placement="bottom", token_color=SLATE, title_font=fonts["chip"], text_font=fonts["small"])
    elif lower == "finish":
        lines = _wrap_text(draw, str(params.get("message") or ""), fonts["small"], text_width, 4)
        _draw_action_panel(frame, phone_box, title="Finish", lines=lines, placement="bottom", token_color=GREEN, title_font=fonts["chip"], text_font=fonts["small"])
    elif lower == "home":
        x1, _, x2, y2 = phone_box
        cx = (x1 + x2) // 2
        draw.rounded_rectangle((cx - 58, y2 - 24, cx + 58, y2 - 18), radius=3, fill=(124, 58, 237, 230))
        _draw_action_panel(frame, phone_box, title="Home", lines=["Return to home screen"], placement="bottom", token_color=PURPLE, title_font=fonts["chip"], text_font=fonts["small"])
    elif lower == "back":
        x1, y1, _, y2 = phone_box
        cy = (y1 + y2) // 2
        draw.line((x1 + 48, cy - 20, x1 + 24, cy, x1 + 48, cy + 20), fill=PURPLE, width=6)
        _draw_action_panel(frame, phone_box, title="Back", lines=["Back gesture"], placement="top", token_color=PURPLE, title_font=fonts["chip"], text_font=fonts["small"])
    else:
        lines = [_truncate_text(draw, json.dumps(params, ensure_ascii=False), fonts["small"], text_width)]
        _draw_action_panel(frame, phone_box, title=name, lines=lines, placement="bottom", token_color=_panel_color(name), title_font=fonts["chip"], text_font=fonts["small"])


def _fit_image(size: Tuple[int, int], max_size: Tuple[int, int]) -> Tuple[int, int]:
    w, h = size
    mw, mh = max_size
    scale = min(mw / max(1, w), mh / max(1, h))
    return max(1, int(w * scale)), max(1, int(h * scale))


def _parse_safe_area(value: str) -> Tuple[int, int, int, int]:
    text = str(value or "").strip()
    if not text:
        return (0, 0, 0, 0)
    parts = [p for p in re.split(r"[\s,]+", text) if p]
    values: List[int] = []
    for part in parts:
        cleaned = part[:-2] if part.lower().endswith("px") else part
        try:
            number = int(round(float(cleaned)))
        except ValueError as e:
            raise ValueError(f"invalid --phone-safe-area value: {value!r}") from e
        if number < 0:
            raise ValueError("--phone-safe-area values must be >= 0")
        values.append(number)
    if len(values) == 1:
        top = right = bottom = left = values[0]
    elif len(values) == 2:
        top = bottom = values[0]
        right = left = values[1]
    elif len(values) == 3:
        top = values[0]
        right = left = values[1]
        bottom = values[2]
    elif len(values) == 4:
        top, right, bottom, left = values
    else:
        raise ValueError("--phone-safe-area expects 1 to 4 values, e.g. 137,33,117,33")
    return top, right, bottom, left


def _resolve_phone_safe_area(args: argparse.Namespace) -> Tuple[int, int, int, int]:
    if args.layout != "phone":
        if args.phone_safe_area or args.moments_safe_area:
            print("[warn] phone safe area is only used with --layout phone", flush=True)
        return (0, 0, 0, 0)
    if args.phone_safe_area:
        safe_area = _parse_safe_area(args.phone_safe_area)
    elif args.moments_safe_area:
        top_r, right_r, bottom_r, left_r = MOMENTS_SAFE_AREA_RATIO
        safe_area = (
            int(round(args.height * top_r)),
            int(round(args.width * right_r)),
            int(round(args.height * bottom_r)),
            int(round(args.width * left_r)),
        )
    else:
        safe_area = (0, 0, 0, 0)
    top, right, bottom, left = safe_area
    if left + right >= args.width or top + bottom >= args.height:
        raise ValueError(
            f"phone safe area {top},{right},{bottom},{left} leaves no room in "
            f"{args.width}x{args.height}"
        )
    return safe_area


def _load_sample_image(dataset_dir: Path, sample: Dict[str, Any]) -> Any:
    assert Image is not None
    input_obj = sample.get("input") if isinstance(sample.get("input"), dict) else {}
    rel = input_obj.get("image") if isinstance(input_obj.get("image"), str) else ""
    path = dataset_dir / rel
    if path.exists():
        return Image.open(path).convert("RGBA")
    img = Image.new("RGBA", (390, 844), (226, 232, 240, 255))
    d = ImageDraw.Draw(img)
    font = _load_font(24, bold=True)
    d.text((42, 390), "Missing image", fill=MUTED, font=font)
    return img


def _action_brief(draw: Any, sample: Dict[str, Any], font: Any, max_width: int) -> str:
    name = _action_name(sample)
    params = _params(sample)
    if _point(params.get("element")):
        p = _point(params.get("element"))
        assert p is not None
        return f"{name} [{int(p[0])}, {int(p[1])}]"
    if _point(params.get("start")) and _point(params.get("end")):
        s = _point(params.get("start"))
        e = _point(params.get("end"))
        assert s is not None and e is not None
        return f"{name} [{int(s[0])}, {int(s[1])}] -> [{int(e[0])}, {int(e[1])}]"
    if name.lower() == "type":
        return _truncate_text(draw, f"Type {params.get('text') or ''}", font, max_width)
    if name.lower() == "launch":
        return _truncate_text(draw, f"Launch {params.get('app') or params.get('bundle_id') or ''}", font, max_width)
    if name.lower() == "note":
        return _truncate_text(draw, f"Note {params.get('message') or ''}", font, max_width)
    if name.lower() == "finish":
        return _truncate_text(draw, f"Finish {params.get('message') or ''}", font, max_width)
    return _truncate_text(draw, name, font, max_width)


def _draw_pill(draw: Any, box: Tuple[int, int, int, int], text: str, fill: Color, font: Any, *, text_fill: Color = (255, 255, 255)) -> None:
    x1, y1, x2, y2 = box
    _rounded(draw, box, max(4, (y2 - y1) // 2), fill)
    tw, th = _text_size(draw, text, font)
    draw.text((x1 + (x2 - x1 - tw) // 2, y1 + (y2 - y1 - th) // 2 - 2), text, fill=text_fill, font=font)


def _action_detail_lines(draw: Any, sample: Dict[str, Any], font: Any, max_width: int) -> List[str]:
    name = _action_name(sample).lower()
    params = _params(sample)
    if name == "type":
        return [_truncate_text(draw, f"text: {params.get('text') or ''}", font, max_width)]
    if name == "launch":
        return [_truncate_text(draw, f"target: {params.get('app') or params.get('bundle_id') or 'App'}", font, max_width)]
    if name == "note":
        return _note_lines(draw, str(params.get("message") or ""), font, max_width, 4)
    if name == "finish":
        return _wrap_text(draw, str(params.get("message") or ""), font, max_width, 3)
    if _point(params.get("element")):
        p = _point(params.get("element"))
        assert p is not None
        return [f"element: [{int(p[0])}, {int(p[1])}]"]
    if _point(params.get("start")) and _point(params.get("end")):
        s = _point(params.get("start"))
        e = _point(params.get("end"))
        assert s is not None and e is not None
        return [f"start: [{int(s[0])}, {int(s[1])}]    end: [{int(e[0])}, {int(e[1])}]"]
    value = json.dumps(params, ensure_ascii=False)
    return [_truncate_text(draw, f"params: {value}", font, max_width)] if value != "{}" else ["params: {}"]


def _draw_section_card(
    draw: Any,
    *,
    x1: int,
    y: int,
    x2: int,
    title: str,
    lines: List[str],
    fonts: Dict[str, Any],
    max_lines: int,
) -> int:
    content_w = x2 - x1 - 32
    line_h = _text_size(draw, "Ag", fonts["small"])[1] + 9
    title_h = _text_size(draw, title, fonts["section"])[1] + 10
    used = lines[:max_lines]
    h = 22 + title_h + max(1, len(used)) * line_h + 14
    _rounded(draw, (x1, y, x2, y + h), 8, SOFT_PANEL, (226, 232, 240), 1)
    draw.text((x1 + 16, y + 12), title, fill=TEXT, font=fonts["section"])
    accent_w = min(86, max(36, _text_size(draw, title, fonts["section"])[0] + 18))
    draw.line((x1 + 16, y + 12 + title_h, x1 + 16 + accent_w, y + 12 + title_h), fill=TEAL, width=3)
    ty = y + 22 + title_h
    if used:
        for line in used:
            draw.text((x1 + 16, ty), _truncate_text(draw, line, fonts["small"], content_w), fill=TEXT, font=fonts["small"])
            ty += line_h
    else:
        draw.text((x1 + 16, ty), "-", fill=MUTED, font=fonts["small"])
    return y + h


def _draw_right_panel(
    frame: Any,
    sample: Dict[str, Any],
    index: int,
    total: int,
    task: str,
    fonts: Dict[str, Any],
    *,
    width: int,
    height: int,
    panel_x: int,
) -> None:
    assert ImageDraw is not None
    _shadow(frame, (panel_x, 40, width - 44, height - 64), radius=14)
    draw = ImageDraw.Draw(frame, "RGBA")
    x1, y1, x2, y2 = panel_x, 40, width - 44, height - 64
    _rounded(draw, (x1, y1, x2, y2), 14, PANEL, LINE, 1)
    name = _action_name(sample)
    chip_color = _panel_color(name)
    step = sample.get("step", index)
    step_label = f"Step {step}"

    margin = 30
    content_w = x2 - x1 - margin * 2
    small_h = _text_size(draw, "Ag", fonts["small"])[1]
    body_h = _text_size(draw, "Ag", fonts["body"])[1]
    line_h = small_h + 10
    section_gap = 14

    draw.text((x1 + margin, y1 + 26), step_label, fill=TEXT, font=fonts["title"])
    chip_text = name
    chip_w = max(76, _text_size(draw, chip_text, fonts["chip"])[0] + 24)
    chip_h = max(28, _text_size(draw, chip_text, fonts["chip"])[1] + 12)
    chip_y = y1 + 28
    _draw_pill(draw, (x2 - chip_w - margin, chip_y, x2 - margin, chip_y + chip_h), chip_text, chip_color, fonts["chip"])

    y = y1 + 86
    brief = _action_brief(draw, sample, fonts["body"], content_w)
    draw.text((x1 + margin, y), brief, fill=TEXT, font=fonts["body"])
    y += body_h + 18

    meta = sample.get("meta") if isinstance(sample.get("meta"), dict) else {}
    chip_x = x1 + margin
    meta_items = [
        (f"{index + 1}/{total}", TEAL),
        (str(meta.get("response_ts") or ""), SLATE),
    ]
    if meta.get("terminal"):
        meta_items.append(("terminal", GREEN))
    for text, color in meta_items:
        if not text:
            continue
        label = _truncate_text(draw, text, fonts["tiny"], 210)
        tw = _text_size(draw, label, fonts["tiny"])[0]
        box = (chip_x, y, chip_x + tw + 22, y + 25)
        _draw_pill(draw, box, label, color, fonts["tiny"])
        chip_x = box[2] + 8
        if chip_x > x2 - margin - 120:
            break
    y += 25 + 20

    assistant_obj = sample.get("assistant") if isinstance(sample.get("assistant"), dict) else {}
    parsed = assistant_obj.get("parsed_json") if isinstance(assistant_obj.get("parsed_json"), dict) else {}

    action_lines = _action_detail_lines(draw, sample, fonts["small"], content_w - 32)
    y = _draw_section_card(
        draw,
        x1=x1 + margin,
        y=y,
        x2=x2 - margin,
        title="Action",
        lines=action_lines,
        fonts=fonts,
        max_lines=4,
    )
    y += section_gap

    y = _draw_section_card(
        draw,
        x1=x1 + margin,
        y=y,
        x2=x2 - margin,
        title="Task",
        lines=_wrap_text(draw, task, fonts["small"], content_w - 32, 2),
        fonts=fonts,
        max_lines=2,
    )
    y += section_gap

    plan = parsed.get("plan") if isinstance(parsed, dict) else None
    if isinstance(plan, list) and plan:
        plan_lines_top = y
        plan_items: List[Tuple[str, str, Color]] = []
        for item in plan[:6]:
            if not isinstance(item, dict):
                continue
            done = bool(item.get("done"))
            state = "done" if done else "todo"
            color = GREEN if done else MUTED
            plan_items.append((state, str(item.get("text") or ""), color))
        plan_count = max(1, len(plan_items))
        plan_h = 52 + plan_count * max(line_h, 27) + 16
        _rounded(draw, (x1 + margin, y, x2 - margin, y + plan_h), 8, SOFT_PANEL, (226, 232, 240), 1)
        draw.text((x1 + margin + 16, y + 12), "Plan", fill=TEXT, font=fonts["section"])
        draw.line((x1 + margin + 16, y + 39, x1 + margin + 82, y + 39), fill=TEAL, width=3)
        y += 52
        for state, text, color in plan_items:
            pill_h = max(20, _text_size(draw, state, fonts["tiny"])[1] + 8)
            _draw_pill(draw, (x1 + margin + 16, y + 2, x1 + margin + 72, y + 2 + pill_h), state, color, fonts["tiny"])
            draw.text((x1 + margin + 88, y + 2), _truncate_text(draw, text, fonts["small"], content_w - 104), fill=TEXT, font=fonts["small"])
            y += max(line_h, pill_h + 4)
        y = plan_lines_top + plan_h + section_gap

    think = ""
    if isinstance(parsed, dict) and isinstance(parsed.get("think"), str):
        think = parsed["think"]
    elif isinstance(assistant_obj.get("reasoning"), str):
        think = assistant_obj["reasoning"]
    if y < y2 - 110 and think:
        _draw_section_card(
            draw,
            x1=x1 + margin,
            y=y,
            x2=x2 - margin,
            title="Think",
            lines=_wrap_text(draw, think, fonts["small"], content_w - 32, 4),
            fonts=fonts,
            max_lines=4,
        )

    progress_y = height - 34
    draw.line((44, progress_y, width - 44, progress_y), fill=(203, 213, 225), width=8)
    progress_x = 44 + int((width - 88) * ((index + 1) / max(1, total)))
    draw.line((44, progress_y, progress_x, progress_y), fill=TEAL, width=8)
    draw.text((44, progress_y - 28), f"{index + 1}/{total}", fill=MUTED, font=fonts["small"])


def _section(draw: Any, x: int, y: int, title: str, fonts: Dict[str, Any]) -> None:
    draw.text((x, y), title, fill=TEXT, font=fonts["section"])
    tw, _ = _text_size(draw, title, fonts["section"])
    draw.line((x, y + 24, x + tw + 26, y + 24), fill=TEAL, width=3)


def _render_frame(
    *,
    dataset_dir: Path,
    sample: Dict[str, Any],
    index: int,
    total: int,
    task: str,
    width: int,
    height: int,
    fonts: Dict[str, Any],
) -> Any:
    assert Image is not None and ImageDraw is not None
    frame = Image.new("RGBA", (width, height), BG + (255,))
    phone = _load_sample_image(dataset_dir, sample)
    phone_column = max(420, int(width * 0.38))
    phone_size = _fit_image(phone.size, (phone_column - 72, height - 96))
    phone = phone.resize(phone_size, Image.LANCZOS)
    phone_x = 56 + (phone_column - 72 - phone_size[0]) // 2
    phone_y = 40 + (height - 96 - phone_size[1]) // 2
    phone_box = (phone_x, phone_y, phone_x + phone_size[0], phone_y + phone_size[1])
    frame.alpha_composite(phone, (phone_x, phone_y))
    _draw_action_overlay(frame, sample, phone_box, fonts)
    _draw_right_panel(frame, sample, index, total, task, fonts, width=width, height=height, panel_x=max(520, phone_column + 32))
    return frame.convert("RGB")


def _render_phone_frame(
    *,
    dataset_dir: Path,
    sample: Dict[str, Any],
    index: int,
    total: int,
    width: int,
    height: int,
    safe_area: Tuple[int, int, int, int],
    fonts: Dict[str, Any],
) -> Any:
    assert Image is not None and ImageDraw is not None
    frame = Image.new("RGBA", (width, height), BG + (255,))
    phone = _load_sample_image(dataset_dir, sample)
    safe_top, safe_right, safe_bottom, safe_left = safe_area
    content_w = max(1, width - safe_left - safe_right)
    content_h = max(1, height - safe_top - safe_bottom)
    phone_size = _fit_image(phone.size, (content_w, content_h))
    phone = phone.resize(phone_size, Image.LANCZOS)
    phone_x = safe_left + (content_w - phone_size[0]) // 2
    phone_y = safe_top + (content_h - phone_size[1]) // 2
    phone_box = (phone_x, phone_y, phone_x + phone_size[0], phone_y + phone_size[1])
    frame.alpha_composite(phone, (phone_x, phone_y))
    _draw_action_overlay(frame, sample, phone_box, fonts)

    progress_y = height - 32
    draw = ImageDraw.Draw(frame, "RGBA")
    draw.line((24, progress_y, width - 24, progress_y), fill=(203, 213, 225), width=8)
    progress_x = 24 + int((width - 48) * ((index + 1) / max(1, total)))
    draw.line((24, progress_y, progress_x, progress_y), fill=TEAL, width=8)
    draw.text((24, progress_y - 30), f"{index + 1}/{total}", fill=MUTED, font=fonts["small"])
    return frame.convert("RGB")


def _quote_concat_path(path: Path) -> str:
    value = path.resolve().as_posix().replace("'", "'\\''")
    return f"file '{value}'"


def _write_concat(frames: List[Path], durations: List[float], concat_path: Path) -> None:
    lines: List[str] = []
    for frame, duration in zip(frames, durations):
        lines.append(_quote_concat_path(frame))
        lines.append(f"duration {duration:.3f}")
    if frames:
        lines.append(_quote_concat_path(frames[-1]))
    concat_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _ffmpeg_cmd(ffmpeg: str, concat_path: Path, out_path: Path, fps: int, crf: int, preset: str, tune: str, pix_fmt: str) -> List[str]:
    cmd = [
        ffmpeg,
        "-y",
        "-f",
        "concat",
        "-safe",
        "0",
        "-i",
        str(concat_path),
        "-r",
        str(fps),
    ]
    if pix_fmt == "yuv420p":
        cmd.extend(["-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2"])
    cmd.extend([
        "-c:v",
        "libx264",
        "-preset",
        preset,
        "-tune",
        tune,
        "-crf",
        str(crf),
        "-pix_fmt",
        pix_fmt,
        "-movflags",
        "+faststart",
        str(out_path),
    ])
    return cmd


def _sample_duration(args: argparse.Namespace, sample: Dict[str, Any]) -> float:
    meta = sample.get("meta") if isinstance(sample.get("meta"), dict) else {}
    if meta.get("terminal"):
        return args.terminal_seconds
    name = _action_name(sample).lower()
    if name == "note":
        return args.note_seconds
    if name == "type":
        return args.type_seconds
    return args.seconds_per_step


def _filter_samples(samples: List[Dict[str, Any]], start_step: Optional[int], end_step: Optional[int], limit: int) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for sample in samples:
        step = sample.get("step")
        if isinstance(step, int):
            if start_step is not None and step < start_step:
                continue
            if end_step is not None and step > end_step:
                continue
        out.append(sample)
        if limit > 0 and len(out) >= limit:
            break
    return out


def _sample_image_path(dataset_dir: Path, sample: Dict[str, Any]) -> Optional[Path]:
    input_obj = sample.get("input") if isinstance(sample.get("input"), dict) else {}
    rel = input_obj.get("image") if isinstance(input_obj.get("image"), str) else ""
    if not rel:
        return None
    path = dataset_dir / rel
    return path if path.exists() else None


def _image_size(path: Path) -> Optional[Tuple[int, int]]:
    if Image is not None:
        try:
            with Image.open(path) as img:
                return img.size
        except Exception:
            return None
    return None


def _resolve_video_size(args: argparse.Namespace, dataset_dir: Path, samples: List[Dict[str, Any]]) -> None:
    args.phone_safe_area_px = None
    if not args.auto_phone_size:
        return
    if args.layout != "phone":
        print("[warn] --auto-phone-size is only used with --layout phone", flush=True)
        return
    if not _ensure_pillow():
        raise RuntimeError("--auto-phone-size requires Pillow to read image dimensions")
    first_image: Optional[Path] = None
    first_size: Optional[Tuple[int, int]] = None
    size_counts: Dict[Tuple[int, int], int] = {}
    for sample in samples:
        image_path = _sample_image_path(dataset_dir, sample)
        if image_path is None:
            continue
        image_size = _image_size(image_path)
        if image_size is None:
            continue
        if first_image is None:
            first_image = image_path
            first_size = image_size
        size_counts[image_size] = size_counts.get(image_size, 0) + 1
    if first_image is None:
        raise RuntimeError("--auto-phone-size could not find a sample image")
    if first_size is None:
        raise RuntimeError(f"--auto-phone-size could not read image size: {first_image}")
    if len(size_counts) > 1:
        groups = ", ".join(f"{width}x{height}:{count}" for (width, height), count in sorted(size_counts.items()))
        print(
            "[warn] selected screenshots have mixed sizes; phone video uses one fixed canvas "
            f"based on the first readable image. sizes: {groups}",
            flush=True,
        )
    img_w, img_h = first_size
    if args.auto_phone_height and args.auto_phone_height > 0:
        args.height = int(args.auto_phone_height)
        args.width = int(round(args.height * img_w / img_h))
    else:
        args.width = int(img_w)
        args.height = int(img_h)
    print(f"auto phone size: {args.width}x{args.height} from {img_w}x{img_h}", flush=True)


def _script_json(obj: Any) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")


def _browser_frame_url(path: Path, index: int) -> str:
    uri = path.resolve().as_uri()
    return uri + "?" + urllib.parse.urlencode({"index": str(index)})


def _browser_candidates() -> List[Path]:
    env = os.environ.get("WDA_VIDEO_BROWSER") or os.environ.get("BROWSER")
    paths = [Path(env)] if env else []
    paths.extend(
        [
            Path(r"C:\Program Files\Microsoft\Edge\Application\msedge.exe"),
            Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"),
            Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe"),
            Path(r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"),
            Path(r"C:\Users\root\AppData\Local\Google\Chrome\Application\chrome.exe"),
        ]
    )
    return paths


def _find_browser(browser_exe: str) -> Optional[str]:
    if browser_exe.strip():
        p = Path(browser_exe)
        if p.exists():
            return str(p)
        found = shutil.which(browser_exe)
        return found
    for p in _browser_candidates():
        if p.exists():
            return str(p)
    for name in ["msedge", "chrome", "chromium"]:
        found = shutil.which(name)
        if found:
            return found
    return None


def _browser_image_path(dataset_dir: Path, html_dir: Path, image: Any) -> str:
    if not isinstance(image, str) or not image.strip():
        return ""
    value = image.strip().replace("\\", "/")
    lower = value.lower()
    if "://" in lower or lower.startswith("data:"):
        return value
    try:
        return os.path.relpath(dataset_dir / value, html_dir).replace("\\", "/")
    except ValueError:
        return str((dataset_dir / value).resolve()).replace("\\", "/")


def _browser_samples(samples: List[Dict[str, Any]], *, dataset_dir: Path, html_dir: Path) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for index, sample in enumerate(samples):
        assistant = sample.get("assistant") if isinstance(sample.get("assistant"), dict) else {}
        input_obj = sample.get("input") if isinstance(sample.get("input"), dict) else {}
        meta = sample.get("meta") if isinstance(sample.get("meta"), dict) else {}
        parsed = assistant.get("parsed_json") if isinstance(assistant.get("parsed_json"), dict) else {}
        out.append(
            {
                "index": index,
                "id": sample.get("id", ""),
                "step": sample.get("step", index),
                "task": sample.get("task", ""),
                "input": {
                    "image": _browser_image_path(dataset_dir, html_dir, input_obj.get("image", "")),
                    "text": input_obj.get("text", ""),
                },
                "assistant": {
                    "action": assistant.get("action", {}),
                    "parsed_json": parsed,
                },
                "meta": {
                    "response_ts": meta.get("response_ts", ""),
                    "terminal": bool(meta.get("terminal")),
                },
            }
        )
    return out


BROWSER_FRAME_TEMPLATE = r"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    :root {
      --bg: #f4f6f8;
      --panel: #ffffff;
      --soft: #f8fafc;
      --line: #d6dde5;
      --text: #0f172a;
      --muted: #64748b;
      --teal: #0f766e;
      --blue: #2563eb;
      --orange: #f97316;
      --amber: #b45309;
      --green: #15803d;
      --purple: #7c3aed;
      --slate: #475569;
      --phone-safe-top: __SAFE_TOP__px;
      --phone-safe-right: __SAFE_RIGHT__px;
      --phone-safe-bottom: __SAFE_BOTTOM__px;
      --phone-safe-left: __SAFE_LEFT__px;
    }
    * { box-sizing: border-box; }
    html, body {
      width: __WIDTH__px;
      height: __HEIGHT__px;
      margin: 0;
      overflow: hidden;
      background: var(--bg);
      color: var(--text);
      font: 18px/1.42 "Segoe UI", "Microsoft YaHei", "PingFang SC", Arial, sans-serif;
    }
    .frame {
      width: 100%;
      height: 100%;
      display: grid;
      grid-template-columns: 640px minmax(0, 1fr);
      gap: 34px;
      padding: 40px 44px 58px;
      position: relative;
    }
    .frame.phone-only {
      display: block;
      padding: 0;
      overflow: hidden;
    }
    .frame.phone-only .detail {
      display: none;
    }
    .frame.phone-only .phone-wrap {
      position: absolute;
      inset: var(--phone-safe-top) var(--phone-safe-right) var(--phone-safe-bottom) var(--phone-safe-left);
      width: auto;
      height: auto;
      display: block;
    }
    .frame.phone-only .stage {
      position: absolute;
      inset: 0;
      display: block;
      width: 100%;
      height: 100%;
      max-width: none;
      max-height: none;
      overflow: hidden;
    }
    .frame.phone-only #shot {
      position: absolute;
      inset: 0;
      width: 100%;
      height: 100%;
      max-width: none;
      max-height: none;
      object-fit: contain;
    }
    .frame.phone-only #overlay {
      inset: auto;
    }
    .frame.phone-only .progress-line,
    .frame.phone-only .progress-index {
      display: none;
    }
    .phone-wrap {
      display: flex;
      justify-content: center;
      align-items: center;
      min-width: 0;
      min-height: 0;
    }
    .stage {
      position: relative;
      display: inline-block;
      max-width: 100%;
      max-height: calc(100vh - 120px);
      background: transparent;
      border-radius: 0;
      box-shadow: none;
      overflow: visible;
    }
    #shot {
      display: block;
      width: auto;
      height: auto;
      max-width: min(560px, 100%);
      max-height: calc(100vh - 120px);
      object-fit: contain;
      border-radius: 0;
    }
    #overlay {
      position: absolute;
      inset: 0;
      pointer-events: none;
      overflow: visible;
    }
    .tap-marker {
      position: absolute;
      width: 53px;
      height: 53px;
      box-sizing: border-box;
      border: 4px solid var(--teal);
      border-radius: 50%;
      background: rgba(15, 118, 110, .14);
      box-shadow: 0 0 0 3px rgba(255, 255, 255, .9), 0 8px 18px rgba(15, 23, 42, .22);
      transform: translate(-50%, -50%);
    }
    .tap-marker::before,
    .tap-marker::after {
      content: "";
      position: absolute;
      left: 50%;
      top: 50%;
      background: var(--teal);
      border-radius: 999px;
      transform: translate(-50%, -50%);
    }
    .tap-marker::before { width: 32px; height: 4px; }
    .tap-marker::after { width: 4px; height: 32px; }
    .tap-marker.double {
      width: 93px;
      height: 93px;
      box-shadow: 0 0 0 3px rgba(255, 255, 255, .9), 0 0 0 10px rgba(15, 118, 110, .18), 0 8px 18px rgba(15, 23, 42, .22);
    }
    .tap-marker.long {
      width: 98px;
      height: 98px;
      border-style: dashed;
      background: rgba(15, 118, 110, .10);
      box-shadow: 0 0 0 3px rgba(255, 255, 255, .9), 0 0 0 13px rgba(15, 118, 110, .10), 0 8px 18px rgba(15, 23, 42, .22);
    }
    .action-label {
      position: absolute;
      max-width: 180px;
      padding: 6px 12px;
      border-radius: 8px;
      color: #fff;
      background: rgba(15, 23, 42, .82);
      box-shadow: 0 7px 16px rgba(15, 23, 42, .18);
      font-weight: 700;
      font-size: 24px;
      line-height: 1.25;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .action-label.left { transform: translate(27px, -86px); }
    .action-label.right { transform: translate(calc(-100% - 27px), -86px); }
    .swipe-line {
      position: absolute;
      height: 11px;
      border-radius: 999px;
      background: var(--orange);
      box-shadow: 0 0 0 2px rgba(255, 255, 255, .86), 0 7px 16px rgba(15, 23, 42, .2);
      transform-origin: 0 50%;
    }
    .swipe-line::after {
      content: "";
      position: absolute;
      right: -1px;
      top: 50%;
      width: 27px;
      height: 27px;
      border-top: 11px solid var(--orange);
      border-right: 11px solid var(--orange);
      transform: translateY(-50%) rotate(45deg);
    }
    .swipe-dot {
      position: absolute;
      width: 36px;
      height: 36px;
      border-radius: 50%;
      transform: translate(-50%, -50%);
      background: var(--orange);
      border: 3px solid rgba(255, 255, 255, .96);
      box-shadow: 0 5px 12px rgba(15, 23, 42, .2);
    }
    .swipe-dot.start { background: #0ea5e9; }
    .action-panel {
      position: absolute;
      left: 18px;
      right: 18px;
      display: grid;
      grid-template-columns: auto minmax(0, 1fr);
      gap: 10px;
      align-items: center;
      padding: 21px 24px;
      border-radius: 8px;
      color: var(--text);
      background: rgba(255, 255, 255, .92);
      border: 1px solid rgba(148, 163, 184, .65);
      box-shadow: 0 10px 24px rgba(15, 23, 42, .18);
      backdrop-filter: blur(8px);
    }
    .action-panel.top { top: 16px; }
    .action-panel.bottom { bottom: 18px; }
    .action-panel.center {
      top: 50%;
      left: 50%;
      right: auto;
      width: min(82%, 360px);
      transform: translate(-50%, -50%);
    }
    .action-token {
      min-width: 144px;
      padding: 11px 18px;
      border-radius: 999px;
      color: #fff;
      background: var(--slate);
      text-align: center;
      font-weight: 700;
      font-size: 24px;
      line-height: 1.15;
    }
    .action-copy { min-width: 0; }
    .action-copy strong { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 27px; line-height: 1.25; }
    .action-copy span { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #475569; font-size: 24px; margin-top: 3px; }
    .action-panel.launch .action-token { background: var(--teal); }
    .action-panel.type .action-token { background: var(--amber); }
    .action-panel.note .action-token { background: var(--slate); }
    .action-panel.wait .action-token { background: var(--blue); }
    .action-panel.finish .action-token { background: var(--green); }
    .action-panel.nav .action-token { background: var(--purple); }
    .action-panel.type { border-color: rgba(180, 83, 9, .45); background: rgba(255, 251, 235, .94); }
    .action-panel.finish { border-color: rgba(21, 128, 61, .45); background: rgba(240, 253, 244, .94); }
    .action-panel:not(.note) .action-copy strong {
      display: none;
    }
    .action-panel.note { align-items: start; grid-template-columns: 1fr; gap: 6px; }
    .action-panel.note .action-token { min-width: 0; width: fit-content; padding: 9px 21px; }
    .action-panel.note .action-copy strong { display: none; }
    .note-lines { display: grid; gap: 2px; min-width: 0; }
    .note-line { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 24px; line-height: 1.35; }
    .wait-pulse {
      position: absolute;
      left: 50%;
      top: calc(50% - 54px);
      width: 53px;
      height: 53px;
      box-sizing: border-box;
      border-radius: 50%;
      border: 3px solid rgba(37, 99, 235, .75);
      background: rgba(37, 99, 235, .12);
      transform: translate(-50%, -50%);
      box-shadow: 0 0 0 3px rgba(255, 255, 255, .9), 0 8px 18px rgba(15, 23, 42, .22);
    }
    .home-indicator {
      position: absolute;
      left: 50%;
      bottom: 14px;
      width: 174px;
      height: 8px;
      border-radius: 999px;
      background: rgba(124, 58, 237, .88);
      box-shadow: 0 0 0 2px rgba(255, 255, 255, .88), 0 6px 14px rgba(15, 23, 42, .18);
      transform: translateX(-50%);
    }
    .back-cue {
      position: absolute;
      left: 18px;
      top: 50%;
      width: 69px;
      height: 69px;
      border-left: 8px solid var(--purple);
      border-bottom: 8px solid var(--purple);
      transform: translateY(-50%) rotate(45deg);
      filter: drop-shadow(0 3px 4px rgba(15, 23, 42, .25));
    }
    .detail {
      min-width: 0;
      min-height: 0;
      border: 1px solid var(--line);
      border-radius: 14px;
      background: var(--panel);
      box-shadow: 0 12px 0 rgba(148, 163, 184, .24), 0 16px 34px rgba(15, 23, 42, .16);
      padding: 30px;
      overflow: hidden;
    }
    .topline {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 18px;
      align-items: start;
      margin-bottom: 14px;
    }
    h1 { margin: 0; font-size: 42px; line-height: 1.05; letter-spacing: 0; }
    .brief { margin-top: 12px; font-size: 28px; line-height: 1.22; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .badge {
      display: inline-block;
      border-radius: 999px;
      padding: 6px 16px;
      min-width: 76px;
      text-align: center;
      color: #fff;
      background: var(--slate);
      font-size: 16px;
      font-weight: 700;
      line-height: 1;
    }
    .badge.tap { background: var(--blue); }
    .badge.type { background: var(--amber); }
    .badge.swipe { background: var(--purple); }
    .badge.note { background: var(--slate); }
    .badge.finish { background: var(--green); }
    .badge.launch { background: var(--teal); }
    .chips { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 18px; }
    .chip {
      display: inline-flex;
      height: 25px;
      align-items: center;
      border-radius: 999px;
      padding: 0 12px;
      color: #fff;
      background: var(--slate);
      font-size: 12px;
      font-weight: 700;
    }
    .chip.progress { background: var(--teal); }
    .section {
      border: 1px solid #dce3ea;
      border-radius: 8px;
      background: var(--soft);
      padding: 14px 16px 16px;
      margin-bottom: 14px;
    }
    .section h2 {
      margin: 0 0 12px;
      display: inline-block;
      border-bottom: 3px solid var(--teal);
      font-size: 21px;
      line-height: 1.2;
    }
    .section p {
      margin: 0;
      font-size: 18px;
      line-height: 1.5;
      color: var(--text);
      display: -webkit-box;
      -webkit-box-orient: vertical;
      overflow: hidden;
    }
    .section.action p { -webkit-line-clamp: 4; }
    .section.task p { -webkit-line-clamp: 2; }
    .section.think p { -webkit-line-clamp: 4; }
    .plan-list { display: grid; gap: 8px; }
    .plan-item {
      display: grid;
      grid-template-columns: 58px minmax(0, 1fr);
      gap: 12px;
      align-items: center;
      min-height: 22px;
    }
    .state {
      display: inline-flex;
      height: 21px;
      align-items: center;
      justify-content: center;
      border-radius: 999px;
      color: #fff;
      background: var(--slate);
      font-size: 11px;
      font-weight: 700;
    }
    .state.done { background: var(--green); }
    .plan-text { overflow: hidden; white-space: nowrap; text-overflow: ellipsis; font-size: 18px; }
    .progress-line {
      position: absolute;
      left: 44px;
      right: 44px;
      bottom: 29px;
      height: 8px;
      border-radius: 999px;
      background: #d6dde5;
      overflow: hidden;
    }
    .progress-fill { height: 100%; width: 0; background: var(--teal); }
    .progress-index {
      position: absolute;
      left: 44px;
      bottom: 39px;
      color: var(--muted);
      font-size: 20px;
    }
  </style>
</head>
<body>
  <div id="frameRoot" class="frame">
    <section class="phone-wrap">
      <div class="stage">
        <img id="shot" alt="">
        <div id="overlay"></div>
      </div>
    </section>
    <section class="detail">
      <div class="topline">
        <div>
          <h1 id="stepTitle"></h1>
          <div id="brief" class="brief"></div>
        </div>
        <div id="actionBadge" class="badge"></div>
      </div>
      <div id="chips" class="chips"></div>
      <div class="section action"><h2>Action</h2><p id="actionText"></p></div>
      <div class="section task"><h2>Task</h2><p id="taskText"></p></div>
      <div class="section plan"><h2>Plan</h2><div id="planList" class="plan-list"></div></div>
      <div class="section think"><h2>Think</h2><p id="thinkText"></p></div>
    </section>
    <div id="progressIndex" class="progress-index"></div>
    <div class="progress-line"><div id="progressFill" class="progress-fill"></div></div>
  </div>
  <script id="viewer-data" type="application/json">__DATA_JSON__</script>
  <script>
    const DATA = JSON.parse(document.getElementById("viewer-data").textContent);
    const samples = DATA.samples || [];
    const params = new URLSearchParams(location.search);
    const selected = Math.max(0, Math.min(samples.length - 1, Number(params.get("index") || 0)));
    const sample = samples[selected] || {};
    const $ = (id) => document.getElementById(id);
    function escapeHtml(value) {
      return String(value ?? "").replace(/[&<>"']/g, (ch) => ({
        "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
      }[ch]));
    }
    function action() { return sample?.assistant?.action || {}; }
    function actionName() { return String(action().name || "Unknown"); }
    function actionParams() { return action().params || {}; }
    function clamp(value) {
      const n = Number(value);
      if (!Number.isFinite(n)) return 0;
      return Math.max(0, Math.min(1000, n));
    }
    function pct(value) { return `${clamp(value) / 10}%`; }
    function point(value) {
      if (!Array.isArray(value) || value.length < 2) return null;
      return { x: clamp(value[0]), y: clamp(value[1]) };
    }
    function syncOverlayBox() {
      const overlay = $("overlay");
      const root = $("frameRoot");
      if (!root.classList.contains("phone-only")) {
        overlay.style.left = "";
        overlay.style.top = "";
        overlay.style.width = "";
        overlay.style.height = "";
        return overlay.clientWidth > 0 && overlay.clientHeight > 0;
      }
      const stage = document.querySelector(".stage");
      const shot = $("shot");
      const stageWidth = stage.clientWidth;
      const stageHeight = stage.clientHeight;
      if (!stageWidth || !stageHeight) return false;
      let imageWidth = stageWidth;
      let imageHeight = stageHeight;
      let left = 0;
      let top = 0;
      if (shot.naturalWidth && shot.naturalHeight) {
        const scale = Math.min(stageWidth / shot.naturalWidth, stageHeight / shot.naturalHeight);
        imageWidth = shot.naturalWidth * scale;
        imageHeight = shot.naturalHeight * scale;
        left = (stageWidth - imageWidth) / 2;
        top = (stageHeight - imageHeight) / 2;
      }
      overlay.style.left = `${left}px`;
      overlay.style.top = `${top}px`;
      overlay.style.width = `${imageWidth}px`;
      overlay.style.height = `${imageHeight}px`;
      return imageWidth > 0 && imageHeight > 0;
    }
    function div(className, style, text) {
      const el = document.createElement("div");
      el.className = className;
      for (const [key, value] of Object.entries(style || {})) el.style[key] = value;
      if (text !== undefined) el.textContent = text;
      return el;
    }
    function clip(value, max = 120) {
      const text = String(value ?? "").replace(/\s+/g, " ").trim();
      return text.length <= max ? text : `${text.slice(0, max - 3)}...`;
    }
    function noteLines(value, maxLines = 6) {
      const rawLines = String(value ?? "").split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
      const lines = rawLines.length ? rawLines : [String(value ?? "").trim()].filter(Boolean);
      const selected = lines.slice(0, maxLines);
      if (lines.length > maxLines && selected.length) selected[selected.length - 1] += " ...";
      return selected;
    }
    function actionPanel(kind, title, body, placement = "top") {
      const panel = div(`action-panel ${kind} ${placement}`, {});
      panel.innerHTML = `<div class="action-token"></div><div class="action-copy"><strong></strong><span></span></div>`;
      panel.querySelector(".action-token").textContent = title;
      panel.querySelector("strong").textContent = title;
      panel.querySelector("span").textContent = body || "";
      return panel;
    }
    function notePanel(message) {
      const panel = actionPanel("note", "Note", "", "bottom");
      const copy = panel.querySelector(".action-copy");
      copy.innerHTML = "";
      const lines = div("note-lines", {});
      for (const line of noteLines(message, 6)) lines.appendChild(div("note-line", {}, line));
      copy.appendChild(lines);
      return panel;
    }
    function markerLabel(text, x, y) {
      const side = x > 760 ? "right" : "left";
      return div(`action-label ${side}`, { left: pct(x), top: pct(y) }, text);
    }
    function renderOverlay() {
      const overlay = $("overlay");
      overlay.innerHTML = "";
      if (!syncOverlayBox()) return;
      const name = actionName();
      const lower = name.toLowerCase();
      const p = actionParams();
      const start = point(p.start);
      const end = point(p.end);
      if (start && end) {
        const width = overlay.clientWidth;
        const height = overlay.clientHeight;
        const x1 = start.x / 1000 * width;
        const y1 = start.y / 1000 * height;
        const x2 = end.x / 1000 * width;
        const y2 = end.y / 1000 * height;
        const dx = x2 - x1;
        const dy = y2 - y1;
        const length = Math.max(1, Math.hypot(dx, dy));
        const angle = Math.atan2(dy, dx) * 180 / Math.PI;
        overlay.appendChild(div("swipe-line", { left: `${x1}px`, top: `${y1}px`, width: `${length}px`, transform: `translateY(-50%) rotate(${angle}deg)` }));
        overlay.appendChild(div("swipe-dot start", { left: pct(start.x), top: pct(start.y) }));
        overlay.appendChild(div("swipe-dot end", { left: pct(end.x), top: pct(end.y) }));
        overlay.appendChild(markerLabel(name, end.x, end.y));
        return;
      }
      const pt = point(p.element);
      if (pt) {
        const cls = lower.includes("long") ? "tap-marker long" : lower.includes("double") ? "tap-marker double" : "tap-marker";
        overlay.appendChild(div(cls, { left: pct(pt.x), top: pct(pt.y) }));
        overlay.appendChild(markerLabel(lower.includes("long") && p.seconds ? `${name} ${p.seconds}s` : name, pt.x, pt.y));
        return;
      }
      if (lower === "type") overlay.appendChild(actionPanel("type", "Type", clip(p.text || "", 140), "bottom"));
      else if (lower === "launch") overlay.appendChild(actionPanel("launch", "Launch", clip(p.app || p.bundle_id || "App"), "top"));
      else if (lower === "wait") {
        overlay.appendChild(div("wait-pulse", {}));
        overlay.appendChild(actionPanel("wait", "Wait", p.seconds !== undefined ? `${p.seconds}s` : "until stable", "center"));
      }
      else if (lower === "note") overlay.appendChild(notePanel(p.message || ""));
      else if (lower === "finish") overlay.appendChild(actionPanel("finish", "Finish", clip(p.message || "", 150), "bottom"));
      else if (lower === "home") {
        overlay.appendChild(div("home-indicator", {}));
        overlay.appendChild(actionPanel("nav", "Home", "Return to home screen", "bottom"));
      }
      else if (lower === "back") {
        overlay.appendChild(div("back-cue", {}));
        overlay.appendChild(actionPanel("nav", "Back", "Back gesture", "top"));
      }
      else overlay.appendChild(actionPanel("note", name, clip(JSON.stringify(p), 150), "bottom"));
    }
    function actionBrief() {
      const name = actionName();
      const p = actionParams();
      const pt = point(p.element);
      if (pt) return `${name} [${Math.round(pt.x)}, ${Math.round(pt.y)}]`;
      if (point(p.start) && point(p.end)) {
        const s = point(p.start), e = point(p.end);
        return `${name} [${Math.round(s.x)}, ${Math.round(s.y)}] -> [${Math.round(e.x)}, ${Math.round(e.y)}]`;
      }
      if (name.toLowerCase() === "type") return `Type ${p.text || ""}`;
      if (name.toLowerCase() === "launch") return `Launch ${p.app || p.bundle_id || ""}`;
      if (name.toLowerCase() === "note") return `Note ${p.message || ""}`;
      if (name.toLowerCase() === "finish") return `Finish ${p.message || ""}`;
      return name;
    }
    function actionDetail() {
      const name = actionName().toLowerCase();
      const p = actionParams();
      const pt = point(p.element);
      if (pt) return `element: [${Math.round(pt.x)}, ${Math.round(pt.y)}]`;
      if (point(p.start) && point(p.end)) {
        const s = point(p.start), e = point(p.end);
        return `start: [${Math.round(s.x)}, ${Math.round(s.y)}]    end: [${Math.round(e.x)}, ${Math.round(e.y)}]`;
      }
      if (name === "type") return `text: ${p.text || ""}`;
      if (name === "launch") return `target: ${p.app || p.bundle_id || "App"}`;
      if (name === "note") return noteLines(p.message || "", 4).join("\n");
      if (name === "finish") return p.message || "";
      return JSON.stringify(p);
    }
    function badgeClass(name) {
      const lower = name.toLowerCase();
      if (lower.includes("tap")) return "tap";
      if (lower === "type") return "type";
      if (lower === "swipe") return "swipe";
      if (lower === "note") return "note";
      if (lower === "finish") return "finish";
      if (lower === "launch") return "launch";
      return "";
    }
    function renderDetails() {
      if (DATA.layout === "phone") return;
      const name = actionName();
      const parsed = sample?.assistant?.parsed_json || {};
      $("stepTitle").textContent = `Step ${sample.step ?? selected}`;
      $("brief").textContent = actionBrief();
      $("actionBadge").textContent = name;
      $("actionBadge").className = `badge ${badgeClass(name)}`;
      $("chips").innerHTML = "";
      $("chips").appendChild(div("chip progress", {}, `${selected + 1}/${samples.length}`));
      if (sample?.meta?.response_ts) $("chips").appendChild(div("chip", {}, sample.meta.response_ts));
      if (sample?.meta?.terminal) $("chips").appendChild(div("chip", {}, "terminal"));
      $("actionText").textContent = actionDetail();
      $("taskText").textContent = DATA.task || sample.task || "";
      const plan = Array.isArray(parsed.plan) ? parsed.plan.slice(0, 6) : [];
      $("planList").innerHTML = plan.map((item) => `<div class="plan-item"><span class="state ${item.done ? "done" : ""}">${item.done ? "done" : "todo"}</span><span class="plan-text">${escapeHtml(item.text || "")}</span></div>`).join("");
      $("thinkText").textContent = parsed.think || "";
      $("progressIndex").textContent = `${selected + 1}/${samples.length}`;
      $("progressFill").style.width = `${(selected + 1) / Math.max(1, samples.length) * 100}%`;
    }
    function init() {
      if (DATA.layout === "phone") document.getElementById("frameRoot").classList.add("phone-only");
      $("shot").src = sample?.input?.image || "";
      $("shot").addEventListener("load", renderOverlay);
      renderDetails();
      renderOverlay();
    }
    init();
  </script>
</body>
</html>
"""


def _write_browser_frame_html(
    path: Path,
    *,
    dataset_dir: Path,
    samples: List[Dict[str, Any]],
    task: str,
    width: int,
    height: int,
    layout: str,
    safe_area: Tuple[int, int, int, int],
) -> None:
    data = {
        "task": task,
        "layout": layout,
        "samples": _browser_samples(samples, dataset_dir=dataset_dir, html_dir=path.parent),
    }
    safe_top, safe_right, safe_bottom, safe_left = safe_area
    html = (
        BROWSER_FRAME_TEMPLATE.replace("__WIDTH__", str(width))
        .replace("__HEIGHT__", str(height))
        .replace("__SAFE_TOP__", str(safe_top))
        .replace("__SAFE_RIGHT__", str(safe_right))
        .replace("__SAFE_BOTTOM__", str(safe_bottom))
        .replace("__SAFE_LEFT__", str(safe_left))
        .replace("__DATA_JSON__", _script_json(data))
    )
    path.write_text(html, encoding="utf-8")


def _run_browser_screenshot(
    *,
    browser: Path,
    args: argparse.Namespace,
    profile_dir: Path,
    window_width: int,
    window_height: int,
    out: Path,
    url: str,
    cwd: Path,
) -> subprocess.CompletedProcess[str]:
    cmd = [
        browser,
        "--headless=new",
        "--disable-gpu",
        "--hide-scrollbars",
        "--allow-file-access-from-files",
        "--run-all-compositor-stages-before-draw",
        "--force-device-scale-factor=1",
        f"--virtual-time-budget={args.browser_virtual_time_ms}",
        f"--user-data-dir={profile_dir}",
        f"--window-size={window_width},{window_height}",
        f"--screenshot={out}",
        url,
    ]
    return subprocess.run(cmd, text=True, capture_output=True, cwd=str(cwd))


def _black_bbox(path: Path) -> Optional[Tuple[int, int, int, int]]:
    assert Image is not None
    image = Image.open(path).convert("RGB")
    px = image.load()
    min_x = image.width
    min_y = image.height
    max_x = -1
    max_y = -1
    for y in range(image.height):
        for x in range(image.width):
            r, g, b = px[x, y]
            if r < 4 and g < 4 and b < 4:
                min_x = min(min_x, x)
                min_y = min(min_y, y)
                max_x = max(max_x, x)
                max_y = max(max_y, y)
    if max_x < 0:
        return None
    return min_x, min_y, max_x + 1, max_y + 1


def _measure_browser_capture_padding(
    *,
    browser: Path,
    args: argparse.Namespace,
    frames_dir: Path,
    dataset_dir: Path,
) -> Tuple[int, int, int, int]:
    if not _ensure_pillow():
        raise RuntimeError("Browser renderer needs Pillow to crop headless screenshots")
    probe_html = frames_dir / "browser_viewport_probe.html"
    probe_png = frames_dir / "browser_viewport_probe.png"
    probe_profile = frames_dir / "browser_probe_profile"
    probe_profile.mkdir(parents=True, exist_ok=True)
    probe_html.write_text(
        """<!doctype html><meta charset="utf-8"><style>
html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#f4f6f8}
#viewport{position:fixed;inset:0;background:#000}
</style><div id="viewport"></div>""",
        encoding="utf-8",
    )
    probe_w = max(240, args.width + 96)
    probe_h = max(240, args.height + 128)
    proc = _run_browser_screenshot(
        browser=browser,
        args=args,
        profile_dir=probe_profile,
        window_width=probe_w,
        window_height=probe_h,
        out=probe_png,
        url=probe_html.resolve().as_uri(),
        cwd=dataset_dir,
    )
    if proc.returncode != 0 or not probe_png.exists():
        msg = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(f"Browser viewport probe failed: {msg[:1000]}")
    bbox = _black_bbox(probe_png)
    if bbox is None:
        raise RuntimeError("Browser viewport probe failed: could not find viewport marker")
    image = Image.open(probe_png)
    origin_x = max(0, bbox[0])
    origin_y = max(0, bbox[1])
    pad_right = max(0, image.width - bbox[2])
    pad_bottom = max(0, image.height - bbox[3])
    if origin_x or origin_y or pad_right or pad_bottom:
        print(
            f"browser capture padding: left {origin_x}px, top {origin_y}px, right {pad_right}px, bottom {pad_bottom}px",
            flush=True,
        )
    return origin_x, origin_y, pad_right, pad_bottom


def _crop_browser_frame(path: Path, width: int, height: int, origin_x: int, origin_y: int) -> None:
    assert Image is not None
    image = Image.open(path)
    if image.size == (width, height) and origin_x == 0 and origin_y == 0:
        return
    if image.width < origin_x + width or image.height < origin_y + height:
        raise RuntimeError(
            f"Browser screenshot is smaller than target crop: {image.width}x{image.height}, "
            f"crop origin {origin_x},{origin_y}, target {width}x{height}"
        )
    image.crop((origin_x, origin_y, origin_x + width, origin_y + height)).save(path)


def _render_browser_frames(
    *,
    args: argparse.Namespace,
    dataset_dir: Path,
    samples: List[Dict[str, Any]],
    task: str,
    frames_dir: Path,
) -> List[Path]:
    browser = _find_browser(args.browser_exe)
    if not browser:
        raise RuntimeError("No Edge/Chrome browser executable found. Pass --browser-exe or use --renderer pil.")

    html_path = frames_dir / "video_frame.html"
    _write_browser_frame_html(
        html_path,
        dataset_dir=dataset_dir,
        samples=samples,
        task=task,
        width=args.width,
        height=args.height,
        layout=args.layout,
        safe_area=args.phone_safe_area_px,
    )
    profile_dir = frames_dir / "browser_profile"
    profile_dir.mkdir(parents=True, exist_ok=True)
    origin_x, origin_y, pad_width, pad_height = _measure_browser_capture_padding(browser=browser, args=args, frames_dir=frames_dir, dataset_dir=dataset_dir)
    capture_width = args.width + origin_x + pad_width
    capture_height = args.height + origin_y + pad_height

    frame_paths: List[Path] = []
    for index, _sample in enumerate(samples):
        out = frames_dir / f"frame_{index:04d}.png"
        url = _browser_frame_url(html_path, index)
        proc = _run_browser_screenshot(
            browser=browser,
            args=args,
            profile_dir=profile_dir,
            window_width=capture_width,
            window_height=capture_height,
            out=out,
            url=url,
            cwd=dataset_dir,
        )
        if proc.returncode != 0 or not out.exists():
            msg = (proc.stderr or proc.stdout or "").strip()
            raise RuntimeError(f"Browser screenshot failed for frame {index}: {msg[:1000]}")
        _crop_browser_frame(out, args.width, args.height, origin_x, origin_y)
        frame_paths.append(out)
        if (index + 1) % 10 == 0 or index + 1 == len(samples):
            print(f"rendered browser frames: {index + 1}/{len(samples)}", flush=True)
    return frame_paths


def _render_pil_frames(
    *,
    args: argparse.Namespace,
    dataset_dir: Path,
    samples: List[Dict[str, Any]],
    task: str,
    frames_dir: Path,
) -> List[Path]:
    font_scale = max(0.9, min(args.width / 1920.0, args.height / 1080.0))
    fonts = {
        "title": _load_font(round(38 * font_scale), bold=True),
        "section": _load_font(round(20 * font_scale), bold=True),
        "body": _load_font(round(26 * font_scale), bold=True),
        "small": _load_font(round(18 * font_scale)),
        "tiny": _load_latin_font(round(13 * font_scale), bold=True),
        "chip": _load_latin_font(round(16 * font_scale), bold=True),
        "label": _load_latin_font(round(16 * font_scale), bold=True),
    }

    frame_paths: List[Path] = []
    total = len(samples)
    for index, sample in enumerate(samples):
        if args.layout == "phone":
            frame = _render_phone_frame(
                dataset_dir=dataset_dir,
                sample=sample,
                index=index,
                total=total,
                width=args.width,
                height=args.height,
                safe_area=args.phone_safe_area_px,
                fonts=fonts,
            )
        else:
            frame = _render_frame(
                dataset_dir=dataset_dir,
                sample=sample,
                index=index,
                total=total,
                task=task,
                width=args.width,
                height=args.height,
                fonts=fonts,
            )
        path = frames_dir / f"frame_{index:04d}.png"
        frame.save(path)
        frame_paths.append(path)
        if (index + 1) % 10 == 0 or index + 1 == total:
            print(f"rendered PIL frames: {index + 1}/{total}", flush=True)
    return frame_paths


def cmd_export(args: argparse.Namespace) -> int:
    if args.renderer == "pil" and not _ensure_pillow():
        return 2
    dataset_dir = Path(args.dataset_dir)
    try:
        samples, task, data_source = _load_visual_samples(dataset_dir)
    except FileNotFoundError as e:
        print(f"[error] {e}", file=sys.stderr)
        return 2
    print(f"data source: {data_source}", flush=True)
    samples = _filter_samples(samples, args.start_step, args.end_step, args.limit)
    if not samples:
        print("[error] no samples selected", file=sys.stderr)
        return 2
    _resolve_video_size(args, dataset_dir, samples)
    if args.phone_safe_area_px is None:
        args.phone_safe_area_px = _resolve_phone_safe_area(args)
    if args.phone_safe_area_px != (0, 0, 0, 0):
        top, right, bottom, left = args.phone_safe_area_px
        print(f"phone safe area: top {top}px, right {right}px, bottom {bottom}px, left {left}px", flush=True)

    if not task:
        task = next((s.get("task") for s in samples if isinstance(s.get("task"), str) and s.get("task")), "")

    out_path = Path(args.out) if args.out else dataset_dir / "trace_review.mp4"
    frames_dir = Path(args.frames_dir) if args.frames_dir else dataset_dir / "video_frames"
    if frames_dir.exists():
        shutil.rmtree(frames_dir)
    frames_dir.mkdir(parents=True, exist_ok=True)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    renderer = args.renderer
    if renderer == "auto":
        renderer = "browser" if _find_browser(args.browser_exe) else "pil"

    if renderer == "browser":
        try:
            frame_paths = _render_browser_frames(
                args=args,
                dataset_dir=dataset_dir,
                samples=samples,
                task=task,
                frames_dir=frames_dir,
            )
        except RuntimeError:
            if args.renderer != "auto":
                raise
            print("[warn] browser renderer unavailable; falling back to PIL", flush=True)
            if not _ensure_pillow():
                return 2
            frame_paths = _render_pil_frames(
                args=args,
                dataset_dir=dataset_dir,
                samples=samples,
                task=task,
                frames_dir=frames_dir,
            )
    else:
        if not _ensure_pillow():
            return 2
        frame_paths = _render_pil_frames(
            args=args,
            dataset_dir=dataset_dir,
            samples=samples,
            task=task,
            frames_dir=frames_dir,
        )

    durations: List[float] = []
    for sample in samples:
        durations.append(_sample_duration(args, sample))

    concat_path = frames_dir / "frames.txt"
    _write_concat(frame_paths, durations, concat_path)
    print(f"frames dir: {frames_dir}", flush=True)
    print(f"concat file: {concat_path}", flush=True)

    if args.skip_ffmpeg:
        print("skip ffmpeg: true", flush=True)
        return 0

    ffmpeg = args.ffmpeg
    if not shutil.which(ffmpeg) and not Path(ffmpeg).exists():
        print(f"[error] ffmpeg not found: {ffmpeg}", file=sys.stderr)
        return 2

    cmd = _ffmpeg_cmd(ffmpeg, concat_path, out_path, args.fps, args.crf, args.preset, args.tune, args.pix_fmt)
    print("running ffmpeg...", flush=True)
    proc = subprocess.run(cmd, text=True, capture_output=True)
    if proc.returncode != 0:
        print(proc.stdout, file=sys.stderr)
        print(proc.stderr, file=sys.stderr)
        return proc.returncode
    print(f"wrote video: {out_path}", flush=True)
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="wda_training_video.py",
        description="Render a WDA training dataset into a review MP4 with action overlays.",
    )
    p.add_argument("--dataset-dir", default=".", help="Directory containing canonical trace.json and images/")
    p.add_argument("--ffmpeg", default="ffmpeg", help="ffmpeg executable path")
    p.add_argument("--out", default="", help="Output MP4 path; defaults to <dataset-dir>/trace_review.mp4")
    p.add_argument("--frames-dir", default="", help="Temporary/generated frame directory; defaults to <dataset-dir>/video_frames")
    p.add_argument("--renderer", choices=["browser", "pil", "auto"], default="browser", help="Frame renderer. browser uses Edge/Chrome headless; pil is the dependency-light fallback")
    p.add_argument("--layout", choices=["review", "phone"], default="review", help="review renders phone plus right detail panel; phone renders only the phone area")
    p.add_argument("--auto-phone-size", action="store_true", help="With --layout phone, use the first screenshot size as the output canvas. Safe-area padding shrinks and centers the screenshot inside that canvas")
    p.add_argument("--auto-phone-height", type=int, default=0, help="Optional output height for --auto-phone-size; width is computed from screenshot ratio. 0 uses original screenshot pixels")
    p.add_argument("--phone-safe-area", default="", help="Reserved blank pixels for --layout phone, using CSS shorthand: TOP[,RIGHT,BOTTOM,LEFT]. Example: 137,33,117,33")
    p.add_argument("--moments-safe-area", action="store_true", help="Shortcut for WeChat Moments-style padding: about 10.8%% top, 9.2%% bottom, 5.6%% sides")
    p.add_argument("--browser-exe", default="", help="Path to msedge.exe/chrome.exe for --renderer browser")
    p.add_argument("--browser-virtual-time-ms", type=int, default=1000, help="Headless browser virtual time budget before each screenshot")
    p.add_argument("--width", type=int, default=1920, help="Video width")
    p.add_argument("--height", type=int, default=1080, help="Video height")
    p.add_argument("--fps", type=int, default=30, help="Output video FPS")
    p.add_argument("--crf", type=int, default=14, help="H.264 quality: lower is clearer/larger, common range 12-23")
    p.add_argument("--preset", default="slow", help="H.264 preset, e.g. medium, slow, veryslow")
    p.add_argument("--tune", default="stillimage", help="H.264 tune, default stillimage for UI screenshots")
    p.add_argument("--pix-fmt", default="yuv420p", choices=["yuv420p", "yuv444p"], help="Use yuv444p for sharper local review, yuv420p for compatibility")
    p.add_argument("--seconds-per-step", type=float, default=1.4, help="Default duration per step")
    p.add_argument("--type-seconds", type=float, default=1.8, help="Duration for Type steps")
    p.add_argument("--note-seconds", type=float, default=2.1, help="Duration for Note steps")
    p.add_argument("--terminal-seconds", type=float, default=2.4, help="Duration for terminal/Finish step")
    p.add_argument("--start-step", type=int, default=None, help="Only include samples with step >= this value")
    p.add_argument("--end-step", type=int, default=None, help="Only include samples with step <= this value")
    p.add_argument("--limit", type=int, default=0, help="Maximum number of selected samples, 0 means all")
    p.add_argument("--skip-ffmpeg", action="store_true", help="Only render frame PNGs and concat file")
    p.set_defaults(func=cmd_export)
    return p


def main(argv: List[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except (OSError, ValueError, RuntimeError) as e:
        print(f"[error] {e}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
