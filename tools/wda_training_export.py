#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import wda_rich_export as rich


DEFAULT_BASE_URL = os.environ.get("WDA_URL", "http://127.0.0.1:8100")
DEFAULT_AGENT_TOKEN = os.environ.get("WDA_AGENT_TOKEN", "")
TERMINAL_ACTIONS = {"done", "finish", "finished", "stop"}
MESSAGES_MODES = {"standalone", "trace"}


def _write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _write_json(path: Path, obj: Any) -> None:
    _write_text(path, json.dumps(obj, ensure_ascii=False, indent=2))


def _jsonl(items: List[Dict[str, Any]]) -> str:
    return "\n".join(json.dumps(item, ensure_ascii=False) for item in items) + ("\n" if items else "")


def _safe_id(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip())
    value = value.strip("_")
    return value or "run"


def _default_run_id(items: List[Dict[str, Any]]) -> str:
    for item in items:
        ts = item.get("ts")
        if isinstance(ts, str) and ts.strip():
            return "run_" + _safe_id(ts)
    return "run_" + _safe_id(rich._now_iso())


def _chat_snapshot(chat: Dict[str, Any], *, redact: str) -> Dict[str, Any]:
    if redact == "none":
        return chat
    out = dict(chat)
    items = chat.get("items")
    if isinstance(items, list):
        copied: List[Any] = []
        for item in items:
            if not isinstance(item, dict):
                copied.append(item)
                continue
            d = dict(item)
            raw = d.get("raw")
            if isinstance(raw, str) and raw:
                d["raw"] = rich._redact_sensitive_text(raw)
            copied.append(d)
        out["items"] = copied
    return out


def _first_item_datetime(items: List[Dict[str, Any]]) -> Optional[datetime]:
    for item in items:
        ts = item.get("ts")
        if not isinstance(ts, str) or not ts.strip():
            continue
        value = ts.strip()
        for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S"):
            try:
                return datetime.strptime(value[:19], fmt)
            except ValueError:
                pass
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            continue
    return None


def _render_system_prompt_template(prompt: str, items: List[Dict[str, Any]]) -> str:
    if "{{DATE_" not in prompt:
        return prompt
    dt = _first_item_datetime(items)
    if dt is None:
        dt = datetime.now()
    weekdays_zh = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
    date_zh = f"{dt:%Y年%m月%d日} {weekdays_zh[dt.weekday()]}"
    date_en = f"{dt:%Y-%m-%d} ({dt:%a})"
    return prompt.replace("{{DATE_ZH}}", date_zh).replace("{{DATE_EN}}", date_en)


def _system_prompt(status: Dict[str, Any], *, items: Optional[List[Dict[str, Any]]] = None) -> Tuple[str, str]:
    title, prompt = rich._system_prompt_summary(status)
    if items is not None:
        prompt = _render_system_prompt_template(prompt, items)
    if title.endswith("(custom)"):
        return "custom", prompt
    if title.endswith("(default)"):
        return "default", prompt
    if prompt:
        return "configured", prompt
    return "", ""


def _source_config(status: Dict[str, Any]) -> Dict[str, Any]:
    cfg = status.get("config")
    if not isinstance(cfg, dict):
        return {}
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
        "use_custom_system_prompt",
    ]
    return {k: cfg.get(k) for k in keys if k in cfg}


def _decode_image(data_b64: str) -> bytes:
    try:
        return base64.b64decode(data_b64.encode("ascii"), validate=False)
    except Exception:
        return b""


def _image_extension(image_format: str, mime_type: str) -> str:
    fmt = (image_format or "").lower()
    mime = (mime_type or "").lower()
    if fmt in {"jpeg", "jpg"} or "jpeg" in mime or "jpg" in mime:
        return "jpg"
    return "png"


def _save_images(
    *,
    out_dir: Path,
    image_format: str,
    mime_type: str,
    screenshots: Dict[int, str],
) -> Dict[int, str]:
    ext = _image_extension(image_format, mime_type)
    image_dir = out_dir / "images"
    saved: Dict[int, str] = {}
    for step, b64 in sorted(screenshots.items()):
        data = _decode_image(b64)
        if not data:
            continue
        rel = Path("images") / f"step_{step:04d}.{ext}"
        path = out_dir / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        saved[step] = rel.as_posix()
    return saved


def _action_from_item(item: Dict[str, Any]) -> Tuple[Optional[Dict[str, Any]], Optional[Dict[str, Any]]]:
    content = item.get("content")
    if not isinstance(content, str) or not content.strip():
        return None, None
    obj = rich._json_from_model_text(content)
    if not isinstance(obj, dict):
        return None, None
    action = obj.get("action")
    if not isinstance(action, dict):
        return obj, None
    name = action.get("name")
    if not isinstance(name, str) or not name.strip():
        return obj, None
    return obj, action


def _best_action_response(step_items: List[Dict[str, Any]]) -> Tuple[Optional[Dict[str, Any]], Optional[Dict[str, Any]], Optional[Dict[str, Any]]]:
    for item in reversed(step_items):
        if item.get("kind") != "response":
            continue
        obj, action = _action_from_item(item)
        if action is not None:
            return item, obj, action
    return None, None, None


def _safe_raw(raw: Any, *, include_raw: bool, redact: str) -> Optional[str]:
    if not include_raw or not isinstance(raw, str) or not raw:
        return None
    if redact != "none":
        return rich._redact_sensitive_text(raw)
    return raw


def _build_trace(
    *,
    run_id: str,
    base_url: str,
    status: Dict[str, Any],
    items: List[Dict[str, Any]],
    image_paths: Dict[int, str],
    missing_images: List[int],
    include_raw: bool,
    redact: str,
) -> Dict[str, Any]:
    cfg = status.get("config") if isinstance(status.get("config"), dict) else {}
    task = cfg.get("task") if isinstance(cfg.get("task"), str) else ""
    prompt_source, prompt = _system_prompt(status, items=items)
    turns: List[Dict[str, Any]] = []

    for step, step_items in rich._group_by_step(items):
        if step < 0:
            continue
        req = rich._primary_request(step_items)
        response, parsed_json, action = _best_action_response(step_items)
        if req is None and response is None:
            continue

        turn: Dict[str, Any] = {
            "step": step,
            "request": None,
            "response": None,
            "image": image_paths.get(step),
            "repair_attempts": [],
        }
        if req is not None:
            raw_req = _safe_raw(req.get("raw"), include_raw=include_raw, redact=redact)
            request_obj: Dict[str, Any] = {
                "ts": req.get("ts", ""),
                "text": str(req.get("text") or ""),
                "parsed": rich._parse_request_text(str(req.get("text") or "")),
            }
            if raw_req is not None:
                request_obj["raw"] = raw_req
            turn["request"] = request_obj

        if response is not None:
            raw_resp = _safe_raw(response.get("raw"), include_raw=include_raw, redact=redact)
            response_obj: Dict[str, Any] = {
                "ts": response.get("ts", ""),
                "content": str(response.get("content") or ""),
                "reasoning": str(response.get("reasoning") or ""),
                "action": action,
            }
            if parsed_json is not None:
                response_obj["parsed_json"] = parsed_json
            if raw_resp is not None:
                response_obj["raw"] = raw_resp
            turn["response"] = response_obj

        attempts: List[Dict[str, Any]] = []
        for attempt in rich._attempt_numbers(step_items):
            req_attempt = rich._find_attempt_item(step_items, "request", attempt)
            resp_attempt = rich._find_attempt_item(step_items, "response", attempt)
            parsed_attempt, action_attempt = _action_from_item(resp_attempt) if resp_attempt is not None else (None, None)
            attempt_obj: Dict[str, Any] = {"attempt": attempt}
            if req_attempt is not None:
                req_obj: Dict[str, Any] = {
                    "ts": req_attempt.get("ts", ""),
                    "text": str(req_attempt.get("text") or ""),
                }
                raw_req = _safe_raw(req_attempt.get("raw"), include_raw=include_raw, redact=redact)
                if raw_req is not None:
                    req_obj["raw"] = raw_req
                attempt_obj["request"] = req_obj
            if resp_attempt is not None:
                resp_obj: Dict[str, Any] = {
                    "ts": resp_attempt.get("ts", ""),
                    "content": str(resp_attempt.get("content") or ""),
                    "reasoning": str(resp_attempt.get("reasoning") or ""),
                    "action": action_attempt,
                }
                if parsed_attempt is not None:
                    resp_obj["parsed_json"] = parsed_attempt
                raw_resp = _safe_raw(resp_attempt.get("raw"), include_raw=include_raw, redact=redact)
                if raw_resp is not None:
                    resp_obj["raw"] = raw_resp
                attempt_obj["response"] = resp_obj
            attempts.append(attempt_obj)
        turn["repair_attempts"] = attempts
        turns.append(turn)

    return {
        "schema": "wda_ondevice_agent.trace.v1",
        "run_id": run_id,
        "exported_at": rich._now_iso(),
        "runner_url": base_url,
        "api_mode": cfg.get("api_mode", ""),
        "model": cfg.get("model", ""),
        "task": task,
        "system": {
            "source": prompt_source,
            "prompt": prompt,
        },
        "config": _source_config(status),
        "status": {
            "running": status.get("running"),
            "last_message": status.get("last_message", ""),
            "notes": status.get("notes", ""),
            "token_usage": status.get("token_usage", {}),
            "log_lines": status.get("log_lines"),
        },
        "counts": {
            "chat_items": len(items),
            "turns": len(turns),
            "images_saved": len(image_paths),
            "missing_images": len(missing_images),
        },
        "missing_image_steps": missing_images,
        "turns": turns,
    }


def _sample_meta(
    *,
    base_url: str,
    status: Dict[str, Any],
    response: Dict[str, Any],
    action: Dict[str, Any],
) -> Dict[str, Any]:
    cfg = status.get("config") if isinstance(status.get("config"), dict) else {}
    name = action.get("name") if isinstance(action.get("name"), str) else ""
    return {
        "runner_url": base_url,
        "source_model": cfg.get("model", ""),
        "api_mode": cfg.get("api_mode", ""),
        "response_ts": response.get("ts", ""),
        "attempt": response.get("attempt"),
        "terminal": name.strip().lower() in TERMINAL_ACTIONS,
    }


def _build_action_samples(
    *,
    run_id: str,
    base_url: str,
    status: Dict[str, Any],
    items: List[Dict[str, Any]],
    image_paths: Dict[int, str],
    allow_missing_images: bool,
    include_parsed_json: bool,
    include_raw: bool,
    redact: str,
) -> List[Dict[str, Any]]:
    cfg = status.get("config") if isinstance(status.get("config"), dict) else {}
    task = cfg.get("task") if isinstance(cfg.get("task"), str) else ""
    prompt_source, prompt = _system_prompt(status, items=items)

    samples: List[Dict[str, Any]] = []
    for step, step_items in rich._group_by_step(items):
        if step < 0:
            continue
        req = rich._primary_request(step_items)
        response, parsed_json, action = _best_action_response(step_items)
        if req is None or response is None or action is None:
            continue
        image_path = image_paths.get(step)
        if not image_path and not allow_missing_images:
            continue

        content = str(response.get("content") or "")
        reasoning = str(response.get("reasoning") or "")
        sample: Dict[str, Any] = {
            "id": f"{run_id}_step_{step:04d}",
            "run_id": run_id,
            "step": step,
            "task": task,
            "system": {
                "source": prompt_source,
                "prompt": prompt,
            },
            "input": {
                "text": str(req.get("text") or ""),
                "parsed": rich._parse_request_text(str(req.get("text") or "")),
                "image": image_path,
            },
            "assistant": {
                "content": content,
                "reasoning": reasoning,
                "action": action,
            },
            "meta": _sample_meta(base_url=base_url, status=status, response=response, action=action),
        }
        if include_parsed_json and parsed_json is not None:
            sample["assistant"]["parsed_json"] = parsed_json
        if include_raw:
            raw_req = req.get("raw") if isinstance(req.get("raw"), str) else ""
            raw_resp = response.get("raw") if isinstance(response.get("raw"), str) else ""
            if redact != "none":
                raw_req = rich._redact_sensitive_text(raw_req)
                raw_resp = rich._redact_sensitive_text(raw_resp)
            sample["raw"] = {
                "request": raw_req,
                "response": raw_resp,
            }
        samples.append(sample)
    return samples


def _message_user_text(sample: Dict[str, Any], *, messages_mode: str) -> Tuple[str, bool]:
    text = str(sample.get("input", {}).get("text") or "")
    if messages_mode != "standalone":
        return text, False
    task = str(sample.get("task") or "").strip()
    if not task or task in text:
        return text, False
    return f"Task: {task}\n\n{text}", True


def _build_messages(
    samples: List[Dict[str, Any]],
    *,
    include_reasoning: bool,
    messages_mode: str,
) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for sample in samples:
        user_text, task_prepended = _message_user_text(sample, messages_mode=messages_mode)
        user_content: List[Dict[str, Any]] = [
            {
                "type": "text",
                "text": user_text,
            }
        ]
        image = sample.get("input", {}).get("image")
        if image:
            user_content.append({"type": "image_url", "image_url": {"url": image}})

        assistant_content = sample.get("assistant", {}).get("content", "")
        if include_reasoning and sample.get("assistant", {}).get("reasoning"):
            assistant_content = (
                "<reasoning>\n"
                + sample["assistant"]["reasoning"]
                + "\n</reasoning>\n"
                + assistant_content
            )

        messages = []
        prompt = sample.get("system", {}).get("prompt")
        if prompt:
            messages.append({"role": "system", "content": prompt})
        messages.extend(
            [
                {"role": "user", "content": user_content},
                {"role": "assistant", "content": assistant_content},
            ]
        )
        meta = dict(sample.get("meta", {}))
        meta["messages_mode"] = messages_mode
        if task_prepended:
            meta["task_prepended_to_user"] = True
        out.append({"id": sample.get("id"), "messages": messages, "meta": meta})
    return out


def _audit_warnings(
    *,
    status: Dict[str, Any],
    items: List[Dict[str, Any]],
    samples: List[Dict[str, Any]],
    messages_mode: str,
    include_raw: bool,
    missing_images: List[int],
) -> List[Dict[str, Any]]:
    cfg = status.get("config") if isinstance(status.get("config"), dict) else {}
    api_mode = str(cfg.get("api_mode") or "")
    debug_raw = bool(cfg.get("debug_log_raw_assistant"))
    warnings: List[Dict[str, Any]] = []

    request_steps = rich._request_steps(items)
    if len(samples) != len(request_steps):
        warnings.append(
            {
                "code": "sample_count_mismatch",
                "message": "Some request steps did not become action samples, usually because a response/action or screenshot was missing.",
                "request_steps": len(request_steps),
                "action_samples": len(samples),
            }
        )

    if missing_images:
        warnings.append(
            {
                "code": "missing_screenshots",
                "message": "Some request-step screenshots were not available from the agent.",
                "steps": missing_images,
            }
        )

    raw_item_count = sum(1 for item in items if isinstance(item.get("raw"), str) and item.get("raw"))
    if api_mode == "responses" and raw_item_count == 0:
        warnings.append(
            {
                "code": "responses_raw_chain_absent",
                "message": "Responses API raw request/response bodies are absent, so previous_response_id and response id links cannot be reconstructed from this export.",
                "debug_log_raw_assistant": debug_raw,
            }
        )
    elif include_raw and raw_item_count == 0:
        warnings.append(
            {
                "code": "raw_fields_absent",
                "message": "--include-raw was requested, but the agent did not expose raw chat fields for this run.",
            }
        )

    missing_task_steps: List[int] = []
    for sample in samples:
        task = str(sample.get("task") or "").strip()
        if not task:
            continue
        user_text, _ = _message_user_text(sample, messages_mode=messages_mode)
        if task not in user_text:
            step = sample.get("step")
            if isinstance(step, int):
                missing_task_steps.append(step)
    if missing_task_steps:
        warnings.append(
            {
                "code": "messages_missing_task_context",
                "message": "Some messages.jsonl samples do not contain the original task in the user message; they depend on trace state or external sample.task.",
                "messages_mode": messages_mode,
                "steps": missing_task_steps[:20],
                "total": len(missing_task_steps),
            }
        )

    _, prompt = _system_prompt(status, items=items)
    if "{{DATE_" in prompt:
        warnings.append(
            {
                "code": "system_prompt_template_unrendered",
                "message": "The exported system prompt still contains date template placeholders; the runtime request used a rendered prompt.",
            }
        )

    log_lines = status.get("log_lines")
    if isinstance(log_lines, int) and log_lines >= 300:
        warnings.append(
            {
                "code": "logs_may_be_truncated",
                "message": "Agent logs reached the in-memory line cap, so logs.json may not include the beginning of the run.",
                "log_lines": log_lines,
            }
        )
    return warnings


def _build_repair_samples(
    *,
    run_id: str,
    base_url: str,
    status: Dict[str, Any],
    items: List[Dict[str, Any]],
    image_paths: Dict[int, str],
    include_raw: bool,
    redact: str,
) -> List[Dict[str, Any]]:
    samples: List[Dict[str, Any]] = []
    for step, step_items in rich._group_by_step(items):
        for attempt in rich._attempt_numbers(step_items):
            req = rich._find_attempt_item(step_items, "request", attempt)
            resp = rich._find_attempt_item(step_items, "response", attempt)
            if req is None or resp is None:
                continue
            parsed_json, action = _action_from_item(resp)
            content = str(resp.get("content") or "")
            sample: Dict[str, Any] = {
                "id": f"{run_id}_repair_step_{step:04d}_attempt_{attempt}",
                "run_id": run_id,
                "step": step,
                "attempt": attempt,
                "input": {
                    "repair_prompt": str(req.get("text") or ""),
                    "image": image_paths.get(step),
                },
                "assistant": {
                    "content": content,
                    "reasoning": str(resp.get("reasoning") or ""),
                    "action": action,
                    "parsed_json": parsed_json,
                },
                "meta": {
                    "runner_url": base_url,
                    "response_ts": resp.get("ts", ""),
                },
            }
            if include_raw:
                raw_req = req.get("raw") if isinstance(req.get("raw"), str) else ""
                raw_resp = resp.get("raw") if isinstance(resp.get("raw"), str) else ""
                if redact != "none":
                    raw_req = rich._redact_sensitive_text(raw_req)
                    raw_resp = rich._redact_sensitive_text(raw_resp)
                sample["raw"] = {
                    "request": raw_req,
                    "response": raw_resp,
                }
            samples.append(sample)
    return samples


def _http_get_text(base_url: str, path: str, *, token: str, timeout: float) -> str:
    headers = {"Accept": "application/x-ndjson,text/plain,*/*"}
    if token.strip():
        headers["X-OnDevice-Agent-Token"] = token.strip()
    req = urllib.request.Request(rich._join_url(base_url, path), method="GET", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
            charset = resp.headers.get_content_charset() or "utf-8"
            return body.decode(charset, errors="replace")
    except urllib.error.HTTPError as e:
        body = e.read() if e.fp else b""
        msg = body.decode("utf-8", errors="replace")
        raise rich.ApiError(f"HTTP {e.code} {e.reason} for {req.full_url}\n{msg[:2000]}") from e
    except urllib.error.URLError as e:
        raise rich.ApiError(f"Failed to connect to {req.full_url}: {e}") from e
    except Exception as e:  # noqa: BLE001
        raise rich.ApiError(f"Request failed for {req.full_url}: {e}") from e


def _trace_query_path(endpoint: str, **params: str) -> str:
    return endpoint + "?" + urllib.parse.urlencode({k: v for k, v in params.items() if v})


def _canonical_run_id(args: argparse.Namespace, *, token: str) -> str:
    requested = _safe_id(args.trace_run_id) if args.trace_run_id else ""
    if requested:
        return requested
    obj = rich._unwrap_wda_value(
        rich._http_get_json(args.base_url, "/agent/traces", token=token, timeout=args.timeout)
    )
    if not isinstance(obj, dict) or not isinstance(obj.get("items"), list):
        raise rich.ApiError("Unexpected /agent/traces response")
    for item in obj["items"]:
        if isinstance(item, dict) and isinstance(item.get("run_id"), str) and item["run_id"].strip():
            return item["run_id"].strip()
    raise rich.ApiError("No canonical traces are available on the agent")


def _canonical_manifest(args: argparse.Namespace, *, token: str, run_id: str) -> Dict[str, Any]:
    path = _trace_query_path("/agent/trace/manifest", run_id=run_id)
    obj = rich._unwrap_wda_value(rich._http_get_json(args.base_url, path, token=token, timeout=args.timeout))
    if isinstance(obj, dict) and isinstance(obj.get("manifest"), dict):
        return obj["manifest"]
    if isinstance(obj, dict) and obj.get("ok") is False:
        raise rich.ApiError(str(obj.get("error") or "Trace manifest not found"))
    raise rich.ApiError("Unexpected /agent/trace/manifest response")


def _canonical_turns(args: argparse.Namespace, *, token: str, run_id: str) -> List[Dict[str, Any]]:
    path = _trace_query_path("/agent/trace/turns", run_id=run_id)
    text = _http_get_text(args.base_url, path, token=token, timeout=args.timeout)
    turns: List[Dict[str, Any]] = []
    for i, line in enumerate(text.splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError as e:
            raise rich.ApiError(f"Invalid JSONL in canonical turns at line {i}: {e}") from e
        if isinstance(obj, dict):
            turns.append(obj)
    return turns


def _save_canonical_images(
    *,
    args: argparse.Namespace,
    token: str,
    out_dir: Path,
    run_id: str,
    turns: List[Dict[str, Any]],
) -> Tuple[Dict[int, str], List[int]]:
    image_paths: Dict[int, str] = {}
    missing: List[int] = []
    seen_refs: set[str] = set()
    for turn in turns:
        step = rich._to_int(turn.get("step"))
        state = turn.get("state") if isinstance(turn.get("state"), dict) else {}
        image = state.get("image") if isinstance(state.get("image"), dict) else {}
        ref = image.get("ref") if isinstance(image.get("ref"), str) else ""
        if step < 0 or not ref:
            if step >= 0:
                missing.append(step)
            continue
        rel = Path(ref)
        if rel.is_absolute() or ".." in rel.parts:
            missing.append(step)
            continue
        if ref in seen_refs:
            image_paths[step] = rel.as_posix()
            continue
        seen_refs.add(ref)
        path = _trace_query_path("/agent/trace/file", run_id=run_id, path=ref)
        obj = rich._unwrap_wda_value(rich._http_get_json(args.base_url, path, token=token, timeout=args.timeout))
        if not isinstance(obj, dict) or obj.get("ok") is not True or not isinstance(obj.get("base64"), str):
            missing.append(step)
            continue
        data = _decode_image(obj["base64"])
        if not data:
            missing.append(step)
            continue
        target = out_dir / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        image_paths[step] = rel.as_posix()
    return image_paths, sorted(set(missing))


def _canonical_assistant(turn: Dict[str, Any]) -> Tuple[Dict[str, Any], Optional[Dict[str, Any]], Optional[Dict[str, Any]]]:
    parse = turn.get("parse") if isinstance(turn.get("parse"), dict) else {}
    action_json = parse.get("action") if isinstance(parse.get("action"), dict) else None
    action_obj = action_json.get("action") if isinstance(action_json, dict) and isinstance(action_json.get("action"), dict) else None
    response = turn.get("model_response") if isinstance(turn.get("model_response"), dict) else {}
    attempt_used = rich._to_int(parse.get("attempt_used"))
    if attempt_used > 0:
        attempts = turn.get("repair_attempts") if isinstance(turn.get("repair_attempts"), list) else []
        for attempt in attempts:
            if not isinstance(attempt, dict) or rich._to_int(attempt.get("attempt")) != attempt_used:
                continue
            repair_response = attempt.get("response") if isinstance(attempt.get("response"), dict) else None
            if repair_response is not None:
                response = repair_response
                break
    return response, action_json, action_obj


def _build_canonical_samples(
    *,
    run_id: str,
    base_url: str,
    manifest: Dict[str, Any],
    turns: List[Dict[str, Any]],
    image_paths: Dict[int, str],
    allow_missing_images: bool,
    include_parsed_json: bool,
) -> List[Dict[str, Any]]:
    config = manifest.get("config") if isinstance(manifest.get("config"), dict) else {}
    system = manifest.get("system_prompt") if isinstance(manifest.get("system_prompt"), dict) else {}
    prompt = system.get("rendered") if isinstance(system.get("rendered"), str) else ""
    task = manifest.get("task") if isinstance(manifest.get("task"), str) else ""
    samples: List[Dict[str, Any]] = []
    for turn in turns:
        step = rich._to_int(turn.get("step"))
        if step < 0:
            continue
        response, parsed_json, action = _canonical_assistant(turn)
        if action is None:
            continue
        image_path = image_paths.get(step)
        if not image_path and not allow_missing_images:
            continue
        state = turn.get("state") if isinstance(turn.get("state"), dict) else {}
        user_text = state.get("user_text") if isinstance(state.get("user_text"), str) else ""
        action_name = action.get("name") if isinstance(action.get("name"), str) else ""
        sample: Dict[str, Any] = {
            "id": f"{run_id}_step_{step:04d}",
            "run_id": run_id,
            "step": step,
            "task": task,
            "system": {
                "source": "runtime",
                "prompt": prompt,
            },
            "input": {
                "text": user_text,
                "parsed": rich._parse_request_text(user_text),
                "image": image_path,
            },
            "assistant": {
                "content": str(response.get("content") or ""),
                "reasoning": str(response.get("reasoning") or ""),
                "action": action,
            },
            "meta": {
                "runner_url": base_url,
                "source_model": config.get("model", ""),
                "api_mode": config.get("api_mode", ""),
                "response_id": response.get("response_id", ""),
                "terminal": action_name.strip().lower() in TERMINAL_ACTIONS,
                "canonical_source": True,
            },
        }
        if include_parsed_json and parsed_json is not None:
            sample["assistant"]["parsed_json"] = parsed_json
        samples.append(sample)
    return samples


def _build_canonical_repair_samples(
    *,
    run_id: str,
    base_url: str,
    turns: List[Dict[str, Any]],
    image_paths: Dict[int, str],
) -> List[Dict[str, Any]]:
    samples: List[Dict[str, Any]] = []
    for turn in turns:
        step = rich._to_int(turn.get("step"))
        if step < 0:
            continue
        attempts = turn.get("repair_attempts") if isinstance(turn.get("repair_attempts"), list) else []
        for attempt_obj in attempts:
            if not isinstance(attempt_obj, dict):
                continue
            attempt = rich._to_int(attempt_obj.get("attempt"))
            if attempt < 0:
                continue
            response = attempt_obj.get("response") if isinstance(attempt_obj.get("response"), dict) else {}
            content = str(response.get("content") or "")
            parsed_json, action = _action_from_item({"content": content})
            samples.append(
                {
                    "id": f"{run_id}_repair_step_{step:04d}_attempt_{attempt}",
                    "run_id": run_id,
                    "step": step,
                    "attempt": attempt,
                    "input": {
                        "repair_prompt": str(attempt_obj.get("request_text") or ""),
                        "image": image_paths.get(step),
                    },
                    "assistant": {
                        "content": content,
                        "reasoning": str(response.get("reasoning") or ""),
                        "action": action,
                        "parsed_json": parsed_json,
                    },
                    "meta": {
                        "runner_url": base_url,
                        "response_id": response.get("response_id", ""),
                        "canonical_source": True,
                    },
                }
            )
    return samples


def _canonical_trace(manifest: Dict[str, Any], turns: List[Dict[str, Any]], *, base_url: str, run_id: str, image_paths: Dict[int, str], missing_images: List[int]) -> Dict[str, Any]:
    return {
        "schema": "wda_ondevice_agent.trace.v2",
        "run_id": run_id,
        "exported_at": rich._now_iso(),
        "runner_url": base_url,
        "manifest": manifest,
        "counts": {
            "turns": len(turns),
            "images_saved": len(image_paths),
            "missing_images": len(missing_images),
        },
        "missing_image_steps": missing_images,
        "turns": turns,
    }


def _cmd_export_canonical(args: argparse.Namespace, *, token: str, out_dir: Path) -> int:
    run_id = _canonical_run_id(args, token=token)
    manifest = _canonical_manifest(args, token=token, run_id=run_id)
    turns = _canonical_turns(args, token=token, run_id=run_id)
    print(f"source: canonical", flush=True)
    print(f"run_id: {run_id}", flush=True)
    print(f"turns: {len(turns)}", flush=True)

    image_paths, missing = _save_canonical_images(args=args, token=token, out_dir=out_dir, run_id=run_id, turns=turns)
    print(f"images saved: {len(image_paths)}", flush=True)
    if missing:
        print("missing screenshots: " + ",".join(str(x) for x in missing), flush=True)

    samples = _build_canonical_samples(
        run_id=run_id,
        base_url=args.base_url,
        manifest=manifest,
        turns=turns,
        image_paths=image_paths,
        allow_missing_images=args.allow_missing_images,
        include_parsed_json=args.include_parsed_json,
    )
    messages_mode = args.messages_mode
    if messages_mode not in MESSAGES_MODES:
        raise rich.ApiError(f"Invalid messages mode: {messages_mode}")
    messages = _build_messages(
        samples,
        include_reasoning=args.include_reasoning_in_messages,
        messages_mode=messages_mode,
    )
    repair_samples = (
        _build_canonical_repair_samples(
            run_id=run_id,
            base_url=args.base_url,
            turns=turns,
            image_paths=image_paths,
        )
        if args.include_repair_samples
        else []
    )
    trace = _canonical_trace(
        manifest,
        turns,
        base_url=args.base_url,
        run_id=run_id,
        image_paths=image_paths,
        missing_images=missing,
    )
    config = manifest.get("config") if isinstance(manifest.get("config"), dict) else {}
    system = manifest.get("system_prompt") if isinstance(manifest.get("system_prompt"), dict) else {}
    audit_warnings: List[Dict[str, Any]] = []
    if missing:
        audit_warnings.append(
            {
                "code": "missing_canonical_images",
                "message": "Some canonical trace image files could not be fetched.",
                "steps": missing,
            }
        )
    run_meta = {
        "run_id": run_id,
        "exported_at": rich._now_iso(),
        "runner_url": args.base_url,
        "source": "canonical",
        "source_config": config,
        "system_prompt": {
            "source": "runtime",
            "prompt": system.get("rendered", ""),
        },
        "counts": {
            "trace_turns": len(turns),
            "images_saved": len(image_paths),
            "missing_images": len(missing),
            "action_samples": len(samples),
            "messages": len(messages),
            "repair_samples": len(repair_samples),
        },
        "canonical": {
            "file": "trace.json",
            "schema": trace.get("schema"),
            "runtime_schema": manifest.get("schema", ""),
        },
        "derived": {
            "dataset": {"file": "dataset.jsonl", "kind": "state_action_samples"},
            "messages": {
                "file": "messages.jsonl",
                "kind": "chat_sft_samples",
                "mode": messages_mode,
                "reasoning_included": bool(args.include_reasoning_in_messages),
            },
            "repair_samples": {
                "file": "repair_samples.jsonl" if args.include_repair_samples else None,
                "kind": "repair_attempt_samples",
            },
        },
        "audit": {"warnings": audit_warnings},
        "missing_image_steps": missing,
        "files": {
            "trace": "trace.json",
            "dataset": "dataset.jsonl",
            "messages": "messages.jsonl",
            "run_meta": "run_meta.json",
            "images": "images/",
            "repair_samples": "repair_samples.jsonl" if args.include_repair_samples else None,
        },
    }

    _write_json(out_dir / "trace.json", trace)
    _write_text(out_dir / "dataset.jsonl", _jsonl(samples))
    _write_text(out_dir / "messages.jsonl", _jsonl(messages))
    _write_json(out_dir / "run_meta.json", run_meta)
    _write_json(out_dir / "manifest.json", manifest)
    _write_text(out_dir / "turns.jsonl", _jsonl(turns))
    if args.include_repair_samples:
        _write_text(out_dir / "repair_samples.jsonl", _jsonl(repair_samples))

    print(f"action samples: {len(samples)}", flush=True)
    print(f"messages: {len(messages)}", flush=True)
    if args.include_repair_samples:
        print(f"repair samples: {len(repair_samples)}", flush=True)
    if audit_warnings:
        print(f"audit warnings: {len(audit_warnings)}", flush=True)
    print(f"wrote dataset: {out_dir}", flush=True)
    return 0


def cmd_export(args: argparse.Namespace) -> int:
    token = (args.agent_token or "").strip()
    out_dir = Path(args.out_dir)
    if args.source in {"auto", "canonical"}:
        try:
            return _cmd_export_canonical(args, token=token, out_dir=out_dir)
        except rich.ApiError as e:
            if args.source == "canonical":
                raise
            print(f"[warn] canonical source unavailable, falling back to legacy export: {e}", file=sys.stderr, flush=True)

    print("source: legacy", flush=True)
    status = rich._unwrap_wda_value(
        rich._http_get_json(
            args.base_url,
            "/agent/status?include_default_system_prompt=1",
            token=token,
            timeout=args.timeout,
        )
    )
    chat = rich._unwrap_wda_value(rich._http_get_json(args.base_url, "/agent/chat", token=token, timeout=args.timeout))
    logs = rich._unwrap_wda_value(rich._http_get_json(args.base_url, "/agent/logs", token=token, timeout=args.timeout))
    if not isinstance(status, dict):
        raise rich.ApiError("Unexpected /agent/status response")
    if not isinstance(chat, dict) or not isinstance(chat.get("items"), list):
        raise rich.ApiError("Unexpected /agent/chat response")
    if not isinstance(logs, dict):
        logs = {}

    items = [item for item in chat["items"] if isinstance(item, dict)]
    run_id = _safe_id(args.run_id) if args.run_id else _default_run_id(items)
    steps = rich._request_steps(items)
    if args.max_screenshot_steps and args.max_screenshot_steps > 0:
        steps = steps[-args.max_screenshot_steps :]

    print(f"run_id: {run_id}", flush=True)
    print(f"chat items: {len(items)}", flush=True)
    print(f"screenshot steps requested: {len(steps)}", flush=True)

    mime_type, screenshots, missing = rich._fetch_screenshots(
        base_url=args.base_url,
        token=token,
        timeout=args.timeout,
        steps=steps,
        image_format=args.image_format,
        quality=args.quality,
        chunk_size=args.chunk_size,
    )
    image_paths = _save_images(
        out_dir=out_dir,
        image_format=args.image_format,
        mime_type=mime_type,
        screenshots=screenshots,
    )
    print(f"images saved: {len(image_paths)}", flush=True)
    if missing:
        print("missing screenshots: " + ",".join(str(x) for x in missing), flush=True)

    samples = _build_action_samples(
        run_id=run_id,
        base_url=args.base_url,
        status=status,
        items=items,
        image_paths=image_paths,
        allow_missing_images=args.allow_missing_images,
        include_parsed_json=args.include_parsed_json,
        include_raw=args.include_raw,
        redact=args.redact,
    )
    trace = _build_trace(
        run_id=run_id,
        base_url=args.base_url,
        status=status,
        items=items,
        image_paths=image_paths,
        missing_images=missing,
        include_raw=args.include_raw,
        redact=args.redact,
    )
    messages_mode = args.messages_mode
    if messages_mode not in MESSAGES_MODES:
        raise rich.ApiError(f"Invalid messages mode: {messages_mode}")
    messages = _build_messages(
        samples,
        include_reasoning=args.include_reasoning_in_messages,
        messages_mode=messages_mode,
    )
    repair_samples = (
        _build_repair_samples(
            run_id=run_id,
            base_url=args.base_url,
            status=status,
            items=items,
            image_paths=image_paths,
            include_raw=args.include_raw,
            redact=args.redact,
        )
        if args.include_repair_samples
        else []
    )

    prompt_source, prompt = _system_prompt(status, items=items)
    audit_warnings = _audit_warnings(
        status=status,
        items=items,
        samples=samples,
        messages_mode=messages_mode,
        include_raw=args.include_raw,
        missing_images=missing,
    )
    run_meta = {
        "run_id": run_id,
        "exported_at": rich._now_iso(),
        "runner_url": args.base_url,
        "source_config": _source_config(status),
        "system_prompt": {
            "source": prompt_source,
            "prompt": prompt,
        },
        "status": {
            "running": status.get("running"),
            "last_message": status.get("last_message", ""),
            "notes": status.get("notes", ""),
            "token_usage": status.get("token_usage", {}),
            "log_lines": status.get("log_lines"),
        },
        "counts": {
            "chat_items": len(items),
            "request_steps": len(rich._request_steps(items)),
            "images_saved": len(image_paths),
            "missing_images": len(missing),
            "action_samples": len(samples),
            "messages": len(messages),
            "repair_samples": len(repair_samples),
            "trace_turns": len(trace.get("turns", [])),
        },
        "canonical": {
            "file": "trace.json",
            "schema": trace.get("schema"),
            "description": "Canonical run-level trace. Derived JSONL files should be regenerated from this when possible.",
        },
        "derived": {
            "dataset": {
                "file": "dataset.jsonl",
                "kind": "state_action_samples",
                "description": "One sample per request step, derived from trace turns.",
            },
            "messages": {
                "file": "messages.jsonl",
                "kind": "chat_sft_samples",
                "mode": messages_mode,
                "reasoning_included": bool(args.include_reasoning_in_messages),
                "description": "Compatibility export for chat-style SFT loaders.",
            },
            "repair_samples": {
                "file": "repair_samples.jsonl" if args.include_repair_samples else None,
                "kind": "repair_attempt_samples",
            },
        },
        "messages": {
            "mode": messages_mode,
            "reasoning_included": bool(args.include_reasoning_in_messages),
        },
        "audit": {
            "warnings": audit_warnings,
        },
        "missing_image_steps": missing,
        "files": {
            "trace": "trace.json",
            "dataset": "dataset.jsonl",
            "messages": "messages.jsonl",
            "run_meta": "run_meta.json",
            "chat": "chat.json",
            "images": "images/",
            "repair_samples": "repair_samples.jsonl" if args.include_repair_samples else None,
        },
    }

    _write_json(out_dir / "trace.json", trace)
    _write_text(out_dir / "dataset.jsonl", _jsonl(samples))
    _write_text(out_dir / "messages.jsonl", _jsonl(messages))
    _write_json(out_dir / "run_meta.json", run_meta)
    _write_json(out_dir / "status.json", status)
    _write_json(out_dir / "chat.json", _chat_snapshot(chat, redact=args.redact))
    _write_json(out_dir / "logs.json", logs)
    if args.include_repair_samples:
        _write_text(out_dir / "repair_samples.jsonl", _jsonl(repair_samples))

    print(f"action samples: {len(samples)}", flush=True)
    print(f"messages: {len(messages)}", flush=True)
    if audit_warnings:
        print(f"audit warnings: {len(audit_warnings)}", flush=True)
    print(f"wrote dataset: {out_dir}", flush=True)
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="wda_training_export.py",
        description="Export WDA on-device agent traces as multimodal LLM training data.",
    )
    p.add_argument("--base-url", default=DEFAULT_BASE_URL, help=f"WDA base URL (default: {DEFAULT_BASE_URL})")
    p.add_argument("--agent-token", default=DEFAULT_AGENT_TOKEN, help="Agent token for LAN access (or WDA_AGENT_TOKEN)")
    p.add_argument("--timeout", type=float, default=120.0, help="HTTP timeout in seconds")
    p.add_argument("--out-dir", required=True, help="Output dataset directory")
    p.add_argument("--run-id", default="", help="Stable run id; defaults to first chat timestamp")
    p.add_argument("--source", choices=["auto", "canonical", "legacy"], default="auto", help="Trace source; auto prefers the canonical on-device trace API and falls back to legacy chat export")
    p.add_argument("--trace-run-id", default="", help="Canonical trace run_id to export; defaults to the newest on-device trace")
    p.add_argument("--image-format", choices=["png", "jpeg", "jpg"], default="png", help="Saved screenshot format")
    p.add_argument("--quality", type=float, default=0.7, help="JPEG quality in (0, 1], ignored for PNG")
    p.add_argument("--chunk-size", type=int, default=30, help="Screenshot batch size")
    p.add_argument("--max-screenshot-steps", type=int, default=0, help="If > 0, save images only for the last N request steps")
    p.add_argument("--allow-missing-images", action="store_true", help="Keep samples even when their screenshot is missing")
    p.add_argument("--include-parsed-json", action="store_true", help="Include full parsed assistant JSON next to action")
    p.add_argument("--include-raw", action="store_true", help="Include raw request/response fields when present")
    p.add_argument("--include-repair-samples", action="store_true", help="Write repair_samples.jsonl from action-repair attempts")
    p.add_argument("--include-reasoning-in-messages", action="store_true", help="Also embed reasoning in messages.jsonl assistant text")
    p.add_argument(
        "--messages-mode",
        choices=sorted(MESSAGES_MODES),
        default="standalone",
        help="messages.jsonl format: standalone prepends task context to each sample; trace preserves runtime request text",
    )
    p.add_argument("--redact", choices=["safe", "minimal", "none"], default="safe", help="Redaction mode for optional raw fields")
    p.set_defaults(func=cmd_export)
    return p


def main(argv: List[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except KeyboardInterrupt:
        return 130
    except rich.ApiError as e:
        print(f"[error] {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
