#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


DEFAULT_BASE_URL = os.environ.get("WDA_URL", "http://127.0.0.1:8100")
DEFAULT_AGENT_TOKEN = os.environ.get("WDA_AGENT_TOKEN", "")


class ApiError(RuntimeError):
    pass


@dataclass(frozen=True)
class ActionAnnotation:
    name: str
    kind: str
    x1: float = 0
    y1: float = 0
    x2: float = 0
    y2: float = 0


def _now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _join_url(base_url: str, path: str) -> str:
    base = (base_url or "").rstrip("/")
    if not path.startswith("/"):
        path = "/" + path
    return base + path


def _unwrap_wda_value(obj: Any) -> Any:
    if isinstance(obj, dict) and "value" in obj:
        return obj.get("value")
    return obj


def _http_get_json(base_url: str, path: str, *, token: str, timeout: float) -> Any:
    headers = {"Accept": "application/json"}
    if token.strip():
        headers["X-OnDevice-Agent-Token"] = token.strip()
    req = urllib.request.Request(_join_url(base_url, path), method="GET", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
            charset = resp.headers.get_content_charset() or "utf-8"
            text = body.decode(charset, errors="replace")
    except urllib.error.HTTPError as e:
        body = e.read() if e.fp else b""
        msg = body.decode("utf-8", errors="replace")
        raise ApiError(f"HTTP {e.code} {e.reason} for {req.full_url}\n{msg[:2000]}") from e
    except urllib.error.URLError as e:
        raise ApiError(f"Failed to connect to {req.full_url}: {e}") from e
    except Exception as e:  # noqa: BLE001
        raise ApiError(f"Request failed for {req.full_url}: {e}") from e

    try:
        return json.loads(text)
    except Exception as e:  # noqa: BLE001
        raise ApiError(f"Non-JSON response from {req.full_url}: {e}\n{text[:2000]}") from e


def _write_text(path: Path, data: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data, encoding="utf-8")


def _chunked(values: List[int], size: int) -> Iterable[List[int]]:
    if size <= 0:
        size = 30
    for i in range(0, len(values), size):
        yield values[i : i + size]


def _redact_sensitive_text(text: str) -> str:
    if not text:
        return ""
    replacements = [
        (r'(?i)"api_key"\s*:\s*"[^"]*"', '"api_key":"<redacted>"'),
        (r'(?i)"authorization"\s*:\s*"[^"]*"', '"authorization":"<redacted>"'),
        (r'(?i)"x-ondevice-agent-token"\s*:\s*"[^"]*"', '"X-OnDevice-Agent-Token":"<redacted>"'),
        (r'(?i)"ondevice_agent_token"\s*:\s*"[^"]*"', '"ondevice_agent_token":"<redacted>"'),
        (r'(?i)"agent_token"\s*:\s*"[^"]*"', '"agent_token":"<redacted>"'),
        (r"(?i)authorization:\s*bearer\s+[A-Za-z0-9._\\-]+", "Authorization: Bearer <redacted>"),
        (r"(?i)\bbearer\s+[A-Za-z0-9._\\-]{10,}", "Bearer <redacted>"),
        (r"(?i)data:image/?[^\"\\s]*base64,[^\"\\s]+", "data:image/png;base64,<omitted>"),
        (r"(?i)\bondevice_agent_token=([A-Za-z0-9%._\\-]{6,})", "ondevice_agent_token=<redacted>"),
        (r"(?i)([?&]token=)([A-Za-z0-9%._\\-]{6,})", r"\1<redacted>"),
    ]
    out = text
    for pattern, repl in replacements:
        out = re.sub(pattern, repl, out)
    return out


def _pretty_json_if_possible(text: str) -> str:
    s = (text or "").strip()
    if not s.startswith("{") and not s.startswith("["):
        return text or ""
    try:
        obj = json.loads(s)
    except Exception:
        return text or ""
    return json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=True)


def _to_int(value: Any, default: int = -1) -> int:
    try:
        if isinstance(value, bool):
            return default
        return int(value)
    except Exception:
        return default


def _to_float(value: Any) -> Optional[float]:
    try:
        if isinstance(value, bool):
            return None
        f = float(value)
        if not math.isfinite(f):
            return None
        return f
    except Exception:
        return None


def _point(value: Any) -> Optional[Tuple[float, float]]:
    if not isinstance(value, list) or len(value) < 2:
        return None
    x = _to_float(value[0])
    y = _to_float(value[1])
    if x is None or y is None:
        return None
    return x, y


def _json_from_model_text(text: str) -> Optional[Dict[str, Any]]:
    s = (text or "").strip()
    if not s:
        return None
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
    return None


def _parse_action_annotation(content: str) -> Optional[ActionAnnotation]:
    obj = _json_from_model_text(content)
    if not isinstance(obj, dict):
        return None
    action = obj.get("action")
    if not isinstance(action, dict):
        return None
    name = action.get("name")
    if not isinstance(name, str) or not name.strip():
        return None
    params = action.get("params")
    if not isinstance(params, dict):
        params = {}

    lower = name.strip().lower()
    if lower in {"tap", "doubletap", "double tap", "longpress", "long press"}:
        p = _point(params.get("element"))
        if p is None:
            return ActionAnnotation(name=name, kind="label")
        return ActionAnnotation(name=name, kind="tap", x1=p[0], y1=p[1])

    if lower == "swipe":
        start = _point(params.get("start"))
        end = _point(params.get("end"))
        if start is None or end is None:
            return ActionAnnotation(name=name, kind="label")
        return ActionAnnotation(name=name, kind="swipe", x1=start[0], y1=start[1], x2=end[0], y2=end[1])

    return ActionAnnotation(name=name, kind="label")


def _build_action_annotations(items: List[Dict[str, Any]]) -> Dict[int, ActionAnnotation]:
    by_step: Dict[int, List[Dict[str, Any]]] = {}
    for item in items:
        if item.get("kind") != "response":
            continue
        step = _to_int(item.get("step"))
        if step < 0:
            continue
        by_step.setdefault(step, []).append(item)

    out: Dict[int, ActionAnnotation] = {}
    for step, step_items in by_step.items():
        for item in reversed(step_items):
            content = item.get("content")
            if not isinstance(content, str) or not content:
                continue
            ann = _parse_action_annotation(content)
            if ann is not None:
                out[step] = ann
                break
    return out


def _request_steps(items: List[Dict[str, Any]]) -> List[int]:
    steps = set()
    for item in items:
        if item.get("kind") != "request" or item.get("attempt") is not None:
            continue
        step = _to_int(item.get("step"))
        if step >= 0:
            steps.add(step)
    return sorted(steps)


def _fetch_screenshots(
    *,
    base_url: str,
    token: str,
    timeout: float,
    steps: List[int],
    image_format: str,
    quality: float,
    chunk_size: int,
) -> Tuple[str, Dict[int, str], List[int]]:
    images: Dict[int, str] = {}
    missing = set()
    mime_type = "image/png"
    fmt = image_format.lower()
    if fmt == "jpg":
        fmt = "jpeg"

    for chunk in _chunked(steps, chunk_size):
        qs = urllib.parse.urlencode(
            {
                "steps": ",".join(str(s) for s in chunk),
                "format": fmt,
                "quality": str(quality),
            }
        )
        obj = _unwrap_wda_value(_http_get_json(base_url, f"/agent/step_screenshots?{qs}", token=token, timeout=timeout))
        if not isinstance(obj, dict):
            raise ApiError("Unexpected /agent/step_screenshots response")
        if isinstance(obj.get("mime_type"), str) and obj["mime_type"]:
            mime_type = obj["mime_type"]
        got = obj.get("images")
        if isinstance(got, dict):
            for k, v in got.items():
                step = _to_int(k)
                if step >= 0 and isinstance(v, str) and v:
                    images[step] = v
        miss = obj.get("missing")
        if isinstance(miss, list):
            for value in miss:
                step = _to_int(value)
                if step >= 0:
                    missing.add(step)
    for step in steps:
        if step not in images:
            missing.add(step)
    return mime_type, images, sorted(missing)


def _config_summary(status: Dict[str, Any]) -> str:
    cfg = status.get("config")
    if not isinstance(cfg, dict):
        return ""
    keys = [
        "task",
        "base_url",
        "model",
        "api_mode",
        "max_steps",
        "max_completion_tokens",
        "timeout_seconds",
        "step_delay_seconds",
        "reasoning_effort",
        "half_res_screenshot",
        "use_w3c_actions_for_swipe",
        "debug_log_raw_assistant",
        "doubao_seed_enable_session_cache",
        "restart_responses_by_plan",
        "insecure_skip_tls_verify",
        "use_custom_system_prompt",
        "remember_api_key",
        "api_key_set",
        "agent_token_set",
    ]
    lines: List[str] = []
    for key in keys:
        if key not in cfg:
            continue
        value = cfg.get(key)
        if key == "system_prompt":
            continue
        if isinstance(value, str):
            if value:
                lines.append(f"{key}: {value}")
        else:
            lines.append(f"{key}: {json.dumps(value, ensure_ascii=False)}")
    if cfg.get("system_prompt"):
        lines.append("system_prompt: (set)")
    return "\n".join(lines)


def _token_usage_summary(status: Dict[str, Any]) -> str:
    usage = status.get("token_usage")
    if not isinstance(usage, dict):
        return ""
    keys = [
        ("requests", "Requests"),
        ("input_tokens", "Input tokens"),
        ("output_tokens", "Output tokens"),
        ("cached_tokens", "Cached tokens"),
        ("total_tokens", "Total tokens"),
    ]
    lines = []
    for key, label in keys:
        value = usage.get(key)
        if value is not None:
            lines.append(f"{label}: {value}")
    return "\n".join(lines)


def _system_prompt_summary(status: Dict[str, Any]) -> Tuple[str, str]:
    cfg = status.get("config")
    if not isinstance(cfg, dict):
        cfg = {}
    use_custom = bool(cfg.get("use_custom_system_prompt"))
    custom = cfg.get("system_prompt") if isinstance(cfg.get("system_prompt"), str) else ""
    default = cfg.get("default_system_prompt") if isinstance(cfg.get("default_system_prompt"), str) else ""
    if not default and isinstance(status.get("default_system_prompt"), str):
        default = status.get("default_system_prompt") or ""
    if not custom and isinstance(status.get("system_prompt"), str):
        custom = status.get("system_prompt") or ""
    if use_custom and custom.strip():
        return "System Prompt (custom)", custom
    if default.strip():
        return "System Prompt (default)", default
    if custom.strip():
        return "System Prompt (configured)", custom
    return "", ""


def _latest_ts(items: List[Dict[str, Any]]) -> str:
    for item in reversed(items):
        ts = item.get("ts")
        if isinstance(ts, str) and ts:
            return ts
    return ""


def _group_by_step(items: List[Dict[str, Any]]) -> List[Tuple[int, List[Dict[str, Any]]]]:
    order: List[int] = []
    grouped: Dict[int, List[Dict[str, Any]]] = {}
    for item in items:
        step = _to_int(item.get("step"))
        if step not in grouped:
            grouped[step] = []
            order.append(step)
        grouped[step].append(item)
    return [(step, grouped[step]) for step in order]


def _primary_request(items: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    for item in items:
        if item.get("kind") == "request" and item.get("attempt") is None:
            return item
    return None


def _latest_response(items: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    for item in reversed(items):
        if item.get("kind") == "response":
            return item
    return None


def _attempt_numbers(items: List[Dict[str, Any]]) -> List[int]:
    attempts = set()
    for item in items:
        attempt = item.get("attempt")
        if attempt is None:
            continue
        n = _to_int(attempt)
        if n >= 0:
            attempts.add(n)
    return sorted(attempts)


def _find_attempt_item(items: List[Dict[str, Any]], kind: str, attempt: int) -> Optional[Dict[str, Any]]:
    selected = None
    for item in items:
        if item.get("kind") == kind and _to_int(item.get("attempt")) == attempt:
            selected = item
    return selected


def _clean_lines(lines: List[str]) -> str:
    text = "\n".join(lines).strip()
    return text


def _parse_request_text(text: str) -> Dict[str, str]:
    raw_lines = (text or "").splitlines()
    section = "prefix"
    prefix: List[str] = []
    plan: List[str] = []
    notes: List[str] = []
    screen: List[str] = []

    for line in raw_lines:
        stripped = line.strip()
        if stripped == "** Plan Checklist **":
            section = "plan"
            continue
        if stripped == "** Working Notes **":
            section = "notes"
            continue
        if stripped == "** Screen Info **":
            section = "screen"
            continue
        if section == "prefix":
            prefix.append(line)
        elif section == "plan":
            plan.append(line)
        elif section == "notes":
            notes.append(line)
        else:
            screen.append(line)

    out: Dict[str, str] = {}
    first_non_empty = next((i for i, line in enumerate(prefix) if line.strip()), None)
    if first_non_empty is not None:
        first = prefix[first_non_empty].strip()
        if first.startswith("上一步执行失败：") or first.lower().startswith("previous step failed"):
            body: List[str] = []
            i = first_non_empty + 1
            while i < len(prefix) and prefix[i].strip():
                body.append(prefix[i])
                i += 1
            if body:
                out["previous_failure"] = _clean_lines(body)
            del prefix[first_non_empty : min(i, len(prefix))]

    if not screen:
        json_idx = next((i for i, line in enumerate(prefix) if line.strip().startswith("{")), None)
        if json_idx is None:
            task = _clean_lines(prefix)
            if task:
                out["task"] = task
        else:
            task = _clean_lines(prefix[:json_idx])
            screen_text = _clean_lines(prefix[json_idx:])
            if task:
                out["task"] = task
            if screen_text:
                out["screen"] = _pretty_json_if_possible(screen_text)
    else:
        other = _clean_lines(prefix)
        screen_text = _clean_lines(screen)
        if other:
            out["text"] = other
        if screen_text:
            out["screen"] = _pretty_json_if_possible(screen_text)

    if _clean_lines(plan):
        out["plan"] = _clean_lines(plan)
    if _clean_lines(notes):
        out["working_notes"] = _clean_lines(notes)
    return out


def _esc(value: Any) -> str:
    return html.escape("" if value is None else str(value))


def _pre(label: str, text: str, *, details: bool = False, open_details: bool = False) -> str:
    if not text:
        return ""
    body = f"<div class='section-label'>{_esc(label)}</div><pre>{_esc(text)}</pre>"
    if details:
        open_attr = " open" if open_details else ""
        return f"<details class='sec'{open_attr}><summary>{_esc(label)}</summary><pre>{_esc(text)}</pre></details>"
    return f"<div class='sec'>{body}</div>"


def _clamp1000(value: float) -> float:
    return max(0.0, min(1000.0, value))


def _svg_overlay(annotation: ActionAnnotation) -> str:
    if annotation.kind == "tap":
        x = _clamp1000(annotation.x1)
        y = _clamp1000(annotation.y1)
        return (
            "<svg class='overlay' viewBox='0 0 1000 1000' preserveAspectRatio='none' aria-hidden='true'>"
            f"<circle cx='{x:g}' cy='{y:g}' r='22' fill='rgba(255,0,0,0.18)'></circle>"
            f"<circle cx='{x:g}' cy='{y:g}' r='22' fill='none' stroke='#ff3b30' stroke-width='4'></circle>"
            f"<circle cx='{x:g}' cy='{y:g}' r='6' fill='#ff3b30'></circle>"
            "</svg>"
        )
    if annotation.kind == "swipe":
        sx = _clamp1000(annotation.x1)
        sy = _clamp1000(annotation.y1)
        ex = _clamp1000(annotation.x2)
        ey = _clamp1000(annotation.y2)
        dx = ex - sx
        dy = ey - sy
        angle = math.atan2(dy, dx)
        length = 28.0
        spread = 0.55
        p1x = ex - length * math.cos(angle - spread)
        p1y = ey - length * math.sin(angle - spread)
        p2x = ex - length * math.cos(angle + spread)
        p2y = ey - length * math.sin(angle + spread)
        return (
            "<svg class='overlay' viewBox='0 0 1000 1000' preserveAspectRatio='none' aria-hidden='true'>"
            f"<line x1='{sx:g}' y1='{sy:g}' x2='{ex:g}' y2='{ey:g}' stroke='#ff3b30' stroke-width='6' stroke-linecap='round'></line>"
            f"<circle cx='{sx:g}' cy='{sy:g}' r='6' fill='#ff3b30'></circle>"
            f"<line x1='{ex:g}' y1='{ey:g}' x2='{p1x:g}' y2='{p1y:g}' stroke='#ff3b30' stroke-width='6' stroke-linecap='round'></line>"
            f"<line x1='{ex:g}' y1='{ey:g}' x2='{p2x:g}' y2='{p2y:g}' stroke='#ff3b30' stroke-width='6' stroke-linecap='round'></line>"
            "</svg>"
        )
    return ""


def _render_html(
    *,
    base_url: str,
    status: Dict[str, Any],
    logs: Dict[str, Any],
    items: List[Dict[str, Any]],
    mime_type: str,
    screenshots: Dict[int, str],
    missing_steps: List[int],
    annotations: Dict[int, ActionAnnotation],
    annotate: bool,
) -> str:
    token_usage = _token_usage_summary(status)
    config_text = _config_summary(status)
    system_prompt_title, system_prompt_text = _system_prompt_summary(status)
    notes = status.get("notes") if isinstance(status.get("notes"), str) else ""
    last_message = status.get("last_message") if isinstance(status.get("last_message"), str) else ""
    running = bool(status.get("running"))
    log_lines: List[str] = []
    if isinstance(logs, dict) and isinstance(logs.get("lines"), list):
        log_lines = [str(x) for x in logs["lines"]]

    parts: List[str] = [
        "<!doctype html>",
        "<html lang='en'>",
        "<head>",
        "<meta charset='utf-8' />",
        "<meta name='viewport' content='width=device-width, initial-scale=1' />",
        "<title>WDA Agent rich export</title>",
        "<style>",
        ":root{color-scheme:light dark;--bg:#0b0b0c;--fg:#f5f5f7;--muted:rgba(255,255,255,.72);--card:rgba(255,255,255,.06);--panel:rgba(255,255,255,.04);--border:rgba(255,255,255,.12);--accent:#0a84ff;--danger:#ff3b30;--mono:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,'Liberation Mono','Courier New',monospace}",
        "@media(prefers-color-scheme:light){:root{--bg:#fff;--fg:#111;--muted:rgba(0,0,0,.64);--card:rgba(0,0,0,.04);--panel:rgba(0,0,0,.025);--border:rgba(0,0,0,.12)}}",
        "body{margin:0;background:var(--bg);color:var(--fg);font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif}",
        ".wrap{max-width:980px;margin:0 auto;padding:20px 16px 56px}h1{margin:0 0 6px;font-size:22px}.meta{color:var(--muted);font-size:13px;line-height:1.5}",
        ".grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px;margin-top:12px}.card,.step{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:12px}.step{margin-top:14px}",
        ".pill{display:inline-block;border:1px solid var(--border);border-radius:999px;padding:3px 8px;font-size:12px;color:var(--muted);margin:2px 4px 2px 0}.pill.action{color:#fff;background:#ff3b30;border-color:#ff3b30}.pill.missing{color:var(--danger);border-color:var(--danger)}",
        "pre{margin:8px 0 0;padding:10px;border-radius:10px;border:1px solid var(--border);background:rgba(0,0,0,.12);font-family:var(--mono);font-size:12px;line-height:1.38;white-space:pre-wrap;word-break:break-word}",
        "details{margin-top:10px}summary{cursor:pointer;color:var(--muted)}.step-head{display:flex;gap:10px;align-items:baseline;flex-wrap:wrap}.step-title{font-weight:700}.spacer{flex:1}.section-label{font-size:12px;color:var(--muted);margin-top:8px}",
        ".io{display:grid;grid-template-columns:1fr;gap:10px;margin-top:10px}.panel{background:var(--panel);border:1px solid var(--border);border-radius:12px;padding:12px}.panel h2{font-size:13px;margin:0 0 6px;color:var(--muted)}",
        ".shot{position:relative;display:inline-block;max-width:100%;margin-top:10px}.shot img{display:block;max-width:100%;height:auto;border-radius:12px;border:1px solid var(--border);background:#000}.overlay{position:absolute;inset:0;width:100%;height:100%;pointer-events:none}.badge{position:absolute;top:10px;left:10px;font-size:12px;font-weight:700;padding:4px 8px;border-radius:9px;background:rgba(0,0,0,.58);color:#fff;border:1px solid rgba(255,255,255,.14)}",
        ".warn{color:var(--danger)}.footer{margin-top:20px;color:var(--muted);font-size:12px}",
        "</style>",
        "</head><body><div class='wrap'>",
        "<h1>WDA Agent rich export</h1>",
        f"<div class='meta'>Exported at <span class='mono'>{_esc(_now_iso())}</span></div>",
        f"<div class='meta'>Runner URL <span class='mono'>{_esc(base_url)}</span></div>",
        f"<div class='meta'>Screenshot annotations {'enabled' if annotate else 'disabled'} · embedded screenshots {len(screenshots)} · missing {len(missing_steps)}</div>",
    ]

    if missing_steps:
        parts.append(
            "<div class='card warn'>Missing screenshots: "
            + _esc(", ".join(str(x) for x in missing_steps))
            + "</div>"
        )

    parts.append("<div class='grid'>")
    if token_usage:
        parts.append(f"<div class='card'><div class='meta'>Token Usage</div><pre>{_esc(token_usage)}</pre></div>")
    if last_message:
        parts.append(
            "<div class='card'><div class='meta'>Run Summary</div>"
            f"<span class='pill'>running: {str(running).lower()}</span>"
            f"<pre>{_esc(last_message)}</pre></div>"
        )
    if config_text:
        parts.append(f"<div class='card'><div class='meta'>Config (secrets excluded)</div><pre>{_esc(config_text)}</pre></div>")
    if system_prompt_text:
        parts.append(
            "<details class='card'><summary>"
            + _esc(system_prompt_title)
            + "</summary><pre>"
            + _esc(system_prompt_text)
            + "</pre></details>"
        )
    if notes.strip():
        parts.append(f"<div class='card'><div class='meta'>Notes</div><pre>{_esc(notes)}</pre></div>")
    parts.append("</div>")

    if log_lines:
        parts.append(
            "<details class='card'><summary>Logs</summary>"
            f"<pre>{_esc(chr(10).join(log_lines))}</pre></details>"
        )

    parts.append(f"<div class='card' style='margin-top:12px'><div class='meta'>Steps and Messages ({len(items)} chat items)</div></div>")

    for step, step_items in _group_by_step(items):
        primary = _primary_request(step_items)
        latest = _latest_response(step_items)
        ann = annotations.get(step)
        ts = _latest_ts(step_items)

        parts.append("<section class='step'>")
        parts.append("<div class='step-head'>")
        parts.append(f"<div class='step-title'>Step {step}</div>")
        if ann is not None:
            parts.append(f"<span class='pill action'>{_esc(ann.name)}</span>")
        if ts:
            parts.append(f"<span class='pill'>{_esc(ts)}</span>")
        if step in missing_steps:
            parts.append("<span class='pill missing'>screenshot missing</span>")
        parts.append("<span class='spacer'></span>")
        parts.append("</div>")

        if primary is not None and step in screenshots:
            parts.append("<div class='shot'>")
            parts.append(f"<img src='data:{_esc(mime_type)};base64,{screenshots[step]}' alt='Step {step} screenshot' />")
            if annotate and ann is not None:
                overlay = _svg_overlay(ann)
                if overlay:
                    parts.append(overlay)
                parts.append(f"<div class='badge'>{_esc(ann.name)}</div>")
            parts.append("</div>")

        parts.append("<div class='io'>")
        if primary is not None:
            parsed = _parse_request_text(str(primary.get("text") or ""))
            parts.append("<div class='panel'><h2>Input</h2>")
            parts.append(_pre("Previous step failed", parsed.get("previous_failure", "")))
            parts.append(_pre("Task", parsed.get("task", "")))
            parts.append(_pre("Plan Checklist", parsed.get("plan", "")))
            parts.append(_pre("Working Notes", parsed.get("working_notes", "")))
            parts.append(_pre("Text", parsed.get("text", "")))
            parts.append(_pre("Screen Info", parsed.get("screen", ""), details=True))
            if not parsed:
                parts.append(_pre("Text", str(primary.get("text") or "")))
            raw = primary.get("raw")
            if isinstance(raw, str) and raw:
                parts.append(_pre("Raw JSON", _redact_sensitive_text(raw), details=True))
            parts.append("</div>")

        if latest is not None:
            parts.append("<div class='panel'><h2>Output</h2>")
            content = str(latest.get("content") or "")
            parts.append(_pre("Content", _pretty_json_if_possible(content)))
            reasoning = latest.get("reasoning")
            if isinstance(reasoning, str) and reasoning:
                parts.append(_pre("Reasoning", reasoning, details=True))
            raw = latest.get("raw")
            if isinstance(raw, str) and raw:
                parts.append(_pre("Raw JSON", _redact_sensitive_text(raw), details=True))
            parts.append("</div>")
        parts.append("</div>")

        attempts = _attempt_numbers(step_items)
        if attempts:
            parts.append(f"<details><summary>Repair attempts ({len(attempts)})</summary>")
            for attempt in attempts:
                req = _find_attempt_item(step_items, "request", attempt)
                resp = _find_attempt_item(step_items, "response", attempt)
                parts.append("<div class='panel' style='margin-top:10px'>")
                parts.append(f"<h2>Attempt {attempt}</h2>")
                if req is not None:
                    parts.append(_pre("Repair prompt", str(req.get("text") or "")))
                    raw = req.get("raw")
                    if isinstance(raw, str) and raw:
                        parts.append(_pre("Request Raw JSON", _redact_sensitive_text(raw), details=True))
                if resp is not None:
                    parts.append(_pre("Repair output", _pretty_json_if_possible(str(resp.get("content") or ""))))
                    reasoning = resp.get("reasoning")
                    if isinstance(reasoning, str) and reasoning:
                        parts.append(_pre("Reasoning", reasoning, details=True))
                    raw = resp.get("raw")
                    if isinstance(raw, str) and raw:
                        parts.append(_pre("Response Raw JSON", _redact_sensitive_text(raw), details=True))
                parts.append("</div>")
            parts.append("</details>")

        parts.append("</section>")

    parts.append("<div class='footer'>Generated by tools/wda_rich_export.py</div>")
    parts.append("</div></body></html>")
    return "\n".join(parts)


def _jsonl(items: List[Dict[str, Any]]) -> str:
    lines: List[str] = []
    for item in items:
        redacted = dict(item)
        if isinstance(redacted.get("raw"), str):
            redacted["raw"] = _redact_sensitive_text(redacted["raw"])
        lines.append(json.dumps(redacted, ensure_ascii=False))
    return "\n".join(lines) + ("\n" if lines else "")


def cmd_export(args: argparse.Namespace) -> int:
    token = (args.agent_token or "").strip()
    status_path = "/agent/status"
    if not args.no_system_prompt:
        status_path = "/agent/status?include_default_system_prompt=1"
    status = _unwrap_wda_value(_http_get_json(args.base_url, status_path, token=token, timeout=args.timeout))
    chat = _unwrap_wda_value(_http_get_json(args.base_url, "/agent/chat", token=token, timeout=args.timeout))
    logs = _unwrap_wda_value(_http_get_json(args.base_url, "/agent/logs", token=token, timeout=args.timeout))

    if not isinstance(status, dict):
        raise ApiError("Unexpected /agent/status response")
    if not isinstance(chat, dict) or not isinstance(chat.get("items"), list):
        raise ApiError("Unexpected /agent/chat response")
    if not isinstance(logs, dict):
        logs = {}

    items = [item for item in chat["items"] if isinstance(item, dict)]
    steps = _request_steps(items)
    if args.max_screenshot_steps and args.max_screenshot_steps > 0:
        steps = steps[-args.max_screenshot_steps :]

    print(f"chat items: {len(items)}", flush=True)
    print(f"screenshot steps requested: {len(steps)}", flush=True)

    mime_type, screenshots, missing = _fetch_screenshots(
        base_url=args.base_url,
        token=token,
        timeout=args.timeout,
        steps=steps,
        image_format=args.image_format,
        quality=args.quality,
        chunk_size=args.chunk_size,
    )
    print(f"screenshots fetched: {len(screenshots)}", flush=True)
    if missing:
        print("missing screenshots: " + ",".join(str(s) for s in missing), flush=True)

    annotations = _build_action_annotations(items)
    html_text = _render_html(
        base_url=args.base_url,
        status=status,
        logs=logs,
        items=items,
        mime_type=mime_type,
        screenshots=screenshots,
        missing_steps=missing,
        annotations=annotations,
        annotate=not args.no_annotations,
    )
    out = Path(args.html)
    _write_text(out, html_text)
    print(f"Wrote HTML: {out}", flush=True)

    if args.jsonl:
        jsonl_out = Path(args.jsonl)
        _write_text(jsonl_out, _jsonl(items))
        print(f"Wrote JSONL: {jsonl_out}", flush=True)

    if args.status_json:
        status_out = Path(args.status_json)
        _write_text(status_out, json.dumps(status, ensure_ascii=False, indent=2))
        print(f"Wrote status JSON: {status_out}", flush=True)
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="wda_rich_export.py",
        description="Export a richer WDA on-device agent HTML report with token usage, notes, config, and action overlays.",
    )
    p.add_argument("--base-url", default=DEFAULT_BASE_URL, help=f"WDA base URL (default: {DEFAULT_BASE_URL})")
    p.add_argument("--agent-token", default=DEFAULT_AGENT_TOKEN, help="Agent token for LAN access (or WDA_AGENT_TOKEN)")
    p.add_argument("--timeout", type=float, default=120.0, help="HTTP timeout in seconds")
    p.add_argument("--html", required=True, help="Output HTML path")
    p.add_argument("--jsonl", help="Optional redacted chat JSONL output path")
    p.add_argument("--status-json", help="Optional status JSON output path")
    p.add_argument("--image-format", choices=["jpeg", "jpg", "png"], default="png", help="Embedded screenshot format")
    p.add_argument("--quality", type=float, default=0.7, help="JPEG quality in (0, 1], ignored for PNG")
    p.add_argument("--chunk-size", type=int, default=30, help="Screenshot batch size")
    p.add_argument(
        "--max-screenshot-steps",
        type=int,
        default=0,
        help="If > 0, embed screenshots only for the last N request steps",
    )
    p.add_argument("--no-annotations", action="store_true", help="Disable tap/swipe overlays in HTML")
    p.add_argument("--no-system-prompt", action="store_true", help="Do not include the default/custom system prompt")
    p.set_defaults(func=cmd_export)
    return p


def main(argv: List[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except KeyboardInterrupt:
        return 130
    except ApiError as e:
        print(f"[error] {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
