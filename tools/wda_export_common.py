#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
from datetime import datetime
from typing import Any, Dict, List, Optional


class ApiError(RuntimeError):
    pass


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


def _clean_lines(lines: List[str]) -> str:
    return "\n".join(lines).strip()


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
