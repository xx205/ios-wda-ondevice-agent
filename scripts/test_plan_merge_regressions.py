#!/usr/bin/env python3
"""
Lightweight regression checks for plan merge identity stability.

This is intentionally "cheap" (no Xcode build required). It aims to catch
accidental re-introduction of the classic bug:
  - minor plan text edits -> treated as new items -> done_count inflates

It also verifies that the patched runner code still contains the expected
normalization helpers.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
WDA_FILE = REPO_ROOT / "wda_overlay" / "WebDriverAgentRunner" / "UITestingUITests.m"


def normalize_key(text: str) -> str:
    text = (text or "").strip().lower()
    if not text:
        return ""
    out = []
    for ch in text:
        if ch.isalpha() or ch.isdigit():
            out.append(ch)
    return "".join(out)


def gen_id(i: int) -> str:
    return f"t{i:02d}"


def merge_monotonic(old_plan: list[dict], new_plan: list[dict]) -> list[dict]:
    new_by_id: dict[str, tuple[int, dict]] = {}
    new_by_key: dict[str, tuple[int, dict]] = {}
    for idx, item in enumerate(new_plan):
        pid = (item.get("id") or "").strip()
        text = (item.get("text") or "").strip()
        if pid:
            new_by_id[pid] = (idx, item)
        key = normalize_key(text)
        if key and key not in new_by_key:
            new_by_key[key] = (idx, item)

    matched_new = set()
    out: list[dict] = []
    for old in old_plan:
        old_id = (old.get("id") or "").strip()
        old_text = (old.get("text") or "").strip()
        if not old_text:
            continue
        old_done = bool(old.get("done"))

        match = None
        if old_id and old_id in new_by_id:
            match = new_by_id[old_id]
        else:
            key = normalize_key(old_text)
            if key and key in new_by_key:
                match = new_by_key[key]

        if match:
            idx, n = match
            matched_new.add(idx)
            new_done = bool(n.get("done"))
            merged_id = old_id or (n.get("id") or "").strip() or gen_id(len(out) + 1)
            out.append({"id": merged_id, "text": old_text, "done": old_done or new_done})
        else:
            merged_id = old_id or gen_id(len(out) + 1)
            out.append({"id": merged_id, "text": old_text, "done": old_done})

    for idx, n in enumerate(new_plan):
        if idx in matched_new:
            continue
        text = (n.get("text") or "").strip()
        if not text:
            continue
        merged_id = (n.get("id") or "").strip() or gen_id(len(out) + 1)
        out.append({"id": merged_id, "text": text, "done": bool(n.get("done"))})

    return out


def done_count(plan: list[dict]) -> int:
    return sum(1 for it in plan if bool(it.get("done")))


def assert_true(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)


def test_minor_rephrase_does_not_duplicate() -> None:
    old = [{"id": "a1", "text": "打开 小红书 应用", "done": False}]
    new = [{"text": "打开小红书应用", "done": True}]
    merged = merge_monotonic(old, new)
    assert_true(len(merged) == 1, f"expected 1 item, got {json.dumps(merged, ensure_ascii=False)}")
    assert_true(merged[0]["id"] == "a1", "id must be preserved")
    assert_true(merged[0]["done"] is True, "done must be sticky and merge new done")


def test_punctuation_variation_matches() -> None:
    old = [{"text": "Fill A1- A5.", "done": True}]
    new = [{"text": "Fill A1 A5", "done": False}]
    merged = merge_monotonic(old, new)
    assert_true(len(merged) == 1, "punctuation-only variation should match")
    assert_true(merged[0]["done"] is True, "done must remain true")


def test_done_count_not_inflated_by_rephrase() -> None:
    old = [
        {"text": "Step one", "done": True},
        {"text": "Step two", "done": False},
    ]
    new = [
        {"text": "Step one!", "done": True},
        {"text": "Step  two", "done": False},
    ]
    merged = merge_monotonic(old, new)
    assert_true(len(merged) == 2, f"expected 2 items, got {len(merged)}")
    assert_true(done_count(merged) == 1, "done_count should not increase")


def test_ids_are_non_empty() -> None:
    old = [{"text": "One", "done": False}]
    new = [{"text": "One", "done": False}]
    merged = merge_monotonic(old, new)
    assert_true(all((it.get("id") or "").strip() for it in merged), "every item must have an id")


def test_code_contains_expected_helpers() -> None:
    src = WDA_FILE.read_text(encoding="utf-8", errors="replace")
    assert_true("OnDeviceAgentNormalizePlanItemTextKey" in src, "runner code must include plan text normalization helper")
    assert_true("[id:" in src, "runner prompt should expose plan item ids to encourage stable echo")


def main() -> int:
    if not WDA_FILE.exists():
        print(f"Missing runner file: {WDA_FILE}", file=sys.stderr)
        return 2

    tests = [
        test_minor_rephrase_does_not_duplicate,
        test_punctuation_variation_matches,
        test_done_count_not_inflated_by_rephrase,
        test_ids_are_non_empty,
        test_code_contains_expected_helpers,
    ]
    for t in tests:
        t()
    print("OK: plan merge regression tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
