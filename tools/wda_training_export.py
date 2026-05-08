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
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import wda_export_common as rich


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


def _decode_image(data_b64: str) -> bytes:
    try:
        return base64.b64decode(data_b64.encode("ascii"), validate=False)
    except Exception:
        return b""


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
    return _cmd_export_canonical(args, token=token, out_dir=out_dir)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="wda_training_export.py",
        description="Export WDA on-device agent traces as multimodal LLM training data.",
    )
    p.add_argument("--base-url", default=DEFAULT_BASE_URL, help=f"WDA base URL (default: {DEFAULT_BASE_URL})")
    p.add_argument("--agent-token", default=DEFAULT_AGENT_TOKEN, help="Agent token for LAN access (or WDA_AGENT_TOKEN)")
    p.add_argument("--timeout", type=float, default=120.0, help="HTTP timeout in seconds")
    p.add_argument("--out-dir", required=True, help="Output dataset directory")
    p.add_argument("--trace-run-id", default="", help="Canonical trace run_id to export; defaults to the newest on-device trace")
    p.add_argument("--allow-missing-images", action="store_true", help="Keep samples even when their screenshot is missing")
    p.add_argument("--include-parsed-json", action="store_true", help="Include full parsed assistant JSON next to action")
    p.add_argument("--include-repair-samples", action="store_true", help="Write repair_samples.jsonl from action-repair attempts")
    p.add_argument("--include-reasoning-in-messages", action="store_true", help="Also embed reasoning in messages.jsonl assistant text")
    p.add_argument(
        "--messages-mode",
        choices=sorted(MESSAGES_MODES),
        default="standalone",
        help="messages.jsonl format: standalone prepends task context to each sample; trace preserves runtime request text",
    )
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
