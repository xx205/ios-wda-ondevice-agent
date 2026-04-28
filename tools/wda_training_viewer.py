#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional


def _read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def _read_jsonl(path: Path) -> List[Dict[str, Any]]:
    if not path.exists():
        raise FileNotFoundError(f"Missing required file: {path}")
    out: List[Dict[str, Any]] = []
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
                out.append(obj)
    return out


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


def _safe_get_dict(obj: Any, key: str) -> Dict[str, Any]:
    if isinstance(obj, dict) and isinstance(obj.get(key), dict):
        return obj[key]
    return {}


def _image_url(dataset_dir: Path, out_dir: Path, image: Any) -> str:
    if not isinstance(image, str) or not image.strip():
        return ""
    text = image.strip().replace("\\", "/")
    lower = text.lower()
    if "://" in lower or lower.startswith("data:"):
        return text
    source = dataset_dir / text
    try:
        return os.path.relpath(source, out_dir).replace("\\", "/")
    except ValueError:
        return str(source).replace("\\", "/")


def _image_exists(dataset_dir: Path, image: Any) -> bool:
    if not isinstance(image, str) or not image.strip():
        return False
    lower = image.strip().lower()
    if "://" in lower or lower.startswith("data:"):
        return True
    return (dataset_dir / image).exists()


def _action_name(sample: Dict[str, Any]) -> str:
    action = _safe_get_dict(_safe_get_dict(sample, "assistant"), "action")
    name = action.get("name")
    return name.strip() if isinstance(name, str) and name.strip() else "Unknown"


def _terminal_from_action(action: Dict[str, Any]) -> bool:
    name = action.get("name") if isinstance(action.get("name"), str) else ""
    return name.strip().lower() in {"done", "finish", "finished", "stop"}


def _first_system(samples: List[Dict[str, Any]]) -> Dict[str, str]:
    for sample in samples:
        system = sample.get("system")
        if isinstance(system, dict):
            source = system.get("source") if isinstance(system.get("source"), str) else ""
            prompt = system.get("prompt") if isinstance(system.get("prompt"), str) else ""
            if source or prompt:
                return {"source": source, "prompt": prompt}
    return {"source": "", "prompt": ""}


def _system_from_meta(run_meta: Dict[str, Any], samples: List[Dict[str, Any]]) -> Dict[str, str]:
    meta_system = run_meta.get("system_prompt")
    if isinstance(meta_system, dict):
        source = meta_system.get("source") if isinstance(meta_system.get("source"), str) else ""
        prompt = meta_system.get("prompt") if isinstance(meta_system.get("prompt"), str) else ""
        if source or prompt:
            return {"source": source, "prompt": prompt}
    return _first_system(samples)


def _task_from_meta(run_meta: Dict[str, Any], samples: List[Dict[str, Any]]) -> str:
    cfg = run_meta.get("source_config")
    if isinstance(cfg, dict) and isinstance(cfg.get("task"), str):
        return cfg["task"]
    for sample in samples:
        task = sample.get("task")
        if isinstance(task, str) and task:
            return task
    return ""


def _system_from_trace(trace: Dict[str, Any]) -> Dict[str, str]:
    system = trace.get("system")
    if not isinstance(system, dict):
        manifest = trace.get("manifest") if isinstance(trace.get("manifest"), dict) else {}
        system = manifest.get("system_prompt") if isinstance(manifest.get("system_prompt"), dict) else {}
    source = system.get("source") if isinstance(system.get("source"), str) else "runtime"
    prompt = system.get("prompt") if isinstance(system.get("prompt"), str) else ""
    if not prompt and isinstance(system.get("rendered"), str):
        prompt = system["rendered"]
    return {"source": source, "prompt": prompt}


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
    attempt_used = parse.get("attempt_used")
    try:
        attempt_number = int(attempt_used)
    except Exception:
        attempt_number = 0
    if attempt_number <= 0:
        return response
    attempts = turn.get("repair_attempts") if isinstance(turn.get("repair_attempts"), list) else []
    for attempt in attempts:
        if not isinstance(attempt, dict):
            continue
        try:
            current = int(attempt.get("attempt"))
        except Exception:
            current = -1
        if current != attempt_number:
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
    return _json_from_model_text(str(response.get("content") or "")) or {}


def _canonical_image_for_turn(turn: Dict[str, Any]) -> str:
    state = turn.get("state") if isinstance(turn.get("state"), dict) else {}
    image = state.get("image") if isinstance(state.get("image"), dict) else {}
    ref = image.get("ref")
    return ref if isinstance(ref, str) else ""


def _build_samples(dataset_dir: Path, out_dir: Path, raw_samples: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    samples: List[Dict[str, Any]] = []
    for index, raw in enumerate(raw_samples):
        input_obj = _safe_get_dict(raw, "input")
        assistant_obj = _safe_get_dict(raw, "assistant")
        action = _safe_get_dict(assistant_obj, "action")
        parsed_json = assistant_obj.get("parsed_json")
        if not isinstance(parsed_json, dict):
            parsed_json = _json_from_model_text(str(assistant_obj.get("content") or "")) or {}
        if not action and isinstance(parsed_json.get("action"), dict):
            action = parsed_json["action"]

        image = input_obj.get("image")
        sample = {
            "index": index,
            "id": raw.get("id") if isinstance(raw.get("id"), str) else f"sample_{index:04d}",
            "run_id": raw.get("run_id") if isinstance(raw.get("run_id"), str) else "",
            "step": raw.get("step") if isinstance(raw.get("step"), int) else index,
            "task": raw.get("task") if isinstance(raw.get("task"), str) else "",
            "input": {
                "text": input_obj.get("text") if isinstance(input_obj.get("text"), str) else "",
                "parsed": input_obj.get("parsed") if isinstance(input_obj.get("parsed"), dict) else {},
                "image": image if isinstance(image, str) else "",
                "image_url": _image_url(dataset_dir, out_dir, image),
                "image_exists": _image_exists(dataset_dir, image),
            },
            "assistant": {
                "content": assistant_obj.get("content") if isinstance(assistant_obj.get("content"), str) else "",
                "reasoning": assistant_obj.get("reasoning") if isinstance(assistant_obj.get("reasoning"), str) else "",
                "action": action if isinstance(action, dict) else {},
                "parsed_json": parsed_json if isinstance(parsed_json, dict) else {},
            },
            "system_source": _safe_get_dict(raw, "system").get("source", ""),
            "meta": raw.get("meta") if isinstance(raw.get("meta"), dict) else {},
            "raw": raw.get("raw") if isinstance(raw.get("raw"), dict) else {},
        }
        samples.append(sample)
    return samples


def _build_samples_from_trace(dataset_dir: Path, out_dir: Path, trace: Dict[str, Any]) -> List[Dict[str, Any]]:
    run_id = trace.get("run_id") if isinstance(trace.get("run_id"), str) else ""
    task = _task_from_trace(trace)
    cfg = _config_from_trace(trace)
    model = trace.get("model") if isinstance(trace.get("model"), str) else str(cfg.get("model") or "")
    api_mode = trace.get("api_mode") if isinstance(trace.get("api_mode"), str) else str(cfg.get("api_mode") or "")
    runner_url = trace.get("runner_url") if isinstance(trace.get("runner_url"), str) else ""
    system = _system_from_trace(trace)
    turns = trace.get("turns") if isinstance(trace.get("turns"), list) else []
    samples: List[Dict[str, Any]] = []
    for index, turn_obj in enumerate(turns):
        if not isinstance(turn_obj, dict):
            continue
        step = turn_obj.get("step") if isinstance(turn_obj.get("step"), int) else index
        state = turn_obj.get("state") if isinstance(turn_obj.get("state"), dict) else {}
        req = turn_obj.get("request") if isinstance(turn_obj.get("request"), dict) else {}
        resp = turn_obj.get("response") if isinstance(turn_obj.get("response"), dict) else {}
        if not req and state:
            req = {"text": state.get("user_text", ""), "parsed": {}}
        if not resp and isinstance(turn_obj.get("model_response"), dict):
            resp = _canonical_response_for_turn(turn_obj)
        action = resp.get("action") if isinstance(resp.get("action"), dict) else {}
        parsed_json = resp.get("parsed_json") if isinstance(resp.get("parsed_json"), dict) else {}
        if not parsed_json and "parse" in turn_obj:
            parsed_json = _canonical_parsed_json_for_turn(turn_obj, resp)
        if not parsed_json:
            parsed_json = _json_from_model_text(str(resp.get("content") or "")) or {}
        if not action and isinstance(parsed_json.get("action"), dict):
            action = parsed_json["action"]
        image = turn_obj.get("image")
        if not isinstance(image, str):
            image = _canonical_image_for_turn(turn_obj)
        raw: Dict[str, Any] = {}
        if isinstance(req.get("raw"), str) and req.get("raw"):
            raw["request"] = req.get("raw")
        if isinstance(resp.get("raw"), str) and resp.get("raw"):
            raw["response"] = resp.get("raw")
        sample = {
            "index": len(samples),
            "id": f"{run_id}_step_{step:04d}" if run_id else f"trace_step_{step:04d}",
            "run_id": run_id,
            "step": step,
            "task": task,
            "input": {
                "text": req.get("text") if isinstance(req.get("text"), str) else "",
                "parsed": req.get("parsed") if isinstance(req.get("parsed"), dict) else {},
                "image": image if isinstance(image, str) else "",
                "image_url": _image_url(dataset_dir, out_dir, image),
                "image_exists": _image_exists(dataset_dir, image),
            },
            "assistant": {
                "content": resp.get("content") if isinstance(resp.get("content"), str) else "",
                "reasoning": resp.get("reasoning") if isinstance(resp.get("reasoning"), str) else "",
                "action": action if isinstance(action, dict) else {},
                "parsed_json": parsed_json if isinstance(parsed_json, dict) else {},
            },
            "system_source": system.get("source", ""),
            "meta": {
                "runner_url": runner_url,
                "source_model": model,
                "api_mode": api_mode,
                "response_ts": resp.get("ts", "") if isinstance(resp.get("ts"), str) else "",
                "attempt": None,
                "terminal": _terminal_from_action(action if isinstance(action, dict) else {}),
                "source": "trace.json",
            },
            "raw": raw,
        }
        samples.append(sample)
    return samples


def _summarize(
    *,
    dataset_dir: Path,
    run_meta: Dict[str, Any],
    samples: List[Dict[str, Any]],
    messages: List[Dict[str, Any]],
    system: Dict[str, str],
    data_source: str,
) -> Dict[str, Any]:
    action_counts: Dict[str, int] = {}
    for sample in samples:
        name = _action_name({"assistant": sample.get("assistant", {})})
        action_counts[name] = action_counts.get(name, 0) + 1
    image_dir = dataset_dir / "images"
    image_files = 0
    if image_dir.exists():
        image_files = len([p for p in image_dir.iterdir() if p.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp"}])
    message_ids = {m.get("id") for m in messages if isinstance(m, dict)}
    sample_ids = {s.get("id") for s in samples}
    missing_message_ids = sorted(str(x) for x in sample_ids if x and x not in message_ids)
    return {
        "samples": len(samples),
        "messages": len(messages),
        "image_files": image_files,
        "missing_images": sum(1 for s in samples if not s["input"]["image_exists"]),
        "with_reasoning": sum(1 for s in samples if bool(s["assistant"]["reasoning"])),
        "with_content": sum(1 for s in samples if bool(s["assistant"]["content"])),
        "terminal": sum(1 for s in samples if bool(_safe_get_dict(s, "meta").get("terminal"))),
        "system_prompt_chars": len(system.get("prompt") or ""),
        "run_id": run_meta.get("run_id", samples[0].get("run_id", "") if samples else ""),
        "data_source": data_source,
        "action_counts": dict(sorted(action_counts.items(), key=lambda kv: (-kv[1], kv[0]))),
        "missing_message_ids": missing_message_ids[:20],
    }


def _script_json(obj: Any) -> str:
    text = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    return text.replace("</", "<\\/")


HTML_TEMPLATE = r"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>WDA Training Dataset Viewer</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f4f6f8;
      --panel: #ffffff;
      --line: #d6dde5;
      --text: #1c2733;
      --muted: #64748b;
      --accent: #0f766e;
      --blue: #2563eb;
      --amber: #b45309;
      --orange: #f97316;
      --purple: #7c3aed;
      --slate: #475569;
      --red: #b91c1c;
      --green: #15803d;
      --code: #111827;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      height: 100vh;
      overflow: hidden;
      display: grid;
      grid-template-rows: auto minmax(0, 1fr);
      background: var(--bg);
      color: var(--text);
      font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif;
    }
    header {
      min-height: 96px;
      padding: 12px 18px 14px;
      display: grid;
      grid-template-columns: minmax(360px, 1fr) minmax(520px, 44vw);
      gap: 18px;
      align-items: start;
      border-bottom: 1px solid var(--line);
      background: #fbfcfd;
    }
    header > section { min-width: 0; }
    h1 {
      margin: 0 0 6px;
      font-size: 18px;
      font-weight: 700;
      letter-spacing: 0;
    }
    .task {
      color: var(--muted);
      overflow: hidden;
      display: -webkit-box;
      -webkit-line-clamp: 2;
      -webkit-box-orient: vertical;
      line-height: 1.35;
    }
    .metrics {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(104px, 1fr));
      gap: 8px;
      min-width: 0;
    }
    .metric {
      border: 1px solid var(--line);
      background: var(--panel);
      padding: 7px 10px;
      min-width: 0;
    }
    .metric strong {
      display: block;
      font-size: 17px;
      line-height: 1.1;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .metric span {
      display: block;
      color: var(--muted);
      font-size: 12px;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .app {
      min-height: 0;
      display: grid;
      grid-template-columns: 320px minmax(0, 1fr);
    }
    body.left-collapsed .app { grid-template-columns: 0 minmax(0, 1fr); }
    body.left-collapsed aside.rail { display: none; }
    aside.rail {
      min-height: 0;
      border-right: 1px solid var(--line);
      background: #fbfcfd;
      display: grid;
      grid-template-rows: auto 1fr;
    }
    .controls {
      padding: 12px;
      border-bottom: 1px solid var(--line);
      display: grid;
      gap: 8px;
    }
    .control-row { display: grid; grid-template-columns: 1fr 118px; gap: 8px; }
    input[type="search"], select {
      width: 100%;
      height: 34px;
      border: 1px solid var(--line);
      background: #fff;
      color: var(--text);
      padding: 0 10px;
      border-radius: 6px;
      font: inherit;
    }
    label.check {
      color: var(--muted);
      display: inline-flex;
      align-items: center;
      gap: 6px;
      margin-right: 12px;
      font-size: 12px;
      white-space: nowrap;
    }
    .small-line {
      color: var(--muted);
      font-size: 12px;
      display: flex;
      justify-content: space-between;
      gap: 12px;
    }
    .step-list {
      overflow: auto;
      min-height: 0;
      padding: 8px;
    }
    .step-row {
      width: 100%;
      border: 1px solid transparent;
      background: transparent;
      color: inherit;
      display: grid;
      grid-template-columns: 50px 84px 1fr;
      gap: 8px;
      align-items: start;
      text-align: left;
      padding: 8px;
      margin-bottom: 3px;
      border-radius: 6px;
      cursor: pointer;
      font: inherit;
    }
    .step-row:hover { background: #eef3f7; }
    .step-row.active {
      background: #e8f3f1;
      border-color: #8bc3bc;
    }
    .step-no { color: var(--muted); font-variant-numeric: tabular-nums; }
    .badge {
      display: inline-block;
      max-width: 100%;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      border-radius: 999px;
      padding: 2px 8px;
      color: #fff;
      background: var(--accent);
      font-size: 12px;
      line-height: 18px;
    }
    .badge.tap { background: var(--blue); }
    .badge.type { background: var(--amber); }
    .badge.swipe { background: var(--purple); }
    .badge.note { background: var(--slate); }
    .badge.finish { background: var(--green); }
    .badge.launch { background: var(--accent); }
    .badge.wait { background: var(--blue); }
    .badge.nav { background: var(--purple); }
    .row-main { min-width: 0; }
    .row-title {
      display: block;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      font-weight: 600;
    }
    .row-sub {
      display: block;
      color: var(--muted);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      font-size: 12px;
      margin-top: 2px;
    }
    main.workspace {
      min-width: 0;
      min-height: 0;
      display: grid;
      grid-template-columns: minmax(420px, 1fr) 430px;
    }
    body.right-collapsed main.workspace { grid-template-columns: minmax(0, 1fr) 0; }
    body.right-collapsed .detail-pane { display: none; }
    .image-pane {
      min-width: 0;
      min-height: 0;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 10px;
      background: #e7ebef;
      overflow: auto;
      position: relative;
    }
    .pane-toggle {
      position: absolute;
      top: 10px;
      z-index: 4;
      min-width: 34px;
      height: 30px;
      border: 1px solid rgba(148, 163, 184, .85);
      background: rgba(255, 255, 255, .88);
      color: #334155;
      border-radius: 6px;
      cursor: pointer;
      box-shadow: 0 6px 16px rgba(15, 23, 42, .12);
      font: 12px/1 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    .pane-toggle.left { left: 10px; }
    .pane-toggle.right { right: 10px; }
    .pane-toggle:hover { background: #fff; }
    .stage {
      position: relative;
      display: inline-block;
      max-width: 100%;
      max-height: calc(100vh - 108px);
      background: #111827;
      box-shadow: 0 14px 28px rgba(15, 23, 42, 0.18);
    }
    #shot {
      display: block;
      max-width: 100%;
      max-height: calc(100vh - 108px);
      object-fit: contain;
    }
    #overlay {
      position: absolute;
      inset: 0;
      width: 100%;
      height: 100%;
      pointer-events: none;
      overflow: visible;
    }
    .tap-marker {
      position: absolute;
      width: 30px;
      height: 30px;
      box-sizing: border-box;
      border: 3px solid #0f766e;
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
      background: #0f766e;
      border-radius: 999px;
      transform: translate(-50%, -50%);
    }
    .tap-marker::before { width: 19px; height: 3px; }
    .tap-marker::after { width: 3px; height: 19px; }
    .tap-marker.double {
      width: 46px;
      height: 46px;
      box-shadow:
        0 0 0 3px rgba(255, 255, 255, .9),
        0 0 0 10px rgba(15, 118, 110, .18),
        0 8px 18px rgba(15, 23, 42, .22);
    }
    .tap-marker.long {
      width: 48px;
      height: 48px;
      border-style: dashed;
      background: rgba(15, 118, 110, .10);
      box-shadow:
        0 0 0 3px rgba(255, 255, 255, .9),
        0 0 0 13px rgba(15, 118, 110, .10),
        0 8px 18px rgba(15, 23, 42, .22);
    }
    .swipe-line {
      position: absolute;
      height: 5px;
      border-radius: 999px;
      background: #f97316;
      box-shadow: 0 0 0 2px rgba(255, 255, 255, .86), 0 7px 16px rgba(15, 23, 42, .2);
      transform-origin: 0 50%;
    }
    .swipe-line::after {
      content: "";
      position: absolute;
      right: -1px;
      top: 50%;
      width: 13px;
      height: 13px;
      border-top: 5px solid #f97316;
      border-right: 5px solid #f97316;
      transform: translateY(-50%) rotate(45deg);
    }
    .swipe-dot {
      position: absolute;
      width: 18px;
      height: 18px;
      border-radius: 50%;
      transform: translate(-50%, -50%);
      background: #f97316;
      border: 3px solid rgba(255, 255, 255, .96);
      box-shadow: 0 5px 12px rgba(15, 23, 42, .2);
    }
    .swipe-dot.start { background: #0ea5e9; }
    .action-label {
      position: absolute;
      max-width: 180px;
      padding: 4px 8px;
      border-radius: 6px;
      color: #fff;
      background: rgba(15, 23, 42, .82);
      box-shadow: 0 7px 16px rgba(15, 23, 42, .18);
      font-size: 12px;
      line-height: 1.25;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .action-label.left { transform: translate(13px, -42px); }
    .action-label.right { transform: translate(calc(-100% - 13px), -42px); }
    .action-panel {
      position: absolute;
      left: 18px;
      right: 18px;
      display: grid;
      grid-template-columns: auto minmax(0, 1fr);
      gap: 10px;
      align-items: center;
      padding: 10px 12px;
      border-radius: 8px;
      color: #0f172a;
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
      min-width: 72px;
      padding: 5px 9px;
      border-radius: 999px;
      color: #fff;
      background: #334155;
      text-align: center;
      font-weight: 700;
      font-size: 12px;
      line-height: 1.15;
    }
    .action-copy { min-width: 0; }
    .action-copy strong {
      display: block;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      font-size: 13px;
      line-height: 1.25;
    }
    .action-copy span {
      display: block;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      color: #475569;
      font-size: 12px;
      margin-top: 2px;
    }
    .action-panel.launch .action-token { background: #0f766e; }
    .action-panel.type .action-token { background: #b45309; }
    .action-panel.note .action-token { background: #475569; }
    .action-panel.wait .action-token { background: #2563eb; }
    .action-panel.finish .action-token { background: #15803d; }
    .action-panel.nav .action-token { background: #7c3aed; }
    .action-panel.type {
      border-color: rgba(180, 83, 9, .45);
      background: rgba(255, 251, 235, .94);
    }
    .action-panel.note {
      align-items: start;
      grid-template-columns: 1fr;
      gap: 6px;
    }
    .action-panel.note .action-token {
      min-width: 0;
      width: fit-content;
      padding: 4px 10px;
    }
    .action-panel.note .action-copy {
      width: 100%;
    }
    .action-panel.note .action-copy strong {
      display: none;
    }
    .action-panel.note .action-copy span {
      display: block;
      white-space: normal;
      overflow: visible;
      line-height: 1.35;
    }
    .note-lines {
      display: grid;
      gap: 2px;
      min-width: 0;
    }
    .note-line {
      min-width: 0;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .action-panel.finish {
      border-color: rgba(21, 128, 61, .45);
      background: rgba(240, 253, 244, .94);
    }
    .action-panel:not(.note) .action-copy strong {
      display: none;
    }
    .action-panel.wait {
      width: min(72%, 280px);
      left: 50%;
      right: auto;
      grid-template-columns: auto minmax(0, 1fr);
      transform: translate(-50%, -50%);
    }
    .wait-pulse {
      position: absolute;
      left: 50%;
      top: calc(50% - 54px);
      width: 30px;
      height: 30px;
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
      width: 116px;
      height: 5px;
      border-radius: 999px;
      background: rgba(124, 58, 237, .88);
      box-shadow: 0 0 0 2px rgba(255, 255, 255, .88), 0 6px 14px rgba(15, 23, 42, .18);
      transform: translateX(-50%);
    }
    .back-cue {
      position: absolute;
      left: 18px;
      top: 50%;
      width: 46px;
      height: 46px;
      border-left: 5px solid #7c3aed;
      border-bottom: 5px solid #7c3aed;
      transform: translateY(-50%) rotate(45deg);
      filter: drop-shadow(0 3px 4px rgba(15, 23, 42, .25));
    }
    .empty-shot {
      width: 320px;
      min-height: 180px;
      display: none;
      place-items: center;
      color: #cbd5e1;
      padding: 24px;
      text-align: center;
    }
    .detail-pane {
      min-width: 0;
      min-height: 0;
      overflow: auto;
      padding: 10px 12px 12px;
      border-left: 1px solid var(--line);
      background: var(--panel);
    }
    .nav {
      display: grid;
      grid-template-columns: 36px 1fr 36px;
      gap: 8px;
      align-items: center;
      margin-bottom: 10px;
    }
    button.icon {
      height: 34px;
      border: 1px solid var(--line);
      background: #fff;
      border-radius: 6px;
      cursor: pointer;
      font: inherit;
    }
    button.icon:disabled { opacity: .4; cursor: default; }
    .current-title {
      min-width: 0;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      font-weight: 700;
    }
    .action-summary {
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #fbfcfd;
      padding: 10px;
      margin-bottom: 10px;
      display: grid;
      gap: 8px;
    }
    .summary-top {
      display: flex;
      align-items: center;
      gap: 8px;
      min-width: 0;
    }
    .summary-top .badge {
      flex: 0 0 auto;
      max-width: 96px;
    }
    .summary-title {
      min-width: 0;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      font-weight: 700;
    }
    .summary-copy {
      color: #334155;
      line-height: 1.45;
      overflow: hidden;
      display: -webkit-box;
      -webkit-line-clamp: 3;
      -webkit-box-orient: vertical;
    }
    .tabs {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 6px;
      margin: 10px 0;
    }
    .tab-button {
      height: 32px;
      border: 1px solid var(--line);
      background: #f8fafc;
      color: #475569;
      border-radius: 6px;
      cursor: pointer;
      font: inherit;
      font-weight: 700;
    }
    .tab-button.active {
      background: #0f172a;
      border-color: #0f172a;
      color: #fff;
    }
    .tab-panel { display: none; }
    .tab-panel.active {
      display: grid;
      gap: 10px;
    }
    .section-title {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 10px;
      color: #0f172a;
      font-weight: 700;
      margin: 2px 0 6px;
    }
    .section-card {
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #fff;
      overflow: hidden;
    }
    .section-card .section-title {
      margin: 0;
      padding: 9px 10px;
      border-bottom: 1px solid var(--line);
      background: #fbfcfd;
    }
    .kv {
      display: grid;
      grid-template-columns: 120px 1fr;
      gap: 5px 10px;
      padding: 10px;
      border: 1px solid var(--line);
      background: #fbfcfd;
      margin-bottom: 10px;
      border-radius: 8px;
    }
    .kv div:nth-child(odd) { color: var(--muted); }
    details {
      border: 1px solid var(--line);
      border-radius: 6px;
      margin-bottom: 10px;
      background: #fff;
    }
    summary {
      cursor: pointer;
      padding: 9px 10px;
      font-weight: 700;
      user-select: none;
      border-bottom: 1px solid transparent;
    }
    details[open] summary { border-bottom-color: var(--line); }
    pre {
      margin: 0;
      padding: 10px;
      white-space: pre-wrap;
      overflow-wrap: anywhere;
      color: var(--code);
      font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      max-height: 420px;
      overflow: auto;
      background: #fbfcfd;
    }
    .plan-list { padding: 8px 10px 10px; display: grid; gap: 7px; }
    .plan-item {
      display: grid;
      grid-template-columns: 12px 54px 1fr;
      gap: 8px;
      align-items: start;
      font-size: 13px;
      position: relative;
    }
    .plan-item::before {
      content: "";
      position: absolute;
      left: 5px;
      top: 16px;
      bottom: -10px;
      width: 2px;
      background: #e2e8f0;
    }
    .plan-item:last-child::before { display: none; }
    .plan-dot {
      width: 12px;
      height: 12px;
      margin-top: 4px;
      border-radius: 50%;
      border: 2px solid #94a3b8;
      background: #fff;
      z-index: 1;
    }
    .plan-item.done .plan-dot {
      border-color: var(--green);
      background: var(--green);
    }
    .state {
      width: 48px;
      text-align: center;
      border-radius: 999px;
      padding: 1px 6px;
      font-size: 11px;
      color: #fff;
      background: #64748b;
    }
    .state.done { background: var(--green); }
    .dist {
      display: grid;
      gap: 5px;
      padding: 10px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #fbfcfd;
      margin-bottom: 10px;
    }
    .bar-row { display: grid; grid-template-columns: 76px 1fr 34px; gap: 8px; align-items: center; }
    .bar-track { height: 8px; background: #e2e8f0; border-radius: 999px; overflow: hidden; }
    .bar { height: 100%; background: var(--accent); }
    .bar.tap { background: var(--blue); }
    .bar.type { background: var(--amber); }
    .bar.swipe, .bar.nav { background: var(--purple); }
    .bar.note { background: var(--slate); }
    .bar.finish { background: var(--green); }
    .bar.launch { background: var(--accent); }
    .bar.wait { background: var(--blue); }
    .warn { color: var(--red); font-weight: 700; }
    @media (max-width: 1050px) {
      body { overflow: auto; }
      header { grid-template-columns: 1fr; }
      .metrics { grid-template-columns: repeat(auto-fit, minmax(108px, 1fr)); }
      .app { min-height: 0; grid-template-columns: 1fr; }
      aside.rail { height: 330px; border-right: 0; border-bottom: 1px solid var(--line); }
      main.workspace { grid-template-columns: 1fr; }
      .detail-pane { border-left: 0; border-top: 1px solid var(--line); }
    }
  </style>
</head>
<body>
  <header>
    <section>
      <h1>WDA Training Dataset Viewer</h1>
      <div id="task" class="task"></div>
    </section>
    <section id="metrics" class="metrics"></section>
  </header>

  <div class="app">
    <aside class="rail">
      <div class="controls">
        <div class="control-row">
          <input id="query" type="search" placeholder="Search step, action, text">
          <select id="actionFilter"></select>
        </div>
        <div>
          <label class="check"><input id="missingOnly" type="checkbox"> missing image</label>
          <label class="check"><input id="terminalOnly" type="checkbox"> terminal</label>
        </div>
        <div class="small-line">
          <span id="filteredCount"></span>
          <span id="runId"></span>
        </div>
      </div>
      <div id="stepList" class="step-list"></div>
    </aside>

    <main class="workspace">
      <section class="image-pane">
        <button id="toggleRail" class="pane-toggle left" title="Toggle step list">List</button>
        <button id="toggleDetail" class="pane-toggle right" title="Toggle detail pane">Detail</button>
        <div class="stage">
          <img id="shot" alt="">
          <div id="overlay"></div>
          <div id="emptyShot" class="empty-shot">No image for this sample</div>
        </div>
      </section>

      <aside class="detail-pane">
        <div class="nav">
          <button id="prevBtn" class="icon" title="Previous step">&lt;</button>
          <div id="currentTitle" class="current-title"></div>
          <button id="nextBtn" class="icon" title="Next step">&gt;</button>
        </div>
        <div id="actionSummary" class="action-summary"></div>
        <div class="tabs" role="tablist" aria-label="Sample details">
          <button class="tab-button active" data-tab="summary" type="button">Summary</button>
          <button class="tab-button" data-tab="model" type="button">Model</button>
          <button class="tab-button" data-tab="raw" type="button">Raw</button>
        </div>
        <section id="tab-summary" class="tab-panel active">
        <div id="facts" class="kv"></div>
        <div id="distribution" class="dist"></div>
          <div class="section-card">
            <div class="section-title">Plan</div>
          <div id="planList" class="plan-list"></div>
          </div>
        </section>
        <section id="tab-model" class="tab-panel">
          <div class="section-card">
            <div class="section-title">Reasoning</div>
            <pre id="reasoningText"></pre>
          </div>
          <div class="section-card">
            <div class="section-title">Assistant Content</div>
            <pre id="assistantText"></pre>
          </div>
          <div class="section-card">
            <div class="section-title">Request</div>
            <pre id="requestText"></pre>
          </div>
        </section>
        <section id="tab-raw" class="tab-panel">
          <div class="section-card">
            <div class="section-title">Action JSON</div>
            <pre id="actionJson"></pre>
          </div>
          <div class="section-card">
            <div class="section-title">Parsed JSON</div>
            <pre id="parsedText"></pre>
          </div>
          <div class="section-card">
            <div class="section-title">System Prompt</div>
            <pre id="systemText"></pre>
          </div>
          <div class="section-card">
            <div class="section-title">Raw Sample</div>
            <pre id="rawText"></pre>
          </div>
        </section>
      </aside>
    </main>
  </div>

  <script id="viewer-data" type="application/json">__DATA_JSON__</script>
  <script>
    const DATA = JSON.parse(document.getElementById("viewer-data").textContent);
    const samples = DATA.samples || [];
    const summary = DATA.summary || {};
    const system = DATA.system || {};
    const state = { filtered: [], selected: 0, tab: "summary" };
    const $ = (id) => document.getElementById(id);

    function escapeHtml(value) {
      return String(value ?? "").replace(/[&<>"']/g, (ch) => ({
        "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
      }[ch]));
    }
    function pretty(value) {
      if (value === undefined || value === null || value === "") return "";
      if (typeof value === "string") return value;
      return JSON.stringify(value, null, 2);
    }
    function action(sample) {
      return sample?.assistant?.action || {};
    }
    function actionName(sample) {
      return String(action(sample).name || "Unknown");
    }
    function badgeClass(name) {
      const n = name.toLowerCase();
      if (n === "launch") return "launch";
      if (n.includes("tap")) return "tap";
      if (n === "type") return "type";
      if (n === "swipe") return "swipe";
      if (n === "note") return "note";
      if (n === "finish") return "finish";
      if (n === "wait") return "wait";
      if (n === "home" || n === "back") return "nav";
      return "";
    }
    function briefAction(sample) {
      const detail = actionDetail(sample);
      const name = actionName(sample);
      return detail ? `${name} ${detail}` : name;
    }
    function actionDetail(sample, max = 60) {
      const a = action(sample);
      const p = a.params || {};
      const n = actionName(sample).toLowerCase();
      if (Array.isArray(p.element)) return `[${p.element.join(", ")}]`;
      if (Array.isArray(p.start) && Array.isArray(p.end)) return `[${p.start.join(", ")}] -> [${p.end.join(", ")}]`;
      if (n === "wait") return p.seconds !== undefined ? `${p.seconds}s` : "until stable";
      if (typeof p.text === "string") return clip(p.text, max);
      if (typeof p.message === "string") return clip(p.message, max);
      if (typeof p.app === "string") return clip(p.app, max);
      if (typeof p.bundle_id === "string") return clip(p.bundle_id, max);
      if (n === "home") return "Return to home screen";
      if (n === "back") return "Back gesture";
      const paramText = clip(pretty(p), max);
      return paramText && paramText !== "{}" ? paramText : "";
    }
    function clip(value, max = 96) {
      const text = String(value ?? "").replace(/\s+/g, " ").trim();
      if (text.length <= max) return text;
      return `${text.slice(0, max - 1)}…`;
    }
    function noteLines(value, maxLines = 6) {
      const rawLines = String(value ?? "")
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter(Boolean);
      const lines = rawLines.length ? rawLines : [String(value ?? "").trim()].filter(Boolean);
      const selected = lines.slice(0, maxLines);
      if (lines.length > maxLines && selected.length) {
        selected[selected.length - 1] = `${selected[selected.length - 1]} ...`;
      }
      return selected;
    }
    function searchable(sample) {
      return [
        sample.id, sample.step, actionName(sample), actionDetail(sample), briefAction(sample),
        sample.input?.text, sample.assistant?.content, sample.assistant?.reasoning,
        JSON.stringify(action(sample).params || {})
      ].join("\n").toLowerCase();
    }
    function metric(label, value) {
      return `<div class="metric"><strong>${escapeHtml(value)}</strong><span>${escapeHtml(label)}</span></div>`;
    }
    function renderHeader() {
      $("task").textContent = DATA.task || "";
      $("runId").textContent = summary.run_id || "";
      $("metrics").innerHTML = [
        metric("source", summary.data_source || "dataset.jsonl"),
        metric("samples", summary.samples ?? samples.length),
        metric("images / missing", `${summary.image_files ?? 0} / ${summary.missing_images ?? 0}`),
        metric("reasoning", summary.with_reasoning ?? 0),
        metric("system chars", summary.system_prompt_chars ?? 0)
      ].join("");
    }
    function renderDistribution() {
      const counts = summary.action_counts || {};
      const entries = Object.entries(counts);
      const max = Math.max(1, ...entries.map(([, count]) => count));
      $("distribution").innerHTML = entries.map(([name, count]) => {
        const width = Math.max(4, Math.round((count / max) * 100));
        return `<div class="bar-row"><span>${escapeHtml(name)}</span><div class="bar-track"><div class="bar ${badgeClass(name)}" style="width:${width}%"></div></div><span>${count}</span></div>`;
      }).join("") || "<div>No actions</div>";
    }
    function buildActionFilter() {
      const names = Object.keys(summary.action_counts || {});
      $("actionFilter").innerHTML = [
        `<option value="">All actions</option>`,
        ...names.map((name) => `<option value="${escapeHtml(name)}">${escapeHtml(name)}</option>`)
      ].join("");
    }
    function applyFilters() {
      const query = $("query").value.trim().toLowerCase();
      const actionValue = $("actionFilter").value;
      const missingOnly = $("missingOnly").checked;
      const terminalOnly = $("terminalOnly").checked;
      state.filtered = samples
        .map((sample, index) => ({ sample, index }))
        .filter(({ sample }) => !query || searchable(sample).includes(query))
        .filter(({ sample }) => !actionValue || actionName(sample) === actionValue)
        .filter(({ sample }) => !missingOnly || !sample.input?.image_exists)
        .filter(({ sample }) => !terminalOnly || Boolean(sample.meta?.terminal))
        .map(({ index }) => index);
      if (!state.filtered.includes(state.selected)) {
        state.selected = state.filtered.length ? state.filtered[0] : 0;
      }
      renderList();
      renderSelected();
    }
    function renderList() {
      $("filteredCount").textContent = `${state.filtered.length} visible / ${samples.length} total`;
      $("stepList").innerHTML = state.filtered.map((sampleIndex) => {
        const sample = samples[sampleIndex];
        const name = actionName(sample);
        const active = sampleIndex === state.selected ? " active" : "";
        const missing = sample.input?.image_exists ? "" : " missing image";
        return `<button class="step-row${active}" data-index="${sampleIndex}">
          <span class="step-no">#${String(sample.step).padStart(4, "0")}</span>
          <span class="badge ${badgeClass(name)}">${escapeHtml(name)}</span>
          <span class="row-main">
            <span class="row-title">${escapeHtml(actionDetail(sample) || "No parameters")}</span>
            <span class="row-sub${missing ? " warn" : ""}">${missing || escapeHtml(sample.meta?.response_ts || sample.id)}</span>
          </span>
        </button>`;
      }).join("");
      for (const row of $("stepList").querySelectorAll(".step-row")) {
        row.addEventListener("click", () => {
          state.selected = Number(row.dataset.index);
          renderList();
          renderSelected();
        });
      }
    }
    function renderFacts(sample) {
      const imageText = sample.input?.image_exists ? sample.input?.image : "missing";
      $("facts").innerHTML = [
        ["Step", sample.step],
        ["ID", sample.id],
        ["Action", actionName(sample)],
        ["Image", imageText],
        ["Response", sample.meta?.response_ts || ""],
        ["Terminal", sample.meta?.terminal ? "true" : "false"],
        ["Model", sample.meta?.source_model || ""],
        ["System", sample.system_source || system.source || ""]
      ].map(([k, v]) => `<div>${escapeHtml(k)}</div><div>${escapeHtml(v)}</div>`).join("");
    }
    function renderActionSummary(sample) {
      const name = actionName(sample);
      const cls = badgeClass(name);
      const params = action(sample).params || {};
      const detail = actionDetail(sample, 96);
      let body = detail;
      if (typeof params.message === "string") body = params.message;
      else if (typeof params.text === "string") body = params.text;
      else if (typeof params.app === "string") body = params.app;
      else if (typeof params.bundle_id === "string") body = params.bundle_id;
      $("actionSummary").innerHTML = `
        <div class="summary-top">
          <span class="badge ${cls}">${escapeHtml(name)}</span>
          <span class="summary-title">#${String(sample.step).padStart(4, "0")} ${escapeHtml(detail || "No parameters")}</span>
        </div>
        <div class="summary-copy">${escapeHtml(body || "No action details")}</div>
      `;
    }
    function renderPlan(sample) {
      const plan = sample.assistant?.parsed_json?.plan;
      if (!Array.isArray(plan) || !plan.length) {
        $("planList").innerHTML = "<div class=\"row-sub\">No plan in this sample.</div>";
        return;
      }
      $("planList").innerHTML = plan.map((item) => {
        const done = Boolean(item && item.done);
        const text = item && typeof item.text === "string" ? item.text : pretty(item);
        return `<div class="plan-item ${done ? "done" : ""}"><span class="plan-dot"></span><span class="state ${done ? "done" : ""}">${done ? "done" : "todo"}</span><span>${escapeHtml(text)}</span></div>`;
      }).join("");
    }
    function switchTab(name) {
      state.tab = name;
      for (const button of document.querySelectorAll(".tab-button")) {
        button.classList.toggle("active", button.dataset.tab === name);
      }
      for (const panel of document.querySelectorAll(".tab-panel")) {
        panel.classList.toggle("active", panel.id === `tab-${name}`);
      }
    }
    function updateToggleLabels() {
      $("toggleRail").textContent = document.body.classList.contains("left-collapsed") ? "List" : "<";
      $("toggleDetail").textContent = document.body.classList.contains("right-collapsed") ? "Detail" : ">";
    }
    function clamp(value) {
      const n = Number(value);
      if (!Number.isFinite(n)) return 0;
      return Math.max(0, Math.min(1000, n));
    }
    function point(value) {
      if (!Array.isArray(value) || value.length < 2) return null;
      return { x: clamp(value[0]), y: clamp(value[1]) };
    }
    function pct(value) {
      return `${clamp(value) / 10}%`;
    }
    function div(className, style, text) {
      const el = document.createElement("div");
      el.className = className;
      for (const [key, value] of Object.entries(style || {})) el.style[key] = value;
      if (text !== undefined) el.textContent = text;
      return el;
    }
    function notePanel(message) {
      const panel = actionPanel("note", "Note", "", "bottom");
      const copy = panel.querySelector(".action-copy");
      const span = panel.querySelector(".action-copy span");
      if (span) span.remove();
      const lines = div("note-lines", {});
      for (const line of noteLines(message, 6)) {
        lines.appendChild(div("note-line", {}, line));
      }
      if (copy) copy.appendChild(lines);
      return panel;
    }
    function actionPanel(kind, title, body, placement = "top") {
      const panel = div(`action-panel ${kind} ${placement}`, {});
      const token = div("action-token", {}, title);
      const copy = div("action-copy", {});
      const strong = document.createElement("strong");
      strong.textContent = title;
      const span = document.createElement("span");
      span.textContent = body || "";
      copy.appendChild(strong);
      copy.appendChild(span);
      panel.appendChild(token);
      panel.appendChild(copy);
      return panel;
    }
    function markerLabel(text, x, y) {
      const side = x > 760 ? "right" : "left";
      return div(`action-label ${side}`, { left: pct(x), top: pct(y) }, text);
    }
    function renderOverlay(sample) {
      const overlay = $("overlay");
      overlay.innerHTML = "";
      if (!sample?.input?.image_url) return;
      const a = action(sample);
      const params = a.params || {};
      const name = actionName(sample);
      const lower = name.toLowerCase();
      const width = overlay.clientWidth;
      const height = overlay.clientHeight;
      if (!width || !height) {
        requestAnimationFrame(() => renderOverlay(sample));
        return;
      }

      const start = point(params.start);
      const end = point(params.end);
      if (start && end) {
        const x1 = start.x / 1000 * width;
        const y1 = start.y / 1000 * height;
        const x2 = end.x / 1000 * width;
        const y2 = end.y / 1000 * height;
        const dx = x2 - x1;
        const dy = y2 - y1;
        const length = Math.max(1, Math.hypot(dx, dy));
        const angle = Math.atan2(dy, dx) * 180 / Math.PI;
        overlay.appendChild(div("swipe-line", {
          left: `${x1}px`,
          top: `${y1}px`,
          width: `${length}px`,
          transform: `translateY(-50%) rotate(${angle}deg)`
        }));
        overlay.appendChild(div("swipe-dot start", { left: pct(start.x), top: pct(start.y) }));
        overlay.appendChild(div("swipe-dot end", { left: pct(end.x), top: pct(end.y) }));
        overlay.appendChild(markerLabel(name, end.x, end.y));
        return;
      }

      const p = point(params.element);
      if (p) {
        const markerClass = lower.includes("long") ? "tap-marker long" : lower.includes("double") ? "tap-marker double" : "tap-marker";
        overlay.appendChild(div(markerClass, { left: pct(p.x), top: pct(p.y) }));
        const extra = lower.includes("long") && params.seconds ? `${name} ${params.seconds}s` : name;
        overlay.appendChild(markerLabel(extra, p.x, p.y));
        return;
      }

      if (lower === "type") {
        overlay.appendChild(actionPanel("type", "Type", clip(params.text || "", 140), "bottom"));
        return;
      }
      if (lower === "launch") {
        overlay.appendChild(actionPanel("launch", "Launch", clip(params.app || params.bundle_id || "App"), "top"));
        return;
      }
      if (lower === "wait") {
        overlay.appendChild(div("wait-pulse", {}));
        const seconds = params.seconds !== undefined ? `${params.seconds}s` : "until stable";
        overlay.appendChild(actionPanel("wait", "Wait", seconds, "center"));
        return;
      }
      if (lower === "note") {
        overlay.appendChild(notePanel(params.message || ""));
        return;
      }
      if (lower === "finish") {
        overlay.appendChild(actionPanel("finish", "Finish", clip(params.message || "", 150), "bottom"));
        return;
      }
      if (lower === "home") {
        overlay.appendChild(div("home-indicator", {}));
        overlay.appendChild(actionPanel("nav", "Home", "Return to home screen", "bottom"));
        return;
      }
      if (lower === "back") {
        overlay.appendChild(div("back-cue", {}));
        overlay.appendChild(actionPanel("nav", "Back", "Back gesture", "top"));
        return;
      }
      overlay.appendChild(actionPanel("note", name, clip(pretty(params), 150), "bottom"));
    }
    function renderSelected() {
      const sample = samples[state.selected];
      if (!sample) {
        $("currentTitle").textContent = "No sample";
        return;
      }
      const pos = state.filtered.indexOf(state.selected);
      $("prevBtn").disabled = pos <= 0;
      $("nextBtn").disabled = pos < 0 || pos >= state.filtered.length - 1;
      $("currentTitle").textContent = `#${String(sample.step).padStart(4, "0")} ${briefAction(sample)}`;
      const img = $("shot");
      const empty = $("emptyShot");
      if (sample.input?.image_url) {
        img.style.display = "";
        empty.style.display = "none";
        img.src = sample.input.image_url;
      } else {
        img.removeAttribute("src");
        img.style.display = "none";
        empty.style.display = "grid";
      }
      renderOverlay(sample);
      renderActionSummary(sample);
      renderFacts(sample);
      renderPlan(sample);
      $("actionJson").textContent = pretty(action(sample));
      $("requestText").textContent = sample.input?.text || "";
      $("reasoningText").textContent = sample.assistant?.reasoning || "";
      $("assistantText").textContent = sample.assistant?.content || "";
      $("parsedText").textContent = pretty(sample.assistant?.parsed_json || {});
      $("systemText").textContent = system.prompt || "";
      $("rawText").textContent = pretty(sample.raw || {});
    }
    function move(delta) {
      const pos = state.filtered.indexOf(state.selected);
      const next = pos + delta;
      if (next >= 0 && next < state.filtered.length) {
        state.selected = state.filtered[next];
        renderList();
        renderSelected();
        const active = $("stepList").querySelector(".step-row.active");
        if (active) active.scrollIntoView({ block: "nearest" });
      }
    }
    function init() {
      renderHeader();
      renderDistribution();
      buildActionFilter();
      $("query").addEventListener("input", applyFilters);
      $("actionFilter").addEventListener("change", applyFilters);
      $("missingOnly").addEventListener("change", applyFilters);
      $("terminalOnly").addEventListener("change", applyFilters);
      $("prevBtn").addEventListener("click", () => move(-1));
      $("nextBtn").addEventListener("click", () => move(1));
      $("toggleRail").addEventListener("click", () => {
        document.body.classList.toggle("left-collapsed");
        updateToggleLabels();
        requestAnimationFrame(() => renderOverlay(samples[state.selected]));
      });
      $("toggleDetail").addEventListener("click", () => {
        document.body.classList.toggle("right-collapsed");
        updateToggleLabels();
        requestAnimationFrame(() => renderOverlay(samples[state.selected]));
      });
      for (const button of document.querySelectorAll(".tab-button")) {
        button.addEventListener("click", () => switchTab(button.dataset.tab));
      }
      $("shot").addEventListener("load", () => renderOverlay(samples[state.selected]));
      window.addEventListener("resize", () => renderOverlay(samples[state.selected]));
      document.addEventListener("keydown", (event) => {
        const tag = document.activeElement?.tagName?.toLowerCase();
        if (tag === "input" || tag === "select" || tag === "textarea") return;
        if (event.key === "ArrowLeft") move(-1);
        if (event.key === "ArrowRight") move(1);
      });
      updateToggleLabels();
      switchTab(state.tab);
      applyFilters();
    }
    init();
  </script>
</body>
</html>
"""


def build_view_model(dataset_dir: Path, out_html: Path) -> Dict[str, Any]:
    dataset_dir = dataset_dir.resolve()
    out_dir = out_html.resolve().parent
    trace_path = dataset_dir / "trace.json"
    if not trace_path.exists():
        raise FileNotFoundError(f"Missing required canonical trace: {trace_path}")
    trace = _read_json(trace_path, {})
    if not isinstance(trace, dict) or not isinstance(trace.get("turns"), list):
        raise ValueError(f"Invalid canonical trace: {trace_path}")
    messages = _read_jsonl(dataset_dir / "messages.jsonl") if (dataset_dir / "messages.jsonl").exists() else []
    run_meta = _read_json(dataset_dir / "run_meta.json", {})
    status = _read_json(dataset_dir / "status.json", {})
    data_source = "trace.json"
    samples = _build_samples_from_trace(dataset_dir, out_dir, trace)
    system = _system_from_trace(trace)
    task = _task_from_trace(trace)
    return {
        "generated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "dataset_dir": str(dataset_dir),
        "task": task,
        "data_source": data_source,
        "trace": {
            "schema": trace.get("schema", "") if isinstance(trace, dict) else "",
            "counts": trace.get("counts", {}) if isinstance(trace, dict) and isinstance(trace.get("counts"), dict) else {},
        },
        "run_meta": run_meta if isinstance(run_meta, dict) else {},
        "status": status if isinstance(status, dict) else {},
        "system": system,
        "summary": _summarize(
            dataset_dir=dataset_dir,
            run_meta=run_meta if isinstance(run_meta, dict) else {},
            samples=samples,
            messages=messages,
            system=system,
            data_source=data_source,
        ),
        "samples": samples,
    }


def cmd_build(args: argparse.Namespace) -> int:
    dataset_dir = Path(args.dataset_dir)
    out_html = Path(args.out) if args.out else dataset_dir / "viewer.html"
    if not dataset_dir.exists():
        print(f"[error] dataset dir does not exist: {dataset_dir}", file=sys.stderr)
        return 2
    view_model = build_view_model(dataset_dir, out_html)
    html = HTML_TEMPLATE.replace("__DATA_JSON__", _script_json(view_model))
    out_html.parent.mkdir(parents=True, exist_ok=True)
    out_html.write_text(html, encoding="utf-8")
    summary = view_model["summary"]
    print(f"wrote: {out_html}")
    print(f"samples: {summary['samples']}")
    print(f"image files: {summary['image_files']}")
    print(f"missing images: {summary['missing_images']}")
    print(f"system prompt chars: {summary['system_prompt_chars']}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="wda_training_viewer.py",
        description="Generate a static HTML viewer for a WDA training dataset directory.",
    )
    p.add_argument("--dataset-dir", default=".", help="Directory containing canonical trace.json and images/")
    p.add_argument("--out", default="", help="Output HTML path; defaults to <dataset-dir>/viewer.html")
    p.set_defaults(func=cmd_build)
    return p


def main(argv: List[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except (OSError, ValueError) as e:
        print(f"[error] {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
